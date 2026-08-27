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

        statusBar = StatusBarController(
            speechEngine: speechEngine!,
            onQuit: { NSApp.terminate(nil) },
            onShowWindow: { [weak self] in
                self?.floatingPanel?.window?.makeKeyAndOrderFront(nil)
            }
        )

        speechEngine?.startListening()
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
        guard terminalController?.isTerminalFrontmost == true else { return }

        dictationSuppressUntil = Date().addingTimeInterval(3.0)
        dictationCurrentText = ""
        dictationManager?.clear()
        speechEngine?.currentTranscript = ""
        terminalController?.pressEnter()
    }
}
