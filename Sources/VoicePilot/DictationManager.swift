import Foundation
import AppKit
import Combine

func vpLog(_ msg: String) {
    #if DEBUG
    let line = "\(Date()): \(msg)\n"
    if let data = line.data(using: .utf8) {
        let path = "/tmp/voicepilot_debug.log"
        if let fh = FileHandle(forWritingAtPath: path) {
            fh.seekToEndOfFile(); fh.write(data); fh.closeFile()
        } else {
            FileManager.default.createFile(atPath: path, contents: data)
        }
    }
    #endif
}

class DictationManager: ObservableObject {
    @Published var isActive = false
    @Published var accumulatedText = ""
    private var lastAppendedText = ""

    private var keyMonitor: Any?
    private var lastSubmitTime: Date = .distantPast

    /// Called on global Ctrl+Return (or when a UI button triggers submit).
    /// Name is kept for call-site compatibility even though no mouse is involved anymore.
    var onMouseButton: (() -> Void)?

    func start() {
        isActive = true
        accumulatedText = ""
        lastAppendedText = ""
        startKeyMonitor()
    }

    func stop() {
        isActive = false
        accumulatedText = ""
        lastAppendedText = ""
        stopKeyMonitor()
    }

    func appendUtterance(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        vpLog("[DM] appendUtterance: '\(trimmed.prefix(50))'")
        guard !trimmed.isEmpty else { return }
        guard trimmed != lastAppendedText else {
            vpLog("[DM] Deduped — same as last")
            return
        }
        lastAppendedText = trimmed

        if accumulatedText.isEmpty {
            accumulatedText = trimmed
        } else {
            accumulatedText += " " + trimmed
        }
    }

    func clear() {
        accumulatedText = ""
        lastAppendedText = ""
    }

    // MARK: - Ctrl+Return global keyboard shortcut (observe-only; does NOT consume)

    private func startKeyMonitor() {
        stopKeyMonitor()
        keyMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self = self, self.isActive else { return }
            if event.keyCode == 36 && event.modifierFlags.contains(.control) {
                let now = Date()
                guard now.timeIntervalSince(self.lastSubmitTime) > 0.5 else { return }
                self.lastSubmitTime = now
                DispatchQueue.main.async {
                    self.onMouseButton?()
                }
            }
        }
    }

    private func stopKeyMonitor() {
        if let monitor = keyMonitor {
            NSEvent.removeMonitor(monitor)
            keyMonitor = nil
        }
    }

    deinit {
        stopKeyMonitor()
    }
}
