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
    private let silenceThreshold: TimeInterval = 2.0
    private var lastTranscript = ""
    private var lastDeliveryTime: Date = .distantPast

    init(onUtterance: @escaping (String) -> Void) {
        self.onUtterance = onUtterance
    }

    func startListening() {
        requestPermissions { [weak self] granted in
            guard granted else {
                print("Speech recognition permission denied")
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
            if !granted {
                print("Speech recognition not authorized: \(status.rawValue)")
            }
            completion(granted)
        }
    }

    private func beginRecognition() {
        // Cancel any existing task
        recognitionTask?.cancel()
        recognitionTask = nil

        let inputNode = audioEngine.inputNode
        // Remove any existing taps
        inputNode.removeTap(onBus: 0)

        recognitionRequest = SFSpeechAudioBufferRecognitionRequest()
        guard let request = recognitionRequest else { return }
        request.shouldReportPartialResults = true

        recognitionTask = speechRecognizer.recognitionTask(with: request) { [weak self] result, error in
            guard let self = self else { return }

            if let result = result {
                let transcript = result.bestTranscription.formattedString
                DispatchQueue.main.async {
                    self.currentTranscript = transcript
                }

                // Reset silence timer on new speech
                self.resetSilenceTimer(transcript: transcript, isFinal: result.isFinal)
            }

            if error != nil || (result?.isFinal == true) {
                self.audioEngine.stop()
                inputNode.removeTap(onBus: 0)
                self.recognitionRequest = nil
                self.recognitionTask = nil

                // Restart recognition for continuous listening
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
        } catch {
            print("Audio engine failed to start: \(error)")
        }
    }

    private func resetSilenceTimer(transcript: String, isFinal: Bool) {
        silenceTimer?.invalidate()

        // If silence timer already delivered for this recognition session, ignore isFinal
        if isFinal {
            let now = Date()
            if now.timeIntervalSince(lastDeliveryTime) < 1.5 {
                // Already delivered via silence timer — skip
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
        // Dedup — block any delivery within 3 seconds of last one
        let now = Date()
        if now.timeIntervalSince(lastDeliveryTime) < 1.5 {
            return
        }

        lastTranscript = text
        lastDeliveryTime = now
        DispatchQueue.main.async {
            self.currentTranscript = ""
        }

        // Force restart recognition for next utterance
        recognitionRequest?.endAudio()

        onUtterance(text)
    }
}
