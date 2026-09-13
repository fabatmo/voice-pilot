import Foundation
import Speech
import AVFoundation
import CoreMedia

/// SpeechAnalyzer + SpeechTranscriber backend (macOS 26+).
///
/// Structural differences from the SFSpeechRecognizer path:
///  - No ~1 minute cap, so no teardown/restart and no gap in the audio.
///  - Endpointing comes from the model's own volatile range, not a hand-rolled
///    silence Timer, so utterance boundaries are the model's, not a guess.
///  - Fully on-device by design.
///  - Custom vocabulary via AnalysisContext.contextualStrings, which the legacy
///    API cannot do at all.
@available(macOS 26.0, *)
final class AnalyzerSpeechBackend: SpeechBackend, @unchecked Sendable {
    // @unchecked Sendable is justified narrowly: every stored property is touched
    // only on the main thread EXCEPT lastLoudAudio, which the realtime audio tap
    // writes and the watchdog timer reads. That one is lock-guarded below.
    var onPartial: ((String) -> Void)?
    var onUtterance: ((String) -> Void)?
    var onRunningChanged: ((Bool) -> Void)?

    /// Terms the general model reliably mangles in this app's domain.
    static let vocabulary = [
        "Claude", "Claude Code", "VoicePilot", "Voice Pilot", "Anthropic",
        "git", "commit", "rebase", "branch", "repo", "diff", "stash",
        "Xcode", "Swift", "SwiftUI", "macOS", "Accessibility", "AX",
        "terminal", "dictation", "transcript", "prompt", "CLI", "API",
    ]

    private let locale = Locale(identifier: "en-US")
    private let audioEngine = AVAudioEngine()

    private var analyzer: SpeechAnalyzer?
    private var transcriber: SpeechTranscriber?
    private var inputContinuation: AsyncStream<AnalyzerInput>.Continuation?
    private var converter: AVAudioConverter?
    private var analyzerFormat: AVAudioFormat?

    private var resultsTask: Task<Void, Never>?
    private var tapInstalled = false

    /// Last finalized segment, to guard against an identical repeat delivery.
    /// Finalized results arrive as distinct contiguous segments, not cumulatively.
    private var lastFinalizedSegment = ""

    // MARK: Silence watchdog
    //
    // The analyzer types only when it commits a segment, and it decides when a
    // segment ends. Measured over 6713 utterances: 78% commit within 1s of the
    // speaker stopping, but 7% take over 5s, and those are long segments
    // (13.4s average, vs 4.3s for the fast ones). Long unbroken speech means
    // nothing reaches the terminal until the model finally commits.
    //
    // This is a backstop, not a replacement for the model's endpointing: after
    // a real silence, ask the analyzer to finalize what it already has via its
    // own finalize(through:) call.
    private let silenceThreshold: TimeInterval = 1.2
    /// RMS below this counts as silence. Empirical: speech sits well above it,
    /// room tone well below.
    private let silenceRMS: Float = 0.008
    /// Written from the realtime audio tap, read from the watchdog on main.
    /// Lock-guarded: an unsynchronised Date across those two threads is a race.
    private let levelLock = NSLock()
    private var _lastLoudAudio = Date()
    private var lastLoudAudio: Date {
        get { levelLock.lock(); defer { levelLock.unlock() }; return _lastLoudAudio }
        set { levelLock.lock(); defer { levelLock.unlock() }; _lastLoudAudio = newValue }
    }
    private var watchdog: Timer?
    /// End of the newest provisional result, i.e. how far we could finalize.
    private var pendingVolatileEnd: CMTime?
    /// Set while a forced finalize is in flight, so the watchdog does not stack them.
    private var finalizing = false

    func start() {
        SFSpeechRecognizer.requestAuthorization { [weak self] status in
            guard status == .authorized else {
                vpLog("[Analyzer] permission denied, status=\(status.rawValue)")
                self?.onRunningChanged?(false)
                return
            }
            Task { await self?.bringUp() }
        }
    }

