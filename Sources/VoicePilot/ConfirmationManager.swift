import Foundation
import AppKit
import SwiftUI

class ConfirmationManager: ObservableObject {
    @Published var isShowingConfirmation = false
    @Published var originalText = ""
    @Published var refinedText = ""
    @Published var countdown = 3

    private var countdownTimer: Timer?
    private let terminalController: TerminalController

    init(terminalController: TerminalController) {
        self.terminalController = terminalController
    }

    func showBriefly(_ text: String) {
        DispatchQueue.main.async { [weak self] in
            self?.refinedText = text
            self?.isShowingConfirmation = true
            self?.countdown = 0
        }
        // Hide after 2 seconds
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) { [weak self] in
            self?.isShowingConfirmation = false
        }
    }

    func show(original: String, refined: String) {
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }

            self.originalText = original
            self.refinedText = refined
            self.countdown = 2
            self.isShowingConfirmation = true

            self.startCountdown()
            self.playSound()
        }
    }

    func confirmNow() {
        countdownTimer?.invalidate()
        send()
    }

    func cancel() {
        countdownTimer?.invalidate()
        DispatchQueue.main.async { [weak self] in
            self?.isShowingConfirmation = false
        }
    }

    private func startCountdown() {
        countdownTimer?.invalidate()
        countdownTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            guard let self = self else { return }
            DispatchQueue.main.async {
                self.countdown -= 1
                if self.countdown <= 0 {
                    self.countdownTimer?.invalidate()
                    self.send()
                }
            }
        }
    }

    private func send() {
        let text = refinedText
        DispatchQueue.main.async { [weak self] in
            self?.isShowingConfirmation = false
        }

        // Small delay to let terminal regain focus
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
            self?.terminalController.pasteAndEnter(text)
        }
    }

    private func playSound() {
        NSSound(named: "Tink")?.play()
    }
}
