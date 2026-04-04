import SwiftUI
import AppKit
import Combine

class FloatingPanelController {
    private var window: NSPanel?
    private var speechEngine: SpeechEngine
    private var confirmationManager: ConfirmationManager

    init(speechEngine: SpeechEngine, confirmationManager: ConfirmationManager) {
        self.speechEngine = speechEngine
        self.confirmationManager = confirmationManager
        showPanel()
    }

    func showPanel() {
        let view = FloatingPanelView(
            speechEngine: speechEngine,
            confirmationManager: confirmationManager
        )
        let hostingView = NSHostingView(rootView: view)

        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 380, height: 200),
            styleMask: [.nonactivatingPanel, .fullSizeContentView, .resizable],
            backing: .buffered,
            defer: false
        )
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.titlebarAppearsTransparent = true
        panel.titleVisibility = .hidden
        panel.isMovableByWindowBackground = true
        panel.contentView = hostingView
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]

        // Position bottom-right of screen
        if let screen = NSScreen.main {
            let screenFrame = screen.visibleFrame
            let x = screenFrame.maxX - 400
            let y = screenFrame.minY + 20
            panel.setFrameOrigin(NSPoint(x: x, y: y))
        }

        panel.orderFrontRegardless()
        self.window = panel
    }
}

struct FloatingPanelView: View {
    @ObservedObject var speechEngine: SpeechEngine
    @ObservedObject var confirmationManager: ConfirmationManager

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            // Header
            HStack {
                Circle()
                    .fill(speechEngine.isListening ? Color.green : Color.red)
                    .frame(width: 10, height: 10)
                Text("Voice Pilot")
                    .font(.system(.headline, design: .monospaced))
                Spacer()
                Text(speechEngine.isListening ? "Listening" : "Paused")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            Divider()

            // Live transcript
            if !speechEngine.currentTranscript.isEmpty {
                HStack(alignment: .top) {
                    Image(systemName: "waveform")
                        .foregroundColor(.blue)
                        .font(.caption)
                    Text(speechEngine.currentTranscript)
                        .font(.system(.body, design: .monospaced))
                        .foregroundColor(.primary)
                        .lineLimit(3)
                }
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.blue.opacity(0.08))
                .cornerRadius(8)
            } else {
                HStack {
                    Image(systemName: "mic.fill")
                        .foregroundColor(.secondary)
                    Text("Speak a command or prompt...")
                        .font(.system(.body, design: .monospaced))
                        .foregroundColor(.secondary)
                }
                .padding(8)
            }

            // Confirmation area
            if confirmationManager.isShowingConfirmation {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text("Sending in \(confirmationManager.countdown)s")
                            .font(.system(.caption, design: .monospaced))
                            .foregroundColor(confirmationManager.countdown <= 1 ? .red : .orange)
                        Spacer()
                        Button("Cancel") { confirmationManager.cancel() }
                            .font(.caption)
                        Button("Send") { confirmationManager.confirmNow() }
                            .font(.caption)
                            .buttonStyle(.borderedProminent)
                            .controlSize(.small)
                    }

                    Text(confirmationManager.refinedText)
                        .font(.system(.caption, design: .monospaced))
                        .padding(6)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color.green.opacity(0.1))
                        .cornerRadius(6)
                }
                .padding(8)
                .background(Color.orange.opacity(0.05))
                .cornerRadius(8)
            }

            Spacer(minLength: 0)

            // Commands hint
            HStack(spacing: 12) {
                commandHint("enter")
                commandHint("yes/no")
                commandHint("cancel")
                commandHint("scroll")
            }
            .font(.system(.caption2, design: .monospaced))
            .foregroundColor(.secondary)
        }
        .padding(14)
        .frame(minWidth: 380, minHeight: 160)
        .background(.ultraThinMaterial)
        .cornerRadius(12)
    }

    private func commandHint(_ text: String) -> some View {
        Text(text)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(Color.secondary.opacity(0.15))
            .cornerRadius(4)
    }
}
