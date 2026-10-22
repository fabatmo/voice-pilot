import AppKit
import Combine
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
final class ParkZoneController: NSObject, WindowRevealing {
    /// Whether the zone was on screen last time, so it comes back on relaunch.
    static let visibleKey = "parkZoneVisible"
    private static let autosaveName = "VoicePilotParkZone"

    private var panel: NSPanel?
    private let terminalController: TerminalController
    private let speechEngine: SpeechEngine
    private let wakeGate: WakeGate
    private var debouncer: HoverParkDebouncer?

    // Action buttons are companion windows rather than controls inside the zone:
    // anything inside the zone would sit in its tracking area, so reaching for it
    // would park — and the submit and clear paths are both no-ops while parked, making
    // the buttons dead exactly when aimed at.
    private var buttons: [ZoneButtonWindow] = []
    private var listeningObserver: AnyCancellable?
    private var wakeObserver: AnyCancellable?
    private var gateObserver: AnyCancellable?
    private static let buttonGap: CGFloat = 10      // zone to column
    private static let buttonSpacing: CGFloat = 5   // button to button
    private static let buttonSize = NSSize(width: 52, height: 34)
    private static let cardMargin: CGFloat = 4      // card edge to column, top and bottom
    // Sized so three buttons fit the card at the height two did (120 pt): 3 × 34 + 2 × 5
    // + 2 × 4. The first cut used 38 pt buttons and 10 pt margins, which forced the
    // zone 26 pt taller — reported 2026-10-08 as the zone suddenly being bigger.
    // The fourth button (wake word mode, 2026-10-22) adds 39 pt: the card is 159 pt.
    private static let buttonCount = 4              // Send, Clear, Mute, Pilot

    private static func columnHeight(count: Int) -> CGFloat {
        let n = CGFloat(count)
        return n * buttonSize.height + (n - 1) * buttonSpacing
    }

    /// Invoked on send. Wired by AppDelegate to the same path as middle-click.
    var onSend: (() -> Void)?
    /// Invoked on clear. Wipes the terminal's input line.
    var onClear: (() -> Void)?

    var isVisible: Bool { panel != nil }

