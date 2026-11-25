import AppKit
import Carbon.HIToolbox
import SwiftUI
import VoiceMeetCore
import os

/// CONTROL: somebody of the mind drives this Mac, as in a shared call: the mouse, the keyboard and
/// the clipboard (README, "Control: somebody drives this Mac"). The rules are `ControlSessions` in
/// `VoiceMeetCore`; this file posts what they say with `CGEvent`, shows each session (a red border
/// around its display, a red row in the panel, a running act), and lets the owner win:
///
/// - Each local move, click, scroll or key pauses every session for 1 s, and lets go of what a
///   session holds down. A posted event carries `marker` in its user data field, so the watch
///   tells it from the owner's (`OwnerTap`, an event tap of the session).
/// - ⌃⌥⌘Esc ends every session; so do the panel's End, Control turned Off, and another mind.
/// - A session ends after 30 s with no call from its caller.
///
/// A copy with a home of its own posts nothing to this Mac unless `ITERATE_CONTROL_POSTS=1`: its
/// poster only counts (`CountingPoster`), so a test never moves the owner's mouse.
@MainActor
final class RemoteControl: ObservableObject {
    /// A session, for the panel.
    struct Row: Identifiable, Equatable {
        let id: String
        let who: String
        let display: String
        let since: Date
    }

    @Published private(set) var rows: [Row] = []

    /// A session began: its act in Activity, by its id.
    var began: (_ who: String, _ display: String) -> String = { _, _ in "" }
    var finished: (_ act: String, _ failure: String?) -> Void = { _, _ in }

    /// In the user data field of each event the app posts ("itcx").
    nonisolated static let marker: Int64 = 0x6974_6378
    /// ⌃⌥⌘Esc: every session ends.
    static let stopKey = HotKey.Combo(id: 5, key: kVK_Escape, modifiers: controlKey | optionKey | cmdKey)

    let poster: ControlPoster
    private var table = ControlSessions()
    private var acts: [String: String] = [:]
    private var names: [String: String] = [:]
    private var borders: [UInt32: ControlBorder] = [:]
    private lazy var tap = OwnerTap(marker: Self.marker) { [weak self] in self?.ownerActed() }
    private var timer: Timer?
    private var screens: NSObjectProtocol?
    private var wasPaused = false
    private let focus = FocusWatch()
    private var latency = ControlLatency()
    private let log = AppLog("control")

    init(poster: ControlPoster? = nil) {
        let posts = !AppEnvironment.current.hasOwnHome || ProcessInfo.processInfo.environment["ITERATE_CONTROL_POSTS"] == "1"
        self.poster = poster ?? (posts ? EventPoster(marker: Self.marker) : CountingPoster())
    }

    var isRunning: Bool { !table.isEmpty }

    func has(_ id: String) -> Bool { table.session(id) != nil }

    // MARK: - The calls

    /// `control.start`: the caller's gate and question are `AppModel`'s; this begins the session.
    func start(who: String, display id: CGDirectDisplayID, name: String) throws -> [String: Any] {
        guard let display = Self.display(id) else { throw EndpointRefusal("The display \(name) is not connected now.") }
        // the owner must be able to win before anybody drives
        if table.isEmpty, !watch() {
            throw EndpointRefusal("macOS gave this app no event tap, which lets the owner's own mouse and keys win: it needs Accessibility. The Mac's owner gives it from the iterate panel.")
        }
        let session: ControlSessions.Session
        do { session = try table.start(who: who, display: display, now: Date()) } catch let problem as ControlProblem {
            throw EndpointRefusal(problem.words)
        }
        names[session.id] = name
        acts[session.id] = began(who, name)
        showBorders()
        publish()
        log.info("\(who) controls the display \(name) (\(display.pixelWidth) × \(display.pixelHeight) px, \(Int(display.width)) × \(Int(display.height)) pt)\(poster is CountingPoster ? "; a copy with its own home: nothing is posted" : "")")
        return ["session": session.id, "display": display.dictionary]
    }

    /// `control.input`: one batch, posted at once. `arrived`: when the call came, in uptime ns.
    func input(_ id: String, events: [Any], arrived: UInt64) throws -> [String: Any] {
        guard let session = table.session(id) else { throw Self.noSession(id) }
        guard let display = Self.display(session.display.id) else {
            end(id, why: "its display is gone", failure: "its display is gone")
            throw EndpointRefusal("The session's display is no longer connected: the session ended.")
        }
        guard let result = table.input(id, events: events, display: display, now: Date(), doubleClick: NSEvent.doubleClickInterval, isSecret: { focus.isSecret() })
        else { throw Self.noSession(id) }
        for action in result.actions { poster.post(action) }
        latency.add(nanoseconds: DispatchTime.now().uptimeNanoseconds &- arrived, events: result.actions.count)
        if latency.batches % 500 == 1 { log.info("from a batch's arrival to its last event posted: \(latency.line)") }
        return result.dictionary
    }

