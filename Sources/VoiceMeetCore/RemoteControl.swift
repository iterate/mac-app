import Foundation

/// CONTROL: somebody drives this Mac (README, "Control: somebody drives this Mac"). The rules
/// here are pure, and tested on their own; the app posts what they say with `CGEvent`
/// (`RemoteControl.swift` in the app), a thin layer.
///
/// - A caller starts a session for one display; its events come in batches, with coordinates
///   0–1 on that display (`ControlDisplay.point`).
/// - **The owner wins**: a local move, click or key pauses every session for `ownerPause`, and
///   what a session holds down (a button, a key) is let go at once.
/// - A session ends after `idleLimit` with no call from its caller.
/// - A key or text typed while the focus is in a password (`SecretKeys`) is withheld.

/// A mouse button, numbered as a browser's `MouseEvent.button` is.
public enum ControlButton: Int, CaseIterable, Sendable {
    case left = 0
    case middle = 1
    case right = 2
}

/// The modifier keys an event is pressed with.
public struct ControlModifiers: OptionSet, Hashable, Sendable {
    public let rawValue: Int
    public init(rawValue: Int) { self.rawValue = rawValue }

    public static let shift = ControlModifiers(rawValue: 1)
    public static let control = ControlModifiers(rawValue: 2)
    public static let option = ControlModifiers(rawValue: 4)
    public static let command = ControlModifiers(rawValue: 8)

    /// The names a caller may give, a browser's (`shiftKey`, `ctrlKey`, `altKey`, `metaKey`) and macOS's.
    static let names: [String: ControlModifiers] = [
        "shift": .shift, "ctrl": .control, "control": .control, "alt": .option, "option": .option,
        "meta": .command, "command": .command, "cmd": .command,
    ]

    /// A list of names (`["meta", "shift"]`); nil and an empty list are none.
    static func parse(_ value: Any?) throws -> ControlModifiers {
        guard let value, !(value is NSNull) else { return [] }
        guard let list = value as? [Any] else { throw ControlProblem("mods is a list such as [\"meta\", \"shift\"]") }
        var mods: ControlModifiers = []
        for item in list {
            guard let name = item as? String, let mod = names[name.lowercased()] else {
                throw ControlProblem("mods knows shift, ctrl, alt and meta, not \(item)")
            }
            mods.insert(mod)
        }
        return mods
    }
}

/// Why one event of a batch was skipped, in words for the caller.
public struct ControlProblem: Error, Equatable, Sendable {
    public let words: String
    public init(_ words: String) { self.words = words }
}

