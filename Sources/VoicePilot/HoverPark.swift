import AppKit

/// Reports pointer enter/exit for a view regardless of key or active state.
///
/// `.activeAlways` is load-bearing. VoicePilot's windows are non-activating and never
/// main, so a tracking area scoped to the key or active window would never fire — and
/// SwiftUI's `.onHover` installs one of those. Hence an explicit tracking area.
final class HoverReportingView: NSView {
    var onHoverChange: ((Bool) -> Void)?

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for area in trackingAreas { removeTrackingArea(area) }
        // With .inVisibleRect the rect argument is ignored and kept in sync for us.
        addTrackingArea(NSTrackingArea(
            rect: .zero,
            options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
            owner: self,
            userInfo: nil
        ))
    }

    override func mouseEntered(with event: NSEvent) { onHoverChange?(true) }
    override func mouseExited(with event: NSEvent) { onHoverChange?(false) }
}

/// Turns raw hover into a park signal.
///
/// Entering requires a dwell, so the pointer merely crossing a window on its way
/// somewhere else does not park dictation — measured 2026-09-13, the pointer comes to
/// rest inside the transcript panel's own bounds, so incidental contact is the common
/// case, not the rare one. Leaving releases immediately: an un-park must never be
/// delayed, or speech goes to the buffer when the user believes it is typing.
final class HoverParkDebouncer {
    private let dwell: TimeInterval
    private let apply: (Bool) -> Void
    private var timer: Timer?

    init(dwell: TimeInterval = 0.2, apply: @escaping (Bool) -> Void) {
        self.dwell = dwell
        self.apply = apply
    }

    func hoverChanged(_ inside: Bool) {
        timer?.invalidate()
        timer = nil

        guard inside else {
            apply(false)
            return
        }

        // Scheduled in .common modes: during mouse tracking the main run loop sits in
        // event-tracking mode, where a .default-mode timer would not fire.
        let t = Timer(timeInterval: dwell, repeats: false) { [weak self] _ in
            self?.apply(true)
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    func cancel() {
        timer?.invalidate()
        timer = nil
    }
}
