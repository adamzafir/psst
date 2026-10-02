import AppKit
import ApplicationServices

/// An active event filter consumes the entire chord (down, repeats and up)
/// before it reaches web pages, editors, or ordinary application shortcuts.
@MainActor
final class HotKey {
    var onPress: (() -> Void)?
    var onRelease: (() -> Void)?
    var onEscape: (() -> Void)?
    private var installID = UUID()
    private var tap: CFMachPort?
    private var runLoop: CFRunLoop?
    private var context: TapContext?
    var isInstalled: Bool { tap.map { CGEvent.tapIsEnabled(tap: $0) } ?? false }
    static var hasPermission: Bool { AXIsProcessTrusted() }

    static func requestPermission() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
    }

    func install() throws {
        uninstall()
        guard Self.hasPermission else {
            throw PsstError.message("Enable Psst in System Settings → Privacy & Security → Accessibility so Option–Space won’t type or scroll in other apps.")
        }
        let id = installID
        let context = TapContext { [weak self] action in
            DispatchQueue.main.async {
                guard let self, self.installID == id else { return }
                switch action {
                case .press: self.onPress?()
                case .release: self.onRelease?()
                case .cancel: self.onEscape?()
                }
            }
        }
        let mask = (1 << CGEventType.keyDown.rawValue) | (1 << CGEventType.keyUp.rawValue) | (1 << CGEventType.flagsChanged.rawValue)
        guard let tap = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap,
                                         options: .defaultTap, eventsOfInterest: CGEventMask(mask),
                                         callback: { _, type, event, info in
            guard let info else { return Unmanaged.passUnretained(event) }
            let context = Unmanaged<TapContext>.fromOpaque(info).takeUnretainedValue()
            return context.filter(type: type, event: event) ? nil : Unmanaged.passUnretained(event)
        }, userInfo: Unmanaged.passUnretained(context).toOpaque()) else {
            throw PsstError.message("Psst couldn’t intercept the shortcut. Enable Accessibility for Psst, then choose Retry Shortcut.")
        }
        context.tap = tap
        self.context = context
        self.tap = tap
        let ready = DispatchSemaphore(value: 0)
        // Keep the callback off the UI/audio-startup thread so a slow microphone
        // or model cannot time out the event tap and leak keystrokes to other apps.
        let thread = Thread {
            let tap = context.tap!
            let loop = CFRunLoopGetCurrent()!
            let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)!
            context.loop = loop
            CFRunLoopAddSource(loop, source, .commonModes)
            CGEvent.tapEnable(tap: tap, enable: true)
            ready.signal()
            CFRunLoopRun()
            CFRunLoopRemoveSource(loop, source, .commonModes)
            // Capture context until the final callback is completely finished.
            withExtendedLifetime(context) {}
        }
        thread.name = "Psst shortcut filter"
        thread.qualityOfService = .userInteractive
        thread.start()
        ready.wait()
        runLoop = context.loop
    }

    @discardableResult
    func setEscapeEnabled(_ enabled: Bool) -> Bool {
        context?.setEscapeEnabled(enabled)
        return isInstalled
    }

    func uninstall() {
        installID = UUID()
        if let tap { CGEvent.tapEnable(tap: tap, enable: false); CFMachPortInvalidate(tap) }
        if let runLoop { CFRunLoopStop(runLoop) }
        tap = nil; runLoop = nil; context = nil
    }
}

private final class TapContext: @unchecked Sendable {
    private let lock = NSLock()
    private var routing = ShortcutRouting()
    private let notify: @Sendable (ShortcutRouting.Action) -> Void
    var tap: CFMachPort?
    // Written before the startup semaphore is signaled; read only after waiting.
    var loop: CFRunLoop?

    init(notify: @escaping @Sendable (ShortcutRouting.Action) -> Void) { self.notify = notify }

    func setEscapeEnabled(_ enabled: Bool) {
        lock.lock(); defer { lock.unlock() }
        routing.escapeEnabled = enabled
    }

    func filter(type: CGEventType, event: CGEvent) -> Bool {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            lock.lock(); routing = ShortcutRouting(); lock.unlock()
            notify(.cancel)
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            return false
        }
        let key = event.getIntegerValueField(.keyboardEventKeycode)
        let input: ShortcutRouting.Input
        if type == .flagsChanged, !event.flags.contains(.maskAlternate) {
            input = .optionReleased
        } else if key == 49, type == .keyDown {
            let modifiers = event.flags.intersection([.maskAlternate, .maskCommand, .maskControl, .maskShift])
            input = .spaceDown(optionOnly: modifiers == .maskAlternate, isRepeat: event.getIntegerValueField(.keyboardEventAutorepeat) != 0)
        } else if key == 49, type == .keyUp { input = .spaceUp }
        else if key == 53, type == .keyDown { input = .escapeDown }
        else if key == 53, type == .keyUp { input = .escapeUp }
        else { input = .other }
        lock.lock()
        let decision = routing.handle(input)
        lock.unlock()
        if let action = decision.action { notify(action) }
        return decision.consume
    }
}
