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
final class AnalyzerSpeechBackend: SpeechBackend {
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
            onRunningChanged?(true)
            vpLog("[Analyzer] audio engine started")
        } catch {
            vpLog("[Analyzer] audio engine FAILED: \(error)")
            onRunningChanged?(false)
        }
    }

    private func feed(_ buffer: AVAudioPCMBuffer) {
        guard let continuation = inputContinuation else { return }
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
                            self.deliverFinal(text)
                        } else {
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
