import AppKit
import Carbon.HIToolbox
@preconcurrency import CoreFoundation
import VoiceMeetCore
import os

/// THE FN KEY IN EVERY APP: event taps of the session. A Carbon hot key cannot be fn alone. fn is
/// a `flagsChanged` event with key code 63 (`kVK_Function`) whose flags gain or lose
/// `.maskSecondaryFn`; the arrows and the function keys carry that flag in their own events too,
/// so the key code decides, not the flag alone.
///
/// Two taps, so that the Mac's typing costs nothing while no dictation goes:
///
/// - one for `flagsChanged` alone, always on. A modifier is pressed rarely. It is an active tap,
///   not a listening one, so that its callback has run before the next event passes: it switches
///   on the other tap at fn down, before the key that may follow (fn-arrow).
/// - one for `keyDown`, on only while fn is down or a dictation goes (`KeyTapRule.wantsKeyDowns`).
///   It swallows one thing, Esc while a dictation is locked, so that Esc reaches no app.
///
/// Each callback does almost nothing: on the taps' thread it runs `KeyTapRule` under a lock and
/// hands the few events that matter to the main actor, in their order. The tap knows fn's state
/// from its own events, so a key a moment after fn is fn's combination even before the main actor
/// heard fn. macOS gives the taps only to an app with the Accessibility permission, and switches a
/// tap off when it is slow (`tapDisabledByTimeout`) or at a secure input (`tapDisabledByUserInput`);
/// then it is switched on again, and fn's state is read again: its release may have been missed.
final class FnTap: @unchecked Sendable {
    enum Event {
        case fn(down: Bool, at: Date)
        case escape
        case otherKey
    }

    /// What the dictation wants from the keys, set by the main actor.
    struct Interest: Equatable {
        /// A dictation goes: Esc matters.
        var escape = false
        /// A dictation is locked: Esc goes to it and to no app.
        var swallowsEscape = false
    }

    private struct Taps {
        var rule = KeyTapRule()
        var flags: CFMachPort?
        var keys: CFMachPort?
        /// Whether the key tap is on now.
        var keysOn = false

        /// The key tap is on exactly while the rule wants key presses.
        mutating func fit() {
            guard let keys, rule.wantsKeyDowns != keysOn else { return }
            keysOn = rule.wantsKeyDowns
            CGEvent.tapEnable(tap: keys, enable: keysOn)
        }
    }

    private let taps = OSAllocatedUnfairLock(initialState: Taps())
    private let handle: @MainActor (Event) -> Void

    init(handle: @escaping @MainActor (Event) -> Void) {
        self.handle = handle
    }

    var isRunning: Bool { taps.withLock { $0.flags != nil } }

    func want(_ wanted: Interest) {
        taps.withLock { taps in
            taps.rule.escape = wanted.escape
            taps.rule.swallowsEscape = wanted.swallowsEscape
            taps.fit()
        }
    }

    /// Makes the taps and runs them on a thread of their own. False while macOS refuses them (no
    /// Accessibility): call again once the permission is given.
    @MainActor
    func start() -> Bool {
        if isRunning { return true }
        let info = Unmanaged.passUnretained(self).toOpaque()
        guard let flags = CGEvent.tapCreate(
            tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap,
            eventsOfInterest: CGEventMask(1 << CGEventType.flagsChanged.rawValue), callback: fnFlagsCallback, userInfo: info)
        else { return false }
        guard let keys = CGEvent.tapCreate(
            tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap,
            eventsOfInterest: CGEventMask(1 << CGEventType.keyDown.rawValue), callback: fnKeysCallback, userInfo: info)
        else {
            CFMachPortInvalidate(flags)
            return false
        }
        // off until fn goes down or a dictation starts
        CGEvent.tapEnable(tap: keys, enable: false)
        taps.withLock { taps in
            taps.flags = flags
            taps.keys = keys
            taps.keysOn = false
            taps.fit()
        }
        let sources = [flags, keys].map { CFMachPortCreateRunLoopSource(nil, $0, 0) }
        // their own thread: a busy main thread never holds up the Mac's typing
        let thread = Thread {
            for source in sources { CFRunLoopAddSource(CFRunLoopGetCurrent(), source, .commonModes) }
            CGEvent.tapEnable(tap: flags, enable: true)
            CFRunLoopRun()
        }
        thread.name = "fn tap"
        thread.qualityOfService = .userInteractive
        thread.start()
        return true
    }

    /// On the taps' thread, for each modifier change, and for each key press while the key tap is on.
    fileprivate func hear(_ type: CGEventType, _ event: CGEvent, isKeyTap: Bool) -> Unmanaged<CGEvent>? {
        let pass = Unmanaged.passUnretained(event)
        let code = { event.getIntegerValueField(.keyboardEventKeycode) }
        let (heard, swallow): (KeyTapRule.Heard?, Bool) = taps.withLock { taps in
            defer { taps.fit() }
            switch type {
            case .flagsChanged:
                return (taps.rule.flagsChanged(code: code(), fn: event.flags.contains(.maskSecondaryFn)), false)
            case .keyDown:
                return taps.rule.keyDown(code: code())
            case .tapDisabledByTimeout, .tapDisabledByUserInput:
                if isKeyTap {
                    if let keys = taps.keys, taps.keysOn { CGEvent.tapEnable(tap: keys, enable: true) }
                    return (nil, false)
                }
                if let flags = taps.flags { CGEvent.tapEnable(tap: flags, enable: true) }
                // fn may have gone up while the tap was off
                return (taps.rule.resumed(fn: CGEventSource.flagsState(.combinedSessionState).contains(.maskSecondaryFn)), false)
            default:
                return (nil, false)
            }
        }
        if let heard { send(heard) }
        return swallow ? nil : pass
    }

    private func send(_ heard: KeyTapRule.Heard) {
        let event: Event
        switch heard {
        case .fn(let down): event = .fn(down: down, at: Date())
        case .escape: event = .escape
        case .otherKey: event = .otherKey
        }
        let handle = handle
        DispatchQueue.main.async { MainActor.assumeIsolated { handle(event) } }
    }
}

private func fnTapTarget(_ info: UnsafeMutableRawPointer) -> FnTap { Unmanaged<FnTap>.fromOpaque(info).takeUnretainedValue() }

private let fnFlagsCallback: CGEventTapCallBack = { _, type, event, info in
    guard let info else { return Unmanaged.passUnretained(event) }
    return fnTapTarget(info).hear(type, event, isKeyTap: false)
}

private let fnKeysCallback: CGEventTapCallBack = { _, type, event, info in
    guard let info else { return Unmanaged.passUnretained(event) }
    return fnTapTarget(info).hear(type, event, isKeyTap: true)
}
