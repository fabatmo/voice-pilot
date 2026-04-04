import SwiftUI
import AppKit
import Combine

class FloatingPanelController: NSObject, ObservableObject, NSWindowDelegate {
    var window: NSWindow?
    private var speechEngine: SpeechEngine
    private var confirmationManager: ConfirmationManager
    private var promptBuilder: PromptBuilder
    private var terminalController: TerminalController
    @Published var isMini = true

    init(speechEngine: SpeechEngine, confirmationManager: ConfirmationManager, promptBuilder: PromptBuilder, terminalController: TerminalController) {
        self.speechEngine = speechEngine
        self.confirmationManager = confirmationManager
        self.promptBuilder = promptBuilder
        self.terminalController = terminalController
        super.init()
        showWindow()
    }

    func showWindow() {
        let view = MainView(
            speechEngine: speechEngine,
            confirmationManager: confirmationManager,
            promptBuilder: promptBuilder,
            terminalController: terminalController,
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
    @ObservedObject var panelController: FloatingPanelController

    let bg = Color(nsColor: NSColor(red: 0.11, green: 0.11, blue: 0.12, alpha: 1.0))

    var body: some View {
        Group {
            if panelController.isMini {
                MiniContent(
                    speechEngine: speechEngine,
                    confirmationManager: confirmationManager
                )
            } else if promptBuilder.isActive {
                BuilderContent(
                    speechEngine: speechEngine,
                    promptBuilder: promptBuilder
                )
            } else {
                FullContent(
                    speechEngine: speechEngine,
                    confirmationManager: confirmationManager,
                    promptBuilder: promptBuilder,
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
    @ObservedObject var confirmationManager: ConfirmationManager

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
            HStack(spacing: 12) {
                HStack(spacing: 6) {
                    Circle()
                        .fill(speechEngine.isListening ? Color.green : Color.red)
                        .frame(width: 6, height: 6)
                    Text(speechEngine.isListening ? "Listening" : "Paused")
                        .font(.system(size: 11))
                        .foregroundColor(Color.white.opacity(0.3))
                }

                Spacer()

                Button(action: { terminalController.terminalOnly.toggle() }) {
                    Text(terminalController.terminalOnly ? "Terminal" : "Any App")
                        .font(.system(size: 10))
                        .foregroundColor(Color.white.opacity(0.4))
                }
                .buttonStyle(.plain)

                Button(action: { promptBuilder.start() }) {
                    Image(systemName: "wand.and.stars")
                        .font(.system(size: 11))
                        .foregroundColor(Color.white.opacity(0.4))
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(Color.white.opacity(0.03))
        }
    }
}

// MARK: - Builder Content

struct BuilderContent: View {
    @ObservedObject var speechEngine: SpeechEngine
    @ObservedObject var promptBuilder: PromptBuilder

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
                .frame(width: 120)
                .controlSize(.small)

                Spacer()

                Text("\"send\" \u{2022} \"cancel\" \u{2022} \"start over\"")
                    .font(.system(size: 10))
                    .foregroundColor(Color.white.opacity(0.25))
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(Color.white.opacity(0.03))
        }
    }
}