    init(terminalController: TerminalController, speechEngine: SpeechEngine, wakeGate: WakeGate) {
        self.terminalController = terminalController
        self.speechEngine = speechEngine
        self.wakeGate = wakeGate
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
        win.minSize = NSSize(width: 80, height: 44)   // replaced below, once the
                                                      // titlebar inset is measurable
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

        // The card is drawn in the safe area, which excludes the hidden titlebar strip,
        // so the window is always taller than what the user sees. Measure that inset
        // rather than assuming it, then keep the window tall enough for the button
        // column to sit inside the card with real margins — below this the buttons
        // overhang the card, which is the reported fault.
        let cardInset = max(0, win.frame.height - win.contentLayoutRect.height)
        let minCard = Self.columnHeight(count: Self.buttonCount) + Self.cardMargin * 2
        win.minSize = NSSize(width: 80, height: minCard + cardInset)
        if win.frame.height < win.minSize.height {
            var f = win.frame
            // Grow downward from the top edge, so the zone stays where it was put.
            f.origin.y -= win.minSize.height - f.height
            f.size.height = win.minSize.height
            win.setFrame(f, display: true)
            vpLog("[Park] grew zone to \(f.size) so the buttons fit inside the card")
        }
        vpLog("[Park] geometry frame=\(win.frame) contentLayout=\(win.contentLayoutRect) "
              + "cardInset=\(cardInset) minSize=\(win.minSize)")

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

    // MARK: - Recovery after wake / display change

    /// Re-asserts the zone and its buttons. The frame check has to come first: after a
    /// display goes away the zone can be sitting where no screen is, and ordering an
    /// off-screen window front is a no-op the user reads as "the app lost my window".
    /// Brings the zone to the display the pointer is on. Buttons follow via
    /// positionButtons in reveal(), which the caller runs straight after.
    func recallToPointer() {
        guard let win = panel else { return }
        // Inset from the screen's left edge leaves room for the button column, which
        // hangs off that side.
        recallWindowToPointer(win, label: "park zone", inset: NSPoint(x: 90, y: 80))
        win.saveFrame(usingName: Self.autosaveName)
    }

    func reveal() {
        guard let win = panel else { return }

        ensureWindowOnScreen(win, label: "park zone")
        win.level = .floating
        win.orderFront(nil)

        // Buttons are placed relative to the zone, so they must be recomputed after any
        // move rather than merely raised.
        positionButtons()
        for b in buttons {
            b.panel.level = .floating
            b.panel.orderFront(nil)
        }

        // Persist the corrected position: the frame autosave will have already stored
        // the displaced one, which is how a bad frame survives a relaunch.
        win.saveFrame(usingName: Self.autosaveName)
        vpLog("[Park] revealed — zone at \(win.frame), \(buttons.count) buttons")
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
            makeButton(id: "mute", symbol: "mic", title: "Mute", accent: .red) { [weak self] in
                vpLog("[Park] mute button pressed")
                self?.speechEngine.toggleListening()
            },
            makeButton(id: "pilot", symbol: "person.2", title: "Pilot", accent: .blue) { [weak self] in
                vpLog("[Park] pilot button pressed")
                self?.wakeGate.enabled.toggle()
            },
        ]

        // Mute and Pilot carry state. They follow the model rather than their own
        // clicks, so a change from the menu bar shows here too — and they stay lit
        // while on, because a silent app with nothing on screen saying why reads as a
        // broken one.
        listeningObserver = speechEngine.$isListening.sink { [weak self] listening in
            self?.showMuteState(muted: !listening)
        }
        wakeObserver = wakeGate.$enabled.sink { [weak self] enabled in
            self?.showWakeState(enabled: enabled)
        }
        gateObserver = wakeGate.$open.sink { [weak self] open in
            self?.showGateState(open: open)
        }

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

        let model = ZoneButtonModel(symbol: symbol, title: title)
        let click = SendButtonView(frame: NSRect(origin: .zero, size: size))
        click.autoresizingMask = [.width, .height]
        click.onPressedChange = { down in model.pressed = down }
        click.onClick = action

        let host = NSHostingView(
            rootView: ZoneButtonContent(model: model, accent: accent)
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

    private func showMuteState(muted: Bool) {
        guard let model = buttons.first(where: { $0.id == "mute" })?.model else { return }
        model.symbol = muted ? "mic.slash" : "mic"
        model.title = muted ? "Unmute" : "Mute"
        model.latched = muted
    }

    /// Lit while the wake word mode is on: the room-wide "I am not being typed" cue.
    private func showWakeState(enabled: Bool) {
        guard let model = buttons.first(where: { $0.id == "pilot" })?.model else { return }
        model.symbol = enabled ? "person.2.fill" : "person.2"
        model.title = enabled ? "Pilot on" : "Pilot"
        model.latched = enabled
    }

    /// Green "Listening" the moment a partial opens the gate — the "I heard you"
    /// the mode needs, since from the outside a shut gate and a deaf app look alike.
    private func showGateState(open: Bool) {
        guard let model = buttons.first(where: { $0.id == "pilot" })?.model else { return }
        model.hot = open
        if open {
            model.symbol = "waveform"
            model.title = "Listening"
        } else {
            showWakeState(enabled: wakeGate.enabled)
        }
    }

    private func hideButtons() {
        listeningObserver = nil
        wakeObserver = nil
        gateObserver = nil
        for b in buttons { b.panel.orderOut(nil) }
        buttons.removeAll()
    }

    @objc private func zoneFrameChanged() {
        positionButtons()
    }

    /// Screen rect of the card the user actually sees.
    ///
    /// Not the window frame. The zone is a .titled window, so its frame includes a
    /// titlebar strip that is hidden but still reserved, and the card is drawn below it.
    /// Centring the column on the frame therefore sits it visibly high against the card
    /// and lets the top button overhang — which is exactly what was reported.
    private func zoneCardRect() -> NSRect {
        guard let win = panel else { return .zero }
        let layout = win.contentLayoutRect
        guard layout.width > 0, layout.height > 0 else { return win.frame }
        return win.convertToScreen(layout)
    }

    /// Lays the buttons out as a vertical column just outside the zone, never touching
    /// it, so the zone's tracking area and the click targets can never overlap. Flips
    /// to the zone's other side when there is not enough room on the preferred one.
    private func positionButtons() {
        guard !buttons.isEmpty else { return }
        let z = zoneCardRect()
        guard z.height > 0 else { return }
        let size = Self.buttonSize
        let columnHeight = Self.columnHeight(count: buttons.count)

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
    /// Held on by state rather than by the mouse — the mute button while muted.
    @Published var latched = false
    /// Lit in green instead of the button's own accent — the Pilot button while the
    /// gate is open, the "I heard you" flash Fabian asked for 2026-10-22.
    @Published var hot = false
    @Published var symbol: String
    @Published var title: String

    init(symbol: String, title: String) {
        self.symbol = symbol
        self.title = title
    }
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
    let accent: Color

    private var lit: Bool { model.pressed || model.latched || model.hot }
    private var tint: Color { model.hot ? .green : accent }

    private var fill: Color {
        if model.pressed || model.hot { return tint.opacity(0.40) }
        return model.latched ? tint.opacity(0.20) : ZoneStyle.fill
    }

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: ZoneStyle.corner)
                .fill(fill)
            RoundedRectangle(cornerRadius: ZoneStyle.corner)
                .strokeBorder(lit ? tint.opacity(0.9) : ZoneStyle.border,
                              lineWidth: lit ? 2 : 1)
            VStack(spacing: 2) {
                Image(systemName: model.symbol)
                    .font(.system(size: 14, weight: .medium))
                Text(model.title)
                    .font(.system(size: 9, weight: .medium))
            }
            .foregroundColor(lit ? tint : Color.white.opacity(0.55))
        }
        .animation(.easeOut(duration: 0.1), value: model.pressed)
        .animation(.easeOut(duration: 0.1), value: model.latched)
        .animation(.easeOut(duration: 0.1), value: model.hot)
    }
}

