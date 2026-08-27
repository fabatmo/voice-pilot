import Foundation

/// Which recognition implementation the app runs.
/// Selected at launch from UserDefaults so both can be compared in the same build.
enum SpeechEngineChoice: String {
    case legacy    // SFSpeechRecognizer, fixed delivery pipeline
    case analyzer  // SpeechAnalyzer + SpeechTranscriber (macOS 26)

    static let defaultsKey = "VoicePilotSpeechEngine"

    static var current: SpeechEngineChoice {
        if let env = ProcessInfo.processInfo.environment["VOICEPILOT_ENGINE"],
           let choice = SpeechEngineChoice(rawValue: env) {
            return choice
        }
        if let stored = UserDefaults.standard.string(forKey: defaultsKey),
           let choice = SpeechEngineChoice(rawValue: stored) {
            return choice
        }
        return .analyzer
    }

    var displayName: String {
        switch self {
        case .legacy:   return "Legacy (SFSpeechRecognizer)"
        case .analyzer: return "Analyzer (SpeechAnalyzer)"
        }
    }
}

/// A recognition backend. Emits live partials and completed utterances.
/// Implementations own their own endpointing.
protocol SpeechBackend: AnyObject {
    /// Live in-progress text, for display only. Never delivered downstream.
    var onPartial: ((String) -> Void)? { get set }
    /// A completed utterance, ready to type. Emitted once per utterance.
    var onUtterance: ((String) -> Void)? { get set }
    /// Backend changed running state (permission denied, audio failure, cap restart).
    var onRunningChanged: ((Bool) -> Void)? { get set }

    func start()
    func stop()
}
