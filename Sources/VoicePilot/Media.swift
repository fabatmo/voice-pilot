import AppKit

/// "action play music" and friends — the first remote-control verbs (Fabian,
/// 2026-10-22).
///
/// Next / previous / play go out as the keyboard's media keys: macOS hands those to
/// whatever is the current Now Playing source, which includes a browser tab —
/// SoundCloud in Chrome was the case that asked for it. Pause and stop use the
/// media key too, except when Spotify or Music says it is playing: there AppleScript
/// pauses outright, because the media key is a toggle and "pause" must never start
/// something.
enum Media {
    static func perform(_ verb: String) {
        switch verb {
        case "play music", "resume":
            mediaKey(.play, label: "play/pause")
        case "pause music", "stop music", "pause":
            if let player = playingScriptablePlayer() {
                appleScript(player, "pause")
            } else {
                mediaKey(.play, label: "play/pause")
            }
        case "next song":
            mediaKey(.next, label: "next")
        case "previous song":
            mediaKey(.previous, label: "previous")
        case "like":
            SoundCloud.setPlayingTrackLiked(true)
        case "unlike":
            SoundCloud.setPlayingTrackLiked(false)
        default:
            vpLog("[Media] unknown verb '\(verb)'")
        }
    }

    // MARK: - Media keys

    /// NX_KEYTYPE_* from IOKit/hidsystem/ev_keymap.h.
    private enum Key: Int {
        case play = 16, next = 17, previous = 18
    }

    /// A system-defined key event, down then up, posted to the HID tap — the same
    /// event the keyboard's ⏯ ⏭ ⏮ produce. Subtype 8 is the media-key subtype;
    /// data1 packs the key in the high word and the key state (0xA down / 0xB up) in
    /// the low word.
    private static func mediaKey(_ key: Key, label: String) {
        var posted = 0
        for down in [true, false] {
            let state = down ? 0xA : 0xB
            let event = NSEvent.otherEvent(
                with: .systemDefined,
                location: .zero,
                modifierFlags: NSEvent.ModifierFlags(rawValue: UInt(state << 8)),
                timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: 0,
                context: nil,
                subtype: 8,
                data1: (key.rawValue << 16) | (state << 8),
                data2: -1
            )
            if let cg = event?.cgEvent {
                cg.post(tap: .cghidEventTap)
                posted += 1
            }
        }
        vpLog("[Media] media key \(label) — \(posted)/2 events posted to the Now Playing app")
    }

    // MARK: - Spotify / Music

    private static let players: [(name: String, bundle: String)] = [
        ("Spotify", "com.spotify.client"),
        ("Music", "com.apple.Music"),
    ]

    /// The scriptable player that is actually playing right now, if any. Only running
    /// apps are asked — AppleScript would otherwise launch them.
    private static func playingScriptablePlayer() -> String? {
        for player in players
        where !NSRunningApplication.runningApplications(withBundleIdentifier: player.bundle).isEmpty {
            let script = NSAppleScript(source: "tell application \"\(player.name)\" to player state as string")
            var error: NSDictionary?
            let state = script?.executeAndReturnError(&error).stringValue ?? ""
            if state == "playing" { return player.name }
        }
        return nil
    }

    private static func appleScript(_ player: String, _ action: String) {
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