/// A browser's `KeyboardEvent.code` (a physical key, as on a US keyboard) to macOS's virtual key
/// code (`kVK_…` of Carbon's `Events.h`), which is also a physical key: the same position on every
/// layout. Text in the owner's layout is `text`, not keys.
public enum ControlKeys {
    public static let codes: [String: UInt16] = {
        var codes: [String: UInt16] = [
            "KeyA": 0x00, "KeyS": 0x01, "KeyD": 0x02, "KeyF": 0x03, "KeyH": 0x04, "KeyG": 0x05, "KeyZ": 0x06, "KeyX": 0x07,
            "KeyC": 0x08, "KeyV": 0x09, "IntlBackslash": 0x0A, "KeyB": 0x0B, "KeyQ": 0x0C, "KeyW": 0x0D, "KeyE": 0x0E,
            "KeyR": 0x0F, "KeyY": 0x10, "KeyT": 0x11, "Digit1": 0x12, "Digit2": 0x13, "Digit3": 0x14, "Digit4": 0x15,
            "Digit6": 0x16, "Digit5": 0x17, "Equal": 0x18, "Digit9": 0x19, "Digit7": 0x1A, "Minus": 0x1B, "Digit8": 0x1C,
            "Digit0": 0x1D, "BracketRight": 0x1E, "KeyO": 0x1F, "KeyU": 0x20, "BracketLeft": 0x21, "KeyI": 0x22,
            "KeyP": 0x23, "Enter": 0x24, "KeyL": 0x25, "KeyJ": 0x26, "Quote": 0x27, "KeyK": 0x28, "Semicolon": 0x29,
            "Backslash": 0x2A, "Comma": 0x2B, "Slash": 0x2C, "KeyN": 0x2D, "KeyM": 0x2E, "Period": 0x2F, "Tab": 0x30,
            "Space": 0x31, "Backquote": 0x32, "Backspace": 0x33, "Escape": 0x35, "MetaRight": 0x36, "MetaLeft": 0x37,
            "ShiftLeft": 0x38, "CapsLock": 0x39, "AltLeft": 0x3A, "ControlLeft": 0x3B, "ShiftRight": 0x3C,
            "AltRight": 0x3D, "ControlRight": 0x3E, "NumpadDecimal": 0x41, "NumpadMultiply": 0x43, "NumpadAdd": 0x45,
            "NumLock": 0x47, "NumpadClear": 0x47, "NumpadDivide": 0x4B, "NumpadEnter": 0x4C, "NumpadSubtract": 0x4E,
            "NumpadEqual": 0x51, "Numpad0": 0x52, "Numpad1": 0x53, "Numpad2": 0x54, "Numpad3": 0x55, "Numpad4": 0x56,
            "Numpad5": 0x57, "Numpad6": 0x58, "Numpad7": 0x59, "Numpad8": 0x5B, "Numpad9": 0x5C, "IntlYen": 0x5D,
            "IntlRo": 0x5E, "NumpadComma": 0x5F, "Lang2": 0x66, "Lang1": 0x68, "ContextMenu": 0x6E, "Insert": 0x72,
            "Help": 0x72, "Home": 0x73, "PageUp": 0x74, "Delete": 0x75, "End": 0x77, "PageDown": 0x79,
            "ArrowLeft": 0x7B, "ArrowRight": 0x7C, "ArrowDown": 0x7D, "ArrowUp": 0x7E,
            // older browsers' names of the ⌘ keys
            "OSLeft": 0x37, "OSRight": 0x36,
        ]
        let functionKeys: [UInt16] = [
            0x7A, 0x78, 0x63, 0x76, 0x60, 0x61, 0x62, 0x64, 0x65, 0x6D, 0x67, 0x6F, 0x69, 0x6B, 0x71, 0x6A, 0x40, 0x4F, 0x50, 0x5A,
        ]
        for (index, code) in functionKeys.enumerated() { codes["F\(index + 1)"] = code }
        return codes
    }()

    /// The modifier that a modifier key is; nil for every other key.
    public static func modifier(of code: UInt16) -> ControlModifiers? {
        switch code {
        case 0x38, 0x3C: return .shift
        case 0x3B, 0x3E: return .control
        case 0x3A, 0x3D: return .option
        case 0x37, 0x36: return .command
        default: return nil
        }
    }

    /// Caps Lock: a modifier key with no modifier of its own here.
    public static let capsLock: UInt16 = 0x39
    public static let returnKey: UInt16 = 0x24
}

/// One display as the session maps it: its frame in the global space of `CGEvent`, in points from
/// the top left of the main display (other displays may be at negative coordinates), and its pixels.
public struct ControlDisplay: Equatable, Sendable {
    public let id: UInt32
    public let x: Double
    public let y: Double
    public let width: Double
    public let height: Double
    public let pixelWidth: Int
    public let pixelHeight: Int

    public init(id: UInt32, x: Double, y: Double, width: Double, height: Double, pixelWidth: Int, pixelHeight: Int) {
        self.id = id
        self.x = x
        self.y = y
        self.width = width
        self.height = height
        self.pixelWidth = pixelWidth
        self.pixelHeight = pixelHeight
    }

    /// Pixels for each point: 2 on a Retina display at its default size.
    public var scale: Double { width > 0 && pixelWidth > 0 ? Double(pixelWidth) / width : 1 }

    /// A point 0–1 of the display, as global points. Values out of 0–1 are held at the edges, and
    /// the right and bottom edges are the last pixel, so that the point stays on this display.
    public func point(_ normalizedX: Double, _ normalizedY: Double) -> (x: Double, y: Double) {
        let pixel = 1 / scale
        let along = { (value: Double, length: Double) in min(max(value, 0), 1) * length }
        return (x + min(along(normalizedX, width), max(width - pixel, 0)), y + min(along(normalizedY, height), max(height - pixel, 0)))
    }

    /// What `control.start` answers.
    public var dictionary: [String: Any] {
        ["id": Int(id), "pixelWidth": pixelWidth, "pixelHeight": pixelHeight, "pointWidth": width, "pointHeight": height]
    }
}

