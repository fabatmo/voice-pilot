import AppKit

/// "action play music" and friends — the first remote-control verbs (Fabian,
/// 2026-10-22). Spotify when it is running, otherwise Apple Music; both are
/// AppleScript-able, which a media key is not without an HID event.
enum Media {
    static func perform(_ verb: String) {
        let spotifyRunning = !NSRunningApplication.runningApplications(withBundleIdentifier: "com.spotify.client").isEmpty
        let player = spotifyRunning ? "Spotify" : "Music"
        let action: String
        switch verb {
        case "play music": action = "play"
        case "pause music", "stop music": action = "pause"
        case "next song": action = "next track"
        case "previous song": action = "previous track"
        default:
            vpLog("[Media] unknown verb '\(verb)'")
            return
        }
        let script = NSAppleScript(source: "tell application \"\(player)\" to \(action)")
        var error: NSDictionary?
        script?.executeAndReturnError(&error)
        if let error {
            vpLog("[Media] \(player) \(action) FAILED: \(error[NSAppleScript.errorMessage] ?? error)")
        } else {
            vpLog("[Media] \(player): \(action)")
        }
    }
}
