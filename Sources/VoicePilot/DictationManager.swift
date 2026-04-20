import Foundation
import AppKit
import Combine

func vpLog(_ msg: String) {
    let line = "\(Date()): \(msg)\n"
    if let data = line.data(using: .utf8) {
        let path = "/tmp/voicepilot_debug.log"
        if let fh = FileHandle(forWritingAtPath: path) {
            fh.seekToEndOfFile(); fh.write(data); fh.closeFile()
        } else {
            FileManager.default.createFile(atPath: path, contents: data)
        }
    }
}

class DictationManager: ObservableObject {
    @Published var isActive = false
    @Published var accumulatedText = ""
    private var lastAppendedText = ""

    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var tapThread: Thread?
    private var tapRunLoop: CFRunLoop?
    private var selfPtr: UnsafeMutableRawPointer?
    private var keyMonitor: Any?
    private var retryCount = 0
    private let maxRetries = 10
    private var lastSubmitTime: Date = .distantPast
    private var _active: Int32 = 0

    var onMouseButton: (() -> Void)?

    func start() {
        isActive = true
        OSAtomicOr32Barrier(1, &_active)
        accumulatedText = ""
        lastAppendedText = ""

        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue(): true] as CFDictionary
        let trusted = AXIsProcessTrustedWithOptions(options)
        vpLog("[DM] start() called, AXTrusted=\(trusted)")

        startMouseMonitor()
        startKeyMonitor()
    }

    func stop() {
        isActive = false
        OSAtomicAnd32Barrier(0, &_active)
        accumulatedText = ""
        lastAppendedText = ""
        stopMouseMonitor()
        stopKeyMonitor()
    }

    func appendUtterance(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        vpLog("[DM] appendUtterance: '\(trimmed.prefix(50))'")
        guard !trimmed.isEmpty else { return }
        guard trimmed != lastAppendedText else {
            vpLog("[DM] Deduped — same as last")
            return
        }
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

    // MARK: - CGEvent Tap on dedicated thread

    private func startMouseMonitor() {
        stopMouseMonitor()
        retryCount = 0
        attemptEventTap()
    }

    private func attemptEventTap() {
        let mask: CGEventMask = (1 << CGEventType.otherMouseDown.rawValue) |
                                 (1 << CGEventType.keyDown.rawValue)

        let ptr = Unmanaged.passRetained(self).toOpaque()

        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: { (proxy, type, event, refcon) -> Unmanaged<CGEvent>? in
                guard let refcon = refcon else { return Unmanaged.passUnretained(event) }
                let manager = Unmanaged<DictationManager>.fromOpaque(refcon).takeUnretainedValue()

                // Re-enable if macOS disabled the tap
                if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
                    if let tap = manager.eventTap {
                        CGEvent.tapEnable(tap: tap, enable: true)
                    }
                    return Unmanaged.passUnretained(event)
                }

                guard manager._active != 0 else {
                    return Unmanaged.passUnretained(event)
                }

                // Mouse button — consume and submit (with debounce)
                if type == .otherMouseDown {
                    let button = event.getIntegerValueField(.mouseEventButtonNumber)
                    vpLog("[DM] Mouse button \(button), active=\(manager._active)")
                    let now = Date()
                    guard now.timeIntervalSince(manager.lastSubmitTime) > 0.5 else {
                        vpLog("[DM] Debounced")
                        return nil
                    }
                    manager.lastSubmitTime = now
                    vpLog("[DM] Calling onMouseButton")
                    DispatchQueue.main.async {
                        manager.onMouseButton?()
                    }
                    return nil // consume
                }

                // Ctrl+Shift+S submit trigger
                if type == .keyDown {
                    let keyCode = event.getIntegerValueField(.keyboardEventKeycode)
                    let flags = event.flags
                    if keyCode == 1 && flags.contains(.maskControl) && flags.contains(.maskShift) {
                        let now = Date()
                        guard now.timeIntervalSince(manager.lastSubmitTime) > 0.5 else {
                            return nil
                        }
                        manager.lastSubmitTime = now
                        DispatchQueue.main.async {
                            manager.onMouseButton?()
                        }
                        return nil
                    }
                }

                return Unmanaged.passUnretained(event)
            },
            userInfo: ptr
        ) else {
            Unmanaged<DictationManager>.fromOpaque(ptr).release()
            retryCount += 1
            if retryCount <= maxRetries {
                DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) { [weak self] in
                    guard let self = self, self.isActive else { return }
                    self.attemptEventTap()
                }
            }
            return
        }

        selfPtr = ptr
        eventTap = tap
        vpLog("[DM] Tap created, starting thread")

        // Dedicated thread with its own run loop — required for SwiftUI apps
        let thread = Thread {
            let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
            self.runLoopSource = source
            self.tapRunLoop = CFRunLoopGetCurrent()
            CFRunLoopAddSource(CFRunLoopGetCurrent(), source, .commonModes)
            CGEvent.tapEnable(tap: tap, enable: true)
            CFRunLoopRun()
        }
        thread.name = "VoicePilot-EventTap"
        thread.qualityOfService = .userInitiated
        tapThread = thread
        thread.start()
    }

    // MARK: - Ctrl+Return keyboard shortcut

    private func startKeyMonitor() {
        stopKeyMonitor()
        keyMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self = self, self.isActive else { return }
            if event.keyCode == 36 && event.modifierFlags.contains(.control) {
                let now = Date()
                guard now.timeIntervalSince(self.lastSubmitTime) > 0.5 else { return }
                self.lastSubmitTime = now
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
        if let rl = tapRunLoop {
            CFRunLoopStop(rl)
            tapRunLoop = nil
        }
        tapThread = nil
        runLoopSource = nil
        if let ptr = selfPtr {
            Unmanaged<DictationManager>.fromOpaque(ptr).release()
            selfPtr = nil
        }
    }

    deinit {
        stopMouseMonitor()
        stopKeyMonitor()
    }
}