    /// `control.paste`: text on the pasteboard, and ⌘V with `press`. Nothing while the owner's
    /// input pauses the session: their own clipboard stays theirs.
    func paste(_ id: String, text: String, press: Bool) throws -> [String: Any] {
        let now = Date()
        guard table.touch(id, now: now) else { throw Self.noSession(id) }
        guard text.utf8.count <= ControlClipboard.maxBytes else {
            throw EndpointRefusal("control.paste takes at most \(ControlClipboard.maxBytes) bytes of text.")
        }
        guard !table.isPaused(now: now) else { return ["pasted": false, "paused": true] }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        var answer: [String: Any] = ["pasted": true, "characters": text.count, "paused": false]
        if press {
            if focus.isSecret() {
                answer["withheld"] = 1
                answer["pressed"] = false
            } else {
                let v = KeyLayout.code(typing: "v") ?? 0x09
                poster.post(.key(code: v, down: true, mods: .command, isModifier: false))
                poster.post(.key(code: v, down: false, mods: .command, isModifier: false))
                answer["pressed"] = true
            }
        }
        log.info("a session pasted \(text.count) characters\(press ? " and pressed ⌘V" : "")")
        return answer
    }

    /// `control.clipboard`: the pasteboard's text, unless a password manager put it there.
    func clipboard(_ id: String) throws -> [String: Any] {
        guard table.touch(id, now: Date()) else { throw Self.noSession(id) }
        let board = NSPasteboard.general
        return ControlClipboard.answer(text: board.string(forType: .string), types: board.types?.map(\.rawValue) ?? [])
    }

    /// `control.state`: who controls which display, since when; reading it is no use.
    func state() -> [String: Any] {
        let now = Date()
        return [
            "sharing": Shareable.control.sharing.rawValue,
            "permitted": Shareable.control.isPermitted,
            "paused": table.isPaused(now: now),
            "sessions": table.sessions.map { session -> [String: Any] in
                var display = session.display.dictionary
                display["name"] = names[session.id] ?? ""
                return [
                    "session": session.id, "who": session.who, "display": display,
                    "since": Int(session.startedAt.timeIntervalSince1970 * 1000), "idleSeconds": Int(now.timeIntervalSince(session.lastInputAt)),
                ]
            },
        ]
    }

    /// Ends one session: what it held is let go, its act ends, and its border goes.
    func end(_ id: String, why: String, failure: String? = nil) {
        guard let (session, releases) = table.end(id) else { return }
        releases.forEach(poster.post)
        if let act = acts.removeValue(forKey: id) { finished(act, failure) }
        names[id] = nil
        log.info("\(session.who) no longer controls this Mac: \(why); \(latency.line)")
        if table.isEmpty { unwatch() }
        showBorders()
        publish()
    }

    func endAll(why: String) {
        table.sessions.map(\.id).forEach { end($0, why: why) }
    }

    private static func noSession(_ id: String) -> EndpointRefusal {
        EndpointRefusal("No control session \(id.prefix(40)) now: it ended (control.end, 30 s with no input, or the owner ended it) or never began. control.start begins one.")
    }

    // MARK: - The owner wins

