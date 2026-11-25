import AppKit
import SwiftUI
import VoiceMeetCore

/// WHAT THIS MAC TELLS ITS MIND ABOUT ITSELF, as events on the context `/devices/<name>` of the
/// mind it is lent to: the same name as the lend, `itx.<name>`. It publishes for one mind session
/// (`MindSession`): `use` ends the old session's job at once, and a late line of it changes
/// nothing.
///
/// - `device/presence-changed`, always while the Mac is lent: the Mac goes idle, becomes active,
///   is locked, or its displays sleep. Kept in the log.
/// - `device/key-pressed`, `device/mouse-pressed`, `device/mouse-moved` and `device/scrolled`,
///   only while the person has "Keyboard and mouse" on in the panel. A key event holds the key
///   itself. They are ephemeral (to whoever listens now, in no log) unless the person ticks
///   "Keep these events".
/// - `device/act-started` and `device/act-ended`: each act with this Mac for the mind
///   (`ActivityLog`). Kept in the log.
///
/// The bridge also reads the context back: `heard` gets each act and presence event that the
/// context holds, from the last 50 acts on, and each new one; and, only while the Activity window
/// is open, every kept event for it (`readLog`, `heardLog`). The events go through the job
/// `events` of the session's `MindBridge` (`bridge/events.mjs`), on its connection as the person:
/// the Mac's own key lends and does nothing else.
@MainActor
final class DeviceEvents: ObservableObject {
    /// A person is taken as away after this long with no key, click or move.
    static let idleAfterSeconds = 120

    /// The person's choice: keyboard and mouse events go to the mind.
    @Published var sharesInput = AppEnvironment.current.defaults.bool(forKey: "device.input") {
        didSet {
            guard !isDrawing else { return }
            AppEnvironment.current.defaults.set(sharesInput, forKey: "device.input")
            watchInput()
        }
    }
    /// The person's choice: those events are kept in the mind's log. Off: they are ephemeral.
    @Published var keepsInput = AppEnvironment.current.defaults.bool(forKey: "device.keep") {
        didSet { if !isDrawing { AppEnvironment.current.defaults.set(keepsInput, forKey: "device.keep") } }
    }
    /// A drawing's: the choices are set, and nothing is stored or watched.
    private var isDrawing = false

    /// For a drawing (`Rendering`): the choices as given, with no monitor and no stored value.
    func fixForDrawing(sharesInput: Bool, keepsInput: Bool) {
        isDrawing = true
        (self.sharesInput, self.keepsInput) = (sharesInput, keepsInput)
    }
    /// How many events went to the mind in this run, and the last failure, for the panel.
    @Published private(set) var sent = 0
    @Published private(set) var failure: String?
    /// "active", "idle", "locked" or "asleep": what the last presence event said.
    @Published private(set) var presence: String?

    /// The session it publishes for; none while the Mac is lent to no mind.
    private(set) var session: MindSession?
    var readPresence: () -> Presence = { Presence(idleSeconds: 0, screenLocked: false, displayAsleep: false) }
    /// An event of the context, read back by the bridge for the current session.
    var heard: (ContextEvent) -> Void = { _ in }
    /// A line of the Activity window's log of every event (`ContextLog`): a reset, a page, an event.
    var heardLog: ([String: Any]) -> Void = { _ in }
    /// The Activity window is open: the bridge reads every event for it, and only then.
    private(set) var readsLog = false

    private let log = AppLog("device")
    /// The session's bridge, whose job `events` publishes.
    private var bridge: MindBridge?
    private var wasDown = false
    private var timer: Timer?
    private var monitors: [Any] = []
    private var lastMoveAt = Date.distantPast
    private var observers: [(NotificationCenter, NSObjectProtocol)] = []