/// One event of a caller, as it came.
public enum ControlEvent: Equatable, Sendable {
    case move(x: Double, y: Double)
    case button(x: Double, y: Double, button: ControlButton, down: Bool, clicks: Int?, mods: ControlModifiers)
    case scroll(dx: Double, dy: Double)
    case key(code: UInt16, down: Bool, mods: ControlModifiers)
    case text(String)

    /// The most characters of one `text` event: more goes by `control.paste`.
    public static let maxText = 2_000

    public var isMove: Bool { if case .move = self { return true } else { return false } }

    /// One event of `control.input`: `{ t: "move", x, y }`, `{ t: "down" | "up", x, y, button,
    /// clicks?, mods? }`, `{ t: "scroll", dx, dy }`, `{ t: "key", code, down, mods? }`, `{ t: "text", text }`.
    public static func parse(_ raw: Any) throws -> ControlEvent {
        guard let event = raw as? [String: Any], let kind = event["t"] as? String else {
            throw ControlProblem("an event is an object with t: move, down, up, scroll, key or text")
        }
        func number(_ name: String) throws -> Double {
            guard let value = Self.number(event[name]), value.isFinite else { throw ControlProblem("\(kind) needs \(name), a number") }
            return value
        }
        switch kind {
        case "move":
            return .move(x: try number("x"), y: try number("y"))
        case "down", "up":
            let index = event["button"] == nil ? 0 : Self.number(event["button"]).map(Int.init) ?? -1
            guard let button = ControlButton(rawValue: index) else { throw ControlProblem("button is 0 (left), 1 (middle) or 2 (right)") }
            let clicks = Self.number(event["clicks"]).flatMap { $0.isFinite ? min(max(Int($0), 1), 3) : nil }
            return .button(x: try number("x"), y: try number("y"), button: button, down: kind == "down", clicks: clicks, mods: try ControlModifiers.parse(event["mods"]))
        case "scroll":
            let clamp = { (value: Double) in min(max(value, -10_000), 10_000) }
            return .scroll(dx: clamp(event["dx"] == nil ? 0 : try number("dx")), dy: clamp(event["dy"] == nil ? 0 : try number("dy")))
        case "key":
            guard let name = event["code"] as? String else { throw ControlProblem("key needs code, a KeyboardEvent.code such as \"KeyA\"") }
            guard let code = ControlKeys.codes[name] else { throw ControlProblem("no key \"\(name)\" on this Mac") }
            guard let down = event["down"] as? Bool else { throw ControlProblem("key needs down, true or false") }
            return .key(code: code, down: down, mods: try ControlModifiers.parse(event["mods"]))
        case "text":
            guard let text = event["text"] as? String else { throw ControlProblem("text needs text, a string") }
            guard text.count <= maxText else { throw ControlProblem("text is at most \(maxText) characters: control.paste puts more") }
            return .text(text)
        default:
            throw ControlProblem("no event \"\(kind)\": t is move, down, up, scroll, key or text")
        }
    }

    /// A number of JSON (an `NSNumber`) or of Swift.
    static func number(_ value: Any?) -> Double? {
        switch value {
        case let value as Double: return value
        case let value as Int: return Double(value)
        case let value as NSNumber where !(value is Bool): return value.doubleValue
        default: return nil
        }
    }

    /// Consecutive moves are one: the last. Answers the events and how many moves were folded in.
    public static func coalesce(_ events: [ControlEvent]) -> [ControlEvent] {
        var out: [ControlEvent] = []
        out.reserveCapacity(events.count)
        for event in events {
            if event.isMove, let last = out.last, last.isMove { out[out.count - 1] = event } else { out.append(event) }
        }
        return out
    }
}

/// What the app posts, in global points: one `CGEvent` each (a text chunk is a down and an up).
public enum ControlAction: Equatable, Sendable {
    /// A move; a drag while `dragging` is held.
    case move(x: Double, y: Double, dragging: ControlButton?)
    case button(x: Double, y: Double, button: ControlButton, down: Bool, clicks: Int, mods: ControlModifiers)
    /// Pixels, as a browser's `WheelEvent.deltaX` and `deltaY`: positive is right and down.
    case scroll(dx: Int32, dy: Int32)
    /// `mods` is every modifier held with it; a modifier key is a change of the modifiers.
    case key(code: UInt16, down: Bool, mods: ControlModifiers, isModifier: Bool)
    /// At most `textChunk` UTF-16 units: what an app reads of one key event.
    case text(String)

    public static let textChunk = 20

