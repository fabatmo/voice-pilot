import SwiftUI
import AppKit
import Combine

class FloatingPanelController: NSObject, ObservableObject, NSWindowDelegate {
    var window: NSWindow?
    private var speechEngine: SpeechEngine
    private var confirmationManager: ConfirmationManager
    private var promptBuilder: PromptBuilder
    private var terminalController: TerminalController
    private var dictationManager: DictationManager
    @Published var isMini = true

    init(speechEngine: SpeechEngine, confirmationManager: ConfirmationManager, promptBuilder: PromptBuilder, terminalController: TerminalController, dictationManager: DictationManager) {
        self.speechEngine = speechEngine
        self.confirmationManager = confirmationManager
        self.promptBuilder = promptBuilder
        self.terminalController = terminalController
        self.dictationManager = dictationManager
        super.init()
        showWindow()
    }

    func showWindow() {
        let view = MainView(
            speechEngine: speechEngine,
            confirmationManager: confirmationManager,
            promptBuilder: promptBuilder,
            terminalController: terminalController,
            dictationManager: dictationManager,
            panelController: self
        )
        .preferredColorScheme(.dark)

        let hostingView = NSHostingView(rootView: view)
        let miniSize = NSRect(x: 0, y: 0, width: 300, height: 90)

        let window = NSWindow(
            contentRect: miniSize,
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.title = "Voice Pilot"
        window.titlebarAppearsTransparent = true
        window.isMovableByWindowBackground = true
        window.contentView = hostingView
        window.backgroundColor = NSColor(red: 0.11, green: 0.11, blue: 0.12, alpha: 1.0)
        window.isOpaque = true
        window.hasShadow = true
        window.minSize = NSSize(width: 260, height: 90)
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        window.level = .floating
        window.appearance = NSAppearance(named: .darkAqua)
        window.delegate = self

        if let screen = NSScreen.main {
            let screenFrame = screen.visibleFrame
            let x = screenFrame.maxX - 320
            let y = screenFrame.maxY - 110
            window.setFrameOrigin(NSPoint(x: x, y: y))
        }

        window.makeKeyAndOrderFront(nil)
        self.window = window
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
            window.setFrame(NSRect(x: origin.x, y: origin.y, width: 300, height: 90), display: true, animate: true)
        } else {
            window.setFrame(NSRect(x: origin.x, y: origin.y, width: 320, height: 300), display: true, animate: true)
        }
    }
}

// MARK: - Main View

struct MainView: View {
    @ObservedObject var speechEngine: SpeechEngine
    @ObservedObject var confirmationManager: ConfirmationManager
    @ObservedObject var promptBuilder: PromptBuilder
    @ObservedObject var terminalController: TerminalController
    @ObservedObject var dictationManager: DictationManager
    @ObservedObject var panelController: FloatingPanelController

    let bg = Color(nsColor: NSColor(red: 0.11, green: 0.11, blue: 0.12, alpha: 1.0))