    func start() {
        let timer = Timer(timeInterval: 2, repeats: true) { [weak self] _ in MainActor.assumeIsolated { self?.tick() } }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
        // A lock, an unlock, and displays that sleep or wake count at once, not at the next tick:
        // the recorder pauses the screens on this value. Again after half a second, in case the
        // session's dictionary says it a little later than the notification.
        let workspace = NSWorkspace.shared.notificationCenter, distributed = DistributedNotificationCenter.default()
        for (center, name) in [
            (distributed as NotificationCenter, Notification.Name("com.apple.screenIsLocked")),
            (distributed, Notification.Name("com.apple.screenIsUnlocked")),
            (workspace, NSWorkspace.screensDidSleepNotification), (workspace, NSWorkspace.screensDidWakeNotification),
        ] {
            observers.append((center, center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.tick() }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { MainActor.assumeIsolated { self?.tick() } }
            }))
        }
        watchInput()
        tick()
    }

    func stop() {
        timer?.invalidate()
        for (center, observer) in observers { center.removeObserver(observer) }
        monitors.forEach(NSEvent.removeMonitor)
        monitors = []
        endJob()
    }

    /// The path of the device's context in the mind, for the panel.
    var path: String? { session?.path }

    /// Another session and its bridge, or none: the old one's job ends now, and the new one's
    /// starts. The next `tick` says the presence to the new session.
    func use(_ session: MindSession?, bridge: MindBridge?) {
        endJob()
        self.session = session
        self.bridge = bridge
        guard let bridge else { return }
        bridge.on("events") { [weak self, weak bridge] line in
            // a line of an ended job, or of another session, changes nothing
            guard let self, let bridge, self.bridge === bridge else { return }
            self.said(line)
        }
        bridge.send("events", ["start": true])
        if readsLog { bridge.send("events", ["log": "start"]) }
        log.info("session \(session?.generation ?? 0): publishes to \(bridge.mind) at \(session?.path ?? "")")
    }

    // MARK: - Presence

    func tick() {
        guard session != nil else { return presence = nil }
        let now = readPresence()
        let state = now.screenLocked ? "locked" : now.displayAsleep ? "asleep" : now.idleSeconds >= Self.idleAfterSeconds ? "idle" : "active"
        guard state != presence else { return }
        var payload: [String: Any] = ["state": state, "idleSeconds": now.idleSeconds]
        if let presence { payload["was"] = presence }
        presence = state
        publish("device/presence-changed", payload, ephemeral: false)
        log.info("presence: \(state)")
    }

    // MARK: - Keyboard and mouse

    /// Global monitors see the keys and the mouse in every other app. Keys need the Accessibility
    /// permission of macOS; the mouse needs none.
    private func watchInput() {
        monitors.forEach(NSEvent.removeMonitor)
        monitors = []
        guard sharesInput else { return }
        let kinds: NSEvent.EventTypeMask = [.keyDown, .leftMouseDown, .rightMouseDown, .otherMouseDown, .scrollWheel, .mouseMoved, .leftMouseDragged]
        if let monitor = NSEvent.addGlobalMonitorForEvents(matching: kinds, handler: { [weak self] event in
            MainActor.assumeIsolated { self?.saw(event) }
        }) {
            monitors.append(monitor)
        }
        log.info("keyboard and mouse: shared\(Permission.accessibility.isGranted ? "" : ", but macOS has not given Accessibility, so no key arrives")")
    }

    private func saw(_ event: NSEvent) {
        let ephemeral = !keepsInput
        let point = NSEvent.mouseLocation
        let primary = NSScreen.screens.first?.frame.maxY ?? 0
        // points of the desktop from the top left of the first display, as Accessibility counts
        let place: [String: Any] = ["x": Int(point.x), "y": Int(primary - point.y)]
        switch event.type {
        case .keyDown:
            var payload: [String: Any] = ["keyCode": Int(event.keyCode), "isRepeat": event.isARepeat]
            if let key = event.charactersIgnoringModifiers, !key.isEmpty { payload["key"] = key }
            if let text = event.characters, !text.isEmpty { payload["text"] = text }
            let flags = event.modifierFlags
            let modifiers = [(NSEvent.ModifierFlags.command, "command"), (.option, "option"), (.control, "control"), (.shift, "shift")]
                .filter { flags.contains($0.0) }.map(\.1)
            if !modifiers.isEmpty { payload["modifiers"] = modifiers }
            if let app = NSWorkspace.shared.frontmostApplication?.localizedName { payload["app"] = app }
            publish("device/key-pressed", payload, ephemeral: ephemeral)
        case .leftMouseDown, .rightMouseDown, .otherMouseDown:
            var payload = place
            payload["button"] = event.type == .leftMouseDown ? "left" : event.type == .rightMouseDown ? "right" : "other"
            payload["clicks"] = event.clickCount
            if let app = NSWorkspace.shared.frontmostApplication?.localizedName { payload["app"] = app }
            publish("device/mouse-pressed", payload, ephemeral: ephemeral)
        case .scrollWheel:
            guard Date().timeIntervalSince(lastMoveAt) > 0.1 else { return }
            lastMoveAt = Date()
            var payload = place
            payload["dx"] = Int(event.scrollingDeltaX)
            payload["dy"] = Int(event.scrollingDeltaY)
            publish("device/scrolled", payload, ephemeral: ephemeral)
        case .mouseMoved, .leftMouseDragged:
            // at most ten a second: a mouse reports hundreds
            guard Date().timeIntervalSince(lastMoveAt) > 0.1 else { return }
            lastMoveAt = Date()
            publish("device/mouse-moved", place, ephemeral: ephemeral)
        default:
            break
        }
    }

    // MARK: - The events job

    /// One event on the device's context. Other parts of the app that tell the mind about the
    /// device publish through here, so that there is one connection and one path. With no
    /// session it goes nowhere; while the connection is down it waits in the bridge.
    func publish(_ type: String, _ payload: [String: Any], ephemeral: Bool, idempotencyKey: String? = nil) {
        guard let bridge else { return }
        var event: [String: Any] = ["type": type, "payload": payload]
        if ephemeral { event["ephemeral"] = true }
        if let idempotencyKey { event["idempotencyKey"] = idempotencyKey }
        bridge.send("events", ["event": event])
    }

    // MARK: - The Activity window's log

    /// The window opens (true) or closes (false): the bridge's read of every event starts or ends,
    /// with its subscription.
    func readLog(_ on: Bool) {
        guard on != readsLog else { return }
        readsLog = on
        bridge?.send("events", ["log": on ? "start" : "stop"])
        if !on || bridge == nil { heardLog(["reset": true]) }
    }

    /// The person scrolled to the end of the list: the page below `before`.
    func readOlder(before: Int) {
        bridge?.send("events", ["log": "older", "before": before])
    }

    private func said(_ said: [String: Any]) {
        if let line = said["log"] as? [String: Any] { return heardLog(line) }
        if let event = (said["event"] as? [String: Any]).flatMap(ContextEvent.init(json:)) { heard(event) }
        if let count = said["sent"] as? Int {
            sent = count
            failure = nil
        }
        if let why = said["failed"] as? String, said["job"] != nil {
            if failure != why { log.error("not published: \(why)") }
            failure = why
        }
        // the bridge connected again: the mind hears the presence of now, not of before
        if let up = said["connected"] as? Bool {
            if up, wasDown {
                log.info("connected again")
                failure = nil
                presence = nil
                tick()
            }
            wasDown = !up
        }
        // the process ended, or a new one started: the job starts again, and the presence with it
        if said["exited"] != nil { presence = nil }
        if said["started"] != nil {
            bridge?.send("events", ["start": true])
            if readsLog { bridge?.send("events", ["log": "start"]) }
            presence = nil
            tick()
        }
    }

    private func endJob() {
        // the job's end ends the log's read too; the window holds no event of the old context
        if readsLog { heardLog(["reset": true]) }
        bridge?.send("events", ["stop": true])
        bridge = nil
        presence = nil
        wasDown = false
    }
}

