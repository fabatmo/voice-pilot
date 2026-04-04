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

    private var cancellables = Set<AnyCancellable>()

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Hide dock icon — menu bar only
        NSApp.setActivationPolicy(.accessory)

        terminalController = TerminalController()
        commandDetector = CommandDetector()
        promptRefiner = PromptRefiner()
        confirmationManager = ConfirmationManager(terminalController: terminalController!)
        promptBuilder = PromptBuilder()

        speechEngine = SpeechEngine { [weak self] utterance in
            self?.handleUtterance(utterance)
        }

        statusBar = StatusBarController(
            speechEngine: speechEngine!,
            onQuit: { NSApp.terminate(nil) }
        )

        // Show persistent floating panel with all controls
        floatingPanel = FloatingPanelController(
            speechEngine: speechEngine!,
            confirmationManager: confirmationManager!,
            promptBuilder: promptBuilder!,
            terminalController: terminalController!
        )

        speechEngine?.startListening()
    }

    private func handleUtterance(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !trimmed.isEmpty else { return }

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

        // --- Prompt Builder mode ---
        if promptBuilder?.isActive == true {
            // "send" / "done" / "ship it" — send the draft to terminal
            if trimmed == "send" || trimmed == "done" || trimmed == "ship it" || trimmed == "send it" {
                if let draft = promptBuilder?.currentDraft, !draft.isEmpty {
                    terminalController?.pasteAndEnter(draft)
                    confirmationManager?.showBriefly(draft)
                    promptBuilder?.stop()
                }
                return
            }
            // "cancel" / "discard" / "voice control" — exit builder without sending
            if trimmed == "cancel" || trimmed == "discard" || trimmed == "nevermind"
                || trimmed.contains("voice control") || trimmed.contains("back to voice")
                || trimmed.contains("switch to voice") {
                promptBuilder?.stop()
                return
            }
            // "start over" — reset but stay in builder
            if trimmed == "start over" || trimmed == "reset" {
                promptBuilder?.start()
                return
            }
            // Otherwise — feed input to builder
            print("[App] Builder input: \(text)")
            promptBuilder?.addInput(text) {
                print("[App] Builder refinement complete")
            }
            return
        }

        // --- Normal mode ---

        // Voice command to activate prompt builder
        if trimmed.contains("build prompt") || trimmed.contains("prompt builder") || trimmed.contains("prompt mode") || trimmed.contains("switch to prompt") || trimmed == "draft mode" || trimmed == "builder" || trimmed == "go for it" || trimmed == "prompt" {
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
}