    /// Text in pieces of at most `textChunk` UTF-16 units, never inside a character; a line end is
    /// the Return key.
    public static func typing(_ text: String) -> [ControlAction] {
        var actions: [ControlAction] = []
        var chunk = ""
        var units = 0
        func flush() {
            if !chunk.isEmpty { actions.append(.text(chunk)) }
            chunk = ""
            units = 0
        }
        for character in text {
            if character.isNewline {
                flush()
                actions.append(.key(code: ControlKeys.returnKey, down: true, mods: [], isModifier: false))
                actions.append(.key(code: ControlKeys.returnKey, down: false, mods: [], isModifier: false))
                continue
            }
            let size = character.utf16.count
            if units + size > textChunk { flush() }
            chunk.append(character)
            units += size
        }
        flush()
        return actions
    }
}

/// The click count of a down: a second down of the same button soon after, near the first, is a
/// double click, and a third a triple click.
public struct ControlClicks: Sendable {
    private var last: (button: ControlButton, x: Double, y: Double, at: Date, count: Int)?
    private var counts: [ControlButton: Int] = [:]
    /// Points: a down farther than this from the one before starts a new count.
    public static let slop: Double = 4

    public init() {}

    public mutating func down(_ button: ControlButton, x: Double, y: Double, at now: Date, interval: TimeInterval) -> Int {
        var count = 1
        if let last, last.button == button, now.timeIntervalSince(last.at) <= interval, abs(last.x - x) <= Self.slop, abs(last.y - y) <= Self.slop {
            count = last.count % 3 + 1
        }
        last = (button, x, y, now, count)
        counts[button] = count
        return count
    }

    /// An up has the count of its down.
    public mutating func given(_ button: ControlButton, x: Double, y: Double, count: Int, at now: Date) {
        last = (button, x, y, now, count)
        counts[button] = count
    }

    public func up(_ button: ControlButton) -> Int { counts[button] ?? 1 }
}

/// The answer to one batch.
public struct ControlInputResult: Equatable, Sendable {
    /// The events of the batch that took effect; a move folded into a later one counts.
    public var applied = 0
    /// True when the owner's own input paused the batch: its events were dropped.
    public var paused = false
    /// Keys and text dropped because the focus was in a password.
    public var withheld = 0
    /// Events that were not understood, and why the first one was not.
    public var skipped = 0
    public var problem: String?
    /// What to post, in order.
    public var actions: [ControlAction] = []

    public init() {}

    public var dictionary: [String: Any] {
        var answer: [String: Any] = ["applied": applied, "paused": paused]
        if withheld > 0 { answer["withheld"] = withheld }
        if skipped > 0 { answer["skipped"] = skipped }
        if let problem { answer["problem"] = problem }
        return answer
    }
}

/// THE SESSIONS: who controls which display, since when, what they hold down, and the owner's pause.
public struct ControlSessions: Sendable {
    /// A session with no call from its caller for this long ends.
    public static let idleLimit: TimeInterval = 30
    /// The owner's own input pauses every session for this long.
    public static let ownerPause: TimeInterval = 1
    public static let maxSessions = 4

    public struct Session: Equatable, Sendable {
        public let id: String
        public let who: String
        public var display: ControlDisplay
        public let startedAt: Date
        public var lastInputAt: Date
        /// The buttons and keys this session holds down now, and the last point it went to.
        public var buttons: Set<ControlButton> = []
        public var keys: Set<UInt16> = []
        public var point: (x: Double, y: Double)?
        var clicks = ControlClicks()

        public static func == (a: Session, b: Session) -> Bool {
            a.id == b.id && a.who == b.who && a.display == b.display && a.lastInputAt == b.lastInputAt && a.buttons == b.buttons && a.keys == b.keys
        }

        /// The modifiers its held modifier keys make.
        var heldMods: ControlModifiers {
            keys.reduce(into: ControlModifiers()) { mods, code in
                if let mod = ControlKeys.modifier(of: code) { mods.insert(mod) }
            }
        }

        /// Ups for all it holds, in global points: keys first, the modifiers last.
        mutating func letGo() -> [ControlAction] {
            var actions: [ControlAction] = []
            let modifierKeys = keys.filter { ControlKeys.modifier(of: $0) != nil }
            for code in keys.subtracting(modifierKeys).sorted() {
                actions.append(.key(code: code, down: false, mods: heldMods, isModifier: false))
            }
            for button in buttons.sorted(by: { $0.rawValue < $1.rawValue }) {
                let at = point ?? display.point(0.5, 0.5)
                actions.append(.button(x: at.x, y: at.y, button: button, down: false, clicks: clicks.up(button), mods: []))
            }
            for code in modifierKeys.sorted() {
                keys.remove(code)
                actions.append(.key(code: code, down: false, mods: heldMods, isModifier: true))
            }
            keys = []
            buttons = []
            return actions
        }
    }

