import AppKit

/// "action like" / "action unlike" — the heart on the track SoundCloud is playing
/// in a browser tab (Fabian, 2026-10-22). SoundCloud's web player binds the key L
/// to "like playing track" — a toggle — so the tab is brought forward, L is
/// pressed, and the app that was in front comes back. The page's internals are
/// never touched for the like itself.
///
/// Which tab is playing, and whether the track is already liked, are the two open
/// questions. With "Allow JavaScript from Apple Events" on in the browser (View ›
/// Developer) both are read from the player and the key is pressed only when it
/// changes something; with it off — Brave's default here — the first SoundCloud
/// tab is used, L toggles blind, and the log says so.
enum SoundCloud {
    private static let browsers = [
        ("Brave Browser", "com.brave.Browser"),
        ("Google Chrome", "com.google.Chrome"),
    ]

    static func setPlayingTrackLiked(_ liked: Bool) {
        let previous = NSWorkspace.shared.frontmostApplication
        let verb = liked ? "like" : "unlike"
        for (name, bundle) in browsers
        where !NSRunningApplication.runningApplications(withBundleIdentifier: bundle).isEmpty {
            let script = NSAppleScript(source: script(browser: name, wantLiked: liked))
            var error: NSDictionary?
            let result = script?.executeAndReturnError(&error).stringValue ?? ""
            if let error {
                vpLog("[SoundCloud] \(verb) in \(name) FAILED: \(error[NSAppleScript.errorMessage] ?? error)")
                continue
            }
            guard result != "none" else { continue }
            vpLog("[SoundCloud] \(verb) → \(name), \(result)")
            if result.hasPrefix("already") { return }
            // Give the browser its moment, then hand focus back.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                previous?.activate()
            }
            return
        }
        vpLog("[SoundCloud] \(verb): no SoundCloud tab in a running browser")
    }

    /// Returns "none", "already liked|unliked: <title>", or "<how the tab was chosen>: <title>".
    private static func script(browser: String, wantLiked: Bool) -> String {
        // Player state read only when JavaScript from Apple Events is allowed;
        // otherwise the try block fails silently and the state stays unknown.
        let probe = "(function(){var p=document.querySelector('.playControls__play');var b=document.querySelector('.playControls .sc-button-like');return (p&&p.classList.contains('playing')?'playing':'paused')+'/'+(b&&b.classList.contains('sc-button-selected')?'liked':'unliked');})()"
        return """
        tell application "\(browser)"
            set chosen to missing value
            set firstTab to missing value
            set likedState to "unknown"
            set howFound to ""
            repeat with w in windows
                set i to 0
                repeat with t in tabs of w
                    set i to i + 1
                    if URL of t contains "soundcloud.com" then
                        if firstTab is missing value then set firstTab to {w, i}
                        try
                            set state to execute t javascript "\(probe)"
                            if state starts with "playing" then
                                set chosen to {w, i}
                                set howFound to "the playing tab"
                                if state ends with "/liked" then
                                    set likedState to "liked"
                                else
                                    set likedState to "unliked"
                                end if
                                exit repeat
                            end if
                        end try
                    end if
                end repeat
                if chosen is not missing value then exit repeat
            end repeat
            if chosen is missing value then
                if firstTab is missing value then return "none"
                set chosen to firstTab
                set howFound to "first SoundCloud tab, L toggles blind (JavaScript from Apple Events is off)"
            end if
            set chosenTitle to title of (tab (item 2 of chosen) of (item 1 of chosen))
            if likedState is "\(wantLiked ? "liked" : "unliked")" then return "already " & likedState & ": " & chosenTitle
            set active tab index of (item 1 of chosen) to (item 2 of chosen)
            set index of (item 1 of chosen) to 1
            activate
        end tell
        delay 0.3
        tell application "System Events" to keystroke "l"
        return howFound & ": " & chosenTitle
        """
    }
}