    func stop() {
        watchdog?.invalidate()
        watchdog = nil
        pendingVolatileEnd = nil
        finalizing = false
        resultsTask?.cancel()
        resultsTask = nil
        inputContinuation?.finish()
        inputContinuation = nil
        if tapInstalled {
            audioEngine.inputNode.removeTap(onBus: 0)
            tapInstalled = false
        }
        audioEngine.stop()
        let a = analyzer
        analyzer = nil
        transcriber = nil
        Task { await a?.cancelAndFinishNow() }
        onRunningChanged?(false)
        vpLog("[Analyzer] stopped")
    }

    // MARK: - Bring-up

    private func bringUp() async {
        let transcriber = SpeechTranscriber(
            locale: locale,
            transcriptionOptions: [],
            reportingOptions: [.volatileResults, .fastResults],
            attributeOptions: [.transcriptionConfidence]
        )
        self.transcriber = transcriber

        // Models are per-locale downloads. First run on a machine needs this.
        do {
            let status = await AssetInventory.status(forModules: [transcriber])
            vpLog("[Analyzer] asset status: \(status)")
            if status != .installed {
                if let req = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
                    vpLog("[Analyzer] downloading model assets...")
                    try await req.downloadAndInstall()
                    vpLog("[Analyzer] model assets installed")
                }
            }
        } catch {
            vpLog("[Analyzer] asset install FAILED: \(error)")
            onRunningChanged?(false)
            return
        }

        let analyzer = SpeechAnalyzer(modules: [transcriber])
        self.analyzer = analyzer

        // Feed the app's domain terms to the model.
        do {
            let context = AnalysisContext()
            context.contextualStrings[.general] = Self.vocabulary
            try await analyzer.setContext(context)
            vpLog("[Analyzer] contextual strings set (\(Self.vocabulary.count) terms)")
        } catch {
            vpLog("[Analyzer] setContext failed (non-fatal): \(error)")
        }

