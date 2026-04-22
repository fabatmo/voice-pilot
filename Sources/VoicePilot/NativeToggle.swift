import SwiftUI
import AppKit

// Native NSButton wrapped for SwiftUI — works with tablets
struct NativeButton: NSViewRepresentable {
    var title: String
    var action: () -> Void

    func makeNSView(context: Context) -> NSButton {
        let button = NSButton(title: title, target: context.coordinator, action: #selector(Coordinator.clicked))
        button.bezelStyle = .rounded
        button.isBordered = true
        return button
    }

    func updateNSView(_ nsView: NSButton, context: Context) {
        nsView.title = title
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(action: action)
    }

    class Coordinator: NSObject {
        var action: () -> Void

        init(action: @escaping () -> Void) {
            self.action = action
        }

        @objc func clicked() {
            action()
        }
    }
}
