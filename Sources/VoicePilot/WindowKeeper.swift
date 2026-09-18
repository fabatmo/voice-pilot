import AppKit

/// Anything that can put itself back on screen and in front.
protocol WindowRevealing: AnyObject {
    func reveal()
}

/// Puts VoicePilot's floating windows back after the system hides or displaces them.
///
/// Reported 2026-09-18: the park zone and its buttons disappear after the screen sleeps
/// and wakes, with the machine never sleeping. Two independent causes, so re-asserting
/// on wake beats trusting the windows to survive:
///
///  - Display reconfiguration. A display powering down displaces or orphans the windows
///    that were on it, and nothing moves them back when it returns. A window whose frame
///    no longer meets any screen is invisible however often it is ordered front, so the
///    frame has to be validated before an order-front means anything. Worse, the frame
///    autosave persists the displaced position, so a bad frame survives relaunches.
///
///  - Window level and ordering. The lock and screensaver windows sit above .floating,
///    and floating windows are not reliably returned to the front afterwards.
final class WindowKeeper {
    private let targets: [WindowRevealing]
    private var debounce: Timer?

    init(targets: [WindowRevealing]) {
        self.targets = targets

        let ws = NSWorkspace.shared.notificationCenter
        // screensDidWake is the reported case: the display slept, the machine did not.
        // didWake and sessionDidBecomeActive cover real sleep and unlock / user switch.
        for name in [
            NSWorkspace.screensDidWakeNotification,
            NSWorkspace.didWakeNotification,
            NSWorkspace.sessionDidBecomeActiveNotification,
        ] {
            ws.addObserver(self, selector: #selector(schedule), name: name, object: nil)
        }

        // Fires when a display is added, removed, or changes resolution.
        NotificationCenter.default.addObserver(
            self, selector: #selector(schedule),
            name: NSApplication.didChangeScreenParametersNotification, object: nil)

        vpLog("[Keeper] observing wake and screen-parameter changes")
    }

    /// Wake and display notifications arrive in bursts, and the screen layout is not
    /// final when the first one lands — acting immediately would compute positions from
    /// a half-assembled desktop. Coalesce, then act once it has settled.
    @objc private func schedule() {
        debounce?.invalidate()
        let t = Timer(timeInterval: 1.2, repeats: false) { [weak self] _ in
            vpLog("[Keeper] wake / screen change — revealing windows")
            self?.revealNow()
        }
        RunLoop.main.add(t, forMode: .common)
        debounce = t
    }

    func revealNow() {
        for t in targets { t.reveal() }
    }

    deinit {
        NSWorkspace.shared.notificationCenter.removeObserver(self)
        NotificationCenter.default.removeObserver(self)
        debounce?.invalidate()
    }
}

/// Pulls a window back onto a screen that actually exists.
///
/// Shared because every floating window VoicePilot owns has the same exposure: a frame
/// left on a departed display is unreachable, and ordering it front does nothing.
func ensureWindowOnScreen(_ win: NSWindow, label: String) {
    let f = win.frame
    if NSScreen.screens.contains(where: { $0.visibleFrame.intersects(f) }) { return }

    guard let vf = (NSScreen.main ?? NSScreen.screens.first)?.visibleFrame else { return }
    // Clamp rather than recentre, so a window only moves as far as it must.
    let x = min(max(f.minX, vf.minX), max(vf.minX, vf.maxX - f.width))
    let y = min(max(f.minY, vf.minY), max(vf.minY, vf.maxY - f.height))
    vpLog("[Keeper] \(label) frame \(f) is off every screen — moving to (\(x), \(y))")
    win.setFrame(NSRect(x: x, y: y, width: f.width, height: f.height), display: true)
}
