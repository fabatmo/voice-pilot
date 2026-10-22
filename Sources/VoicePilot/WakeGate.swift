import Foundation
import Combine

/// Optional mode for when other people are in the room: nothing is typed until an
/// utterance opens with the wake word; the gate then stays open across pauses up to
/// `idleWindow`, and "action send" submits the prompt and shuts it. Off (the default)
/// is ordinary always-on dictation.
///
/// Spoken commands — "action send", "action delete", "action open Photoshop" … — are
/// decided here as well, whether the mode is on or off, and carried out by
/// AppDelegate. They carry their own prefix, "action", so they are never mistaken
/// for the wake word opening a sentence that happens to start with "send".
///
/// Speech that arrives while the gate is shut is dropped, not buffered — the point
/// of the mode is that a conversation across the desk leaves no trace anywhere.
/// While it is open, the gate cannot tell voices apart: on 2026-10-22 one "pilot"
/// let six other people's utterances through in 50 s. Fabian chose a silence window
/// with a spoken end, and a timeout that wipes, over the one-utterance rule tried in
/// between.
final class WakeGate: ObservableObject {
    static let enabledKey = "wakeWordEnabled"
    static let word = "pilot"
    static let actionWord = "action"

    /// Longest silence that keeps the gate open, measured from the last thing heard.
    /// Was 20 s, then 10; Fabian asked for shorter again on 2026-10-22 evening, and
    /// made the timeout a cancel: a window that ends in silence rather than "action
    /// send" leaves nothing behind. "action write" is the way to get longer.
    static let silenceWindow: TimeInterval = 6
    /// "action write": room to think. The window a composed prompt gets.
    static let writeWindow: TimeInterval = 60

    /// The window currently in force — `silenceWindow`, or `writeWindow` after
    /// "action write" until the gate next shuts.
    private(set) var idleWindow: TimeInterval = WakeGate.silenceWindow

    /// True while the long "action write" window is in force. The card shows it in
    /// orange where ordinary listening is green, so the mode is never a guess.
    @Published private(set) var writing = false

    /// Spoken "action mute" in pilot mode. The mic stays on — a muted mic could never
    /// hear the wake-up — but everything is dropped, the wake word and commands
    /// included, until "hey pilot". Fabian's remote-control idea, 2026-10-22: sleep,
    /// then "hey pilot, action play music" from across the room. The mute button is
    /// still a real mic-off.
    @Published private(set) var sleeping = false

    /// "hey pilot", "hi pilot", "okay pilot" — the only thing heard while asleep.
    private static let wakeUp = try! NSRegularExpression(
        pattern: "^\\W*(?:hey|hi|ok|okay)[\\s,]+pilot\\b",
        options: .caseInsensitive
    )

    private static func wakesUp(_ text: String) -> Bool {
        wakeUp.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil
    }

    /// A spoken "action …". The gate decides; AppDelegate carries it out.
    enum Command: Equatable {
        /// Enter, and the prompt is done — "action send".
        case send
        /// Remove what this app typed — "action delete".
        case delete
        /// Select all in the focused field and delete — "action delete all".
        case deleteAll
        /// Escape — "action stop".
        case stop
        /// Mute the mic — "action mute". There is no spoken unmute: a muted app
        /// cannot hear one. The button does that.
        case mute
        /// Open the gate with the long window — "action write".
        case write
        /// A keystroke, by System Events key code and modifier names.
        case key(code: Int, modifiers: [String], label: String)
        /// Launch an app, folder or file by spoken name — "action open Illustrator".
        case open(String)
        /// Music transport — "action play music", "action next song".
        case media(String)
    }

    /// What to do with a final.
    enum Verdict {
        /// Type this (possibly empty, when the utterance was just the wake word).
        case type(String)
        /// Type this, then submit — "… action send" at the end of a sentence.
        case typeThenSend(String)
        /// Carry out a command.
        case command(Command)
        /// The gate swallowed it.
        case drop
    }

    /// Whether the mode is on. Persisted; the floater button and the menu both flip it.
    @Published var enabled: Bool {
        didSet {
            guard enabled != oldValue else { return }
            UserDefaults.standard.set(enabled, forKey: Self.enabledKey)
            vpLog("[Gate] wake word mode \(enabled ? "on" : "off")")
            if !enabled {
                close(reason: "mode switched off")
                sleeping = false
            }
        }
    }

    /// True while speech is being let through. Meaningless when the mode is off.
    @Published private(set) var open = false

