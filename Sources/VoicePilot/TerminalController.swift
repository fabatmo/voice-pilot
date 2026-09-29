import Foundation
import AppKit
import ApplicationServices

class TerminalController: ObservableObject {
    @Published var terminalOnly = false

    /// Parked = deliver nothing, but keep recognising.
    ///
    /// This is deliberately NOT mute: mute calls SpeechEngine.stopListening, which
    /// tears down the audio engine and discards the in-flight segment. Parking only
    /// makes typeText return false, and the caller (AppDelegate.handleUtterance)
    /// already routes an undelivered utterance into the panel buffer instead.
    ///
    /// Derived, never set directly — it is the OR of every hover source. Two sources
    /// can overlap (pointer crossing from the transcript panel into the park zone),
    /// and letting either one write `parked` would un-park while the other is still
    /// held, dropping speech the user believes is safely buffered.
    @Published private(set) var parked = false

    enum ParkSource: String { case panel, zone }

    private var parkSources: Set<ParkSource> = []

    func setParked(_ on: Bool, source: ParkSource) {
        if on { parkSources.insert(source) } else { parkSources.remove(source) }

        let next = !parkSources.isEmpty
        guard next != parked else { return }
        parked = next
        let held = parkSources.map(\.rawValue).sorted().joined(separator: "+")
        vpLog("[TC] park \(next ? "ON" : "OFF") — held by [\(held)]")
    }

    private let terminalApps: Set<String> = [
        "Terminal", "iTerm2", "kitty", "Alacritty",
        "WezTerm", "Ghostty", "Warp", "Hyper", "Rio"
    ]

    /// Check if the frontmost app is a terminal
    var isTerminalFrontmost: Bool { frontmostIsTerminal }
    private var frontmostIsTerminal: Bool {
        guard let frontApp = NSWorkspace.shared.frontmostApplication?.localizedName else { return false }
        return terminalApps.contains(frontApp)
    }

    /// Non-terminal apps where Enter means "submit" and clearing the input is meaningful.
    ///
    /// Deliberately NOT merged into terminalApps: that set also decides how text is
    /// typed (AppleScript keystroke vs Accessibility) and what "Terminal only" mode
    /// admits, so listing an app here must not silently change how dictation reaches it.
    ///
    /// Runtime-extendable, so a new app needs no rebuild:
    ///   defaults write com.fabianklainman.VoicePilot VoicePilotSubmitApps -array Orca Foo
    static let submitAppsKey = "VoicePilotSubmitApps"
    private static let defaultSubmitApps = ["Orca"]

    private var extraSubmitApps: Set<String> {
        Set(UserDefaults.standard.stringArray(forKey: Self.submitAppsKey) ?? Self.defaultSubmitApps)
    }

    /// True when Send and Clear make sense in whatever is frontmost.
    var isSubmitTarget: Bool {
        if frontmostIsTerminal { return true }
        guard let name = NSWorkspace.shared.frontmostApplication?.localizedName else { return false }
        return extraSubmitApps.contains(name)
    }

    /// Find a terminal, activate it, paste text, and press Enter
    func activateTerminalAndPasteEnter(_ text: String) {
        let pasteboard = NSPasteboard.general
        let previousContents = pasteboard.string(forType: .string)

        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)