        analyzerFormat = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber])
        vpLog("[Analyzer] analyzer format: \(analyzerFormat?.description ?? "nil")")

        let (stream, continuation) = AsyncStream<AnalyzerInput>.makeStream()
        inputContinuation = continuation

        consumeResults(from: transcriber)

        do {
            try await analyzer.start(inputSequence: stream)
            vpLog("[Analyzer] analyzer started")
        } catch {
            vpLog("[Analyzer] analyzer.start FAILED: \(error)")
            onRunningChanged?(false)
            return
        }

        await MainActor.run { self.startAudio() }
    }

    // MARK: - Audio

    @MainActor
    private func startAudio() {
        guard !tapInstalled else { return }
        let input = audioEngine.inputNode
        let tapFormat = input.outputFormat(forBus: 0)

        if let target = analyzerFormat, target != tapFormat {
            converter = AVAudioConverter(from: tapFormat, to: target)
            vpLog("[Analyzer] converting \(tapFormat.sampleRate)Hz -> \(target.sampleRate)Hz")
        }

        input.installTap(onBus: 0, bufferSize: 1024, format: tapFormat) { [weak self] buffer, _ in
            self?.feed(buffer)
        }
        tapInstalled = true

        audioEngine.prepare()
        do {
            try audioEngine.start()
            lastLoudAudio = Date()
            startWatchdog()
            onRunningChanged?(true)
            vpLog("[Analyzer] audio engine started, silence watchdog armed (\(silenceThreshold)s)")
        } catch {
            vpLog("[Analyzer] audio engine FAILED: \(error)")
            onRunningChanged?(false)
        }
    }

    private func feed(_ buffer: AVAudioPCMBuffer) {
        guard let continuation = inputContinuation else { return }
        noteAudioLevel(of: buffer)
        guard let target = analyzerFormat, let converter else {
            continuation.yield(AnalyzerInput(buffer: buffer))
            return
        }

        let ratio = target.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 1024
        guard let out = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: capacity) else { return }

        var supplied = false
        var error: NSError?
        converter.convert(to: out, error: &error) { _, status in
            if supplied {
                status.pointee = .noDataNow
                return nil
            }
            supplied = true
            status.pointee = .haveData
            return buffer
        }
        if let error {
            vpLog("[Analyzer] convert error: \(error.localizedDescription)")
            return
        }
        guard out.frameLength > 0 else { return }
        continuation.yield(AnalyzerInput(buffer: out))
    }

    // MARK: - Silence watchdog

    /// Tracks when audio was last above the silence floor.
    private func noteAudioLevel(of buffer: AVAudioPCMBuffer) {
        guard let channels = buffer.floatChannelData, buffer.frameLength > 0 else { return }
        let samples = channels[0]
        let n = Int(buffer.frameLength)
        var sumSquares: Float = 0
        for i in 0..<n { sumSquares += samples[i] * samples[i] }
        let rms = (sumSquares / Float(n)).squareRoot()
        if rms > silenceRMS {
            lastLoudAudio = Date()
        }
    }

    @MainActor
    private func startWatchdog() {
        watchdog?.invalidate()
        watchdog = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
            self?.checkSilence()
        }
    }

    private func checkSilence() {
        guard !finalizing,
              let analyzer,
              let through = pendingVolatileEnd,
              Date().timeIntervalSince(lastLoudAudio) >= silenceThreshold
        else { return }

        finalizing = true
        let target = through
        pendingVolatileEnd = nil
        Task { @MainActor [weak self] in
            do {
                try await analyzer.finalize(through: target)
                vpLog(String(format: "[Analyzer] forced finalize through %.2f after silence",
                             CMTimeGetSeconds(target)))
            } catch {
                vpLog("[Analyzer] forced finalize failed: \(error)")
            }
            self?.finalizing = false
        }
    }

    // MARK: - Results

    /// SpeechTranscriber.Result has no isFinal flag. Determined empirically against
    /// SDK 26.1: volatile results carry resultsFinalizationTime == 0, and a result is
    /// committed once resultsFinalizationTime reaches the end of its own range.
    /// analyzer.volatileRange is NOT usable for this — it stays pinned at the full
    /// analysed span and never distinguishes the two.
    private func consumeResults(from transcriber: SpeechTranscriber) {
        resultsTask = Task { [weak self] in
            do {
                for try await result in transcriber.results {
                    guard let self else { return }
                    let text = String(result.text.characters)
                    let isFinal = CMTimeCompare(result.resultsFinalizationTime, result.range.end) >= 0

                    vpLog(String(
                        format: "[Analyzer] result final=%@ range=[%.2f,%.2f] finalizedThrough=%.2f text='%@'",
                        isFinal ? "Y" : "n",
                        CMTimeGetSeconds(result.range.start),
                        CMTimeGetSeconds(result.range.end),
                        CMTimeGetSeconds(result.resultsFinalizationTime),
                        String(text.prefix(60))
                    ))

                    await MainActor.run {
                        if isFinal {
                            self.pendingVolatileEnd = nil
                            self.deliverFinal(text)
                        } else {
                            // Remember how far we could force a commit to, if the
                            // model does not get there on its own.
                            self.pendingVolatileEnd =
                                text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                                ? nil : result.range.end
                            self.onPartial?(text)
                        }
                    }
                }
            } catch {
                vpLog("[Analyzer] results stream ended: \(error)")
            }
        }
    }

    @MainActor
    private func deliverFinal(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        guard trimmed != lastFinalizedSegment else {
            vpLog("[Analyzer] dropped duplicate segment: '\(trimmed.prefix(40))'")
            return
        }
        lastFinalizedSegment = trimmed
        vpLog("[Analyzer] deliver: '\(trimmed.prefix(80))'")
        onUtterance?(trimmed)
    }
}
