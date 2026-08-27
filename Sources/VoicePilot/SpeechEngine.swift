import Foundation
import Speech
import AVFoundation

/// Observable facade over a swappable recognition backend.
///
/// The public surface is unchanged from the original SFSpeechRecognizer-only
/// version, so FloatingPanel, StatusBarController and App keep working as-is.
/// Which backend runs is decided once at launch by SpeechEngineChoice.current.
class SpeechEngine: ObservableObject {
    @Published var isListening = false
    @Published var currentTranscript = ""

    /// Which backend this process is running. Fixed for the lifetime of the app.
    let engineChoice: SpeechEngineChoice

    private var backend: SpeechBackend
    private var onUtterance: (String) -> Void

    init(onUtterance: @escaping (String) -> Void) {
        self.onUtterance = onUtterance

        let choice = SpeechEngineChoice.current
        self.engineChoice = choice

        if choice == .analyzer, #available(macOS 26.0, *) {
            self.backend = AnalyzerSpeechBackend()
        } else {
            if choice == .analyzer {
                vpLog("[Speech] analyzer requested but macOS < 26, falling back to legacy")
            }
            self.backend = LegacySpeechBackend()
        }
        vpLog("[Speech] engine = \(engineChoice.displayName)")

        backend.onPartial = { [weak self] text in
            DispatchQueue.main.async { self?.currentTranscript = text }
        }
        backend.onUtterance = { [weak self] text in
            guard let self else { return }
            DispatchQueue.main.async { self.currentTranscript = "" }
            self.onUtterance(text)
        }
        backend.onRunningChanged = { [weak self] running in
            DispatchQueue.main.async { self?.isListening = running }
        }
    }

    func startListening() {
        vpLog("[Speech] startListening (\(engineChoice.rawValue))")
        backend.start()
    }

    func stopListening() {
        backend.stop()
        DispatchQueue.main.async {
            self.isListening = false
            self.currentTranscript = ""
        }
    }

    func toggleListening() {
        if isListening {
            stopListening()
        } else {
            startListening()
        }
    }
}