// MARK: - Appearance

/// Palette for the floating controls.
///
/// Translucent by request — these sit on top of whatever is being dictated into, and
/// the point is to see through them. A solid card was tried and rejected. The trade is
/// accepted deliberately: the controls take their apparent colour from the backdrop, so
/// they read light over a pale window and dark over a black one.
enum ZoneStyle {
    static let fill = Color.black.opacity(0.30)
    static let border = Color.white.opacity(0.20)
    static let ink = Color.white.opacity(0.45)

    static let parkedFill = Color.orange.opacity(0.20)
    static let parkedBorder = Color.orange.opacity(0.85)
    static let parkedInk = Color.orange

    static let corner: CGFloat = 12
}

private struct ParkZoneView: View {
    @ObservedObject var terminalController: TerminalController

    private var parked: Bool { terminalController.parked }

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: ZoneStyle.corner)
                .fill(parked ? ZoneStyle.parkedFill : ZoneStyle.fill)
            RoundedRectangle(cornerRadius: ZoneStyle.corner)
                .strokeBorder(parked ? ZoneStyle.parkedBorder : ZoneStyle.border,
                              lineWidth: parked ? 2 : 1)

            VStack(spacing: 5) {
                Image(systemName: parked ? "pause.circle.fill" : "pause.circle")
                    .font(.system(size: 20, weight: .light))
                Text(parked ? "Parked" : "Park")
                    .font(.system(size: 11, weight: .medium))
                if parked {
                    Text("buffering")
                        .font(.system(size: 9))
                }
            }
            .foregroundColor(parked ? ZoneStyle.parkedInk : ZoneStyle.ink)
            .padding(6)
        }
        .animation(.easeOut(duration: 0.12), value: parked)
    }
}
