import AppKit
import ApplicationServices

/// "action go to <name>" — a worktree or agent tab in Orca's sidebar (Fabian,
/// 2026-10-23: "mostly I'm interested in go to name, and it shouldn't even be the
/// full name").
///
/// Read straight from Orca's sidebar through Accessibility: the Worktrees list
/// (DOM class `worktree-sidebar-scrollbar`) holds one AXMenuItem per worktree,
/// whose static texts are its display name and branch ("color lab",
/// "feature/palette-lab-app"), and one AXRow per agent tab under it ("Butterfly
/// morph and light field"). Each exposes AXPress. The spoken words are matched
/// against those texts with some tolerance for the recogniser — it heard "pilot
/// lab" for "palette lab" three times — and the best row is pressed, walking the
/// tree top-down so ties go to the first.
///
/// The ⌘J palette (`worktree.palette` in Orca 1.4.223's keybinding table) is the
/// fallback when the sidebar is hidden: it ranks by its own rules, which is how
/// "go to palette lab" kept landing one row off.
enum Orca {
    static let bundleID = "com.stablyai.orca"

    static func goTo(_ spokenName: String) {
        var name = spokenName.trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: .punctuationCharacters)
        for article in ["the ", "my ", "a "] where name.lowercased().hasPrefix(article) {
            name = String(name.dropFirst(article.count))
        }
        guard !name.isEmpty else { return }
        guard let app = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first else {
            vpLog("[Orca] go to '\(name)' — Orca is not running")
            return
        }
        if !app.isActive {
            app.activate()
        }

