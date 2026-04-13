import Foundation
import AppKit
import Combine

class DictationManager: ObservableObject {
    @Published var isActive = false
    @Published var accumulatedText = ""
    private var lastAppendedText = ""

    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var keyMonitor: Any?

    var onMouseButton: (() -> Void)?

    func start() {
        isActive = true
        accumulatedText = ""
        startMouseMonitor()
        startKeyMonitor()
    }

    func stop() {
        isActive = false
        accumulatedText = ""
        stopMouseMonitor()
        stopKeyMonitor()
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

        let eventMask: CGEventMask = (1 << CGEventType.otherMouseDown.rawValue) | (1 << CGEventType.keyDown.rawValue)

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
                    return nil
                }

                // Ctrl+Shift+S (keyCode 1 = S) as global submit trigger
                if type == .keyDown && manager.isActive {
                    let keyCode = event.getIntegerValueField(.keyboardEventKeycode)
                    let flags = event.flags
                    if keyCode == 1 && flags.contains(.maskControl) && flags.contains(.maskShift) {
                        print("[Dictation] Ctrl+Shift+S pressed — submit")
                        DispatchQueue.main.async {
                            manager.onMouseButton?()
                        }
                        return nil
                    }
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

    // MARK: - Global keyboard shortcut (Ctrl+Return)

    private func startKeyMonitor() {
        stopKeyMonitor()
        // Monitor Ctrl+Return globally as alternative submit trigger
        keyMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self = self, self.isActive else { return }
            // Ctrl+Return: keyCode 36 = Return, control flag
            if event.keyCode == 36 && event.modifierFlags.contains(.control) {
                print("[Dictation] Ctrl+Return pressed")
                DispatchQueue.main.async {
                    self.onMouseButton?()
                }
            }
        }
    }

    private func stopKeyMonitor() {
        if let monitor = keyMonitor {
            NSEvent.removeMonitor(monitor)
            keyMonitor = nil
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
        stopKeyMonitor()
    }
}
