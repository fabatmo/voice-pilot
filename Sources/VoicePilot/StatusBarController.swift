import AppKit
import SwiftUI
import Combine

class StatusBarController {
    private var statusItem: NSStatusItem
    private var speechEngine: SpeechEngine
    private var onQuit: () -> Void
    private var cancellables = Set<AnyCancellable>()

    init(speechEngine: SpeechEngine, onQuit: @escaping () -> Void) {
        self.speechEngine = speechEngine
        self.onQuit = onQuit

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)

        if let button = statusItem.button {
            button.image = NSImage(systemSymbolName: "mic.circle", accessibilityDescription: "Voice Pilot")
            button.action = #selector(toggleMenu)
            button.target = self
        }

        observeState()
    }

    @objc private func toggleMenu() {
        statusItem.menu = buildMenu()
        statusItem.button?.performClick(nil)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
            self?.statusItem.menu = nil
        }
    }

    private func buildMenu() -> NSMenu {
        let menu = NSMenu()

        let stateItem = NSMenuItem(
            title: speechEngine.isListening ? "Listening..." : "Paused",
            action: nil,
            keyEquivalent: ""
        )
        stateItem.isEnabled = false
        menu.addItem(stateItem)

        menu.addItem(.separator())

        let toggleItem = NSMenuItem(
            title: speechEngine.isListening ? "Pause Listening" : "Start Listening",
            action: #selector(toggleListening),
            keyEquivalent: "l"
        )
        toggleItem.keyEquivalentModifierMask = [.command, .shift]
        toggleItem.target = self
        menu.addItem(toggleItem)

        menu.addItem(.separator())

        let quitItem = NSMenuItem(title: "Quit Voice Pilot", action: #selector(quit), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)

        return menu
    }

    @objc private func toggleListening() {
        speechEngine.toggleListening()
    }

    @objc private func quit() {
        onQuit()
    }

    private func observeState() {
        speechEngine.$isListening
            .receive(on: DispatchQueue.main)
            .sink { [weak self] listening in
                self?.updateIcon(listening: listening)
            }
            .store(in: &cancellables)

        speechEngine.$currentTranscript
            .receive(on: DispatchQueue.main)
            .sink { [weak self] transcript in
                if !transcript.isEmpty {
                    self?.updateIcon(listening: true, active: true)
                }
            }
            .store(in: &cancellables)
    }

    private func updateIcon(listening: Bool, active: Bool = false) {
        let symbolName: String
        if active {
            symbolName = "mic.fill"
        } else if listening {
            symbolName = "mic.circle"
        } else {
            symbolName = "mic.slash"
        }
        statusItem.button?.image = NSImage(
            systemSymbolName: symbolName,
            accessibilityDescription: "Voice Pilot"
        )
    }

    func flash(_ message: String) {
        let original = statusItem.button?.title
        statusItem.button?.title = " \(message)"
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
            self?.statusItem.button?.title = original ?? ""
        }
    }

    func showRefining() {
        statusItem.button?.image = NSImage(
            systemSymbolName: "brain.head.profile",
            accessibilityDescription: "Refining prompt..."
        )
    }

    func showIdle() {
        updateIcon(listening: speechEngine.isListening)
    }
}
