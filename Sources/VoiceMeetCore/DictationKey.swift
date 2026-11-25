import Foundation

/// THE DICTATION KEY, as Wispr Flow has it (README, "Dictation"): hold fn (🌐) and talk, let go
/// and the text is written. Tap fn twice within `window` and the dictation stays on with no key
/// held: the next press of fn ends it and writes the text, Esc ends it and writes nothing. fn with
/// another key is that key's combination (fn-arrow, fn-delete): the dictation it started ends with
/// no sign.
///
/// | State   | Event                     | Next    | Act                                      |
/// | ------- | ------------------------- | ------- | ---------------------------------------- |
/// | idle    | down                      | pressed | `start`                                  |
/// | pressed | up after `hold` or longer | idle    | `finish`                                 |
/// | pressed | up before `hold`          | tapped  | `wait(until:)` the end of `window`       |
/// | pressed | another key down          | idle    | `cancel(quietly: true)`                  |
/// | tapped  | down before `window` ends | locked  | `lock`                                   |
/// | tapped  | `window` ends             | idle    | `cancel(quietly: true)`                  |
/// | locked  | up                        | locked  | `nothing`                                |
/// | locked  | down                      | idle    | `finish`; this press's release does nothing |
/// | locked  | Esc                       | idle    | `cancel(quietly: false)`                 |
/// | any     | the listening ended       | idle    | (`ended()`)                              |
///
/// The ⌥⇧D shortcut (`Press.shortcut`) is the same machine with one difference, as Hex has it: a
/// tap keeps the dictation on at once (pressed, up before `hold`: locked), with no second press.
///
/// The struct cannot wait: `wait(until:)` asks its owner (`Dictation`) to call `windowEnded(at:)`
/// at that time.
public struct DictationKey: Equatable, Sendable {
    public enum Act: Equatable, Sendable {
        case nothing
        /// Start listening and show the pill.
        case start
        /// Keep listening; call `windowEnded(at:)` at this time.
        case wait(until: Date)
        /// It stays on with no key held: the pill shows the lock.
        case lock
        /// Write the text.
        case finish
        /// Throw the sound away. `quietly`: with no line in the panel (fn was a modifier, or one
        /// tap of fn alone).
        case cancel(quietly: Bool)
    }

    /// Which key made the press.
    public enum Press: Equatable, Sendable {
        case fn
        /// ⌥⇧D, the panel's Dictate button, and the control socket's `dictation.start`.
        case shortcut
    }

    public enum State: Equatable, Sendable {
        case idle
        case pressed(since: Date)
        case tapped(until: Date)
        case locked
    }

    /// A press this long or longer is a hold.
    public static let hold: TimeInterval = 0.35
    /// From the first press: a second press within this makes a double tap.
    public static let window: TimeInterval = 0.5

    public private(set) var state = State.idle
    /// The key of the press that started the dictation.
    public private(set) var press = Press.fn
    private var isDown = false
    /// The press that ended a dictation (or another key spoiled): its release does nothing.
    private var ignoresRelease = false

    public init() {}

    public var isLocked: Bool { state == .locked }
    /// Whether another key down matters now: fn is held for a dictation it started.
    public var wantsOtherKeys: Bool {
        if case .pressed = state { return press == .fn }
        return false
    }

    public mutating func down(_ key: Press = .fn, at time: Date) -> Act {
        guard !isDown else { return .nothing }
        isDown = true
        ignoresRelease = false
        switch state {
        case .idle:
            press = key
            state = .pressed(since: time)
            return .start
        case .tapped(let until):
            guard time < until else {
                // the window's end was not seen yet: this is a new hold of the listening that goes
                state = .pressed(since: time)
                return .nothing
            }
            state = .locked
            return .lock
        case .locked:
            state = .idle
            ignoresRelease = true
            return .finish
        case .pressed:
            return .nothing
        }
    }

