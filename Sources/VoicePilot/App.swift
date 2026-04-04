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

    private var cancellables = Set<AnyCancellable>()

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Hide dock icon — menu bar only
        NSApp.setActivationPolicy(.accessory)

        terminalController = TerminalController()
        commandDetector = CommandDetector()
        promptRefiner = PromptRefiner()
        confirmationManager = ConfirmationManager(terminalController: terminalController!)

        speechEngine = SpeechEngine { [weak self] utterance in
            self?.handleUtterance(utterance)
        }

        statusBar = StatusBarController(
            speechEngine: speechEngine!,
            onQuit: { NSApp.terminate(nil) }
        )

        // Show persistent floating panel
        floatingPanel = FloatingPanelController(
            speechEngine: speechEngine!,
            confirmationManager: confirmationManager!
        )

        speechEngine?.startListening()
    }

    private func handleUtterance(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !trimmed.isEmpty else { return }

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
