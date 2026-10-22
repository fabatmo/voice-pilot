import AppKit

/// "action open …": an app by spoken name, one of the standard folders, or any file
/// Spotlight knows by name — in that order, first hit wins.
enum Launcher {
    static func open(_ spoken: String) {
        var target = spoken.trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: .punctuationCharacters)
        // "open a Photoshop", "open the downloads folder", "open my documents"
        for article in ["a ", "an ", "the ", "my "] where target.lowercased().hasPrefix(article) {
            target = String(target.dropFirst(article.count))
        }
        target = target.replacingOccurrences(
            of: "\\s+(folder|app|application)$", with: "", options: [.regularExpression, .caseInsensitive]
        )
        guard !target.isEmpty else { return }

        if let app = findApp(named: target) {
            NSWorkspace.shared.openApplication(at: app, configuration: NSWorkspace.OpenConfiguration()) { _, error in
                vpLog("[Open] app '\(target)' → \(app.lastPathComponent)\(error.map { " FAILED: \($0.localizedDescription)" } ?? "")")
            }
            return
        }
        if let folder = standardFolder(named: target) {
            NSWorkspace.shared.open(folder)
            vpLog("[Open] folder '\(target)' → \(folder.path)")
            return
        }
        if let file = spotlightFile(named: target) {
            NSWorkspace.shared.open(file)
            vpLog("[Open] file '\(target)' → \(file.path)")
            return
        }
        vpLog("[Open] nothing found for '\(target)'")
    }

    /// Every word of the spoken name must appear in the app's name. Among matches the
    /// newest year wins, then the shortest name: "photoshop" picks "Adobe Photoshop
    /// 2025" over the 2022 copy still installed, and a plain name over a helper.
    /// Looks one folder deep as well, for the Adobe-style "/Applications/Adobe X/X.app".
    private static func findApp(named spoken: String) -> URL? {
        let words = spoken.lowercased().split(separator: " ").map(String.init)
        let roots = [
            URL(fileURLWithPath: "/Applications"),
            URL(fileURLWithPath: "/System/Applications"),
            URL(fileURLWithPath: "/System/Applications/Utilities"),
            URL(fileURLWithPath: "/System/Library/CoreServices"),   // Finder
            FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Applications"),
        ]
        var candidates: [URL] = []
        for root in roots {
            guard let entries = try? FileManager.default.contentsOfDirectory(
                at: root, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]
            ) else { continue }
            for entry in entries {
                if entry.pathExtension == "app" {
                    candidates.append(entry)
                } else if (try? entry.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true,
                          let inner = try? FileManager.default.contentsOfDirectory(
                              at: entry, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]
                          ) {
                    candidates.append(contentsOf: inner.filter { $0.pathExtension == "app" })
                }
            }
        }
        let matches = candidates.filter { url in
            let name = url.deletingPathExtension().lastPathComponent.lowercased()
            return words.allSatisfy { name.contains($0) }
        }
        func year(_ url: URL) -> Int {
            let name = url.deletingPathExtension().lastPathComponent
            return Int(name.split(separator: " ").last ?? "") ?? 0
        }
        return matches.min {
            year($0) != year($1) ? year($0) > year($1) : $0.lastPathComponent.count < $1.lastPathComponent.count
        }
    }

    private static func standardFolder(named spoken: String) -> URL? {
        let home = FileManager.default.homeDirectoryForCurrentUser
        switch spoken.lowercased() {
        case "desktop": return home.appendingPathComponent("Desktop")
        case "documents": return home.appendingPathComponent("Documents")
        case "downloads": return home.appendingPathComponent("Downloads")
        case "pictures": return home.appendingPathComponent("Pictures")
        case "music": return home.appendingPathComponent("Music")
        case "movies": return home.appendingPathComponent("Movies")
        case "applications": return URL(fileURLWithPath: "/Applications")
        case "home": return home
        default: return nil
        }
    }

    /// Spotlight by display name, inside the home folder only. Shortest name first:
    /// "open invoice" should find "invoice.pdf" before "invoice-2024-draft-v3 copy.pdf".
    private static func spotlightFile(named spoken: String) -> URL? {
        let escaped = spoken.replacingOccurrences(of: "\"", with: "")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/mdfind")
        process.arguments = [
            "-onlyin", FileManager.default.homeDirectoryForCurrentUser.path,
            "kMDItemDisplayName == \"*\(escaped)*\"cd",
        ]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch {
            vpLog("[Open] mdfind failed to start: \(error.localizedDescription)")
            return nil
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let paths = String(decoding: data, as: UTF8.self)
            .split(separator: "\n")
            .map(String.init)
            .filter { !$0.contains("/Library/") && !$0.contains("/.") }
        return paths
            .min { URL(fileURLWithPath: $0).lastPathComponent.count < URL(fileURLWithPath: $1).lastPathComponent.count }
            .map { URL(fileURLWithPath: $0) }
    }
}