    /// Fires when a final opens the gate, before its words are typed. AppDelegate uses
    /// it to flush what was buffered while parked into the prompt first.
    var onOpened: (() -> Void)?

    /// Fires when the gate shuts on silence, after `open` has gone false. AppDelegate
    /// uses it to wipe what the window typed, so a window has two endings — sent, or
    /// gone — and anything that leaked in from the room never lingers in the prompt.
    var onTimedOut: (() -> Void)?

    private var lastActivity = Date.distantPast
    private var closeGeneration = 0

    /// Opened by a partial and not yet confirmed by its final. A partial that begins
    /// "Pilot" can still finalise as "Pilots are flying", so the final has the last
    /// word: it either confirms the opening or shuts the gate and is dropped.
    private var provisional = false

    /// Set when a command ran from a partial; the segment's final must not run it
    /// again. Reset by every final.
    private var partialCommandFired = false

    // MARK: - Patterns

    private static let fillers = "(?:(?:uh|um|uh-huh|hmm|hm|okay|ok|yeah|so|and|hey|voice)[\\s,.!?-]+)*"

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
        pattern: "(?:(?i:^\\W*\(fillers)pilot)|[.!?]\\s+Pilot)\\b[\\s,.!?:;]*",
        options: []
    )

    /// Spoken verbs, longest first so "delete all" wins over "delete". "sent" is
    /// what the recogniser made of "send" at 7:47 PM on 2026-10-22 — typed as text.
    private static let verbs = "send|sent|pass|delete all|clear all|clear|delete|stop music|stop|mute|write|select all|copy|paste|cut|undo|redo|new line|tab|save|close|find|open|play music|pause music|next song|previous song|like"

    /// "action <verb> [argument]" at the end of an utterance, with whatever
    /// punctuation the recogniser wrapped it in: "Action send.", ", action, delete!",
    /// "action open Photoshop".
    ///
    /// "pass" alone at the end is "action send" — Fabian's shorthand (2026-10-22):
    /// "… and that's it, pass." Only as the last word; "pass the file" is dictation.
    private static let command = try! NSRegularExpression(
        pattern: "[\\s,.;:]*\\b(?:action\\b[\\s,]+(\(verbs))|(pass))\\b(?:[\\s,]+(.+?))?[\\s.!?]*$",
        options: .caseInsensitive
    )

    /// The wake word and a verb with nothing else — "Pilot send." — is the command
    /// too. Fabian said it that way three times on 2026-10-22 and got "send." typed;
    /// "pilot, send the file" is still words, because something follows the verb.
    private static let bareCommand = try! NSRegularExpression(
        pattern: "^\\W*\(fillers)pilot\\b[\\s,.]+(\(verbs))\\b(?:[\\s,]+(.+?))?[\\s.!?]*$",
        options: .caseInsensitive
    )

    /// A parsed "action …": the verb, what followed it, and the words before it.
    private struct Spoken {
        let verb: String
        let argument: String
        let body: String
        /// A lone "pass" with no "action" or "pilot" before it. Never run from a
        /// partial: partials arrive letter by letter, and "pass" is how "passport"
        /// and "passed" begin.
        var shorthand = false
        var bare: Bool { body.trimmingCharacters(in: .whitespaces).isEmpty }
    }

    private static func parse(_ text: String) -> Spoken? {
        let whole = NSRange(text.startIndex..., in: text)
        let spoken: Spoken
        if let match = bareCommand.firstMatch(in: text, range: whole),
           let verb = Range(match.range(at: 1), in: text) {
            let argument = Range(match.range(at: 2), in: text).map { String(text[$0]) } ?? ""
            spoken = Spoken(verb: text[verb].lowercased(), argument: argument, body: "")
        } else if let match = command.firstMatch(in: text, range: whole),
                  let range = Range(match.range, in: text) {
            let shorthand = match.range(at: 1).location == NSNotFound
            let verb = Range(match.range(at: shorthand ? 2 : 1), in: text).map { text[$0].lowercased() } ?? "pass"
            let argument = Range(match.range(at: 3), in: text).map { String(text[$0]) } ?? ""
            spoken = Spoken(verb: verb, argument: argument, body: String(text[..<range.lowerBound]), shorthand: shorthand)
        } else {
            return nil
        }
        // "open" needs a target; "delete all" tolerates one ("… all lines"); any other
        // verb followed by more words is a sentence, not a command — "action copy the
        // file" is dictation.
        switch spoken.verb {
        case "open": return spoken.argument.isEmpty ? nil : spoken
        case "delete all", "clear", "clear all": return spoken
        default: return spoken.argument.isEmpty ? spoken : nil
        }
    }

    private static func command(for spoken: Spoken) -> Command {
        switch spoken.verb {
        case "send", "sent", "pass": return .send
        case "delete": return .delete
        case "delete all", "clear", "clear all": return .deleteAll
        case "stop": return .stop
        case "mute": return .mute
        case "write": return .write
        case "select all": return .key(code: 0, modifiers: ["command"], label: "⌘A")
        case "copy": return .key(code: 8, modifiers: ["command"], label: "⌘C")
        case "paste": return .key(code: 9, modifiers: ["command"], label: "⌘V")
        case "cut": return .key(code: 7, modifiers: ["command"], label: "⌘X")
        case "undo": return .key(code: 6, modifiers: ["command"], label: "⌘Z")
        case "redo": return .key(code: 6, modifiers: ["command", "shift"], label: "⇧⌘Z")
        case "new line": return .key(code: 36, modifiers: ["shift"], label: "⇧⏎")
        case "tab": return .key(code: 48, modifiers: [], label: "⇥")
        case "save": return .key(code: 1, modifiers: ["command"], label: "⌘S")
        case "close": return .key(code: 13, modifiers: ["command"], label: "⌘W")
        case "find": return .key(code: 3, modifiers: ["command"], label: "⌘F")
        case "play music", "pause music", "stop music", "next song", "previous song", "like": return .media(spoken.verb)
        default: return .open(spoken.argument)
        }
    }

    /// Range of the wake word that opens this text, or nil.
    private static func openerRange(in text: String) -> Range<String.Index>? {
        let whole = NSRange(text.startIndex..., in: text)
        guard let last = opener.matches(in: text, range: whole).last else { return nil }
        return Range(last.range, in: text)
    }

    init() {
        enabled = UserDefaults.standard.bool(forKey: Self.enabledKey)
    }

    // MARK: - Partials

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
        if sleeping {
            guard Self.wakesUp(text) else { return }
            vpLog("[Gate] \"hey \(Self.word)\" in a partial — awake")
            onMain { self.sleeping = false }
        }
        guard enabled, !open, Self.openerRange(in: text) != nil else { return }
        provisional = true
        vpLog("[Gate] opened by \"\(Self.word)\" in a partial — awaiting the final")
        setOpen(true)
        scheduleClose()
    }

    /// A command on its own in a partial: run it now, not 1–2 s later when the final
    /// lands (Fabian, 2026-10-22: "for any action command, don't wait"). Only the bare
    /// form — words in front of it are not final yet and have to be typed first — and
    /// never "open", whose target is still being spoken.
    func immediateCommand(in partial: String) -> Command? {
        guard !sleeping, !partialCommandFired, let spoken = Self.parse(partial), spoken.bare, !spoken.shorthand, spoken.verb != "open" else { return nil }
        partialCommandFired = true
        let command = Self.command(for: spoken)
        vpLog("[Gate] \"\(Self.actionWord) \(spoken.verb)\" in a partial — executing now")
        apply(command)
        return command
    }

    // MARK: - Finals

    /// What to do with a final.
    func admit(_ text: String) -> Verdict {
        let firedEarly = partialCommandFired
        partialCommandFired = false
        noteActivity()

        if sleeping {
            guard Self.wakesUp(text) else {
                vpLog("[Gate] asleep — dropped '\(text.prefix(60))'")
                return .drop
            }
            vpLog("[Gate] \"hey \(Self.word)\" — awake")
            onMain { self.sleeping = false }
        }

        let spoken = Self.parse(text)
        let body = spoken?.body ?? text

        if let spoken {
            if firedEarly, spoken.bare {
                vpLog("[Gate] \"\(Self.actionWord) \(spoken.verb)\" already executed from the partial")
                return .drop
            }
            let command = Self.command(for: spoken)
            if command == .send {
                return admitSend(body: body)
            }
            // Words spoken before a command in the same breath are dropped: they were
            // part of what is being cancelled, copied or opened, not dictation.
            let dropped = body.trimmingCharacters(in: .whitespaces)
            vpLog("[Gate] \"\(Self.actionWord) \(spoken.verb)\"\(spoken.argument.isEmpty ? "" : " '\(spoken.argument)'")\(dropped.isEmpty ? "" : " — dropping the words before it: '\(dropped.prefix(60))'")")
            apply(command)
            return .command(command)
        }

        return admitWords(text, sends: false)
    }

    /// "action send", alone or ending a sentence.
    private func admitSend(body: String) -> Verdict {
        if body.trimmingCharacters(in: .whitespaces).isEmpty {
            vpLog("[Gate] \"\(Self.actionWord) send\"")
            return .command(.send)
        }
        if Self.openerRange(in: body) != nil {
            return admitWords(body, sends: true)
        }
        if !enabled || (open && !provisional) {
            vpLog("[Gate] delivering '\(body.prefix(60))' then send")
            return .typeThenSend(body)
        }
        vpLog("[Gate] \"\(Self.actionWord) send\" — dropping the words before it, gate was shut: '\(body.prefix(60))'")
        return .command(.send)
    }

    /// Free text: through when the mode is off, when the wake word opens it, or while
    /// the gate is open; dropped otherwise.
    private func admitWords(_ text: String, sends: Bool) -> Verdict {
        guard enabled else { return sends ? .typeThenSend(text) : .type(text) }

        if let range = Self.openerRange(in: text) {
            let rest = String(text[range.upperBound...])
            let before = text[..<range.lowerBound].trimmingCharacters(in: .whitespaces)
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

        if open {
            if provisional {
                // The partial that opened the gate finalised as something else.
                provisional = false
                vpLog("[Gate] partial opening not confirmed by the final — dropped '\(text.prefix(60))'")
                setOpen(false)
                return .drop
            }
            return sends ? .typeThenSend(text) : .type(text)
        }
        vpLog("[Gate] closed — dropped '\(text.prefix(60))'")
        return .drop
    }

    /// What a command does to the gate itself. delete, stop and mute mean "done with
    /// this" and shut it, so the next sentence needs its own "pilot" — on 2026-10-22
    /// two "action delete"s left it open and the room's next six sentences went into
    /// the prompt, one into Photoshop. send shuts it through closeForSend. write
    /// opens it with the long window.
    private func apply(_ command: Command) {
        switch command {
        case .delete, .deleteAll: close(reason: "delete")
        case .stop: close(reason: "stop")
        case .mute:
            close(reason: "mute")
            if enabled {
                vpLog("[Gate] asleep — say \"hey \(Self.word)\" to wake")
                onMain { self.sleeping = true }
            }
        case .write:
            guard enabled else { return }
            idleWindow = Self.writeWindow
            provisional = false
            vpLog("[Gate] \"\(Self.actionWord) write\" — open for \(Int(Self.writeWindow)) s of silence")
            setOpen(true)
            onMain { self.writing = true }
            scheduleClose()
        // A remote command is a complete thought: after "next song" the window
        // stayed green and took the room's talk ("the listener keeps listening",
        // Fabian 2026-10-22). Keys (copy, paste, new line) are editing and stay open.
        case .open: close(reason: "open")
        case .media: close(reason: "music")
        case .send, .key: break
        }
    }

    // MARK: - Closing

    private func scheduleClose() {
        closeGeneration += 1
        let generation = closeGeneration
        DispatchQueue.main.asyncAfter(deadline: .now() + idleWindow) { [weak self] in
            self?.checkIdle(generation: generation)
        }
    }

    /// Fires `idleWindow` after the last final. Speech since then (partials count)
    /// pushes the deadline out by however much is left, so the gate only shuts on real
    /// silence.
    private func checkIdle(generation: Int) {
        guard generation == closeGeneration, open else { return }
        let idle = Date().timeIntervalSince(lastActivity)
        if idle >= idleWindow {
            close(reason: "\(Int(idle)) s silence")
            onTimedOut?()
        } else {
            DispatchQueue.main.asyncAfter(deadline: .now() + (idleWindow - idle)) { [weak self] in
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
        idleWindow = Self.silenceWindow
        guard open else { return }
        provisional = false
        vpLog("[Gate] closed after \(reason) — say \"\(Self.word)\" to dictate")
        setOpen(false)
        onMain { self.writing = false }
    }

    private func setOpen(_ value: Bool) {
        onMain { self.open = value }
    }

    /// Finals from the legacy backend arrive off the main thread; @Published must not.
    private func onMain(_ work: @escaping () -> Void) {
        if Thread.isMainThread {
            work()
        } else {
            DispatchQueue.main.sync(execute: work)
        }
    }
}
