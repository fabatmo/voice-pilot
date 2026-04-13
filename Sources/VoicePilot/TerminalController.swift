import Foundation
import AppKit

class TerminalController: ObservableObject {
    @Published var terminalOnly = true

    private let terminalApps: Set<String> = [
        "Terminal", "iTerm2", "kitty", "Alacritty",
        "WezTerm", "Ghostty", "Warp", "Hyper", "Rio"
    ]

    /// Check if the frontmost app is a terminal
    private var frontmostIsTerminal: Bool {
        guard let frontApp = NSWorkspace.shared.frontmostApplication?.localizedName else { return false }
        return terminalApps.contains(frontApp)
    }

    func execute(_ command: TerminalCommand) {
        switch command {
        case .enter:
            sendToTerminal(keystroke: "return")
        case .confirm:
            sendToTerminal(text: "y")
            usleep(100_000)
            sendToTerminal(keystroke: "return")
        case .deny:
            sendToTerminal(text: "n")
            usleep(100_000)
            sendToTerminal(keystroke: "return")
        case .cancel:
            sendToTerminal(keystroke: "c", using: "control down")
        case .scrollUp:
            sendToTerminal(keystroke: "upArrow", using: "shift down")
        case .scrollDown:
            sendToTerminal(keystroke: "downArrow", using: "shift down")
        }
    }

    /// Find a terminal, activate it, paste text, and press Enter
    func activateTerminalAndPasteEnter(_ text: String) {
        let pasteboard = NSPasteboard.general
        let previousContents = pasteboard.string(forType: .string)

        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)

        let apps = terminalApps.map { "\"\($0)\"" }.joined(separator: ", ")
        let script = """
        set termApps to {\(apps)}
        set termApp to ""
        tell application "System Events"
            repeat with appName in termApps
                if exists (process appName) then
                    set termApp to appName as text
                    exit repeat
                end if
            end repeat
        end tell

        if termApp is not "" then
            tell application termApp to activate
            delay 0.3
            tell application "System Events"
                keystroke "v" using command down
            end tell
            delay 0.2
            tell application "System Events"
                key code 36
            end tell
        end if
        """
        runAppleScript(script)

        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
            if let previous = previousContents {
                pasteboard.clearContents()
                pasteboard.setString(previous, forType: .string)
            }
        }
    }

    func pasteAndEnter(_ text: String) {
        if terminalOnly && !frontmostIsTerminal {
            print("[TerminalController] Frontmost app is not a terminal — skipping")
            return
        }

        let pasteboard = NSPasteboard.general
        let previousContents = pasteboard.string(forType: .string)

        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)

        // Send to frontmost app — no app switching
        let script = """
        tell application "System Events"
            keystroke "v" using command down
        end tell
        delay 0.2
        tell application "System Events"
            key code 36
        end tell
        """
        runAppleScript(script)

        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
            if let previous = previousContents {
                pasteboard.clearContents()
                pasteboard.setString(previous, forType: .string)
            }
        }
    }

    func pressEnter() {
        if terminalOnly && !frontmostIsTerminal { return }

        let script = """
        tell application "System Events"
            key code 36
        end tell
        """
        runAppleScript(script)
    }

    private var savedClipboard: String?

    /// Save clipboard before dictation starts
    func saveClipboard() {
        savedClipboard = NSPasteboard.general.string(forType: .string)
    }

    /// Restore clipboard after dictation ends
    func restoreClipboard() {
        if let saved = savedClipboard {
            let pasteboard = NSPasteboard.general
            pasteboard.clearContents()
            pasteboard.setString(saved, forType: .string)
        }
        savedClipboard = nil
    }

    /// Clear entire input line (Ctrl+E to end, Ctrl+U to kill backward) then paste
    func clearLineAndPaste(_ text: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)

        // Ctrl+E = move to end of line, Ctrl+U = kill line backward, then paste
        let script = """
        tell application "System Events"
            key code 14 using control down
            key code 32 using control down
            keystroke "v" using command down
        end tell
        """
        runAppleScript(script)
    }

    /// Paste text at cursor via clipboard (instant, no flicker)
    func pasteText(_ text: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)

        let script = """
        tell application "System Events"
            keystroke "v" using command down
        end tell
        """
        runAppleScript(script)
    }

    /// Type text at cursor position via keystrokes
    func typeText(_ text: String) {
        let escaped = text.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        guard !escaped.isEmpty else { return }

        let script = """
        tell application "System Events"
            keystroke "\(escaped)"
        end tell
        """
        runAppleScript(script)
    }

    /// Delete N characters backward (backspace)
    func deleteBackward(count: Int) {
        guard count > 0 else { return }
        let script = """
        tell application "System Events"
            repeat \(count) times
                key code 51
            end repeat
        end tell
        """
        runAppleScript(script)
    }

    private func sendToTerminal(text: String) {
        if terminalOnly && !frontmostIsTerminal { return }

        let escaped = text.replacingOccurrences(of: "\"", with: "\\\"")
        let script = """
        tell application "System Events"
            keystroke "\(escaped)"
        end tell
        """
        runAppleScript(script)
    }

    private func sendToTerminal(keystroke key: String, using modifier: String? = nil) {
        if terminalOnly && !frontmostIsTerminal { return }

        let script: String
        if let modifier = modifier {
            script = """
            tell application "System Events"
                key code \(keyCodeFor(key)) using {\(modifier)}
            end tell
            """
        } else {
            script = """
            tell application "System Events"
                key code \(keyCodeFor(key))
            end tell
            """
        }
        runAppleScript(script)
    }

    private func keyCodeFor(_ name: String) -> Int {
        switch name {
        case "return": return 36
        case "escape": return 53
        case "c": return 8
        case "v": return 9
        case "upArrow": return 126
        case "downArrow": return 125
        default: return 0
        }
    }

    func runScript(_ source: String) {
        runAppleScript(source)
    }

    private func runAppleScript(_ source: String) {
        if let script = NSAppleScript(source: source) {
            var error: NSDictionary?
            script.executeAndReturnError(&error)
            if let error = error {
                print("[TerminalController] AppleScript error: \(error)")
            }
        }
    }
}