    /// While a session runs: the owner's own input, the stop key, the idle limit, the displays.
    /// False when macOS gives no event tap (no Accessibility): then nobody may drive.
    private func watch() -> Bool {
        guard tap.start() else { return false }
        if !HotKey.register(Self.stopKey, pressed: { [weak self] in self?.endAll(why: "the owner pressed ⌃⌥⌘Esc") }) {
            log.error("macOS refused ⌃⌥⌘Esc: the panel's End stops a session")
        }
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        screens = NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) {
            [weak self] _ in MainActor.assumeIsolated { self?.showBorders() }
        }
        focus.start()
        return true
    }

    private func unwatch() {
        tap.stop()
        HotKey.unregister(Self.stopKey.id)
        timer?.invalidate()
        timer = nil
        if let screens { NotificationCenter.default.removeObserver(screens) }
        screens = nil
        focus.stop()
        wasPaused = false
    }

    /// The owner's own input (`OwnerTap`): every session pauses and lets go.
    private func ownerActed() {
        guard !table.isEmpty else { return }
        let releases = table.ownerActed(at: Date())
        releases.forEach(poster.post)
        if !wasPaused {
            wasPaused = true
            log.info("the owner's own input pauses control\(releases.isEmpty ? "" : ", and lets go of \(releases.count) held keys and buttons")")
        }
    }

    private func tick() {
        let now = Date()
        if wasPaused, !table.isPaused(now: now) { wasPaused = false }
        for id in table.idle(now: now) { end(id, why: "no input for \(Int(ControlSessions.idleLimit)) s") }
    }

    // MARK: - What the owner sees

    private func publish() {
        rows = table.sessions.map { Row(id: $0.id, who: $0.who, display: names[$0.id] ?? "", since: $0.startedAt) }
    }

    /// A red border around each display a session controls.
    private func showBorders() {
        let wanted = Set(table.sessions.map(\.display.id))
        for (id, border) in borders where !wanted.contains(id) {
            border.close()
            borders[id] = nil
        }
        for id in wanted {
            guard let screen = NSScreen.screens.first(where: { Self.id(of: $0) == id }) else { continue }
            let border = borders[id] ?? ControlBorder()
            borders[id] = border
            border.show(on: screen)
        }
    }

    // MARK: - Displays

    private static func id(of screen: NSScreen) -> CGDirectDisplayID? {
        screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID
    }

    /// A display as the session maps it, read now: nil when it is not connected.
    static func display(_ id: CGDirectDisplayID) -> ControlDisplay? {
        guard CGDisplayIsOnline(id) != 0 else { return nil }
        let bounds = CGDisplayBounds(id)
        guard bounds.width > 0, bounds.height > 0 else { return nil }
        let mode = CGDisplayCopyDisplayMode(id)
        return ControlDisplay(
            id: id, x: bounds.minX, y: bounds.minY, width: bounds.width, height: bounds.height,
            pixelWidth: mode?.pixelWidth ?? Int(bounds.width), pixelHeight: mode?.pixelHeight ?? Int(bounds.height))
    }
}

// MARK: - The owner's input

/// Hears the Mac's mouse and keys while a session runs, on a thread of its own, and tells the main
/// actor of each event that the app did not post, at most once in 50 ms (the pause is 1 s). An event
/// tap of the session reads the user data field of each event as it was posted; macOS gives an
/// active tap to an app with Accessibility (a listening one would need Input Monitoring too), so
/// it is active and passes every event on unchanged, as `FnTap`'s flags tap does.
final class OwnerTap: @unchecked Sendable {
    private struct State {
        var port: CFMachPort?
        var loop: CFRunLoop?
        var lastTold: UInt64 = 0
    }

    private let marker: Int64
    private let told: @MainActor () -> Void
    private let state = OSAllocatedUnfairLock(initialState: State())
    private static let spacing: UInt64 = 50_000_000

    init(marker: Int64, told: @escaping @MainActor () -> Void) {
        self.marker = marker
        self.told = told
    }

    @MainActor
    func start() -> Bool {
        if state.withLock({ $0.port != nil }) { return true }
        let kinds: [CGEventType] = [
            .mouseMoved, .leftMouseDown, .rightMouseDown, .otherMouseDown, .leftMouseDragged, .rightMouseDragged, .otherMouseDragged,
            .scrollWheel, .keyDown, .flagsChanged,
        ]
        let mask = kinds.reduce(CGEventMask(0)) { $0 | CGEventMask(1) << $1.rawValue }
        guard let port = CGEvent.tapCreate(
            tap: .cgSessionEventTap, place: .tailAppendEventTap, options: .listenOnly, eventsOfInterest: mask, callback: ownerTapCallback,
            userInfo: Unmanaged.passUnretained(self).toOpaque())
        else { return false }
        state.withLock { $0.port = port }
        let source = CFMachPortCreateRunLoopSource(nil, port, 0)
        let thread = Thread { [state] in
            let loop = CFRunLoopGetCurrent()
            state.withLock { $0.loop = loop }
            CFRunLoopAddSource(loop, source, .commonModes)
            CGEvent.tapEnable(tap: port, enable: true)
            CFRunLoopRun()
        }
        thread.name = "control owner tap"
        thread.qualityOfService = .userInteractive
        thread.start()
        return true
    }