        if let (candidates, list) = sidebarCandidates(pid: app.processIdentifier) {
            let words = name.lowercased().split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init)
            let scored = candidates.map { ($0, score(words: words, against: $0.tokens)) }
            if let best = scored.max(by: { $0.1 < $1.1 }), best.1 >= 0.6 {
                let r = AXUIElementPerformAction(best.0.element, kAXPressAction as CFString)
                vpLog("[Orca] go to '\(name)' → \(best.0.kind) \"\(best.0.label)\" (match \(Int(best.1 * 100))%, \(candidates.count) rows) — AXPress \(r == .success ? "ok" : "err \(r.rawValue)")")
                return
            }
            let top = scored.sorted { $0.1 > $1.1 }.prefix(3).map { "\"\($0.0.label)\" \(Int($0.1 * 100))%" }
            vpLog("[Orca] go to '\(name)' — nothing in the sidebar matches well enough (best: \(top.joined(separator: ", "))); trying the palette")
            _ = list
        } else {
            vpLog("[Orca] go to '\(name)' — sidebar list not visible; trying the palette")
        }
        palette(name)
    }

    // MARK: - Sidebar through Accessibility

    private struct Candidate {
        let element: AXUIElement
        let kind: String      // "worktree" or "agent"
        let label: String
        let tokens: [String]
    }

    private static func attr(_ e: AXUIElement, _ name: String) -> AnyObject? {
        var v: AnyObject?
        AXUIElementCopyAttributeValue(e, name as CFString, &v)
        return v
    }

    private static func children(_ e: AXUIElement) -> [AXUIElement] {
        (attr(e, kAXChildrenAttribute as String) as? [AXUIElement]) ?? []
    }

    private static func classes(_ e: AXUIElement) -> [String] {
        (attr(e, "AXDOMClassList") as? [String]) ?? []
    }

    private static func sidebarCandidates(pid: pid_t) -> ([Candidate], AXUIElement)? {
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetAttributeValue(app, "AXManualAccessibility" as CFString, kCFBooleanTrue)
        guard let list = findList(app, depth: 0) else { return nil }
        var out: [Candidate] = []
        collect(list, into: &out, depth: 0)
        return (out, list)
    }

    private static func findList(_ e: AXUIElement, depth: Int) -> AXUIElement? {
        if depth > 40 { return nil }
        if classes(e).contains("worktree-sidebar-scrollbar") { return e }
        for k in children(e) {
            if let f = findList(k, depth: depth + 1) { return f }
        }
        return nil
    }

    private static func collect(_ e: AXUIElement, into out: inout [Candidate], depth: Int) {
        if depth > 30 { return }
        let role = attr(e, kAXRoleAttribute as String) as? String ?? ""
        if role == "AXMenuItem" {
            let texts = staticTexts(e, depth: 0)
            // "Active", "primary", "Mark as unread" are status chrome, not names.
            let named = texts.filter { !["active", "primary", "mark as unread"].contains($0.lowercased()) }
            let label = named.first ?? texts.first ?? "?"
            out.append(Candidate(element: e, kind: "worktree", label: label, tokens: tokens(of: named.joined(separator: " "))))
        } else if role == "AXRow", classes(e).contains("compact-agent-row") {
            // The agent row's title is the first static text after the status word.
            let texts = staticTexts(e, depth: 0).filter { $0.trimmingCharacters(in: .whitespaces).count > 1 }
            let label = texts.first ?? (attr(e, kAXDescriptionAttribute as String) as? String ?? "?")
            out.append(Candidate(element: e, kind: "agent", label: label, tokens: tokens(of: label)))
        }
        for k in children(e) { collect(k, into: &out, depth: depth + 1) }
    }

    /// Static texts under an element, in document order, stopping at nested rows so
    /// a worktree does not absorb its agents' titles.
    private static func staticTexts(_ e: AXUIElement, depth: Int) -> [String] {
        if depth > 12 { return [] }
        var out: [String] = []
        for k in children(e) {
            let role = attr(k, kAXRoleAttribute as String) as? String ?? ""
            if role == "AXRow" || (role == "AXGroup" && (attr(k, kAXTitleAttribute as String) as? String) == "Agents") { continue }
            if role == "AXStaticText", let v = attr(k, kAXValueAttribute as String) as? String {
                let t = v.trimmingCharacters(in: .whitespacesAndNewlines)
                if t.count > 1 { out.append(t) }
            } else {
                out.append(contentsOf: staticTexts(k, depth: depth + 1))
            }
        }
        return out
    }

    private static func tokens(of text: String) -> [String] {
        text.lowercased().split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init)
    }

    // MARK: - Matching

    /// Mean, over the spoken words, of each word's best similarity to any token:
    /// 1 for an exact or prefix match, otherwise 1 − edit distance ⁄ length. "pilot
    /// lab" against "color lab feature palette lab app" scores ("pilot"→"palette"
    /// 0.57 + "lab" 1) / 2 = 0.79; against "voice pilot dev" ("pilot" 1 + "lab" 0.33) / 2 = 0.67.
    private static func score(words: [String], against tokens: [String]) -> Double {
        guard !words.isEmpty, !tokens.isEmpty else { return 0 }
        let total = words.reduce(0.0) { sum, w in
            sum + tokens.map { t -> Double in
                if t == w || t.hasPrefix(w) || w.hasPrefix(t) && t.count >= 3 { return 1 }
                let d = Double(levenshtein(w, t))
                return max(0, 1 - d / Double(max(w.count, t.count)))
            }.max()!
        }
        return total / Double(words.count)
    }

    private static func levenshtein(_ a: String, _ b: String) -> Int {
        let a = Array(a), b = Array(b)
        if a.isEmpty { return b.count }
        if b.isEmpty { return a.count }
        var prev = Array(0...b.count)
        var cur = [Int](repeating: 0, count: b.count + 1)
        for i in 1...a.count {
            cur[0] = i
            for j in 1...b.count {
                cur[j] = min(prev[j] + 1, cur[j - 1] + 1, prev[j - 1] + (a[i - 1] == b[j - 1] ? 0 : 1))
            }
            swap(&prev, &cur)
        }
        return prev[b.count]
    }

    // MARK: - Palette fallback

    private static func palette(_ name: String) {
        let escaped = name.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
        let script = NSAppleScript(source: """
        tell application "System Events"
            tell process "Orca"
                set frontmost to true
            end tell
            delay 0.2
            keystroke "j" using {command down}
            delay 0.4
            keystroke "\(escaped)"
            delay 0.5
            key code 36
        end tell
        """)
        var error: NSDictionary?
        script?.executeAndReturnError(&error)
        if let error {
            vpLog("[Orca] palette '\(name)' FAILED: \(error[NSAppleScript.errorMessage] ?? error)")
        } else {
            vpLog("[Orca] palette '\(name)' — ⌘J, typed, Enter")
        }
    }
}
