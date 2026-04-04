import AppKit
import SwiftUI
import Combine

class StatusBarController {
    private var statusItem: NSStatusItem
    private var speechEngine: SpeechEngine
    private var terminalController: TerminalController
    private var onQuit: () -> Void
    private var cancellables = Set<AnyCancellable>()

    init(speechEngine: SpeechEngine, terminalController: TerminalController, onQuit: @escaping () -> Void) {
        self.speechEngine = speechEngine
        self.terminalController = terminalController
        self.onQuit = onQuit

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)

        if let button = statusItem.button {
            button.image = NSImage(systemSymbolName: "mic.circle", accessibilityDescription: "Voice Pilot")
            button.action = #selector(toggleMenu)
            button.target = self
        }

        setupMenu()
        observeState()
    }

    @objc private func toggleMenu() {
        statusItem.menu = buildMenu()
        statusItem.button?.performClick(nil)
        // Clear menu after it closes so clicks work next time
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
            self?.statusItem.menu = nil
        }
    }

    private func setupMenu() {
        // Menu built on demand in toggleMenu
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

        if !speechEngine.currentTranscript.isEmpty {
            let transcriptItem = NSMenuItem(
                title: "  \"\(speechEngine.currentTranscript.prefix(50))\"",
                action: nil,
                keyEquivalent: ""
            )
            transcriptItem.isEnabled = false
            menu.addItem(transcriptItem)
        }

        menu.addItem(.separator())

        let modeLabel = NSMenuItem(title: "── Send To ──", action: nil, keyEquivalent: "")
        modeLabel.isEnabled = false
        menu.addItem(modeLabel)

        let terminalItem = NSMenuItem(
            title: "  Terminal Only",
            action: #selector(setTerminalMode),
            keyEquivalent: ""
        )
        terminalItem.target = self
        terminalItem.state = terminalController.terminalOnly ? .on : .off
        menu.addItem(terminalItem)

        let anyAppItem = NSMenuItem(
            title: "  Any App (Browser, Notes, etc.)",
            action: #selector(setAnyAppMode),
            keyEquivalent: ""
        )
        anyAppItem.target = self
        anyAppItem.state = terminalController.terminalOnly ? .off : .on
        menu.addItem(anyAppItem)

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

    @objc private func setTerminalMode() {
        terminalController.terminalOnly = true
        flash("Terminal Only")
    }

    @objc private func setAnyAppMode() {
        terminalController.terminalOnly = false
        flash("Any App")
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
