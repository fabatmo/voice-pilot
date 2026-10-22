import Foundation
import Combine

/// Optional mode for when other people are in the room: nothing is typed until an
/// utterance opens with the wake word; the gate then stays open across pauses up to
/// `idleWindow`, and "action send" submits the prompt and shuts it. Off (the default)
/// is ordinary always-on dictation.
///
/// Speech that arrives while the gate is shut is dropped, not buffered — the point
/// of the mode is that a conversation across the desk leaves no trace anywhere.
/// While it is open, the gate cannot tell voices apart: on 2026-10-22 one "pilot"
/// let six other people's utterances through in 50 s. Fabian chose 20 s with
/// a spoken end over the one-utterance rule tried in between. The command carries
/// its own prefix, "action", so it is never mistaken for the wake word opening a
/// sentence that happens to start with "send".
final class WakeGate: ObservableObject {
    static let enabledKey = "wakeWordEnabled"
    static let word = "pilot"
    static let actionWord = "action"
    /// Longest silence that keeps the gate open, measured from the last thing heard.
    static let idleWindow: TimeInterval = 20

    /// What to do with a final.
    enum Verdict {
        /// Type this (possibly empty, when the utterance was just the wake word).
        case type(String)
        /// Type this, then submit — "… action send" at the end of a sentence.
        case typeThenSend(String)
        /// Submit what has been typed — "action send" on its own.
        case send
        /// Wipe the line — "action delete".
        case clear
        /// Press Escape — "action stop".
        case escape
        /// The gate swallowed it.
        case drop
    }

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

    /// Fires when a final opens the gate, before its words are typed. AppDelegate uses
    /// it to flush what was buffered while parked into the prompt first.
    var onOpened: (() -> Void)?

    private var lastActivity = Date.distantPast
    private var closeGeneration = 0

    /// Opened by a partial and not yet confirmed by its final. A partial that begins
    /// "Pilot" can still finalise as "Pilots are flying", so the final has the last
    /// word: it either confirms the opening or shuts the gate and is dropped.
    private var provisional = false

    /// The wake word where it starts a sentence, swallowing the punctuation and
    /// whitespace the recogniser puts after it so the remainder is ready to type.
    ///
    /// Two shapes, because the segmenter merges whatever was said just before with
    /// the wake word when there is no pause between them — 2026-10-22 17:14 the final
    /// was 'Uh-huh. Pilot, okay. …' and 17:15 'Action that has that. Pilot, let's add
    /// …', both missed by a start-anchored match:
    ///   • at the very start, any case, with fillers allowed before it ("Uh, pilot");
    ///   • after sentence punctuation with a capital P, which is how the recogniser
    ///     marks a new sentence — "the pilot said" never gets one, so it stays a word.
    /// The last such match wins; what precedes it was not addressed to the app.
    private static let opener = try! NSRegularExpression(
        pattern: "(?:(?i:^\\W*(?:(?:uh|um|uh-huh|hmm|hm|okay|ok|yeah|so|and|hey|voice)[\\s,.!?-]+)*pilot)|[.!?]\\s+Pilot)\\b[\\s,.!?:;]*",
        options: []
    )

    /// Range of the wake word that opens this text, or nil.
    private static func openerRange(in text: String) -> Range<String.Index>? {
        let whole = NSRange(text.startIndex..., in: text)
        guard let last = opener.matches(in: text, range: whole).last else { return nil }
        return Range(last.range, in: text)
    }

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

    /// "action send" / "action delete" / "action stop" at the end of an utterance,
    /// with whatever punctuation the recogniser wrapped it in: "Action send.",
    /// ", action, delete!".
    private static let command = try! NSRegularExpression(
        pattern: "[\\s,.;:]*\\baction\\b[\\s,]+(send|delete|stop)\\b[\\s.!?]*$",
        options: .caseInsensitive
    )

    /// What to do with a final.
    func admit(_ text: String) -> Verdict {
        guard enabled else { return .type(text) }
        noteActivity()

        var body = text
        var command: String?
        let whole = NSRange(body.startIndex..., in: body)
        if let match = Self.command.firstMatch(in: body, range: whole),
           let range = Range(match.range, in: body),
           let verb = Range(match.range(at: 1), in: body) {
            command = body[verb].lowercased()
            body = String(body[..<range.lowerBound])
        }

        // "action delete" wipes the line; words spoken before it in the same breath
        // would be typed and wiped again, so they are dropped instead.
        if command == "delete" {
            vpLog("[Gate] \"\(Self.actionWord) delete\"\(body.isEmpty ? "" : " — dropping the words before it: '\(body.prefix(60))'")")
            return .clear
        }
        // "action stop" is Escape: cancel whatever the app is doing. Words before it
        // are dropped for the same reason — they were part of what is being stopped.
        if command == "stop" {
            vpLog("[Gate] \"\(Self.actionWord) stop\"\(body.isEmpty ? "" : " — dropping the words before it: '\(body.prefix(60))'")")
            return .escape
        }
        let sends = command == "send"

        if let range = Self.openerRange(in: body) {
            let rest = String(body[range.upperBound...])
            let before = body[..<range.lowerBound].trimmingCharacters(in: .whitespaces)
            if !before.isEmpty {
                vpLog("[Gate] dropping what the segmenter merged in before \"\(Self.word)\": '\(before.prefix(60))'")
            }
            vpLog("[Gate] opened by \"\(Self.word)\"\(provisional ? " (confirmed)" : "") — delivering '\(rest.prefix(60))'\(sends ? " then send" : "")")
            provisional = false
            setOpen(true)
            scheduleClose()
            onOpened?()
            return sends ? .typeThenSend(rest) : .type(rest)
        }

        if sends {
            // "action send" on its own, or ending a sentence spoken while open.
            if body.trimmingCharacters(in: .whitespaces).isEmpty {
                vpLog("[Gate] \"\(Self.actionWord) send\"")
                return .send
            }
            if open && !provisional {
                vpLog("[Gate] open — delivering '\(body.prefix(60))' then send")
                return .typeThenSend(body)
            }
            vpLog("[Gate] \"\(Self.actionWord) send\" — dropping the words before it, gate was shut: '\(body.prefix(60))'")
            return .send
        }

        if open {
            if provisional {
                // The partial that opened the gate finalised as something else.
                provisional = false
                vpLog("[Gate] partial opening not confirmed by the final — dropped '\(text.prefix(60))'")
                setOpen(false)
                return .drop
            }
            return .type(text)
        }
        vpLog("[Gate] closed — dropped '\(text.prefix(60))'")
        return .drop
    }

    private static func opens(_ text: String) -> Bool {
        openerRange(in: text) != nil
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
