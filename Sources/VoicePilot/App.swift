import SwiftUI
import Combine

@main
struct VoicePilotApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        Settings {
            EmptyView()
        }
    }
}

class AppDelegate: NSObject, NSApplicationDelegate {
    var statusBar: StatusBarController?
    var speechEngine: SpeechEngine?
    var terminalController: TerminalController?
    var floatingPanel: FloatingPanelController?
    var dictationManager: DictationManager?
    var parkZone: ParkZoneController?

    private var dictationCurrentText = ""
    private var dictationSuppressUntil: Date = .distantPast

    func applicationDidFinishLaunching(_ notification: Notification) {
        vpLog("[App] applicationDidFinishLaunching")
        NSApp.setActivationPolicy(.accessory)

        terminalController = TerminalController()
        dictationManager = DictationManager()

        dictationManager?.onMouseButton = { [weak self] in
            self?.submitDictation()
        }

        speechEngine = SpeechEngine { [weak self] utterance in
            self?.handleUtterance(utterance)
        }

        floatingPanel = FloatingPanelController(
            speechEngine: speechEngine!,
            terminalController: terminalController!,
            dictationManager: dictationManager!
        )

        parkZone = ParkZoneController(terminalController: terminalController!)
        parkZone?.onSend = { [weak self] in
            self?.submitDictation()
        }

        statusBar = StatusBarController(
            speechEngine: speechEngine!,
            parkZone: parkZone!,
            onQuit: { NSApp.terminate(nil) },
            onShowWindow: { [weak self] in
                self?.floatingPanel?.window?.makeKeyAndOrderFront(nil)
            }
        )

        // Defaults to true, preserving single-app behaviour. The side-by-side
        // evaluation bundle seeds it false so two builds never type at once.
        let autoStart = UserDefaults.standard.object(forKey: "autoStartListening") as? Bool ?? true
        if autoStart {
            speechEngine?.startListening()
        } else {
            vpLog("[App] autoStartListening=false — start it from the menu bar")
        }
        terminalController?.saveClipboard()
        dictationManager?.start()
    }

    private func handleUtterance(_ text: String) {
        vpLog("[App] handleUtterance: '\(text.prefix(80))'")
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        guard Date() > dictationSuppressUntil else { return }

        let clean = trimmed.replacingOccurrences(of: "\n", with: " ")
        guard !clean.isEmpty else { return }

        let toType = dictationCurrentText.isEmpty ? clean : " " + clean
        let delivered = terminalController?.typeText(toType) ?? false
        if delivered {
            dictationCurrentText += toType
        } else {
            dictationManager?.appendUtterance(text)
        }
    }

    private func submitDictation() {
        // While parked, the panel buffer holds text that was never typed. Submitting
        // would clear() it below and lose it — the exact truncation parking exists to
        // avoid — and would submit a prompt missing everything spoken while parked.
        if terminalController?.parked == true {
            vpLog("[App] submitDictation ignored — parked")
            return
        }

        // Enter only means "submit" in a terminal. Logged rather than silent because
        // the Send button makes this reachable by a deliberate click, and a button that
        // does nothing with no trace is indistinguishable from a broken one.
        guard terminalController?.isTerminalFrontmost == true else {
            let front = NSWorkspace.shared.frontmostApplication?.localizedName ?? "?"
            vpLog("[App] submitDictation ignored — frontmost is \(front), not a terminal")
            return
        }

        // Text buffered while parked was never typed. Clearing it below would discard
        // it, so say so — flushing it on send needs the buffer scoped to the park
        // session, otherwise a long-stale backlog would be dumped into the prompt.
        if let buffered = dictationManager?.accumulatedText, !buffered.isEmpty {
            vpLog("[App] submitDictation discarding \(buffered.count) buffered chars")
        }

        dictationSuppressUntil = Date().addingTimeInterval(3.0)
        dictationCurrentText = ""
        dictationManager?.clear()
        speechEngine?.currentTranscript = ""
        terminalController?.pressEnter()
    }
}
