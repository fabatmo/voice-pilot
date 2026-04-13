import Foundation
import AppKit
import Combine

class DictationManager: ObservableObject {
    @Published var isActive = false
    @Published var accumulatedText = ""
    private var lastAppendedText = ""

    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?

    var onMouseButton: (() -> Void)?

    func start() {
        isActive = true
        accumulatedText = ""
        startMouseMonitor()
    }

    func stop() {
        isActive = false
        accumulatedText = ""
        stopMouseMonitor()
    }

    func appendUtterance(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        // Dedup — skip if same as last appended
        guard trimmed != lastAppendedText else { return }
        lastAppendedText = trimmed

        if accumulatedText.isEmpty {
            accumulatedText = trimmed
        } else {
            accumulatedText += " " + trimmed
        }
    }

    func clear() {
        accumulatedText = ""
        lastAppendedText = ""
    }

    // MARK: - Mouse Button Monitor (CGEvent tap)

    private func startMouseMonitor() {
        stopMouseMonitor()

        let eventMask: CGEventMask = (1 << CGEventType.otherMouseDown.rawValue)

        // Store self as unmanaged pointer for the C callback
        let selfPtr = Unmanaged.passRetained(self).toOpaque()

        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: eventMask,
            callback: { (proxy, type, event, refcon) -> Unmanaged<CGEvent>? in
                guard let refcon = refcon else { return Unmanaged.passUnretained(event) }
                let manager = Unmanaged<DictationManager>.fromOpaque(refcon).takeUnretainedValue()

                if type == .otherMouseDown && manager.isActive {
                    let button = event.getIntegerValueField(.mouseEventButtonNumber)
                    print("[Dictation] Mouse button \(button) consumed")
                    DispatchQueue.main.async {
                        manager.onMouseButton?()
                    }
                    // Consume the event — don't let terminal paste clipboard
                    return nil
                }

                return Unmanaged.passUnretained(event)
            },
            userInfo: selfPtr
        ) else {
            print("[Dictation] Failed to create event tap — check Accessibility permissions")
            // Fall back to NSEvent monitor
            startNSEventMonitor()
            Unmanaged<DictationManager>.fromOpaque(selfPtr).release()
            return
        }

        eventTap = tap
        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        runLoopSource = source
        CFRunLoopAddSource(CFRunLoopGetCurrent(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        print("[Dictation] CGEvent tap started")
    }

    private var nsEventMonitor: Any?

    private func startNSEventMonitor() {
        print("[Dictation] Falling back to NSEvent monitor")
        nsEventMonitor = NSEvent.addGlobalMonitorForEvents(matching: .otherMouseDown) { [weak self] event in
            guard let self = self, self.isActive else { return }
            print("[Dictation] NSEvent mouse button \(event.buttonNumber) pressed")
            DispatchQueue.main.async {
                self.onMouseButton?()
            }
        }
    }

    private func stopMouseMonitor() {
        if let tap = eventTap {
            CGEvent.tapEnable(tap: tap, enable: false)
            eventTap = nil
        }
        if let source = runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetCurrent(), source, .commonModes)
            runLoopSource = nil
        }
        if let monitor = nsEventMonitor {
            NSEvent.removeMonitor(monitor)
            nsEventMonitor = nil
        }
    }

    deinit {
        stopMouseMonitor()
    }
}
