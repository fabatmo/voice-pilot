import SwiftUI
import AppKit

// Native NSSegmentedControl wrapped for SwiftUI — works with tablets
struct NativeSegmentedToggle: NSViewRepresentable {
    var items: [String]
    @Binding var selectedIndex: Int

    func makeNSView(context: Context) -> NSSegmentedControl {
        let control = NSSegmentedControl(labels: items, trackingMode: .selectOne, target: context.coordinator, action: #selector(Coordinator.segmentChanged(_:)))
        control.segmentStyle = .rounded
        control.selectedSegment = selectedIndex
        for i in 0..<items.count {
            control.setWidth(0, forSegment: i) // Auto-size
        }
        return control
    }

    func updateNSView(_ nsView: NSSegmentedControl, context: Context) {
        nsView.selectedSegment = selectedIndex
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    class Coordinator: NSObject {
        var parent: NativeSegmentedToggle

        init(_ parent: NativeSegmentedToggle) {
            self.parent = parent
        }

        @objc func segmentChanged(_ sender: NSSegmentedControl) {
            parent.selectedIndex = sender.selectedSegment
        }
    }
}

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
