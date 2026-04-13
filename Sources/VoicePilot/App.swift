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
    var commandDetector: CommandDetector?
    var promptRefiner: PromptRefiner?
    var terminalController: TerminalController?
    var confirmationManager: ConfirmationManager?
    var floatingPanel: FloatingPanelController?
    var promptBuilder: PromptBuilder?
    var dictationManager: DictationManager?

    private var cancellables = Set<AnyCancellable>()
    /// What's currently in the terminal from dictation
    private var dictationCurrentText = ""
    /// Suppress partials after submit to prevent doubles
    private var dictationSuppressUntil: Date = .distantPast
    /// Prevent concurrent terminal updates
    private var isUpdatingTerminal = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Hide dock icon — menu bar only
        NSApp.setActivationPolicy(.accessory)

        terminalController = TerminalController()
        commandDetector = CommandDetector()
        promptRefiner = PromptRefiner()
        confirmationManager = ConfirmationManager(terminalController: terminalController!)
        promptBuilder = PromptBuilder()
        dictationManager = DictationManager()

        dictationManager?.onMouseButton = { [weak self] in
            self?.submitDictation()
        }

        speechEngine = SpeechEngine { [weak self] utterance in
            self?.handleUtterance(utterance)
        }

        // No partial updates to terminal — only finalized utterances are appended

        // Show persistent floating panel with all controls
        floatingPanel = FloatingPanelController(
            speechEngine: speechEngine!,
            confirmationManager: confirmationManager!,
            promptBuilder: promptBuilder!,
            terminalController: terminalController!,
            dictationManager: dictationManager!
        )

        statusBar = StatusBarController(
            speechEngine: speechEngine!,
            onQuit: { NSApp.terminate(nil) },
            onShowWindow: { [weak self] in
                self?.floatingPanel?.window?.makeKeyAndOrderFront(nil)
            }
        )

        speechEngine?.startListening()

        // Default to dictation mode
        terminalController?.saveClipboard()
        dictationManager?.start()
    }

    // MARK: - Dictation live typing

    private func handleDictationPartial(_ partial: String) {
        guard dictationManager?.isActive == true else { return }
        guard Date() > dictationSuppressUntil else { return }
        guard !isUpdatingTerminal else { return }

        let clean = partial.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "\n", with: " ")

        // Build full line: committed text + current partial
        let committed = dictationManager?.accumulatedText.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let fullLine: String
        if committed.isEmpty {
            fullLine = clean
        } else if clean.isEmpty {
            return
        } else {
            fullLine = committed + " " + clean
        }

        guard !fullLine.isEmpty else { return }
        guard fullLine != dictationCurrentText else { return }

        isUpdatingTerminal = true

        // Delete old text with exact backspace count, then paste new
        let deleteCount = dictationCurrentText.count
        terminalController?.replaceTerminalText(deleteCount: deleteCount, newText: fullLine)
        dictationCurrentText = fullLine

        // Unlock after AppleScript has time to execute
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
            self?.isUpdatingTerminal = false
        }
    }

    private func handleUtterance(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !trimmed.isEmpty else { return }

        // Mute/unmute commands
        if trimmed == "mute" || trimmed == "shut up" || trimmed == "stop listening" || trimmed == "pause" {
            speechEngine?.stopListening()
            return
        }

        // Window control commands
        if trimmed == "expand" || trimmed == "open" || trimmed == "open up" || trimmed == "bigger" || trimmed == "make it bigger" || trimmed.contains("expand") {
            floatingPanel?.toggleMini()
            return
        }
        if trimmed == "minimize" || trimmed == "collapse" || trimmed == "shrink" {
            if floatingPanel?.isMini == false {
                floatingPanel?.toggleMini()
            }
            return
        }

        // --- Dictation mode ---
        if dictationManager?.isActive == true {
            guard Date() > dictationSuppressUntil else { return }

            if trimmed == "clear" || trimmed == "clear dictation" || trimmed == "start over" {
                dictationManager?.clear()
                dictationCurrentText = ""
                return
            }
            if trimmed == "cancel" || trimmed == "discard" || trimmed == "nevermind"
                || trimmed.contains("voice control") || trimmed.contains("back to voice")
                || trimmed.contains("switch to voice") {
                terminalController?.restoreClipboard()
                dictationManager?.stop()
                dictationCurrentText = ""
                return
            }

            // Utterance finalized — append to terminal (no replacing, no flickering)
            let clean = text.trimmingCharacters(in: .whitespacesAndNewlines)
                .replacingOccurrences(of: "\n", with: " ")
            guard !clean.isEmpty else { return }

            let toType = dictationCurrentText.isEmpty ? clean : " " + clean
            terminalController?.typeText(toType)
            dictationCurrentText += toType
            dictationManager?.appendUtterance(text)
            return
        }

        // --- Prompt Builder mode ---
        if promptBuilder?.isActive == true {
            if trimmed == "send" || trimmed == "done" || trimmed == "ship it" || trimmed == "send it" {
                if let draft = promptBuilder?.currentDraft, !draft.isEmpty {
                    terminalController?.pasteAndEnter(draft)
                    confirmationManager?.showBriefly(draft)
                    promptBuilder?.stop()
                }
                return
            }
            if trimmed == "cancel" || trimmed == "discard" || trimmed == "nevermind"
                || trimmed.contains("voice control") || trimmed.contains("back to voice")
                || trimmed.contains("switch to voice") {
                promptBuilder?.stop()
                return
            }
            if trimmed == "start over" || trimmed == "reset" {
                promptBuilder?.start()
                return
            }
            promptBuilder?.addInput(text) {
                print("[App] Builder refinement complete")
            }
            return
        }

        // --- Normal mode ---

        // Voice command to activate dictation mode
        if trimmed == "dictation" || trimmed == "dictation mode" || trimmed.contains("switch to dictation") || trimmed == "dictate" {
            promptBuilder?.stop()
            dictationCurrentText = ""
            terminalController?.saveClipboard()
            dictationManager?.start()
            return
        }

        // Voice command to activate prompt builder
        if trimmed.contains("build prompt") || trimmed.contains("prompt builder") || trimmed.contains("prompt mode") || trimmed.contains("switch to prompt") || trimmed == "draft mode" || trimmed == "builder" || trimmed == "go for it" || trimmed == "prompt" {
            dictationManager?.stop()
            promptBuilder?.start()
            return
        }

        // Check if it's a confirmation/cancel for pending prompt
        if confirmationManager?.isShowingConfirmation == true {
            if trimmed == "send" || trimmed == "go" || trimmed == "yes" {
                confirmationManager?.confirmNow()
                return
            }
            if trimmed == "cancel" || trimmed == "no" || trimmed == "abort" {
                confirmationManager?.cancel()
                return
            }
        }

        // Check if it's a terminal command
        if let command = commandDetector?.detect(trimmed) {
            DispatchQueue.main.async { [weak self] in
                self?.statusBar?.flash(command.description)
                self?.terminalController?.execute(command)
            }
            return
        }

        // It's a prompt — clean up and send directly to terminal
        promptRefiner?.refine(text) { [weak self] refined in
            DispatchQueue.main.async {
                self?.confirmationManager?.showBriefly(refined)
                self?.terminalController?.pasteAndEnter(refined)
            }
        }
    }

    private func submitDictation() {
        // Suppress partials for 3 seconds to prevent doubles
        dictationSuppressUntil = Date().addingTimeInterval(3.0)
        dictationCurrentText = ""
        dictationManager?.clear()
        speechEngine?.currentTranscript = ""
        // Always send Enter — activate terminal if needed
        terminalController?.activateTerminalAndPressEnter()
        terminalController?.saveClipboard()
    }
}