    var body: some View {
        Group {
            if panelController.isMini {
                MiniContent(
                    speechEngine: speechEngine,
                    confirmationManager: confirmationManager,
                    dictationManager: dictationManager
                )
            } else if dictationManager.isActive {
                DictationContent(
                    speechEngine: speechEngine,
                    dictationManager: dictationManager,
                    promptBuilder: promptBuilder,
                    terminalController: terminalController
                )
            } else if promptBuilder.isActive {
                BuilderContent(
                    speechEngine: speechEngine,
                    promptBuilder: promptBuilder,
                    dictationManager: dictationManager
                )
            } else {
                FullContent(
                    speechEngine: speechEngine,
                    confirmationManager: confirmationManager,
                    promptBuilder: promptBuilder,
                    terminalController: terminalController,
                    dictationManager: dictationManager
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
    @ObservedObject var confirmationManager: ConfirmationManager
    @ObservedObject var dictationManager: DictationManager

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Spacer().frame(height: 22)

            HStack(spacing: 8) {
                Circle()
                    .fill(dictationManager.isActive ? Color.orange : (speechEngine.isListening ? Color.green : Color.red))
                    .frame(width: 7, height: 7)

                if dictationManager.isActive {
                    if !speechEngine.currentTranscript.isEmpty {
                        Text(speechEngine.currentTranscript)
                            .font(.system(size: 12))
                            .foregroundColor(.white)
                            .lineLimit(2)
                    } else {
                        Text("Dictating...")
                            .font(.system(size: 12))
                            .foregroundColor(Color.white.opacity(0.5))
                    }
                } else if !speechEngine.currentTranscript.isEmpty {
                    Text(speechEngine.currentTranscript)
                        .font(.system(size: 12))
                        .foregroundColor(.white)
                        .lineLimit(2)
                } else if confirmationManager.isShowingConfirmation {
                    HStack(spacing: 4) {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.system(size: 10))
                            .foregroundColor(.green)
                        Text("Sent")
                            .font(.system(size: 11))
                            .foregroundColor(.green)
                    }
                } else {
                    Text(speechEngine.isListening ? "Listening..." : "Paused")
                        .font(.system(size: 12))
                        .foregroundColor(Color.white.opacity(0.3))
                }

                Spacer()
            }
            .padding(.horizontal, 14)

            Spacer()
        }
    }
}

// MARK: - Full Content

struct FullContent: View {
    @ObservedObject var speechEngine: SpeechEngine
    @ObservedObject var confirmationManager: ConfirmationManager
    @ObservedObject var promptBuilder: PromptBuilder
    @ObservedObject var terminalController: TerminalController
    @ObservedObject var dictationManager: DictationManager

    private var modeIndex: Int {
        if dictationManager.isActive { return 2 }
        if promptBuilder.isActive { return 1 }
        return 0
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 10) {
                Spacer().frame(height: 22)

                // Transcript
                if !speechEngine.currentTranscript.isEmpty {
                    HStack(alignment: .top, spacing: 8) {
                        Image(systemName: "waveform")
                            .font(.system(size: 12))
                            .foregroundColor(.blue)
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
                        Text("Speak a command or prompt...")
                            .font(.system(size: 13))
                            .foregroundColor(Color.white.opacity(0.2))
                    }
                }

                if confirmationManager.isShowingConfirmation {
                    HStack(spacing: 6) {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.system(size: 10))
                            .foregroundColor(.green)
                        Text(confirmationManager.refinedText)
                            .font(.system(size: 12))
                            .foregroundColor(Color.white.opacity(0.6))
                            .lineLimit(3)
                    }
                }
            }
            .padding(.horizontal, 16)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)

            // Bottom bar
            VStack(spacing: 8) {
                ModeToggle(
                    promptBuilder: promptBuilder,
                    dictationManager: dictationManager
                )
                .frame(height: 24)

                // Status row
                HStack {
                    HStack(spacing: 6) {
                        Circle()
                            .fill(speechEngine.isListening ? Color.green : Color.red)
                            .frame(width: 6, height: 6)
                        Text(speechEngine.isListening ? "Listening" : "Muted")
                            .font(.system(size: 10))
                            .foregroundColor(Color.white.opacity(0.25))
                    }
                    Spacer()
                    NativeButton(title: speechEngine.isListening ? "Mute" : "Unmute") {
                        speechEngine.toggleListening()
                    }
                    .frame(width: 65, height: 20)
                    NativeButton(title: terminalController.terminalOnly ? "Terminal" : "Any App") {
                        terminalController.terminalOnly.toggle()
                    }
                    .frame(width: 70, height: 20)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(Color.white.opacity(0.02))
        }
    }
}

// MARK: - Builder Content