    public private(set) var sessions: [Session] = []
    public private(set) var ownerActedAt: Date?

    public init() {}

    public var isEmpty: Bool { sessions.isEmpty }

    public func session(_ id: String) -> Session? { sessions.first { $0.id == id } }

    public mutating func start(who: String, display: ControlDisplay, now: Date, id: String = UUID().uuidString.lowercased()) throws -> Session {
        guard sessions.count < Self.maxSessions else {
            throw ControlProblem("\(Self.maxSessions) people control this Mac already: one ends first")
        }
        let session = Session(id: id, who: who, display: display, startedAt: now, lastInputAt: now)
        sessions.append(session)
        return session
    }

    /// The session ends: it and what to post to let go of all it held.
    public mutating func end(_ id: String) -> (session: Session, releases: [ControlAction])? {
        guard let index = sessions.firstIndex(where: { $0.id == id }) else { return nil }
        var session = sessions.remove(at: index)
        let releases = session.letGo()
        return (session, releases)
    }

    /// The sessions whose caller said nothing for `idleLimit`, for `end`.
    public func idle(now: Date) -> [String] {
        sessions.filter { now.timeIntervalSince($0.lastInputAt) >= Self.idleLimit }.map(\.id)
    }

    /// A call of the session's caller that is no input (`paste`, `clipboard`): it keeps the session.
    @discardableResult
    public mutating func touch(_ id: String, now: Date) -> Bool {
        guard let index = sessions.firstIndex(where: { $0.id == id }) else { return false }
        sessions[index].lastInputAt = now
        return true
    }

    /// The owner moved, clicked or typed: every session pauses, and lets go of all it holds, so
    /// that the owner's own moves are no drags. Answers what to post (nothing when nothing is held).
    public mutating func ownerActed(at now: Date) -> [ControlAction] {
        ownerActedAt = now
        var releases: [ControlAction] = []
        for index in sessions.indices where !sessions[index].buttons.isEmpty || !sessions[index].keys.isEmpty {
            releases += sessions[index].letGo()
        }
        return releases
    }

    public func isPaused(now: Date) -> Bool {
        guard let ownerActedAt else { return false }
        return now.timeIntervalSince(ownerActedAt) < Self.ownerPause
    }

