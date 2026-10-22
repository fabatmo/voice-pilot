import AppKit

/// "action like" — the heart on the track SoundCloud is playing in a browser tab
/// (Fabian, 2026-10-22). SoundCloud's web player binds the key L to "like playing
/// track", so the tab is brought forward, L is pressed, and the app that was in
/// front comes back. The page's internals are never touched for the like itself.
///
/// Which tab is playing is the one open question. With "Allow JavaScript from
/// Apple Events" on in the browser (View › Developer), the player's state is read
/// and the playing tab is chosen exactly; with it off — Brave's default here — the
/// first SoundCloud tab is used and the log says so.
enum SoundCloud {
    private static let browsers = [
        ("Brave Browser", "com.brave.Browser"),
        ("Google Chrome", "com.google.Chrome"),
    ]

    static func likePlayingTrack() {
        let previous = NSWorkspace.shared.frontmostApplication
        for (name, bundle) in browsers
        where !NSRunningApplication.runningApplications(withBundleIdentifier: bundle).isEmpty {
            let script = NSAppleScript(source: likeScript(browser: name))
            var error: NSDictionary?
            let result = script?.executeAndReturnError(&error).stringValue ?? ""
            if let error {
                vpLog("[SoundCloud] \(name) FAILED: \(error[NSAppleScript.errorMessage] ?? error)")
                continue
            }
            guard result != "none" else { continue }
            vpLog("[SoundCloud] like → \(name), \(result)")
            // Give the browser its moment, then hand focus back.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                previous?.activate()
            }
            return
        }
        vpLog("[SoundCloud] no SoundCloud tab in a running browser")
    }

    private static func likeScript(browser: String) -> String {
        """
        tell application "\(browser)"
            set playingTab to missing value
            set firstTab to missing value
            set howFound to ""
            repeat with w in windows
                set i to 0
                repeat with t in tabs of w
                    set i to i + 1
                    if URL of t contains "soundcloud.com" then
                        if firstTab is missing value then set firstTab to {w, i}
                        try
                            set state to execute t javascript "document.querySelector('.playControls__play')?.classList.contains('playing') ? 'yes' : 'no'"
                            if state is "yes" then
                                set playingTab to {w, i}
                                exit repeat
                            end if
                        end try
                    end if
                end repeat
                if playingTab is not missing value then exit repeat
            end repeat
            if playingTab is not missing value then
                set chosen to playingTab
                set howFound to "the playing tab"
            else if firstTab is not missing value then
                set chosen to firstTab
                set howFound to "first SoundCloud tab (playing state unreadable — JavaScript from Apple Events is off)"
            else
                return "none"
            end if
            set active tab index of (item 1 of chosen) to (item 2 of chosen)
            set index of (item 1 of chosen) to 1
            activate
            set chosenTitle to title of active tab of (item 1 of chosen)
        end tell
        delay 0.3
        tell application "System Events" to keystroke "l"
        return howFound & ": " & chosenTitle
        """
    }
}
