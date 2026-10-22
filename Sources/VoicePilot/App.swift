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
    var wakeGate: WakeGate?

    private var dictationCurrentText = ""
    private var dictationSuppressUntil: Date = .distantPast
    private var cancellables = Set<AnyCancellable>()

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

        wakeGate = WakeGate()
        wakeGate?.onOpened = { [weak self] in self?.flushParkBuffer() }
        wakeGate?.onTimedOut = { [weak self] in self?.discardAfterSilence() }
        // Partials open the gate the moment one begins with "pilot", and keep an open
        // gate open: the 20 s window runs from the last thing heard, not the last
        // final delivered.
        speechEngine?.$currentTranscript
            .filter { !$0.isEmpty }
            .sink { [weak self] text in self?.wakeGate?.notePartial(text) }
            .store(in: &cancellables)

        floatingPanel = FloatingPanelController(
            speechEngine: speechEngine!,
            terminalController: terminalController!,
            dictationManager: dictationManager!,
            wakeGate: wakeGate!
        )

        parkZone = ParkZoneController(
            terminalController: terminalController!,
            speechEngine: speechEngine!,
            wakeGate: wakeGate!
        )
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

        windowKeeper?.onWake = { [weak self] in
            self?.restartSpeechAfterWake()
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
            wakeGate: wakeGate!,
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

        // Launch System Events now rather than on the first utterance, which would
        // otherwise be the one to wait for it. Async so the windows are up first.
        DispatchQueue.main.async { [weak self] in
            self?.terminalController?.keepSystemEventsRunning()
        }
    }

    /// Rebuild the speech pipeline after the machine wakes.
    ///
    /// AVAudioEngine stops when the machine sleeps and does not come back on its own.
    /// Nothing else notices: the process stays alive, the windows still respond to
    /// hover, the menu still opens — and not one word is heard, which reads as
    /// "VoicePilot is off". Observed 2026-09-29: zero recognizer output for the eleven
    /// hours after an overnight sleep, while park events kept firing normally.
    ///
    /// Restarts unconditionally rather than probing engine health first: on wake nobody
    /// is mid-sentence, so the ~1s gap costs nothing, and a health check that returns a
    /// false positive would leave the user silently deaf again for hours.
    private func restartSpeechAfterWake() {
        guard let engine = speechEngine else { return }

        // isListening false means the user muted it deliberately. Restarting would
        // un-mute behind their back.
        guard engine.isListening else {
            vpLog("[App] wake: muted, leaving speech alone")
            return
        }

        vpLog("[App] wake: restarting the speech pipeline")
        engine.stopListening()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
            engine.startListening()
        }
    }

    private func handleUtterance(_ text: String) {
        vpLog("[App] handleUtterance: '\(text.prefix(80))'")
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        guard Date() > dictationSuppressUntil else { return }

        let heard = trimmed.replacingOccurrences(of: "\n", with: " ")
        guard !heard.isEmpty else { return }

        // Wake word mode: drops speech outright while the gate is shut, strips the
        // "pilot" that opened it, and turns "action send" / "action delete" /
        // "action stop" into Send, Clear and Escape. Sits before parking so a shut
        // gate never fills the park buffer either — nothing said across the desk is
        // kept anywhere.
        guard let gate = wakeGate else { return }
        switch gate.admit(heard) {
        case .drop:
            return
        case .send:
            submitDictation()
        case .clear:
            clearDictation()
        case .escape:
            terminalController?.pressEscape()
        case .mute:
            speechEngine?.stopListening()
        case .type(let clean):
            typeUtterance(clean)
        case .typeThenSend(let clean):
            typeUtterance(clean)
            // The paste has to land before Enter. Orca takes the clipboard a beat
            // after the keystroke; Enter on its heels would submit the previous text.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
                self?.submitDictation()
            }
        }
    }

    /// The listening window ended in silence, not "action send": wipe what it typed.
    /// Only when this app typed something since the last send or clear — otherwise
    /// the triple-click-and-Delete would take text Fabian typed by hand.
    private func discardAfterSilence() {
        guard !dictationCurrentText.isEmpty else {
            vpLog("[App] window timed out with nothing typed — nothing to discard")
            return
        }
        vpLog("[App] window timed out — discarding \(dictationCurrentText.count) typed chars")
        clearDictation()
    }

    /// "pilot" types out what was dictated while parked, once, ahead of the words that
    /// followed it. Only when delivery is actually possible: parked, the flush would
    /// bounce straight back into the buffer; in a non-target app it has nowhere to go
    /// and would be lost. Both cases leave the buffer alone for the next "pilot".
    private func flushParkBuffer() {
        guard let buffered = dictationManager?.accumulatedText.trimmingCharacters(in: .whitespacesAndNewlines),
              !buffered.isEmpty else { return }
        if terminalController?.parked == true {
            vpLog("[App] pilot: \(buffered.count) buffered chars kept — still parked")
            return
        }
        guard terminalController?.isSubmitTarget == true else {
            let front = NSWorkspace.shared.frontmostApplication?.localizedName ?? "?"
            vpLog("[App] pilot: \(buffered.count) buffered chars kept — frontmost is \(front), not a submit target")
            return
        }
        vpLog("[App] pilot: flushing \(buffered.count) buffered chars from the park zone")
        typeUtterance(buffered.replacingOccurrences(of: "\n", with: " "))
        dictationManager?.clear()
    }

    private func typeUtterance(_ clean: String) {
        guard !clean.isEmpty else { return }
        let toType = dictationCurrentText.isEmpty ? clean : " " + clean
        let delivered = terminalController?.typeText(toType) ?? false
        if delivered {
            dictationCurrentText += toType
        } else {
            dictationManager?.appendUtterance(clean)
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

        guard terminalController?.isSubmitTarget == true else {
            let front = NSWorkspace.shared.frontmostApplication?.localizedName ?? "?"
            vpLog("[App] clear ignored — frontmost is \(front), not a submit target")
            return
        }

        // Pass what we typed: in apps that hide their text from accessibility, the only
        // way to clear it is to remove exactly as many characters as we added.
        terminalController?.clearLine(charactersTyped: dictationCurrentText.count)

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

        // Enter only means "submit" in a terminal or a listed app. Logged rather than
        // silent because the Send button makes this reachable by a deliberate click, and
        // a button that does nothing with no trace is indistinguishable from a broken one.
        guard terminalController?.isSubmitTarget == true else {
            let front = NSWorkspace.shared.frontmostApplication?.localizedName ?? "?"
            vpLog("[App] submitDictation ignored — frontmost is \(front), not a submit target")
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
        wakeGate?.closeForSend()
        terminalController?.pressEnter()
    }
}