    /// One batch of `control.input`: what to post and the answer. Nil when there is no such session.
    /// `display`: the display as it is now (nil: as at the start). `isSecret` is asked at most once,
    /// at the first key or text of the batch: true when the focus is in a password.
    public mutating func input(
        _ id: String, events raw: [Any], display: ControlDisplay? = nil, now: Date, doubleClick: TimeInterval = 0.5,
        isSecret: () -> Bool
    ) -> ControlInputResult? {
        guard let index = sessions.firstIndex(where: { $0.id == id }) else { return nil }
        var session = sessions[index]
        defer { sessions[index] = session }
        session.lastInputAt = now
        if let display { session.display = display }
        var result = ControlInputResult()
        var events: [ControlEvent] = []
        events.reserveCapacity(raw.count)
        for item in raw {
            do { events.append(try ControlEvent.parse(item)) } catch {
                result.skipped += 1
                if result.problem == nil { result.problem = (error as? ControlProblem)?.words ?? "\(error)" }
            }
        }
        let paused = isPaused(now: now)
        result.paused = paused
        let folded = events.count
        events = ControlEvent.coalesce(events)
        var secret: Bool?
        func inSecret() -> Bool {
            if let secret { return secret }
            let answer = isSecret()
            secret = answer
            return answer
        }
        for event in events {
            switch event {
            case .move(let x, let y):
                guard !paused else { continue }
                let at = session.display.point(x, y)
                session.point = at
                let dragging = [ControlButton.left, .right, .middle].first { session.buttons.contains($0) }
                result.actions.append(.move(x: at.x, y: at.y, dragging: dragging))
                result.applied += 1
            case .button(let x, let y, let button, let down, let clicks, let mods):
                let at = session.display.point(x, y)
                if down {
                    guard !paused else { continue }
                    let count = clicks ?? session.clicks.down(button, x: at.x, y: at.y, at: now, interval: doubleClick)
                    if clicks != nil { session.clicks.given(button, x: at.x, y: at.y, count: count, at: now) }
                    session.buttons.insert(button)
                    session.point = at
                    result.actions.append(.button(x: at.x, y: at.y, button: button, down: true, clicks: count, mods: mods.union(session.heldMods)))
                } else {
                    // a release of what the session holds goes even while paused; another is dropped then
                    guard session.buttons.contains(button) || !paused else { continue }
                    session.buttons.remove(button)
                    session.point = at
                    result.actions.append(.button(x: at.x, y: at.y, button: button, down: false, clicks: clicks ?? session.clicks.up(button), mods: mods.union(session.heldMods)))
                }
                result.applied += 1
            case .scroll(let dx, let dy):
                guard !paused else { continue }
                result.actions.append(.scroll(dx: Int32(dx.rounded()), dy: Int32(dy.rounded())))
                result.applied += 1
            case .key(let code, let down, let mods):
                let modifier = ControlKeys.modifier(of: code)
                let isModifier = modifier != nil || code == ControlKeys.capsLock
                if down {
                    guard !paused else { continue }
                    guard !inSecret() else {
                        result.withheld += 1
                        continue
                    }
                    session.keys.insert(code)
                } else {
                    guard session.keys.contains(code) || !paused else { continue }
                    // a key that went down outside the password may come up inside it
                    guard session.keys.contains(code) || !inSecret() else {
                        result.withheld += 1
                        continue
                    }
                    session.keys.remove(code)
                }
                result.actions.append(.key(code: code, down: down, mods: mods.union(session.heldMods), isModifier: isModifier))
                result.applied += 1
            case .text(let text):
                guard !paused else { continue }
                guard !inSecret() else {
                    result.withheld += 1
                    continue
                }
                result.actions += ControlAction.typing(text)
                result.applied += 1
            }
        }
        // the moves folded into a later one took effect with it
        if !paused { result.applied += folded - events.count }
        return result
    }
}

/// Text from the pasteboard, for `control.clipboard`: a password manager marks what it copies as
/// concealed (nspasteboard.org), and that goes to no caller.
public enum ControlClipboard {
    /// The most bytes of UTF-8 `control.clipboard` answers and `control.paste` takes.
    public static let maxBytes = 1_000_000
    /// The pasteboard types that say "a secret": a password manager's copy.
    public static let concealedTypes: Set<String> = ["org.nspasteboard.ConcealedType", "org.nspasteboard.TransientType", "com.agilebits.onepassword"]

    /// The text a caller gets, at most `maxBytes`, never cut inside a character.
    public static func answer(text: String?, types: [String]) -> [String: Any] {
        if types.contains(where: concealedTypes.contains) {
            return ["text": NSNull(), "withheld": "the clipboard holds a secret (a password manager's copy)"]
        }
        guard let text else { return ["text": NSNull()] }
        let utf8 = text.utf8
        guard utf8.count > maxBytes else { return ["text": text, "truncated": false] }
        var cut = String(decoding: utf8.prefix(maxBytes), as: UTF8.self)
        // a cut inside a character decodes to a replacement character at the end: drop it
        if cut.hasSuffix("\u{FFFD}"), !text.hasPrefix(cut) { cut.removeLast() }
        return ["text": cut, "truncated": true]
    }
}

/// How long the app took from a batch's arrival to its last event posted: for the log.
public struct ControlLatency: Equatable, Sendable {
    public private(set) var batches = 0
    public private(set) var events = 0
    public private(set) var totalNanoseconds: UInt64 = 0
    public private(set) var maxNanoseconds: UInt64 = 0

    public init() {}

    public mutating func add(nanoseconds: UInt64, events: Int) {
        batches += 1
        self.events += events
        totalNanoseconds += nanoseconds
        maxNanoseconds = max(maxNanoseconds, nanoseconds)
    }

    /// "120 batches, 340 events posted: 0.04 ms on average, 0.31 ms at most"
    public var line: String {
        guard batches > 0 else { return "no batches" }
        let ms = { (ns: UInt64) in String(format: "%.3f", Double(ns) / 1_000_000) }
        return "\(batches) batches, \(events) events posted: \(ms(totalNanoseconds / UInt64(batches))) ms on average, \(ms(maxNanoseconds)) ms at most"
    }
}