struct BuilderContent: View {
    @ObservedObject var speechEngine: SpeechEngine
    @ObservedObject var promptBuilder: PromptBuilder
    @ObservedObject var dictationManager: DictationManager

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 10) {
                Spacer().frame(height: 22)

                if !speechEngine.currentTranscript.isEmpty {
                    HStack(spacing: 6) {
                        Image(systemName: "waveform")
                            .font(.system(size: 10))
                            .foregroundColor(.blue)
                        Text(speechEngine.currentTranscript)
                            .font(.system(size: 11))
                            .foregroundColor(Color.white.opacity(0.5))
                            .lineLimit(2)
                    }
                }

                if promptBuilder.isRefining {
                    HStack(spacing: 8) {
                        ProgressView()
                            .controlSize(.small)
                            .tint(.white)
                        Text("Refining...")
                            .font(.system(size: 12))
                            .foregroundColor(Color.white.opacity(0.4))
                    }
                } else if !promptBuilder.currentDraft.isEmpty {
                    ScrollView {
                        Text(promptBuilder.currentDraft)
                            .font(.system(size: 13))
                            .foregroundColor(.white)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                } else {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Describe your prompt...")
                            .font(.system(size: 13))
                            .foregroundColor(Color.white.opacity(0.25))
                        Text("Speak freely. Refine as you go.")
                            .font(.system(size: 11))
                            .foregroundColor(Color.white.opacity(0.15))
                    }
                }
            }
            .padding(.horizontal, 16)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)

            VStack(spacing: 8) {
                ModeToggle(
                    promptBuilder: promptBuilder,
                    dictationManager: dictationManager
                )
                .frame(height: 24)

                // Model + hints row
                HStack {
                    Picker("", selection: Binding(
                        get: { promptBuilder.selectedModel },
                        set: { promptBuilder.selectedModel = $0 }
                    )) {
                        ForEach(BuilderModel.allCases, id: \.self) { model in
                            Text(model.displayName).tag(model)
                        }
                    }
                    .pickerStyle(.menu)
                    .frame(width: 110)
                    .controlSize(.small)

                    Spacer()

                    Text("\"send\" \u{2022} \"cancel\"")
                        .font(.system(size: 10))
                        .foregroundColor(Color.white.opacity(0.2))
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(Color.white.opacity(0.02))
        }
    }
}

// MARK: - Dictation Content

struct DictationContent: View {
    @ObservedObject var speechEngine: SpeechEngine
    @ObservedObject var dictationManager: DictationManager
    @ObservedObject var promptBuilder: PromptBuilder
    @ObservedObject var terminalController: TerminalController

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 10) {
                Spacer().frame(height: 22)

                // Live transcript — typing into terminal in real-time
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
                        Text("Speak — text types live into terminal")
                            .font(.system(size: 13))
                            .foregroundColor(Color.white.opacity(0.2))
                    }
                }

                if !dictationManager.accumulatedText.isEmpty {
                    Text(dictationManager.accumulatedText)
                        .font(.system(size: 11))
                        .foregroundColor(Color.white.opacity(0.3))
                        .lineLimit(3)
                }
            }
            .padding(.horizontal, 16)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)

            VStack(spacing: 8) {
                ModeToggle(
                    promptBuilder: promptBuilder,
                    dictationManager: dictationManager
                )
                .frame(height: 24)

                HStack {
                    HStack(spacing: 6) {
                        Circle()
                            .fill(speechEngine.isListening ? Color.green : Color.red)
                            .frame(width: 6, height: 6)
                        Text("Dictation")
                            .font(.system(size: 10))
                            .foregroundColor(Color.white.opacity(0.25))
                    }
                    Spacer()
                    Text("mouse btn = Enter")
                        .font(.system(size: 10))
                        .foregroundColor(Color.white.opacity(0.2))
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(Color.white.opacity(0.02))
        }
    }
}

// MARK: - Mode Toggle (shared across all content views)

struct ModeToggle: View {
    @ObservedObject var promptBuilder: PromptBuilder
    @ObservedObject var dictationManager: DictationManager

    private var modeIndex: Int {
        if dictationManager.isActive { return 2 }
        if promptBuilder.isActive { return 1 }
        return 0
    }

    var body: some View {
        NativeSegmentedToggle(
            items: ["Voice", "Builder", "Dictation"],
            selectedIndex: Binding(
                get: { modeIndex },
                set: { idx in
                    // Deactivate all first
                    promptBuilder.stop()
                    dictationManager.stop()
                    // Activate selected
                    switch idx {
                    case 1: promptBuilder.start()
                    case 2: dictationManager.start()
                    default: break
                    }
                }
            )
        )
    }
}