    public mutating func up(at time: Date) -> Act {
        guard isDown else { return .nothing }
        isDown = false
        guard !ignoresRelease else {
            ignoresRelease = false
            return .nothing
        }
        guard case .pressed(let since) = state else { return .nothing }
        if time.timeIntervalSince(since) >= Self.hold {
            state = .idle
            return .finish
        }
        if press == .shortcut {
            state = .locked
            return .lock
        }
        let until = since.addingTimeInterval(Self.window)
        state = .tapped(until: until)
        return .wait(until: until)
    }

    /// The owner's timer for `wait(until:)` fired.
    public mutating func windowEnded(at time: Date) -> Act {
        guard case .tapped(let until) = state, time >= until else { return .nothing }
        state = .idle
        return .cancel(quietly: true)
    }

    /// A key other than fn and Esc went down (or another modifier changed).
    public mutating func otherKey() -> Act {
        guard wantsOtherKeys else { return .nothing }
        state = .idle
        ignoresRelease = true
        return .cancel(quietly: true)
    }

    public mutating func escape() -> Act {
        switch state {
        case .locked, .tapped:
            state = .idle
            return .cancel(quietly: false)
        case .pressed:
            // Esc with fn held is fn-Esc, as any other key; ⌥⇧D held and Esc throws it away
            guard press == .shortcut else { return otherKey() }
            state = .idle
            ignoresRelease = true
            return .cancel(quietly: false)
        case .idle:
            return .nothing
        }
    }

    /// The listening ended for another reason (it failed, or the input bar took it).
    public mutating func ended() {
        state = .idle
        ignoresRelease = isDown
    }
}

/// WHAT THE FN TAP DOES WITH A KEY (`FnTap`), on the tap's own thread: pure, so that a test runs it.
///
/// The tap knows whether fn is down from the events themselves, not from the main actor: a key
/// that goes down a moment after fn, before the main actor heard fn, is still fn's combination
/// (fn-arrow), and goes to the dictation in order after fn. The main actor sets what a dictation
/// wants (`escape`, `swallowsEscape`); the rest follows from fn.
///
/// `wantsKeyDowns` says when key presses matter at all: while fn is down or a dictation goes. The
/// tap for key presses is on only then, so that the Mac's typing passes no tap of this app the rest
/// of the time.
public struct KeyTapRule: Equatable, Sendable {
    public enum Heard: Equatable, Sendable {
        case fn(down: Bool)
        case escape
        case otherKey
    }

    /// fn (63, `kVK_Function`), and the 🌐 key of some keyboards (179).
    public static let fnCodes: Set<Int64> = [63, 179]
    public static let escapeCode: Int64 = 53

    /// fn is down, as the tap's own events say.
    public private(set) var fnDown = false
    /// A dictation goes: Esc matters.
    public var escape = false
    /// A dictation is locked: Esc goes to it and to no app.
    public var swallowsEscape = false

    public init() {}

    public var wantsKeyDowns: Bool { fnDown || escape }

    /// A modifier changed: fn itself, or another one, which is fn's combination while fn is down.
    public mutating func flagsChanged(code: Int64, fn: Bool) -> Heard? {
        if Self.fnCodes.contains(code) {
            fnDown = fn
            return .fn(down: fn)
        }
        return fnDown ? .otherKey : nil
    }

    /// A key went down. `swallow`: the key goes to no app.
    public mutating func keyDown(code: Int64) -> (heard: Heard?, swallow: Bool) {
        if code == Self.escapeCode, escape { return (.escape, swallowsEscape) }
        return (fnDown ? .otherKey : nil, false)
    }

    /// macOS switched the tap off a while (it was slow, or a secure input took the keys) and on
    /// again: fn may have changed meanwhile. `fn` is the keyboard's state now.
    public mutating func resumed(fn: Bool) -> Heard? {
        guard fn != fnDown else { return nil }
        fnDown = fn
        return .fn(down: fn)
    }
}