/// The panel's "Events to the mind": at the title's right what always goes (the presence, and the
/// app in front with its window's title), and in the card the one choice, keyboard and mouse.
struct DeviceEventsSection: View {
    @ObservedObject var events: DeviceEvents
    /// macOS has not given Accessibility: no key arrives.
    let accessibilityMissing: Bool
    let allow: (Permission) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            SectionTitle(title: "Events to the mind") {
                Text("Presence and the app in front: always")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .help(help)
            }
            Card(padding: 10) {
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: "keyboard")
                        .font(.system(size: 14))
                        .frame(width: 30, height: 18)
                        .foregroundStyle(events.sharesInput ? Palette.redText : Color.secondary)
                    VStack(alignment: .leading, spacing: 4) {
                        VStack(alignment: .leading, spacing: 1) {
                            Text("Keyboard and mouse").font(.system(size: 13))
                            Text(events.sharesInput ? "Every key goes to the mind, a password too" : "Every key you type, click, move and scroll")
                                .font(.system(size: 11))
                                .foregroundStyle(events.sharesInput ? Palette.redText : Color.secondary)
                                .lineLimit(1)
                        }
                        if events.sharesInput {
                            Toggle("Keep these events in the mind's log", isOn: $events.keepsInput)
                                .toggleStyle(.checkbox)
                                .font(.system(size: 12))
                                .accessibilityIdentifier("device.keep")
                                .help("Off: an event reaches whoever listens at that moment, and is in no log")
                            if accessibilityMissing {
                                MissingPermission(words: "macOS has not allowed Accessibility yet: no key arrives") { allow(.accessibility) }
                                    .padding(.top, 2)
                            }
                        }
                        if let failure = events.failure {
                            Text("Not published: \(failure)")
                                .font(.system(size: 11))
                                .foregroundStyle(Palette.waitText)
                                .lineLimit(2)
                                .textSelection(.enabled)
                        }
                    }
                    Spacer(minLength: 6)
                    Toggle("", isOn: $events.sharesInput).toggleStyle(.switch).controlSize(.small).labelsHidden()
                        .accessibilityIdentifier("device.input")
                }
            }
        }
    }

    /// The context and its count, for the title's help.
    private var help: String {
        let what = "The presence (idle, active, locked, asleep), and the app in front with its window's title, go to the mind always while the Mac is lent."
        guard let path = events.path else { return what }
        return "\(what) \(path) · \(events.sent) sent\(events.presence.map { " · now \($0)" } ?? "")"
    }
}
