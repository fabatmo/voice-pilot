import AppKit
import SwiftUI
import Combine

class StatusBarController {
    private var statusItem: NSStatusItem
    private var speechEngine: SpeechEngine
    private var parkZone: ParkZoneController
    private var wakeGate: WakeGate
    private var onBringToFront: () -> Void
    private var onQuit: () -> Void
    private var onShowWindow: () -> Void
    private var cancellables = Set<AnyCancellable>()

    init(
        speechEngine: SpeechEngine,
        parkZone: ParkZoneController,
        wakeGate: WakeGate,
        onBringToFront: @escaping () -> Void,
        onQuit: @escaping () -> Void,
        onShowWindow: @escaping () -> Void
    ) {
        self.speechEngine = speechEngine
        self.parkZone = parkZone
        self.wakeGate = wakeGate
        self.onBringToFront = onBringToFront
        self.onQuit = onQuit
        self.onShowWindow = onShowWindow

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

        let showItem = NSMenuItem(title: "Show Window", action: #selector(showWindow), keyEquivalent: "w")
        showItem.keyEquivalentModifierMask = [.command]
        showItem.target = self
        menu.addItem(showItem)

        let toggleItem = NSMenuItem(
            title: speechEngine.isListening ? "Pause Listening" : "Start Listening",
            action: #selector(toggleListening),
            keyEquivalent: "l"
        )
        toggleItem.keyEquivalentModifierMask = [.command, .shift]
        toggleItem.target = self
        menu.addItem(toggleItem)

        menu.addItem(.separator())

        let zoneItem = NSMenuItem(
            title: parkZone.isVisible ? "Hide Park Zone" : "Show Park Zone",
            action: #selector(toggleParkZone),
            keyEquivalent: "p"
        )
        zoneItem.keyEquivalentModifierMask = [.command, .shift]
        zoneItem.target = self
        menu.addItem(zoneItem)

        // Manual escape hatch: the wake handler should make this unnecessary, but a
        // window you cannot get back is worth a one-click recovery either way.
        let frontItem = NSMenuItem(
            title: "Bring Windows Here  (⌃⇧P)",
            action: #selector(bringToFront),
            keyEquivalent: ""
        )
        frontItem.target = self
        menu.addItem(frontItem)

        let panelHoverItem = NSMenuItem(
            title: "Park on Panel Hover",
            action: #selector(togglePanelHover),
            keyEquivalent: ""
        )
        panelHoverItem.state = FloatingPanelController.panelHoverEnabled ? .on : .off
        panelHoverItem.target = self
        menu.addItem(panelHoverItem)

        let wakeWordItem = NSMenuItem(
            title: "Wake Word “\(WakeGate.word)”  (people in the room)",
            action: #selector(toggleWakeWord),
            keyEquivalent: ""
        )
        wakeWordItem.state = wakeGate.enabled ? .on : .off
        wakeWordItem.target = self
        menu.addItem(wakeWordItem)

        menu.addItem(.separator())

        let engineLabel = NSMenuItem(
            title: "Engine: \(speechEngine.engineChoice.displayName)",
            action: nil,
            keyEquivalent: ""
        )
        engineLabel.isEnabled = false
        menu.addItem(engineLabel)

        let other: SpeechEngineChoice = speechEngine.engineChoice == .analyzer ? .legacy : .analyzer
        let switchItem = NSMenuItem(
            title: "Switch to \(other.displayName) and Relaunch",
            action: #selector(switchEngine),
            keyEquivalent: ""
        )
        switchItem.target = self
        menu.addItem(switchItem)

        menu.addItem(.separator())

        let quitItem = NSMenuItem(title: "Quit Voice Pilot", action: #selector(quit), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)

        return menu
    }

    @objc private func showWindow() {
        onShowWindow()
    }

    @objc private func toggleListening() {
        speechEngine.toggleListening()
    }

    @objc private func quit() {
        onQuit()
    }

    @objc private func bringToFront() {
        vpLog("[StatusBar] bring windows to front requested")
        onBringToFront()
    }

    @objc private func toggleParkZone() {
        parkZone.toggle()
    }

    /// Takes effect on the next hover — the panel reads the setting each time rather
    /// than caching it, so there is nothing to relaunch for.
    @objc private func togglePanelHover() {
        let next = !FloatingPanelController.panelHoverEnabled
        UserDefaults.standard.set(next, forKey: FloatingPanelController.panelHoverKey)
        vpLog("[StatusBar] park on panel hover = \(next)")
    }

    /// Same switch as the "Pilot: On/Off" button on the floater.
    @objc private func toggleWakeWord() {
        wakeGate.enabled.toggle()
    }

    /// Engines are chosen at launch, so switching relaunches the process.
    @objc private func switchEngine() {
        let other: SpeechEngineChoice = speechEngine.engineChoice == .analyzer ? .legacy : .analyzer
        UserDefaults.standard.set(other.rawValue, forKey: SpeechEngineChoice.defaultsKey)
        UserDefaults.standard.synchronize()
        vpLog("[StatusBar] switching engine to \(other.rawValue), relaunching")

        let url = Bundle.main.bundleURL
        let config = NSWorkspace.OpenConfiguration()
        config.createsNewApplicationInstance = true
        NSWorkspace.shared.openApplication(at: url, configuration: config) { _, _ in
            DispatchQueue.main.async { NSApp.terminate(nil) }
        }
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
