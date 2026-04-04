import Foundation

enum TerminalCommand {
    case enter
    case confirm
    case deny
    case cancel
    case scrollUp
    case scrollDown

    var description: String {
        switch self {
        case .enter: return "Enter"
        case .confirm: return "Confirm (y)"
        case .deny: return "Deny (n)"
        case .cancel: return "Cancel (Ctrl+C)"
        case .scrollUp: return "Scroll Up"
        case .scrollDown: return "Scroll Down"
        }
    }
}

class CommandDetector {
    private let commandMap: [(keywords: [String], command: TerminalCommand)] = [
        (["enter", "submit", "return", "press enter"], .enter),
        (["yes", "confirm", "one", "accept", "approve", "yeah"], .confirm),
        (["no", "deny", "reject", "two", "decline", "nah"], .deny),
        (["cancel", "stop", "abort", "kill", "quit", "escape"], .cancel),
        (["scroll up", "page up", "go up"], .scrollUp),
        (["scroll down", "page down", "go down"], .scrollDown),
    ]

    func detect(_ text: String) -> TerminalCommand? {
        let normalized = text.lowercased()
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: ".", with: "")
            .replacingOccurrences(of: ",", with: "")

        // Only match short utterances as commands (< 5 words)
        let wordCount = normalized.split(separator: " ").count
        guard wordCount <= 4 else { return nil }

        for entry in commandMap {
            for keyword in entry.keywords {
                if normalized == keyword || normalized == "say \(keyword)" {
                    return entry.command
                }
            }
        }

        return nil
    }
}
