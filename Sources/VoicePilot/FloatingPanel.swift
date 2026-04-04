import SwiftUI
import AppKit
import Combine

class FloatingPanelController: ObservableObject {
    private var window: NSPanel?
    private var speechEngine: SpeechEngine
    private var confirmationManager: ConfirmationManager
    @Published var isMini = true

    init(speechEngine: SpeechEngine, confirmationManager: ConfirmationManager) {
        self.speechEngine = speechEngine
        self.confirmationManager = confirmationManager
        showPanel()
    }

    func showPanel() {
        let view = WidgetView(
            speechEngine: speechEngine,
            confirmationManager: confirmationManager,
            panelController: self
        )
        let hostingView = NSHostingView(rootView: view)

        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 180, height: 32),
            styleMask: [.nonactivatingPanel, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        panel.isFloatingPanel = true
        panel.level = .statusBar
        panel.titlebarAppearsTransparent = true
        panel.titleVisibility = .hidden
        panel.isMovableByWindowBackground = true
        panel.contentView = hostingView
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]

        // Position just below menu bar, right side
        if let screen = NSScreen.main {
            let screenFrame = screen.visibleFrame
            let x = screenFrame.maxX - 195
            let y = screenFrame.maxY - 8
            panel.setFrameOrigin(NSPoint(x: x, y: y))
        }

        panel.orderFrontRegardless()
        self.window = panel
    }

    func toggle() {
        isMini.toggle()
        // Resize window
        if let window = window, let screen = NSScreen.main {
            let origin = window.frame.origin
            let newWidth: CGFloat = isMini ? 180 : 340
            let newHeight: CGFloat = isMini ? 32 : 180
            window.setFrame(NSRect(x: origin.x, y: origin.y, width: newWidth, height: newHeight), display: true, animate: true)
        }
    }
}

struct WidgetView: View {
    @ObservedObject var speechEngine: SpeechEngine
    @ObservedObject var confirmationManager: ConfirmationManager
    @ObservedObject var panelController: FloatingPanelController

    var body: some View {
        if panelController.isMini {
            MiniView(
                speechEngine: speechEngine,
                confirmationManager: confirmationManager,
                onTap: { panelController.toggle() }
            )
        } else {
            ExpandedView(
                speechEngine: speechEngine,
                confirmationManager: confirmationManager,
                onTap: { panelController.toggle() }
            )
        }
    }
}

// MARK: - Mini View (tiny pill)

struct MiniView: View {
    @ObservedObject var speechEngine: SpeechEngine
    @ObservedObject var confirmationManager: ConfirmationManager
    var onTap: () -> Void

    var body: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(speechEngine.isListening ? Color.green : Color.red)
                .frame(width: 7, height: 7)

            if !speechEngine.currentTranscript.isEmpty {
                Text(speechEngine.currentTranscript)
                    .font(.system(size: 11, design: .monospaced))
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .foregroundColor(.primary)
            } else {
                Text(speechEngine.isListening ? "Listening..." : "Paused")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundColor(.secondary)
            }

            Spacer(minLength: 0)

            if confirmationManager.isShowingConfirmation {
                Text("Sent")
                    .font(.system(size: 9, weight: .bold, design: .monospaced))
                    .foregroundColor(.green)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .frame(width: 180, height: 28)
        .background(.ultraThinMaterial)
        .cornerRadius(14)
        .onTapGesture { onTap() }
        .animation(.easeInOut(duration: 0.2), value: speechEngine.currentTranscript.isEmpty)
    }
}

// MARK: - Expanded View (full panel)

struct ExpandedView: View {
    @ObservedObject var speechEngine: SpeechEngine
    @ObservedObject var confirmationManager: ConfirmationManager
    var onTap: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            // Header — tap to minimize
            HStack {
                Circle()
                    .fill(speechEngine.isListening ? Color.green : Color.red)
                    .frame(width: 8, height: 8)
                Text("Voice Pilot")
                    .font(.system(size: 12, weight: .semibold, design: .monospaced))
                Spacer()
                Image(systemName: "minus.circle.fill")
                    .foregroundColor(.secondary)
                    .font(.system(size: 12))
            }
            .onTapGesture { onTap() }

            Divider()

            // Live transcript
            if !speechEngine.currentTranscript.isEmpty {
                HStack(alignment: .top, spacing: 6) {
                    Image(systemName: "waveform")
                        .foregroundColor(.blue)
                        .font(.system(size: 10))
                    Text(speechEngine.currentTranscript)
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundColor(.primary)
                        .lineLimit(3)
                }
                .padding(6)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.blue.opacity(0.08))
                .cornerRadius(6)
            } else {
                Text("Speak a command or prompt...")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundColor(.secondary)
                    .padding(6)
            }

            // Confirmation
            if confirmationManager.isShowingConfirmation {
                Text(confirmationManager.refinedText)
                    .font(.system(size: 11, design: .monospaced))
                    .padding(6)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.green.opacity(0.1))
                    .cornerRadius(6)
            }

            Spacer(minLength: 0)

            // Command hints
            HStack(spacing: 8) {
                commandHint("enter")
                commandHint("yes/no")
                commandHint("cancel")
            }
            .font(.system(size: 9, design: .monospaced))
            .foregroundColor(.secondary)
        }
        .padding(10)
        .frame(width: 340, height: 180)
        .background(.ultraThinMaterial)
        .cornerRadius(10)
    }

    private func commandHint(_ text: String) -> some View {
        Text(text)
            .padding(.horizontal, 5)
            .padding(.vertical, 2)
            .background(Color.secondary.opacity(0.15))
            .cornerRadius(3)
    }
}
