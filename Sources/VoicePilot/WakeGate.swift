import Foundation
import Combine

/// Optional mode for when other people are in the room: nothing is typed until an
/// utterance opens with the wake word, and the gate shuts again after 20 s without
/// speech. Off (the default) is ordinary always-on dictation.
///
/// Speech that arrives while the gate is shut is dropped, not buffered — the point
/// of the mode is that a conversation across the desk leaves no trace anywhere.
final class WakeGate: ObservableObject {
    static let enabledKey = "wakeWordEnabled"
    static let word = "pilot"
    static let idleWindow: TimeInterval = 20

    /// Whether the mode is on. Persisted; the floater button and the menu both flip it.
    @Published var enabled: Bool {
        didSet {
            guard enabled != oldValue else { return }
            UserDefaults.standard.set(enabled, forKey: Self.enabledKey)
            vpLog("[Gate] wake word mode \(enabled ? "on" : "off")")
            if !enabled { close(reason: "mode switched off") }
        }
    }

    /// True while speech is being let through. Meaningless when the mode is off.
    @Published private(set) var open = false

    private var lastActivity = Date.distantPast
    private var closeGeneration = 0

    /// "Pilot", "pilot,", "Pilot." … at the very start, swallowing the punctuation and
    /// whitespace the recogniser puts after it so the remainder is ready to type.
    private static let opener = try! NSRegularExpression(
        pattern: "^\\W*pilot\\b[\\s,.!?:;]*",
        options: .caseInsensitive
    )

    init() {
        enabled = UserDefaults.standard.bool(forKey: Self.enabledKey)
    }

    /// Call on every partial and final. Measured from the last thing heard rather than
    /// the last thing delivered, so the recogniser's finalisation lag does not eat the
    /// window.
    func noteActivity() {
        lastActivity = Date()
    }

    /// What to deliver from a final, or nil when the gate swallowed it.
    func admit(_ text: String) -> String? {
        guard enabled else { return text }
        noteActivity()

        let whole = NSRange(text.startIndex..., in: text)
        if let match = Self.opener.firstMatch(in: text, range: whole),
           let range = Range(match.range, in: text) {
            let rest = String(text[range.upperBound...])
            vpLog("[Gate] opened by \"\(Self.word)\" — delivering '\(rest.prefix(60))'")
            setOpen(true)
            scheduleClose()
            return rest
        }

        if open { return text }
        vpLog("[Gate] closed — dropped '\(text.prefix(60))'")
        return nil
    }

    private func scheduleClose() {
        closeGeneration += 1
        let generation = closeGeneration
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.idleWindow) { [weak self] in
            self?.checkIdle(generation: generation)
        }
    }

    /// Fires 20 s after the last final. Speech since then (partials count) pushes the
    /// deadline out by however much is left, so the gate only shuts on real silence.
    private func checkIdle(generation: Int) {
        guard generation == closeGeneration, open else { return }
        let idle = Date().timeIntervalSince(lastActivity)
        if idle >= Self.idleWindow {
            close(reason: "\(Int(idle)) s silence")
        } else {
            DispatchQueue.main.asyncAfter(deadline: .now() + (Self.idleWindow - idle)) { [weak self] in
                self?.checkIdle(generation: generation)
            }
        }
    }

    private func close(reason: String) {
        guard open else { return }
        vpLog("[Gate] closed after \(reason) — say \"\(Self.word)\" to dictate")
        setOpen(false)
    }

    /// Finals from the legacy backend arrive off the main thread; @Published must not.
    private func setOpen(_ value: Bool) {
        if Thread.isMainThread {
            open = value
        } else {
            DispatchQueue.main.sync { self.open = value }
        }
    }
}
