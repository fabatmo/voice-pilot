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

    // Action buttons are companion windows rather than controls inside the zone:
    // anything inside the zone would sit in its tracking area, so reaching for it
    // would park — and the submit and clear paths are both no-ops while parked, making
    // the buttons dead exactly when aimed at.
    private var buttons: [ZoneButtonWindow] = []
    private static let buttonGap: CGFloat = 10      // zone to column
    private static let buttonSpacing: CGFloat = 8   // button to button
    private static let buttonSize = NSSize(width: 58, height: 46)

    /// Invoked on send. Wired by AppDelegate to the same path as middle-click.
    var onSend: (() -> Void)?
    /// Invoked on clear. Wipes the terminal's input line.
    var onClear: (() -> Void)?

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

        // Keep the button glued to the zone as it is dragged and resized.
        for name in [NSWindow.didMoveNotification, NSWindow.didResizeNotification] {
            NotificationCenter.default.addObserver(
                self, selector: #selector(zoneFrameChanged), name: name, object: win)
        }
        showButtons()

        UserDefaults.standard.set(true, forKey: Self.visibleKey)
        vpLog("[Park] zone shown at \(win.frame)")
    }

    func hide() {
        guard let win = panel else { return }
        win.saveFrame(usingName: Self.autosaveName)
        NotificationCenter.default.removeObserver(self, name: NSWindow.didMoveNotification, object: win)
        NotificationCenter.default.removeObserver(self, name: NSWindow.didResizeNotification, object: win)
        hideButtons()
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

    // MARK: - Action buttons

    private func showButtons() {
        guard buttons.isEmpty else { return }

        buttons = [
            makeButton(id: "send", symbol: "return", title: "Send", accent: .green) { [weak self] in
                vpLog("[Park] send button pressed")
                self?.onSend?()
            },
            makeButton(id: "clear", symbol: "delete.left", title: "Clear", accent: .red) { [weak self] in
                vpLog("[Park] clear button pressed")
                self?.onClear?()
            },
        ]

        // Position before ordering front, so no button is ever seen at its default
        // origin — the first placement used to be a silent no-op for exactly this
        // kind of ordering mistake.
        positionButtons()
        for b in buttons { b.panel.orderFront(nil) }
        vpLog("[Park] \(buttons.count) action buttons shown")
    }

    private func makeButton(
        id: String,
        symbol: String,
        title: String,
        accent: Color,
        action: @escaping () -> Void
    ) -> ZoneButtonWindow {
        let size = Self.buttonSize
        let win = NonFocusingPanel(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.borderless, .nonactivatingPanel, .utilityWindow],
            backing: .buffered,
            defer: false
        )
        win.level = .floating
        win.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        win.backgroundColor = .clear
        win.isOpaque = false
        win.hasShadow = false
        win.hidesOnDeactivate = false
        win.appearance = NSAppearance(named: .darkAqua)
        // Deliberately NOT movableByWindowBackground: buttons follow the zone, and a
        // click that drifts a pixel must stay a click rather than becoming a drag.
        win.isMovableByWindowBackground = false

        let model = ZoneButtonModel()
        let click = SendButtonView(frame: NSRect(origin: .zero, size: size))
        click.autoresizingMask = [.width, .height]
        click.onPressedChange = { down in model.pressed = down }
        click.onClick = action

        let host = NSHostingView(
            rootView: ZoneButtonContent(model: model, symbol: symbol, title: title, accent: accent)
        )
        host.frame = click.bounds
        host.autoresizingMask = [.width, .height]
        // Display only — if the SwiftUI layer took hits it would swallow mouseDown
        // before the AppKit container, which is what actually makes the click work
        // in a window that never becomes key.
        click.addSubview(host)
        click.hitTestSubviewsDisabled = true

        win.contentView = click
        return ZoneButtonWindow(id: id, panel: win, model: model)
    }

    private func hideButtons() {
        for b in buttons { b.panel.orderOut(nil) }
        buttons.removeAll()
    }

    @objc private func zoneFrameChanged() {
        positionButtons()
    }

    /// Lays the buttons out as a vertical column just outside the zone, never touching
    /// it, so the zone's tracking area and the click targets can never overlap. Flips
    /// to the zone's other side when there is not enough room on the preferred one.
    private func positionButtons() {
        guard let zone = panel, !buttons.isEmpty else { return }
        let z = zone.frame
        let size = Self.buttonSize
        let n = CGFloat(buttons.count)
        let columnHeight = n * size.height + (n - 1) * Self.buttonSpacing

        var x = z.minX - Self.buttonGap - size.width          // prefer the left
        let screen = NSScreen.screens.first { $0.frame.intersects(z) } ?? NSScreen.main
        if let vf = screen?.visibleFrame {
            if x < vf.minX {
                x = z.maxX + Self.buttonGap                   // flip to the right
                if x + size.width > vf.maxX { x = vf.maxX - size.width }
            }
        }

        // Column centred on the zone, filling downwards from the top.
        var y = z.midY + columnHeight / 2 - size.height
        for b in buttons {
            b.panel.setFrame(
                NSRect(x: x, y: y, width: size.width, height: size.height), display: true)
            y -= size.height + Self.buttonSpacing
        }
    }
}

/// One action button window plus the model driving its pressed appearance.
private final class ZoneButtonWindow {
    let id: String
    let panel: NSPanel
    let model: ZoneButtonModel

    init(id: String, panel: NSPanel, model: ZoneButtonModel) {
        self.id = id
        self.panel = panel
        self.model = model
    }
}

// MARK: - Action button internals

private final class ZoneButtonModel: ObservableObject {
    @Published var pressed = false
}

/// Click target for a window that never becomes key.
///
/// `acceptsFirstMouse` is load-bearing: in a non-activating panel the first click
/// would otherwise be spent activating the window and swallowed, so every press would
/// need two clicks. Subview hit-testing is disabled so the SwiftUI appearance layer
/// cannot intercept the event before this view sees it.
private final class SendButtonView: NSView {
    var onClick: (() -> Void)?
    var onPressedChange: ((Bool) -> Void)?
    var hitTestSubviewsDisabled = false

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard hitTestSubviewsDisabled else { return super.hitTest(point) }
        return bounds.contains(convert(point, from: superview)) ? self : nil
    }

    override func mouseDown(with event: NSEvent) {
        onPressedChange?(true)
    }

    override func mouseUp(with event: NSEvent) {
        onPressedChange?(false)
        // Only fire if released inside, matching normal button behaviour so a press
        // dragged off the button can be abandoned.
        if bounds.contains(convert(event.locationInWindow, from: nil)) { onClick?() }
    }
}

private struct ZoneButtonContent: View {
    @ObservedObject var model: ZoneButtonModel
    let symbol: String
    let title: String
    let accent: Color

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 12)
                .fill(model.pressed ? accent.opacity(0.40) : Color.black.opacity(0.30))
            RoundedRectangle(cornerRadius: 12)
                .strokeBorder(model.pressed ? accent.opacity(0.9) : Color.white.opacity(0.20),
                              lineWidth: model.pressed ? 2 : 1)
            VStack(spacing: 2) {
                Image(systemName: symbol)
                    .font(.system(size: 17, weight: .medium))
                Text(title)
                    .font(.system(size: 10, weight: .medium))
            }
            .foregroundColor(model.pressed ? accent : Color.white.opacity(0.55))
        }
        .animation(.easeOut(duration: 0.1), value: model.pressed)
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
