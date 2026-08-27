import SwiftUI
import AppKit
import Combine

/// Panel that allows text editing without stealing focus from other apps
class NonActivatingPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

class FloatingPanelController: NSObject, ObservableObject, NSWindowDelegate {
    var window: NSWindow?
    private var speechEngine: SpeechEngine
    private var terminalController: TerminalController
    private var dictationManager: DictationManager
    @Published var isMini = true

    init(speechEngine: SpeechEngine, terminalController: TerminalController, dictationManager: DictationManager) {
        self.speechEngine = speechEngine
        self.terminalController = terminalController
        self.dictationManager = dictationManager
        super.init()
        showWindow()
    }

    func showWindow() {
        let view = MainView(
            speechEngine: speechEngine,
            terminalController: terminalController,
            dictationManager: dictationManager,
            panelController: self
        )
        .preferredColorScheme(.dark)

        let hostingView = NSHostingView(rootView: view)
        let miniSize = NSRect(x: 0, y: 0, width: 310, height: 90)

        let panel = NonActivatingPanel(
            contentRect: miniSize,
            styleMask: [.titled, .closable, .resizable, .fullSizeContentView, .nonactivatingPanel, .utilityWindow],
            backing: .buffered,
            defer: false
        )
        panel.title = "Voice Pilot"
        panel.titlebarAppearsTransparent = true
        panel.isMovableByWindowBackground = true
        panel.contentView = hostingView
        panel.backgroundColor = NSColor(red: 0.11, green: 0.11, blue: 0.12, alpha: 1.0)
        panel.isOpaque = true
        panel.hasShadow = true
        panel.minSize = NSSize(width: 310, height: 90)
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.level = .floating
        panel.appearance = NSAppearance(named: .darkAqua)
        panel.delegate = self
        panel.becomesKeyOnlyIfNeeded = true
        panel.hidesOnDeactivate = false

        if let screen = NSScreen.main {
            let screenFrame = screen.visibleFrame
            let x = screenFrame.maxX - 330
            let y = screenFrame.maxY - 110
            panel.setFrameOrigin(NSPoint(x: x, y: y))
        }

        panel.orderFront(nil)
        self.window = panel
    }

    // Green button (zoom) toggles mini/full
    func windowShouldZoom(_ window: NSWindow, toFrame newFrame: NSRect) -> Bool {
        toggleMini()
        return false // We handle it ourselves
    }

    func toggleMini() {
        guard let window = window else { return }
        isMini.toggle()
        let origin = window.frame.origin

        if isMini {
            window.setFrame(NSRect(x: origin.x, y: origin.y, width: 310, height: 90), display: true, animate: true)
        } else {
            window.setFrame(NSRect(x: origin.x, y: origin.y, width: 310, height: 300), display: true, animate: true)
        }
    }
}

// MARK: - Main View

struct MainView: View {
    @ObservedObject var speechEngine: SpeechEngine
    @ObservedObject var terminalController: TerminalController
    @ObservedObject var dictationManager: DictationManager
    @ObservedObject var panelController: FloatingPanelController

    let bg = Color(nsColor: NSColor(red: 0.11, green: 0.11, blue: 0.12, alpha: 1.0))

    var body: some View {
        Group {
            if panelController.isMini {
                MiniContent(
                    speechEngine: speechEngine,
                    dictationManager: dictationManager
                )
            } else {
                DictationContent(
                    speechEngine: speechEngine,
                    dictationManager: dictationManager,
                    terminalController: terminalController
                )
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(bg)
    }
}

// MARK: - Mini Content

struct MiniContent: View {
    @ObservedObject var speechEngine: SpeechEngine
    @ObservedObject var dictationManager: DictationManager

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Spacer().frame(height: 22)

            HStack(spacing: 8) {
                Circle()
                    .fill(speechEngine.isListening ? Color.green : Color.red)
                    .frame(width: 7, height: 7)

                if !speechEngine.currentTranscript.isEmpty {
                    Text(speechEngine.currentTranscript)
                        .font(.system(size: 12))
                        .foregroundColor(.white)
                        .lineLimit(2)
                } else {
                    Text(speechEngine.isListening ? "Dictating..." : "Paused")
                        .font(.system(size: 12))
                        .foregroundColor(Color.white.opacity(0.5))
                }

                Spacer()

                NativeButton(title: speechEngine.isListening ? "Mute" : "Unmute") {
                    speechEngine.toggleListening()
                }
                .frame(width: 58, height: 18)
            }
            .padding(.horizontal, 14)

            Spacer()
        }
    }
}

// MARK: - Dictation Content

struct DictationContent: View {
    @ObservedObject var speechEngine: SpeechEngine
    @ObservedObject var dictationManager: DictationManager
    @ObservedObject var terminalController: TerminalController

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 10) {
                Spacer().frame(height: 22)

                if !speechEngine.currentTranscript.isEmpty {
                    HStack(alignment: .top, spacing: 8) {
                        Image(systemName: "waveform")
                            .font(.system(size: 12))
                            .foregroundColor(.green)
                        Text(speechEngine.currentTranscript)
                            .font(.system(size: 13))
                            .foregroundColor(.white)
                            .lineLimit(5)
                    }
                } else {
                    HStack(spacing: 8) {
                        Image(systemName: "waveform")
                            .font(.system(size: 12))
                            .foregroundColor(Color.white.opacity(0.2))
                        Text("Speak — text types live")
                            .font(.system(size: 13))
                            .foregroundColor(Color.white.opacity(0.2))
                    }
                }

                TextEditor(text: $dictationManager.accumulatedText)
                    .font(.system(size: 12))
                    .foregroundColor(Color.white.opacity(0.7))
                    .scrollContentBackground(.hidden)
                    .background(Color.white.opacity(0.04))
                    .cornerRadius(6)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .padding(.horizontal, 16)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)

            BottomToolbar(
                speechEngine: speechEngine,
                terminalController: terminalController,
                dictationManager: dictationManager
            )
        }
    }
}

// MARK: - Toolbar button

private let tbButtonWidth: CGFloat = 54

struct TBButton: View {
    let title: String
    let active: Bool
    let action: () -> Void

    var body: some View {
        Button(title, action: action)
            .buttonStyle(.bordered)
            .controlSize(.mini)
            .tint(active ? .green : nil)
            .frame(width: tbButtonWidth)
            .opacity(active ? 1.0 : 0.6)
    }
}

// MARK: - Bottom toolbar

struct BottomToolbar: View {
    @ObservedObject var speechEngine: SpeechEngine
    @ObservedObject var terminalController: TerminalController
    @ObservedObject var dictationManager: DictationManager

    var body: some View {
        HStack(spacing: 0) {
            TBButton(title: "Dictation", active: dictationManager.isActive) {
                if !dictationManager.isActive { dictationManager.start() }
            }
            Spacer(minLength: 4)
            TBButton(title: speechEngine.isListening ? "Mute" : "Unmute", active: false) {
                speechEngine.toggleListening()
            }
            Spacer(minLength: 4)
            TargetButtonInline(terminalController: terminalController)
        }
        .padding(.horizontal, 10)
        .padding(.top, 10)
        .padding(.bottom, 12)
    }
}

/// Thin wrapper so the target button observes TerminalController only when it actually renders.
private struct TargetButtonInline: View {
    @ObservedObject var terminalController: TerminalController
    var body: some View {
        TBButton(title: terminalController.terminalOnly ? "Terminal" : "Any App", active: false) {
            terminalController.terminalOnly.toggle()
        }
    }
}

