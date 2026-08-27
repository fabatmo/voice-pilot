import Foundation
import Speech
import AVFoundation

/// SFSpeechRecognizer backend with the delivery pipeline repaired.
///
/// Fixes vs. the original SpeechEngine:
///  - No blanket time-based drop window. Utterances are deduped by content, not by clock.
///  - No endAudio() per utterance, so the recognizer is never torn down mid-speech.
///  - The audio engine and its tap stay up across recognizer restarts, so the ~1 minute
///    SFSpeechRecognitionRequest cap no longer costs 300ms of deafness.
///  - On-device recognition, so audio does not leave the machine.
final class LegacySpeechBackend: SpeechBackend {
    var onPartial: ((String) -> Void)?
    var onUtterance: ((String) -> Void)?
    var onRunningChanged: ((Bool) -> Void)?

    private let recognizer = SFSpeechRecognizer(locale: Locale(identifier: "en-US"))!
    private let audioEngine = AVAudioEngine()
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?

    private let silenceThreshold: TimeInterval = 1.0
    private var silenceTimer: Timer?

    /// Portion of the CURRENT task's cumulative transcript already delivered downstream.
    /// SFSpeechRecognizer reports the whole task transcript every time, so without this
    /// we would re-type everything on each delivery.
    private var deliveredPrefix = ""
    private var lastDelivered = ""
    /// Most recent cumulative transcript for the current task.
    private var lastKnownTranscript: String?
    private var tapInstalled = false

    func start() {
        SFSpeechRecognizer.requestAuthorization { [weak self] status in
            guard status == .authorized else {
                vpLog("[Legacy] permission denied, status=\(status.rawValue)")
                self?.onRunningChanged?(false)
                return
            }
            DispatchQueue.main.async { self?.startAudioThenRecognize() }
        }
    }

    func stop() {
        silenceTimer?.invalidate()
        silenceTimer = nil
        task?.cancel()
        task = nil
        request?.endAudio()
        request = nil
        if tapInstalled {
            audioEngine.inputNode.removeTap(onBus: 0)
            tapInstalled = false
        }
        audioEngine.stop()
        onRunningChanged?(false)
        vpLog("[Legacy] stopped")
    }

    // MARK: - Audio

    /// Starts the audio engine ONCE. Recognizer restarts reuse this tap.
    private func startAudioThenRecognize() {
        guard !tapInstalled else {
            beginTask()
            return
        }
        let input = audioEngine.inputNode
        let format = input.outputFormat(forBus: 0)
        input.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self] buffer, _ in
            self?.request?.append(buffer)
        }
        tapInstalled = true

        audioEngine.prepare()
        do {
            try audioEngine.start()
            vpLog("[Legacy] audio engine started, format=\(format.sampleRate)Hz")
            beginTask()
        } catch {
            vpLog("[Legacy] audio engine FAILED: \(error)")
            onRunningChanged?(false)
        }
    }

    // MARK: - Recognition

    /// Creates a fresh request+task. Audio keeps flowing throughout.
    private func beginTask() {
        task?.cancel()
        task = nil
        deliveredPrefix = ""
        lastKnownTranscript = nil

        let req = SFSpeechAudioBufferRecognitionRequest()
        req.shouldReportPartialResults = true
        req.requiresOnDeviceRecognition = true   // was false: audio was leaving the machine
        req.addsPunctuation = true
        req.taskHint = .dictation
        request = req

        task = recognizer.recognitionTask(with: req) { [weak self] result, error in
            guard let self else { return }

            if let result {
                let transcript = result.bestTranscription.formattedString
                DispatchQueue.main.async {
                    self.lastKnownTranscript = transcript
                    self.onPartial?(transcript)
                    self.armSilenceTimer()
                }
            }

            if let error {
                vpLog("[Legacy] task error: \(error.localizedDescription)")
            }

            // Task ended (usually the ~1 minute audio cap, or an error).
            // Flush whatever is pending, then restart WITHOUT touching the audio engine.
            if error != nil || result?.isFinal == true {
                DispatchQueue.main.async {
                    self.flushPending(reason: "task-ended")
                    self.request = nil
                    self.task = nil
                    self.beginTask()
                    vpLog("[Legacy] recognizer restarted, audio never stopped")
                }
            }
        }

        onRunningChanged?(true)
    }

    // MARK: - Delivery

    private func armSilenceTimer() {
        silenceTimer?.invalidate()
        silenceTimer = Timer.scheduledTimer(
            withTimeInterval: silenceThreshold, repeats: false
        ) { [weak self] _ in
            self?.flushPending(reason: "silence")
        }
    }

    /// Delivers only the part of the transcript not yet sent downstream.
    private func flushPending(reason: String) {
        silenceTimer?.invalidate()
        silenceTimer = nil

        guard let full = lastKnownTranscript, !full.isEmpty else { return }
        guard full.count > deliveredPrefix.count,
              full.hasPrefix(deliveredPrefix) || deliveredPrefix.isEmpty else {
            // Transcript was revised rather than extended; deliver the whole thing.
            deliverIfNew(full.trimmingCharacters(in: .whitespacesAndNewlines), reason: reason)
            deliveredPrefix = full
            return
        }

        let suffix = String(full.dropFirst(deliveredPrefix.count))
            .trimmingCharacters(in: .whitespacesAndNewlines)
        deliveredPrefix = full
        deliverIfNew(suffix, reason: reason)
    }

    /// Content-based dedup. The old code dropped ANY utterance within 2.5s of the
    /// previous one, which silently ate whole sentences when speaking continuously.
    private func deliverIfNew(_ text: String, reason: String) {
        guard !text.isEmpty else { return }
        guard text != lastDelivered else {
            vpLog("[Legacy] dropped duplicate: '\(text.prefix(40))'")
            return
        }
        lastDelivered = text
        vpLog("[Legacy] deliver(\(reason)): '\(text.prefix(80))'")
        onUtterance?(text)
    }
}
