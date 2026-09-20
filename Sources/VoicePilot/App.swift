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
    var windowKeeper: WindowKeeper?

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
        parkZone?.onClear = { [weak self] in
            self?.clearDictation()
        }

        // Recovers both floating windows after screen wake and display changes. Run once
        // now as well: launching while a display is still asleep (login, or a relaunch
        // after an engine switch) can restore a frame onto a screen that is not there.
        windowKeeper = WindowKeeper(targets: [floatingPanel!, parkZone!])
        windowKeeper?.revealNow()

        dictationManager?.onRecall = { [weak self] in
            self?.windowKeeper?.recallNow()
        }

        // Ops escape hatch, same pattern as VOICEPILOT_ENGINE: launch with
        // VOICEPILOT_RECALL=1 to drag the windows onto the pointer's display, for when
        // they are stranded on a monitor that is off or not being looked at.
        if ProcessInfo.processInfo.environment["VOICEPILOT_RECALL"] == "1" {
            vpLog("[App] VOICEPILOT_RECALL=1 — recalling windows to the pointer")
            windowKeeper?.recallNow()
        }

        statusBar = StatusBarController(
            speechEngine: speechEngine!,
            parkZone: parkZone!,
            onBringToFront: { [weak self] in self?.windowKeeper?.recallNow() },
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

    /// Wipes the terminal's input line and the app's view of it — for when dictation
    /// has put gibberish at the prompt.
    private func clearDictation() {
        // Same reasoning as submit: while parked nothing was typed, so there is no
        // gibberish on the line to remove, and dictationManager.clear() below would
        // destroy the buffer parking exists to protect.
        if terminalController?.parked == true {
            vpLog("[App] clear ignored — parked")
            return
        }

        guard terminalController?.isTerminalFrontmost == true else {
            let front = NSWorkspace.shared.frontmostApplication?.localizedName ?? "?"
            vpLog("[App] clear ignored — frontmost is \(front), not a terminal")
            return
        }

        terminalController?.clearLine()

        // Reset our own view of the line as well. dictationCurrentText decides whether
        // the next utterance gets a leading space, so leaving it set would open the
        // freshly cleared prompt with a stray space.
        dictationCurrentText = ""
        dictationManager?.clear()
        speechEngine?.currentTranscript = ""
        vpLog("[App] clear: terminal line and dictation state reset")
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