    @MainActor
    func stop() {
        let (port, loop) = state.withLock { state in
            defer {
                state.port = nil
                state.loop = nil
            }
            return (state.port, state.loop)
        }
        guard let port else { return }
        CGEvent.tapEnable(tap: port, enable: false)
        CFMachPortInvalidate(port)
        if let loop { CFRunLoopStop(loop) }
    }

    /// On the tap's thread, for each event: it passes on unchanged. The tap only listens
    /// (`.listenOnly`): a stalled app never holds up the owner's own mouse and keys.
    fileprivate func hear(_ type: CGEventType, _ event: CGEvent) -> Unmanaged<CGEvent>? {
        let pass = Unmanaged.passUnretained(event)
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let port = state.withLock({ $0.port }) { CGEvent.tapEnable(tap: port, enable: true) }
            return pass
        }
        guard event.getIntegerValueField(.eventSourceUserData) != marker else { return pass }
        let now = DispatchTime.now().uptimeNanoseconds
        let tell = state.withLock { state -> Bool in
            guard state.port != nil, now &- state.lastTold >= Self.spacing else { return false }
            state.lastTold = now
            return true
        }
        if tell {
            let told = told
            DispatchQueue.main.async { MainActor.assumeIsolated { told() } }
        }
        return pass
    }
}

private func ownerTapCallback(proxy: CGEventTapProxy, type: CGEventType, event: CGEvent, info: UnsafeMutableRawPointer?) -> Unmanaged<CGEvent>? {
    guard let info else { return Unmanaged.passUnretained(event) }
    return Unmanaged<OwnerTap>.fromOpaque(info).takeUnretainedValue().hear(type, event)
}

// MARK: - Posting

/// Posts what a session does.
@MainActor
protocol ControlPoster: AnyObject {
    func post(_ action: ControlAction)
}

/// Posts each action as `CGEvent`s at the HID level, as a mouse and a keyboard would. Posting
/// needs the Accessibility permission of macOS.
@MainActor
final class EventPoster: ControlPoster {
    private let source: CGEventSource?
    private let marker: Int64

    init(marker: Int64) {
        self.marker = marker
        source = CGEventSource(stateID: .hidSystemState)
        source?.userData = marker
        // a posted event must not hold back the owner's own mouse and keys for a moment
        source?.localEventsSuppressionInterval = 0
        source?.setLocalEventsFilterDuringSuppressionState(
            [.permitLocalMouseEvents, .permitLocalKeyboardEvents, .permitSystemDefinedEvents], state: .eventSuppressionStateSuppressionInterval)
    }

    func post(_ action: ControlAction) {
        switch action {
        case .move(let x, let y, let dragging):
            let type: CGEventType
            switch dragging {
            case .left: type = .leftMouseDragged
            case .right: type = .rightMouseDragged
            case .middle: type = .otherMouseDragged
            case nil: type = .mouseMoved
            }
            send(CGEvent(mouseEventSource: source, mouseType: type, mouseCursorPosition: CGPoint(x: x, y: y), mouseButton: Self.button(dragging ?? .left)))
        case .button(let x, let y, let button, let down, let clicks, let mods):
            let type: CGEventType
            switch button {
            case .left: type = down ? .leftMouseDown : .leftMouseUp
            case .right: type = down ? .rightMouseDown : .rightMouseUp
            case .middle: type = down ? .otherMouseDown : .otherMouseUp
            }
            let event = CGEvent(mouseEventSource: source, mouseType: type, mouseCursorPosition: CGPoint(x: x, y: y), mouseButton: Self.button(button))
            event?.setIntegerValueField(.mouseEventClickState, value: Int64(clicks))
            event?.flags = Self.flags(mods)
            send(event)
        case .scroll(let dx, let dy):
            // a browser's delta is positive down and right; a wheel's is positive up and left
            send(CGEvent(scrollWheelEvent2Source: source, units: .pixel, wheelCount: 2, wheel1: -dy, wheel2: -dx, wheel3: 0))
        case .key(let code, let down, let mods, let isModifier):
            let event = CGEvent(keyboardEventSource: source, virtualKey: code, keyDown: down)
            if isModifier { event?.type = .flagsChanged }
            event?.flags = Self.flags(mods)
            send(event)
        case .text(let text):
            var units = Array(text.utf16)
            for down in [true, false] {
                let event = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: down)
                event?.flags = []
                event?.keyboardSetUnicodeString(stringLength: units.count, unicodeString: &units)
                send(event)
            }
        }
    }

    private func send(_ event: CGEvent?) {
        guard let event else { return }
        event.setIntegerValueField(.eventSourceUserData, value: marker)
        event.post(tap: .cghidEventTap)
    }

    private static func button(_ button: ControlButton) -> CGMouseButton {
        switch button {
        case .left: return .left
        case .right: return .right
        case .middle: return .center
        }
    }

    private static func flags(_ mods: ControlModifiers) -> CGEventFlags {
        var flags: CGEventFlags = []
        if mods.contains(.shift) { flags.insert(.maskShift) }
        if mods.contains(.control) { flags.insert(.maskControl) }
        if mods.contains(.option) { flags.insert(.maskAlternate) }
        if mods.contains(.command) { flags.insert(.maskCommand) }
        return flags
    }
}

