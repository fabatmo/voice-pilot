import Foundation
import Speech
import AVFoundation

class SpeechEngine: ObservableObject {
    @Published var isListening = false
    @Published var currentTranscript = ""

    private let speechRecognizer = SFSpeechRecognizer(locale: Locale(identifier: "en-US"))!
    private let audioEngine = AVAudioEngine()
    private var recognitionRequest: SFSpeechAudioBufferRecognitionRequest?
    private var recognitionTask: SFSpeechRecognitionTask?
    private var onUtterance: (String) -> Void

    // Silence detection
    private var silenceTimer: Timer?
    private let silenceThreshold: TimeInterval = 1.5
    private var lastTranscript = ""
    private var lastDeliveryTime: Date = .distantPast

    init(onUtterance: @escaping (String) -> Void) {
        self.onUtterance = onUtterance
    }

    func startListening() {
        requestPermissions { [weak self] granted in
            guard granted else {
                vpLog("[Speech] permission denied")
                return
            }
            DispatchQueue.main.async {
                self?.beginRecognition()
            }
        }
    }

    func stopListening() {
        audioEngine.stop()
        recognitionRequest?.endAudio()
        recognitionTask?.cancel()
        recognitionRequest = nil
        recognitionTask = nil
        silenceTimer?.invalidate()
        DispatchQueue.main.async {
            self.isListening = false
        }
    }

    func toggleListening() {
        if isListening {
            stopListening()
        } else {
            startListening()
        }
    }

    private func requestPermissions(completion: @escaping (Bool) -> Void) {
        SFSpeechRecognizer.requestAuthorization { status in
            let granted = status == .authorized
            vpLog("[Speech] authorization status: \(status.rawValue) granted=\(granted)")
            completion(granted)
        }
    }

    private func beginRecognition() {
        vpLog("[Speech] beginRecognition called")
        recognitionTask?.cancel()
        recognitionTask = nil

        let inputNode = audioEngine.inputNode
        inputNode.removeTap(onBus: 0)

        recognitionRequest = SFSpeechAudioBufferRecognitionRequest()
        guard let request = recognitionRequest else { return }
        request.shouldReportPartialResults = true
        request.requiresOnDeviceRecognition = false
        if #available(macOS 13, *) {
            request.addsPunctuation = true
        }
        request.taskHint = .dictation

        recognitionTask = speechRecognizer.recognitionTask(with: request) { [weak self] result, error in
            guard let self = self else { return }

            if let result = result {
                let transcript = result.bestTranscription.formattedString
                DispatchQueue.main.async {
                    self.currentTranscript = transcript
                }

                DispatchQueue.main.async {
                    self.resetSilenceTimer(transcript: transcript, isFinal: result.isFinal)
                }
            }

            if let error = error {
                vpLog("[Speech] error: \(error.localizedDescription)")
            }
            if error != nil || (result?.isFinal == true) {
                self.audioEngine.stop()
                inputNode.removeTap(onBus: 0)
                self.recognitionRequest = nil
                self.recognitionTask = nil

                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                    if self.isListening {
                        self.beginRecognition()
                    }
                }
            }
        }

        let recordingFormat = inputNode.outputFormat(forBus: 0)
        inputNode.installTap(onBus: 0, bufferSize: 1024, format: recordingFormat) { buffer, _ in
            self.recognitionRequest?.append(buffer)
        }

        audioEngine.prepare()
        do {
            try audioEngine.start()
            DispatchQueue.main.async {
                self.isListening = true
                self.currentTranscript = ""
            }
            vpLog("[Speech] audio engine started, isListening=true")
        } catch {
            vpLog("[Speech] audio engine FAILED: \(error)")
        }
    }

    private func resetSilenceTimer(transcript: String, isFinal: Bool) {
        silenceTimer?.invalidate()

        if isFinal {
            let now = Date()
            if now.timeIntervalSince(lastDeliveryTime) < 2.5 {
                return
            }
            deliverUtterance(transcript)
            return
        }

        silenceTimer = Timer.scheduledTimer(withTimeInterval: silenceThreshold, repeats: false) { [weak self] _ in
            guard let self = self else { return }
            let text = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
            if !text.isEmpty {
                self.deliverUtterance(text)
            }
        }
    }

    private func deliverUtterance(_ text: String) {
        let now = Date()
        if now.timeIntervalSince(lastDeliveryTime) < 2.5 {
            return
        }

        lastTranscript = text
        lastDeliveryTime = now
        vpLog("[Speech] deliver: '\(text.prefix(80))'")
        DispatchQueue.main.async {
            self.currentTranscript = ""
        }

        recognitionRequest?.endAudio()
        onUtterance(text)
    }
}
