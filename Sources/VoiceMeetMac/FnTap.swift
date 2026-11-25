import AppKit
import Carbon.HIToolbox
import os

/// THE FN KEY IN EVERY APP: one event tap of the session for `flagsChanged` and `keyDown`. A
/// Carbon hot key cannot be fn alone. fn is a `flagsChanged` event with key code 63
/// (`kVK_Function`) whose flags gain or lose `.maskSecondaryFn`; the arrows and the function keys
/// carry that flag in their own events too, so the key code decides, not the flag alone.
///
/// The tap sees every key press of the Mac, so its callback does almost nothing: on its own thread
/// it reads the key code and what the dictation wants now (`Interest`, under a lock), and hands the
/// few events that matter to the main actor. It swallows one thing, Esc while a dictation is
/// locked, so that Esc does not reach the app in front. macOS gives the tap only to an app with
/// the Accessibility permission, and switches it off when it is slow (`tapDisabledByTimeout`) or
/// at a secure input (`tapDisabledByUserInput`); then it is switched on again.
final class FnTap: @unchecked Sendable {
    enum Event {
        case fn(down: Bool, at: Date)
        case escape
        case otherKey
    }

    /// What the dictation wants from the keys other than fn, set by the main actor.
    struct Interest: Equatable {
        /// fn is held for a dictation: another key down cancels it.
        var otherKeys = false
        /// A dictation goes: Esc matters.
        var escape = false
        /// A dictation is locked: Esc goes to it and to no app.
        var swallowsEscape = false
    }

    private let interest = OSAllocatedUnfairLock(initialState: Interest())
    private let handle: @MainActor (Event) -> Void
    private var port: CFMachPort?

    init(handle: @escaping @MainActor (Event) -> Void) {
        self.handle = handle
    }

    var isRunning: Bool { port != nil }

    func want(_ wanted: Interest) {
        interest.withLock { $0 = wanted }
    }

    /// Makes the tap and runs it on a thread of its own. False while macOS refuses it (no
    /// Accessibility): call again once the permission is given.
    @MainActor
    func start() -> Bool {
        if port != nil { return true }
        let events = (1 << CGEventType.flagsChanged.rawValue) | (1 << CGEventType.keyDown.rawValue)
        guard let port = CGEvent.tapCreate(
            tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap,
            eventsOfInterest: CGEventMask(events), callback: fnTapCallback,
            userInfo: Unmanaged.passUnretained(self).toOpaque())
        else { return false }
        self.port = port
        let source = CFMachPortCreateRunLoopSource(nil, port, 0)
        // its own thread: a busy main thread never holds up the Mac's typing
        let thread = Thread {
            CFRunLoopAddSource(CFRunLoopGetCurrent(), source, .commonModes)
            CGEvent.tapEnable(tap: port, enable: true)
            CFRunLoopRun()
        }
        thread.name = "fn tap"
        thread.qualityOfService = .userInteractive
        thread.start()
        return true
    }

    /// On the tap's thread, for every key of the Mac.
    fileprivate func hear(_ type: CGEventType, _ event: CGEvent) -> Unmanaged<CGEvent>? {
        let pass = Unmanaged.passUnretained(event)
        switch type {
        case .flagsChanged:
            let code = event.getIntegerValueField(.keyboardEventKeycode)
            // some keyboards' 🌐 key says 179
            if code == kVK_Function || code == 179 {
                send(.fn(down: event.flags.contains(.maskSecondaryFn), at: Date()))
            } else if interest.withLock({ $0.otherKeys }) {
                send(.otherKey)
            }
        case .keyDown:
            let wanted = interest.withLock { $0 }
            guard wanted.otherKeys || wanted.escape else { return pass }
            if event.getIntegerValueField(.keyboardEventKeycode) == kVK_Escape {
                send(.escape)
                if wanted.swallowsEscape { return nil }
            } else if wanted.otherKeys {
                send(.otherKey)
            }
        case .tapDisabledByTimeout, .tapDisabledByUserInput:
            if let port { CGEvent.tapEnable(tap: port, enable: true) }
        default:
            break
        }
        return pass
    }

    private func send(_ event: Event) {
        let handle = handle
        DispatchQueue.main.async { MainActor.assumeIsolated { handle(event) } }
    }
}

private let fnTapCallback: CGEventTapCallBack = { _, type, event, info in
    guard let info else { return Unmanaged.passUnretained(event) }
    return Unmanaged<FnTap>.fromOpaque(info).takeUnretainedValue().hear(type, event)
}
