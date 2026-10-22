import Foundation
import Combine

/// Optional mode for when other people are in the room: only an utterance that opens
/// with the wake word is typed, minus the word, and the gate shuts behind it. Off
/// (the default) is ordinary always-on dictation.
///
/// Speech that arrives while the gate is shut is dropped, not buffered — the point
/// of the mode is that a conversation across the desk leaves no trace anywhere.
final class WakeGate: ObservableObject {
    static let enabledKey = "wakeWordEnabled"
    static let word = "pilot"
    /// Safety for a gate opened by a partial whose final never comes: shut it after
    /// this much silence. (Was the continuation window — 20 s, then 4 s — before the
    /// one-utterance rule: on 2026-10-22 one "pilot" let six other people's utterances
    /// through over 50 s, each arriving within the window and keeping it alive.)
    static let idleWindow: TimeInterval = 4

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

    /// Opened by a partial and not yet confirmed by its final. A partial that begins
    /// "Pilot" can still finalise as "Pilots are flying", so the final has the last
    /// word: it either confirms the opening or shuts the gate and is dropped.
    private var provisional = false

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

    /// Every partial. Opens the gate as soon as one begins with the wake word, 1–3 s
    /// before the final would — measured 2026-10-22: "Pilot" was in the partials at
    /// 4:49:14 and the final opened the gate at 4:49:17. The state reacts at once; the
    /// words still land when the recogniser finalises.
    func notePartial(_ text: String) {
        noteActivity()
        guard enabled, !open, Self.opens(text) else { return }
        provisional = true
        vpLog("[Gate] opened by \"\(Self.word)\" in a partial — awaiting the final")
        setOpen(true)
        scheduleClose()
    }

    /// What to deliver from a final, or nil when the gate swallowed it.
    func admit(_ text: String) -> String? {
        guard enabled else { return text }
        noteActivity()

        let whole = NSRange(text.startIndex..., in: text)
        if let match = Self.opener.firstMatch(in: text, range: whole),
           let range = Range(match.range, in: text) {
            let rest = String(text[range.upperBound...])
            vpLog("[Gate] opened by \"\(Self.word)\"\(provisional ? " (confirmed)" : "") — delivering '\(rest.prefix(60))'")
            // One utterance per wake word: the sentence that starts with "pilot" is
            // typed and the gate shuts behind it. Chosen 2026-10-22 after the pause
            // rule still let a reply land within the 4 s gap. Every sentence needs the
            // word; nothing anyone else says can ride on it.
            provisional = false
            setOpen(false)
            return rest
        }

        if open && provisional {
            // The partial that opened the gate finalised as something else.
            provisional = false
            vpLog("[Gate] partial opening not confirmed by the final — dropped '\(text.prefix(60))'")
            setOpen(false)
            return nil
        }
        vpLog("[Gate] closed — dropped '\(text.prefix(60))'")
        return nil
    }

    private static func opens(_ text: String) -> Bool {
        let whole = NSRange(text.startIndex..., in: text)
        return opener.firstMatch(in: text, range: whole) != nil
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

    /// The prompt went off; whatever is said next is a new one and needs its own
    /// "pilot". Wired to the same path as middle-click and the Send button.
    func closeForSend() {
        close(reason: "send")
    }

    private func close(reason: String) {
        guard open else { return }
        provisional = false
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