        let apps = terminalApps.map { "\"\($0)\"" }.joined(separator: ", ")
        let script = """
        set termApps to {\(apps)}
        set termApp to ""
        tell application "System Events"
            repeat with appName in termApps
                if exists (process appName) then
                    set termApp to appName as text
                    exit repeat
                end if
            end repeat
        end tell

        if termApp is not "" then
            tell application termApp to activate
            delay 0.3
            tell application "System Events"
                keystroke "v" using command down
            end tell
            delay 0.2
            tell application "System Events"
                key code 36
            end tell
        end if
        """
        runAppleScript(script)

        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
            if let previous = previousContents {
                pasteboard.clearContents()
                pasteboard.setString(previous, forType: .string)
            }
        }
    }

    func pasteAndEnter(_ text: String) {
        if terminalOnly && !frontmostIsTerminal {
            #if DEBUG
            print("[TerminalController] Frontmost app is not a terminal — skipping")
            #endif
            return
        }

        let pasteboard = NSPasteboard.general
        let previousContents = pasteboard.string(forType: .string)

        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)

        // Send to frontmost app — no app switching
        let script = """
        tell application "System Events"
            keystroke "v" using command down
        end tell
        delay 0.2
        tell application "System Events"
            key code 36
        end tell
        """
        runAppleScript(script)

        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
            if let previous = previousContents {
                pasteboard.clearContents()
                pasteboard.setString(previous, forType: .string)
            }
        }
    }

    /// Always works — press Enter to frontmost app, or find target app if needed
    func activateTerminalAndPressEnter() {
        let frontApp = NSWorkspace.shared.frontmostApplication
        let isSelf = frontApp?.bundleIdentifier == Bundle.main.bundleIdentifier

        // If frontmost is a real app (not VoicePilot), just press Enter
        if !isSelf {
            let script = """
            tell application "System Events"
                key code 36
            end tell
            """
            runAppleScript(script)
            return
        }

        // VoicePilot is frontmost — need to find the right app
        if terminalOnly {
            // Find a terminal
            let apps = terminalApps.map { "\"\($0)\"" }.joined(separator: ", ")
            let script = """
            set termApps to {\(apps)}
            set termApp to ""
            tell application "System Events"
                repeat with appName in termApps
                    if exists (process appName) then
                        set termApp to appName as text
                        exit repeat
                    end if
                end repeat
            end tell

            if termApp is not "" then
                tell application termApp to activate
                delay 0.3
                tell application "System Events"
                    key code 36
                end tell
            end if
            """
            runAppleScript(script)
        } else {
            // Any app mode — find last regular app
            if let lastApp = NSWorkspace.shared.runningApplications.first(where: {
                $0.isActive == false &&
                $0.activationPolicy == .regular &&
                $0.bundleIdentifier != Bundle.main.bundleIdentifier
            }) {
                lastApp.activate()
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
                    let script = """
                    tell application "System Events"
                        key code 36
                    end tell
                    """
                    self?.runAppleScript(script)
                }
            }
        }
    }

    /// Dictation submit — always targets a terminal. Does nothing if no terminal is frontmost.
    func pressEnter() {
        guard isSubmitTarget else {
            let front = NSWorkspace.shared.frontmostApplication?.localizedName ?? "?"
            vpLog("[TC] pressEnter ignored — \(front) is not a submit target")
            return
        }

        let script = """
        tell application "System Events"
            key code 36
        end tell
        """
        runAppleScript(script)
    }

    /// Wipes whatever is sitting on the terminal's current input line.
    ///
    /// Ctrl+E then Ctrl+U, not Ctrl+U alone: in bash Ctrl+U is unix-line-discard,
    /// which only kills from the cursor back to the start, so anything to the right of
    /// the cursor would survive. Moving to end-of-line first makes it clear the whole
    /// line there, and zsh's kill-whole-line is indifferent to the extra move.
    func clearLine() {
        guard isSubmitTarget else {
            let front = NSWorkspace.shared.frontmostApplication?.localizedName ?? "?"
            vpLog("[TC] clearLine ignored — \(front) is not a submit target")
            return
        }

        if frontmostIsTerminal {
            let script = """
            tell application "System Events"
                key code 14 using {control down}
                key code 32 using {control down}
            end tell
            """
            runAppleScript(script)
            vpLog("[TC] clearLine sent (ctrl-E then ctrl-U)")
            return
        }

        // Chromium and Electron: AX for the decision, real keys for the action.
        //
        // Writing "" through AX has the same defect as inserting through it — React
        // never sees an input event, so the field snaps back. Cmd+A then Delete does
        // work, but would "work" anywhere, which is the danger: with focus outside a
        // text box, select-all takes whatever the app calls everything — a message
        // list, a canvas — and Delete destroys it. So the keys are sent only after AX
        // confirms a text field actually holds focus. Reading that needs the app's real
        // accessibility tree, hence the opt-in here; it is safe now that no mutation
        // goes through AX for these apps.
        if frontmostIsChromiumBased() {
            enableChromiumAccessibilityForReading()
            guard focusedElementIsTextField() else {
                vpLog("[TC] clearLine: no focused text field — refusing to send select-all")
                return
            }
            let script = """
            tell application "System Events"
                keystroke "a" using {command down}
                key code 51
            end tell
            """
            runAppleScript(script)
            vpLog("[TC] clearLine: select-all + delete (text field confirmed)")
            return
        }

        // Native GUI app: empty the focused field through Accessibility. Safe here for
        // the reason it is unsafe above — it only touches an element whose value is
        // already a string, so a miss is a no-op rather than data loss.
        if clearViaAccessibility() {
            vpLog("[TC] clearLine: focused text field cleared via AX")
        } else {
            vpLog("[TC] clearLine: no writable text field found — nothing cleared")
        }
    }

    private var chromiumReadOptIn: Set<pid_t> = []

    /// Ask a Chromium/Electron app for its real accessibility tree so it can be READ.
    /// Never used to enable AX writes for these apps — see typeText.
    private func enableChromiumAccessibilityForReading() {
        guard let pid = NSWorkspace.shared.frontmostApplication?.processIdentifier,
              !chromiumReadOptIn.contains(pid) else { return }
        let r = AXUIElementSetAttributeValue(
            AXUIElementCreateApplication(pid), "AXManualAccessibility" as CFString, kCFBooleanTrue)
        chromiumReadOptIn.insert(pid)
        vpLog("[TC] AX read opt-in for pid \(pid) -> \(r.rawValue) (0 = ok)")
    }

    // The gate for the select-all path is focusedElementIsTextField() below, which
    // already existed: it matches on AX role (AXTextField, AXTextArea, AXComboBox,
    // AXSearchField), a stricter test than "has a string value".

    private var savedClipboard: String?

    /// Save clipboard before dictation starts
    func saveClipboard() {
        savedClipboard = NSPasteboard.general.string(forType: .string)
    }

    /// Restore clipboard after dictation ends
    func restoreClipboard() {
        if let saved = savedClipboard {
            let pasteboard = NSPasteboard.general
            pasteboard.clearContents()
            pasteboard.setString(saved, forType: .string)
        }
        savedClipboard = nil
    }

    /// Clear entire input line (Ctrl+E to end, Ctrl+U to kill backward) then paste
    func clearLineAndPaste(_ text: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)

        // Ctrl+E = move to end of line, Ctrl+U = kill line backward, then paste
        let script = """
        tell application "System Events"
            key code 14 using control down
            key code 32 using control down
            keystroke "v" using command down
        end tell
        """
        runAppleScript(script)
    }

    /// Paste text at cursor via clipboard (instant, no flicker)
    func pasteText(_ text: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)

        let script = """
        tell application "System Events"
            keystroke "v" using command down
        end tell
        """
        runAppleScript(script)
    }

    /// Insert dictation text live into the destination.
    /// - Terminals: keystroke via System Events (terminals interpret letters as TTY input — no shortcut chaos).
    /// - Other apps: insert directly into the focused text field via the Accessibility API
    ///   (no key events emitted, so app shortcuts like space=pause / f=fullscreen never fire).
    /// Returns true if the text was delivered. False = caller should accumulate in the panel buffer instead.
    @discardableResult
    func typeText(_ text: String) -> Bool {
        guard !text.isEmpty else { return false }

        let frontApp = NSWorkspace.shared.frontmostApplication?.localizedName ?? "?"
        vpLog("[TC] typeText called, terminalOnly=\(terminalOnly) frontmost=\(frontApp) isTerminal=\(frontmostIsTerminal)")

        // Pointer is resting on the panel. Returning false is the whole mechanism:
        // handleUtterance appends to the panel buffer instead, so nothing is lost.
        if parked {
            vpLog("[TC] PARKED: mouse over panel, buffering '\(text.prefix(40))'")
            return false
        }

        // In Terminal-only mode, refuse to type when frontmost isn't a terminal.
        if terminalOnly && !frontmostIsTerminal {
            vpLog("[TC] BLOCKED: terminalOnly=true but frontmost is not terminal")
            return false
        }

        if frontmostIsTerminal {
            let escaped = text.replacingOccurrences(of: "\\", with: "\\\\")
                .replacingOccurrences(of: "\"", with: "\\\"")
            let script = """
            tell application "System Events"
                keystroke "\(escaped)"
            end tell
            """
            runAppleScript(script)
            return true
        }

        // Chromium and Electron apps: skip AX entirely and paste.
        //
        // Not because AX fails there — since the AXManualAccessibility opt-in it
        // "succeeds" every time. That was the bug. These apps render React-controlled
        // inputs, and writing a value through AX never fires the JS input events the
        // component listens for, so React overwrites it on the next render and nothing
        // reaches the screen. A synthetic Cmd+V goes through real key events, which do
        // fire those handlers.
        //
        // Measured in Orca: every insertion logged "AX insertion succeeded" and typed
        // nothing, while the same app worked all day on the clipboard path before the
        // opt-in was added.
        if frontmostIsChromiumBased() {
            vpLog("[TC] chromium/electron — clipboard paste (AX writes never reach React)")
            pasteText(text)
            return true
        }

        // Non-terminal frontmost — Any App mode.
        // Try AX first (clean, no clipboard side-effects).
        if insertViaAccessibility(text) {
            vpLog("[TC] AX insertion succeeded")
            return true
        }

        // AX failed — fall back to clipboard paste (Cmd+V).
        // If a text field is focused, text appears. If not, Cmd+V is harmless.
        vpLog("[TC] AX failed, falling back to clipboard paste")
        pasteText(text)
        return true
    }

    private var chromiumCache: [pid_t: Bool] = [:]

    /// True for Chromium- and Electron-based apps.
    ///
    /// AXManualAccessibility is the attribute those apps expose so assistive clients can
    /// ask for a real accessibility tree; nothing else advertises it, which makes its
    /// presence a reliable detector. Detection only — the attribute is deliberately NOT
    /// set. See deliverToChromium for why enabling it made things worse.
    private func frontmostIsChromiumBased() -> Bool {
        guard let app = NSWorkspace.shared.frontmostApplication else { return false }
        let pid = app.processIdentifier
        if let known = chromiumCache[pid] { return known }

        var names: CFArray?
        AXUIElementCopyAttributeNames(AXUIElementCreateApplication(pid), &names)
        let isChromium = (names as? [String])?.contains("AXManualAccessibility") ?? false
        chromiumCache[pid] = isChromium
        vpLog("[TC] \(app.localizedName ?? "?") chromium/electron=\(isChromium)")
        return isChromium
    }

    /// Focused-element candidates, from three sources.
    ///
    /// The multi-source approach is needed because Catalyst/UIKit apps (WhatsApp) and
    /// Chromium browsers return different elements depending on the query level. Shared
    /// by insertion and clearing so both agree on what "the focused field" means.
    private func focusedTextCandidates() -> ([AXUIElement], AXError) {
        var candidates: [AXUIElement] = []

        // Source 1: System-wide focused element (works for Cocoa-native apps)
        let systemWide = AXUIElementCreateSystemWide()
        var sysFocused: AnyObject?
        let sysResult = AXUIElementCopyAttributeValue(
            systemWide, kAXFocusedUIElementAttribute as CFString, &sysFocused
        )
        if sysResult == .success, let ref = sysFocused {
            candidates.append(ref as! AXUIElement)
        }

        // Source 2: App-level focused element (penetrates Catalyst UIKit bridge)
        if let pid = NSWorkspace.shared.frontmostApplication?.processIdentifier {
            let appElement = AXUIElementCreateApplication(pid)

            var appFocused: AnyObject?
            if AXUIElementCopyAttributeValue(
                appElement, kAXFocusedUIElementAttribute as CFString, &appFocused
            ) == .success, let ref = appFocused {
                candidates.append(ref as! AXUIElement)
            }

            // Source 3: Focused window's focused element (Chromium, Electron)
            var focusedWin: AnyObject?
            if AXUIElementCopyAttributeValue(
                appElement, kAXFocusedWindowAttribute as CFString, &focusedWin
            ) == .success, let winRef = focusedWin {
                let win = winRef as! AXUIElement
                var winFocused: AnyObject?
                if AXUIElementCopyAttributeValue(
                    win, kAXFocusedUIElementAttribute as CFString, &winFocused
                ) == .success, let ref = winFocused {
                    candidates.append(ref as! AXUIElement)
                }
            }
        }

        return (candidates, sysResult)
    }

    /// Empty the focused text field via the Accessibility API.
    ///
    /// Only writes to an element whose value already reads as a string, so pointing this
    /// at a list, canvas or web view is a no-op rather than a deletion. That restraint is
    /// the entire reason this exists instead of Cmd+A followed by Delete.
    private func clearViaAccessibility() -> Bool {
        let (candidates, _) = focusedTextCandidates()
        guard !candidates.isEmpty else { return false }

        for el in candidates where clearText(in: el) { return true }
        for el in candidates {
            if let desc = findFocusedTextDescendant(in: el), clearText(in: desc) { return true }
        }
        return false
    }

    private func clearText(in element: AXUIElement) -> Bool {
        var settable: DarwinBoolean = false
        AXUIElementIsAttributeSettable(element, kAXValueAttribute as CFString, &settable)
        guard settable.boolValue else { return false }

        // Refuse anything whose current value is not a string — that is what keeps this
        // away from non-text elements that happen to expose a settable value.
        var current: AnyObject?
        guard AXUIElementCopyAttributeValue(element, kAXValueAttribute as CFString, &current) == .success,
              current as? String != nil else { return false }

        return AXUIElementSetAttributeValue(
            element, kAXValueAttribute as CFString, "" as CFTypeRef) == .success
    }

    /// Insert text at the cursor of the focused text field via the Accessibility API.
    /// Returns false only if no writable text element is reachable (Finder, video player, no focus).
    private func insertViaAccessibility(_ text: String) -> Bool {
        let (candidates, sysResult) = focusedTextCandidates()

        guard !candidates.isEmpty else {
            axDiagDump(reason: "no-focused-element", element: nil, getResult: sysResult)
            return false
        }

        // Try direct write on each candidate
        for el in candidates {
            if writeText(text, to: el) { return true }
        }

        // Try descendant walk from each candidate
        for el in candidates {
            if let desc = findFocusedTextDescendant(in: el),
               writeText(text, to: desc) {
                return true
            }
        }

        axDiagDump(reason: "no-settable-text-attribute", element: candidates.first, getResult: sysResult)
        return false
    }

    /// Try to insert `text` into the given element via AXSelectedText (Cocoa) then AXValue (UIKit).
    private func writeText(_ text: String, to element: AXUIElement) -> Bool {
        // Path 1 — kAXSelectedTextAttribute (Cocoa-native: Notes, TextEdit, Mail, Telegram).
        var selSettable: DarwinBoolean = false
        AXUIElementIsAttributeSettable(element, kAXSelectedTextAttribute as CFString, &selSettable)
        if selSettable.boolValue {
            let r = AXUIElementSetAttributeValue(element, kAXSelectedTextAttribute as CFString, text as CFTypeRef)
            if r == .success { return true }
        }

        // Path 2 — kAXValueAttribute (Catalyst/UIKit: WhatsApp).
        var valSettable: DarwinBoolean = false
        AXUIElementIsAttributeSettable(element, kAXValueAttribute as CFString, &valSettable)
        if valSettable.boolValue {
            var current: AnyObject?
            let cr = AXUIElementCopyAttributeValue(element, kAXValueAttribute as CFString, &current)
            let existing = (cr == .success ? (current as? String) : nil) ?? ""
            let combined = existing + text
            let r = AXUIElementSetAttributeValue(element, kAXValueAttribute as CFString, combined as CFTypeRef)
            if r == .success {
                let endLoc = combined.utf16.count
                var range = CFRange(location: endLoc, length: 0)
                if let rangeValue = AXValueCreate(.cfRange, &range) {
                    AXUIElementSetAttributeValue(element, kAXSelectedTextRangeAttribute as CFString, rangeValue)
                }
                return true
            }
        }

        return false
    }

    /// Walk the AX tree down from `element` looking for a writable text descendant.
    /// Pass 1: follow kAXFocusedUIElementAttribute shortcuts and AXFocused children (Chromium).
    /// Pass 2: recurse into container roles checking for text-input elements (Catalyst/iOS apps
    /// where AXFocused isn't propagated to children).
    private func findFocusedTextDescendant(in element: AXUIElement, depth: Int = 0) -> AXUIElement? {
        if depth > 12 { return nil }

        // Shortcut: element's own kAXFocusedUIElementAttribute
        var subFocused: AnyObject?
        let fr = AXUIElementCopyAttributeValue(element, kAXFocusedUIElementAttribute as CFString, &subFocused)
        if fr == .success, let sub = subFocused {
            let subElement = sub as! AXUIElement
            if !CFEqual(subElement, element) {
                if isWritableText(subElement) { return subElement }
                if let found = findFocusedTextDescendant(in: subElement, depth: depth + 1) { return found }
            }
        }

        var children: AnyObject?
        let cr = AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &children)
        guard cr == .success, let array = children as? [AXUIElement] else { return nil }

        // Pass 1: children claiming AXFocused == true
        for child in array {
            var flag: AnyObject?
            let r = AXUIElementCopyAttributeValue(child, kAXFocusedAttribute as CFString, &flag)
            if r == .success, (flag as? Bool) == true {
                if isWritableText(child) { return child }
                if let found = findFocusedTextDescendant(in: child, depth: depth + 1) { return found }
            }
        }

        // Pass 2: check text-input roles directly and recurse into containers.
        // Limited to first 30 children per level for performance.
        let limit = min(array.count, 30)
        for i in 0..<limit {
            let child = array[i]
            var role: AnyObject?
            AXUIElementCopyAttributeValue(child, kAXRoleAttribute as CFString, &role)
            let r = (role as? String) ?? ""
            if r == kAXTextFieldRole || r == kAXTextAreaRole {
                if isWritableText(child) { return child }
            }
            if r == kAXGroupRole || r == "AXScrollArea" || r == kAXSplitGroupRole {
                if let found = findFocusedTextDescendant(in: child, depth: depth + 1) { return found }
            }
        }

        return nil
    }

    /// Check whether any of the focused element candidates has a text-input role.
    /// Used to decide if clipboard-paste fallback is appropriate.
    private func focusedElementIsTextField() -> Bool {
        let textRoles: Set<String> = [
            kAXTextFieldRole as String,
            kAXTextAreaRole as String,
            "AXComboBox",
            "AXSearchField"
        ]

        // Check system-wide focused element
        let systemWide = AXUIElementCreateSystemWide()
        var focused: AnyObject?
        if AXUIElementCopyAttributeValue(
            systemWide, kAXFocusedUIElementAttribute as CFString, &focused
        ) == .success, let ref = focused {
            let el = ref as! AXUIElement
            var role: AnyObject?
            AXUIElementCopyAttributeValue(el, kAXRoleAttribute as CFString, &role)
            if let r = role as? String, textRoles.contains(r) { return true }
        }

        // Check app-level focused element
        if let pid = NSWorkspace.shared.frontmostApplication?.processIdentifier {
            let appElement = AXUIElementCreateApplication(pid)
            var appFocused: AnyObject?
            if AXUIElementCopyAttributeValue(
                appElement, kAXFocusedUIElementAttribute as CFString, &appFocused
            ) == .success, let ref = appFocused {
                let el = ref as! AXUIElement
                var role: AnyObject?
                AXUIElementCopyAttributeValue(el, kAXRoleAttribute as CFString, &role)
                if let r = role as? String, textRoles.contains(r) { return true }
            }
        }

        return false
    }

    private func isWritableText(_ element: AXUIElement) -> Bool {
        var s: DarwinBoolean = false
        AXUIElementIsAttributeSettable(element, kAXSelectedTextAttribute as CFString, &s)
        if s.boolValue { return true }
        AXUIElementIsAttributeSettable(element, kAXValueAttribute as CFString, &s)
        return s.boolValue
    }

    /// Diagnostic-only: writes detailed AX state for the focused element to /tmp/voicepilot_ax_diag.log
    /// when insertViaAccessibility() fails. Always-on (no #if DEBUG) so we can collect data from a
    /// release build. Remove this method after WhatsApp/Catalyst app investigation is done.
    private func axDiagDump(reason: String, element: AXUIElement?, getResult: AXError) {
        let path = "/tmp/voicepilot_ax_diag.log"
        var out = ""
        out += "===== \(Date()) =====\n"
        out += "reason: \(reason)\n"
        out += "AXIsProcessTrusted: \(AXIsProcessTrusted())\n"

        if let frontApp = NSWorkspace.shared.frontmostApplication {
            out += "frontmost: name=\(frontApp.localizedName ?? "?") "
            out += "bundle=\(frontApp.bundleIdentifier ?? "?") "
            out += "pid=\(frontApp.processIdentifier)\n"
        } else {
            out += "frontmost: <none>\n"
        }

        if let element = element {
            // Role / subrole / description
            for attr in [kAXRoleAttribute, kAXSubroleAttribute, kAXRoleDescriptionAttribute, kAXTitleAttribute, kAXIdentifierAttribute] {
                var val: AnyObject?
                let r = AXUIElementCopyAttributeValue(element, attr as CFString, &val)
                if r == .success, let s = val as? String {
                    out += "  \(attr) = \(s)\n"
                }
            }

            // All attribute names + settable status
            var attrNames: CFArray?
            if AXUIElementCopyAttributeNames(element, &attrNames) == .success, let names = attrNames as? [String] {
                out += "  attributes (\(names.count)):\n"
                for name in names {
                    var settable: DarwinBoolean = false
                    AXUIElementIsAttributeSettable(element, name as CFString, &settable)
                    out += "    \(name) — settable=\(settable.boolValue)\n"
                }
            } else {
                out += "  attribute-names: <unavailable>\n"
            }

            // Action names (e.g., AXPress)
            var actionNames: CFArray?
            if AXUIElementCopyActionNames(element, &actionNames) == .success, let actions = actionNames as? [String] {
                out += "  actions: \(actions.joined(separator: ", "))\n"
            }
        }

        out += "\n"
        if let data = out.data(using: .utf8) {
            if let fh = FileHandle(forWritingAtPath: path) {
                fh.seekToEndOfFile(); fh.write(data); fh.closeFile()
            } else {
                FileManager.default.createFile(atPath: path, contents: data)
            }
        }
    }

    /// Delete N characters backward (backspace)
    func deleteBackward(count: Int) {
        guard count > 0 else { return }
        let script = """
        tell application "System Events"
            repeat \(count) times
                key code 51
            end repeat
        end tell
        """
        runAppleScript(script)
    }

    private func sendToTerminal(text: String) {
        if terminalOnly && !frontmostIsTerminal { return }

        let escaped = text.replacingOccurrences(of: "\"", with: "\\\"")
        let script = """
        tell application "System Events"
            keystroke "\(escaped)"
        end tell
        """
        runAppleScript(script)
    }

    private func sendToTerminal(keystroke key: String, using modifier: String? = nil) {
        if terminalOnly && !frontmostIsTerminal { return }

        let script: String
        if let modifier = modifier {
            script = """
            tell application "System Events"
                key code \(keyCodeFor(key)) using {\(modifier)}
            end tell
            """
        } else {
            script = """
            tell application "System Events"
                key code \(keyCodeFor(key))
            end tell
            """
        }
        runAppleScript(script)
    }

    private func keyCodeFor(_ name: String) -> Int {
        switch name {
        case "return": return 36
        case "escape": return 53
        case "c": return 8
        case "v": return 9
        case "upArrow": return 126
        case "downArrow": return 125
        default: return 0
        }
    }

    func runScript(_ source: String) {
        runAppleScript(source)
    }

    private func runAppleScript(_ source: String) {
        #if DEBUG
        let logMsg = "[AS] \(Date()): \(source.prefix(80))"
        let data = (logMsg + "\n").data(using: .utf8)!
        if let fh = FileHandle(forWritingAtPath: "/tmp/voicepilot_as.log") {
            fh.seekToEndOfFile(); fh.write(data); fh.closeFile()
        } else {
            FileManager.default.createFile(atPath: "/tmp/voicepilot_as.log", contents: data)
        }
        #endif

        if let script = NSAppleScript(source: source) {
            var error: NSDictionary?
            script.executeAndReturnError(&error)
            if let error = error {
                vpLog("[AS-ERROR] \(error)")
            }
            #if DEBUG
            if let error = error {
                let errMsg = "[AS-ERROR] \(error)\n"
                if let errData = errMsg.data(using: .utf8), let fh = FileHandle(forWritingAtPath: "/tmp/voicepilot_as.log") {
                    fh.seekToEndOfFile(); fh.write(errData); fh.closeFile()
                }
            }
            #endif
        }
    }
}