/// A copy with a home of its own posts nothing: it counts.
@MainActor
final class CountingPoster: ControlPoster {
    private(set) var posted: [ControlAction] = []

    func post(_ action: ControlAction) {
        posted.append(action)
        if posted.count > 1_000 { posted.removeFirst(500) }
    }
}

/// The key that types a character in the owner's layout now: ⌘V is the key that types "v", which on
/// Dvorak is not the key of QWERTY's V.
enum KeyLayout {
    static func code(typing character: String) -> UInt16? {
        guard let source = TISCopyCurrentKeyboardLayoutInputSource()?.takeRetainedValue(),
            let pointer = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData)
        else { return nil }
        let data = Unmanaged<CFData>.fromOpaque(pointer).takeUnretainedValue() as Data
        return data.withUnsafeBytes { bytes -> UInt16? in
            guard let layout = bytes.baseAddress?.assumingMemoryBound(to: UCKeyboardLayout.self) else { return nil }
            for code in UInt16(0)..<128 {
                var deadKeys: UInt32 = 0
                var characters = [UniChar](repeating: 0, count: 4)
                var length = 0
                let status = UCKeyTranslate(
                    layout, code, UInt16(kUCKeyActionDown), 0, UInt32(LMGetKbdType()), OptionBits(kUCKeyTranslateNoDeadKeysBit),
                    &deadKeys, characters.count, &length, &characters)
                if status == noErr, length > 0, String(utf16CodeUnits: characters, count: length) == character { return code }
            }
            return nil
        }
    }
}

// MARK: - The border

/// A thin red border around a controlled display, over every window and on every space. Clicks go
/// through it, and it is in no picture of the screen, as the activity pill is not.
@MainActor
final class ControlBorder {
    private let window: NSPanel

    init() {
        window = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        window.level = NSWindow.Level(rawValue: NSWindow.Level.statusBar.rawValue + 1)
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = false
        window.ignoresMouseEvents = true
        window.sharingType = .none
        window.isReleasedWhenClosed = false
        let view = NSView()
        view.wantsLayer = true
        view.layer?.borderWidth = 4
        view.layer?.borderColor = NSColor.systemRed.cgColor
        window.contentView = view
    }

    func show(on screen: NSScreen) {
        window.setFrame(screen.frame, display: true)
        window.orderFrontRegardless()
    }

    func close() {
        window.orderOut(nil)
    }
}

/// The panel's sessions, while there are any, first under the mind: one red row for each, who,
/// which display and since when, and the button that ends it.
struct ControlSection: View {
    @ObservedObject var control: RemoteControl

    var body: some View {
        if !control.rows.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                ForEach(control.rows) { row in
                    HStack(spacing: 10) {
                        Image(systemName: "cursorarrow.motionlines").font(.system(size: 13, weight: .regular)).frame(width: 16).foregroundStyle(Theme.liveText)
                        VStack(alignment: .leading, spacing: 1) {
                            Text("\(row.who) controls this Mac").font(.system(size: 13, weight: .semibold)).lineLimit(1).truncationMode(.middle)
                            Text("\(row.display) · since \(Lend.shortClock(row.since)) · ⌃⌥⌘Esc ends it")
                                .font(.system(size: 12)).foregroundStyle(Theme.t2).lineLimit(1).truncationMode(.middle)
                        }
                        Spacer(minLength: 8)
                        Button("End") { control.end(row.id, why: "the owner ended it") }
                            .buttonStyle(FillButtonStyle(prominent: true))
                            .help("Ends this session now")
                            .accessibilityIdentifier("control.end")
                    }
                    .padding(.leading, 12)
                    .padding(.trailing, 10)
                    .padding(.vertical, 9)
                    .background(Theme.liveWash, in: RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous).strokeBorder(Theme.liveEdge))
                }
            }
            .padding(.top, 12)
        }
    }
}
