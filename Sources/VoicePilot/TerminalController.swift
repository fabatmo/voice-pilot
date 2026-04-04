import Foundation
import AppKit

class TerminalController {
    var terminalOnly = true

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

    func pasteAndEnter(_ text: String) {
        // Save current clipboard
        let pasteboard = NSPasteboard.general
        let previousContents = pasteboard.string(forType: .string)

        // Set clipboard to our text
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)

        let script: String
        if terminalOnly {
            script = """
            -- Find terminal app
            set termApp to ""
            tell application "System Events"
                if exists (process "Terminal") then
                    set termApp to "Terminal"
                else if exists (process "iTerm2") then
                    set termApp to "iTerm2"
                else if exists (process "kitty") then
                    set termApp to "kitty"
                else if exists (process "Alacritty") then
                    set termApp to "Alacritty"
                else if exists (process "WezTerm") then
                    set termApp to "WezTerm"
                else if exists (process "Ghostty") then
                    set termApp to "Ghostty"
                end if
            end tell

            if termApp is not "" then
                tell application termApp to activate
                delay 0.3
                tell application "System Events"
                    keystroke "v" using command down
                end tell
                delay 0.3
                tell application "System Events"
                    key code 36
                end tell
            end if
            """
        } else {
            script = """
            -- Send to whatever app is frontmost
            tell application "System Events"
                keystroke "v" using command down
            end tell
            delay 0.2
            tell application "System Events"
                key code 36
            end tell
            """
        }

        runAppleScript(script)

        // Restore clipboard after a delay
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
            if let previous = previousContents {
                pasteboard.clearContents()
                pasteboard.setString(previous, forType: .string)
            }
        }
    }

    private func sendToTerminal(text: String) {
        let escaped = text.replacingOccurrences(of: "\"", with: "\\\"")
        let script = """
        tell application "System Events"
            keystroke "\(escaped)"
        end tell
        """
        runAppleScript(script)
    }

    private func sendToTerminal(keystroke key: String, using modifier: String? = nil) {
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

    private func runAppleScript(_ source: String) {
        if let script = NSAppleScript(source: source) {
            var error: NSDictionary?
            script.executeAndReturnError(&error)
            if let error = error {
                print("AppleScript error: \(error)")
            }
        }
    }
}
