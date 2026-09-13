import AppKit
import SwiftUI

/// Never becomes key or main: dragging, resizing or clicking the zone must not pull
/// focus away from whatever the user is dictating into.
private final class NonFocusingPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

/// A standalone window whose only job is to be somewhere to rest the pointer.
///
/// Deliberately not the transcript panel. Measured 2026-09-13, the pointer comes to
/// rest inside the transcript panel's own bounds, so using that panel as the park
/// target fires by accident. This window goes wherever the user drags it, at whatever
/// size they choose, and its frame survives relaunches — which matters because the app
/// relaunches on every engine switch and every permission change.
final class ParkZoneController: NSObject {
    /// Whether the zone was on screen last time, so it comes back on relaunch.
    static let visibleKey = "parkZoneVisible"
    private static let autosaveName = "VoicePilotParkZone"

    private var panel: NSPanel?
    private let terminalController: TerminalController
    private var debouncer: HoverParkDebouncer?

    var isVisible: Bool { panel != nil }

    init(terminalController: TerminalController) {
        self.terminalController = terminalController
        super.init()
        // Absent key means first run since the feature landed: show it, so the zone is
        // discoverable without hunting through the menu. After that, honour the choice.
        if UserDefaults.standard.object(forKey: Self.visibleKey) as? Bool ?? true { show() }
    }

    func toggle() {
        if isVisible { hide() } else { show() }
    }

    func show() {
        guard panel == nil else { return }

        // .titled + .fullSizeContentView with a hidden transparent titlebar rather than
        // .borderless: it reads as a plain floating card but keeps AppKit's real
        // edge-resize behaviour and resize cursors, which borderless windows lack.
        let win = NonFocusingPanel(
            contentRect: NSRect(x: 0, y: 0, width: 200, height: 130),
            styleMask: [.titled, .resizable, .fullSizeContentView,
                        .nonactivatingPanel, .utilityWindow],
            backing: .buffered,
            defer: false
        )
        win.titlebarAppearsTransparent = true
        win.titleVisibility = .hidden
        win.standardWindowButton(.closeButton)?.isHidden = true
        win.standardWindowButton(.miniaturizeButton)?.isHidden = true
        win.standardWindowButton(.zoomButton)?.isHidden = true
        win.isMovableByWindowBackground = true
        win.level = .floating
        win.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        win.backgroundColor = .clear
        win.isOpaque = false
        win.hasShadow = false
        win.hidesOnDeactivate = false
        win.minSize = NSSize(width: 64, height: 44)
        win.appearance = NSAppearance(named: .darkAqua)

        let debouncer = HoverParkDebouncer { [weak self] parked in
            self?.terminalController.setParked(parked, source: .zone)
        }
        self.debouncer = debouncer

        let hover = HoverReportingView(frame: win.contentView?.bounds ?? .zero)
        hover.autoresizingMask = [.width, .height]
        hover.onHoverChange = { inside in debouncer.hoverChanged(inside) }

        let host = NSHostingView(rootView: ParkZoneView(terminalController: terminalController))
        host.frame = hover.bounds
        host.autoresizingMask = [.width, .height]
        hover.addSubview(host)
        win.contentView = hover

        // Restores both position and size; only falls back on the very first run.
        win.setFrameAutosaveName(Self.autosaveName)
        if !win.setFrameUsingName(Self.autosaveName), let screen = NSScreen.main {
            let vf = screen.visibleFrame
            win.setFrameOrigin(NSPoint(x: vf.maxX - 240, y: vf.minY + 40))
        }

        win.orderFront(nil)
        panel = win
        UserDefaults.standard.set(true, forKey: Self.visibleKey)
        vpLog("[Park] zone shown at \(win.frame)")
    }

    func hide() {
        guard let win = panel else { return }
        win.saveFrame(usingName: Self.autosaveName)
        win.orderOut(nil)
        panel = nil

        // Release the zone's park contribution, or hiding it while hovered would leave
        // dictation parked with nothing on screen to explain why.
        debouncer?.cancel()
        debouncer = nil
        terminalController.setParked(false, source: .zone)

        UserDefaults.standard.set(false, forKey: Self.visibleKey)
        vpLog("[Park] zone hidden")
    }
}

// MARK: - Appearance

private struct ParkZoneView: View {
    @ObservedObject var terminalController: TerminalController

    private var parked: Bool { terminalController.parked }

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 12)
                .fill(parked ? Color.orange.opacity(0.20) : Color.black.opacity(0.30))
            RoundedRectangle(cornerRadius: 12)
                .strokeBorder(parked ? Color.orange.opacity(0.85) : Color.white.opacity(0.20),
                              lineWidth: parked ? 2 : 1)

            VStack(spacing: 5) {
                Image(systemName: parked ? "pause.circle.fill" : "pause.circle")
                    .font(.system(size: 20, weight: .light))
                Text(parked ? "Parked" : "Park")
                    .font(.system(size: 11, weight: .medium))
                if parked {
                    Text("buffering")
                        .font(.system(size: 9))
                        .foregroundColor(.orange.opacity(0.7))
                }
            }
            .foregroundColor(parked ? .orange : Color.white.opacity(0.45))
            .padding(6)
        }
        .animation(.easeOut(duration: 0.12), value: parked)
    }
}
