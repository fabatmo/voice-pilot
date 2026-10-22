import AppKit

/// "action go to <name>" — Orca's worktree palette (Fabian, 2026-10-23: "mostly
/// I'm interested in go to name, and it shouldn't even be the full name").
///
/// Read from Orca 1.4.223's keybinding table: `worktree.palette` "Switch worktree"
/// is ⌘J on macOS. The palette takes typed text and matches it loosely, so
/// "voice" reaches voice-pilot; Enter takes the top match. Orca is brought to the
/// front first when it is not already there.
enum Orca {
    static let bundleID = "com.stablyai.orca"

    static func goTo(_ spokenName: String) {
        var name = spokenName.trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: .punctuationCharacters)
        // "go to the voice pilot", "go to my hub" — the article would only confuse
        // the palette's matching.
        for article in ["the ", "my ", "a "] where name.lowercased().hasPrefix(article) {
            name = String(name.dropFirst(article.count))
        }
        guard !name.isEmpty else { return }
        guard let app = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first else {
            vpLog("[Orca] go to '\(name)' — Orca is not running")
            return
        }
        if !app.isActive {
            app.activate()
            vpLog("[Orca] go to '\(name)' — bringing Orca forward first")
        }
        let escaped = name.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
        let script = NSAppleScript(source: """
        tell application "System Events"
            tell process "Orca"
                set frontmost to true
            end tell
            delay 0.2
            keystroke "j" using {command down}
            delay 0.4
            keystroke "\(escaped)"
            delay 0.5
            key code 36
        end tell
        """)
        var error: NSDictionary?
        script?.executeAndReturnError(&error)
        if let error {
            vpLog("[Orca] go to '\(name)' FAILED: \(error[NSAppleScript.errorMessage] ?? error)")
        } else {
            vpLog("[Orca] go to '\(name)' — ⌘J, typed, Enter")
        }
    }
}
