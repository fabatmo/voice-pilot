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
    var promptRefiner: PromptRefiner?
    var terminalController: TerminalController?
    var confirmationManager: ConfirmationManager?
    var floatingPanel: FloatingPanelController?
    var promptBuilder: PromptBuilder?
    var dictationManager: DictationManager?

    private var cancellables = Set<AnyCancellable>()
    private var dictationCurrentText = ""
    private var dictationSuppressUntil: Date = .distantPast

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)

        terminalController = TerminalController()
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
            promptBuilder: promptBuilder!,
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

    private func handleUtterance(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !trimmed.isEmpty else { return }

        if dictationManager?.isActive == true {
            guard Date() > dictationSuppressUntil else { return }

            let clean = text.trimmingCharacters(in: .whitespacesAndNewlines)
                .replacingOccurrences(of: "\n", with: " ")
            guard !clean.isEmpty else { return }

            // Type live into the destination. typeText returns whether delivery succeeded:
            // - terminal frontmost → keystroke (always succeeds)
            // - other app with focused text field → AX direct insert
            // - Finder / video player / no focus / Terminal-only mode but no terminal → false
            let toType = dictationCurrentText.isEmpty ? clean : " " + clean
            let delivered = terminalController?.typeText(toType) ?? false
            if delivered {
                dictationCurrentText += toType
                // Don't accumulate in the panel — the destination already has the text.
            } else {
                // Delivery failed (no focused field, etc.) — keep it in the panel buffer
                // so the user has a fallback transcript.
                dictationManager?.appendUtterance(text)
            }
            return
        }

        // Prompt Builder mode — pass input through (no keyword commands)
        if promptBuilder?.isActive == true {
            promptBuilder?.addInput(text) {
                #if DEBUG
                print("[App] Builder refinement complete")
                #endif
            }
            return
        }

        // Normal mode — send as prompt to terminal
        promptRefiner?.refine(text) { [weak self] refined in
            DispatchQueue.main.async {
                self?.confirmationManager?.showBriefly(refined)
                self?.terminalController?.pasteAndEnter(refined)
            }
        }
    }

    private func submitDictation() {
        // Dictation submit is always terminal-targeted, regardless of the Terminal/Any App
        // toggle. If no terminal is frontmost, the middle-click is still consumed (YouTube
        // isolation) but the submit is a no-op and the buffer is preserved.
        guard terminalController?.isTerminalFrontmost == true else { return }

        dictationSuppressUntil = Date().addingTimeInterval(3.0)
        dictationCurrentText = ""
        dictationManager?.clear()
        speechEngine?.currentTranscript = ""
        terminalController?.pressEnter()
    }
}
