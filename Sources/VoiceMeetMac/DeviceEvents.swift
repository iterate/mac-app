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
    /// A person is taken as away after this long with no key, click or move (`Presence`).
    static let idleAfterSeconds = Presence.idleAfterSeconds

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
    /// How many events went to the mind in this run, for the help of the panel's title. Not
    /// published: the bridge says a new count for each batch of keys and moves, and the panel
    /// (also a closed one) would lay itself out again for each. An open panel reads it when it draws.
    private(set) var sent = 0
    /// The last failure, for the panel: set only when it changes.
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
    /// The events job started, or its connection came again: the facts of now are said again
    /// (the offer to be driven, `ControlOffer`). The presence is said by `tick`.
    var jobStarted: () -> Void = {}

    private let log = AppLog("device")
    /// The session's bridge, whose job `events` publishes.
    private var bridge: MindBridge?
    private var wasDown = false
    /// The one next look at the presence (`tick`).
    private var nextLook: Timer?
    /// While idle, the monitor of the person's return.
    private var returnWatch: Any?
    private var monitors: [Any] = []
    /// The app in front and whether its focus is a password field, kept between keys.
    private let focus = FocusWatch()
    private var lastMoveAt = Date.distantPast
    private var observers: [(NotificationCenter, NSObjectProtocol)] = []

    func start() {
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
        nextLook?.invalidate()
        nextLook = nil
        endWatchForReturn()
        for (center, observer) in observers { center.removeObserver(observer) }
        observers = []
        monitors.forEach(NSEvent.removeMonitor)
        monitors = []
        focus.stop()
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
        jobStarted()
        log.info("session \(session?.generation ?? 0): publishes to \(bridge.mind) at \(session?.path ?? "")")
    }

    // MARK: - Presence

    /// Reads the presence, says it when it changed, and sets the one next look (`Presence.nextLookSeconds`):
    /// at the moment an active person would turn idle, else an input, an unlock or a wake says the
    /// change. No look runs while the Mac is lent to no mind.
    func tick() {
        Perf.count("presenceLooks")
        nextLook?.invalidate()
        nextLook = nil
        guard session != nil else {
            endWatchForReturn()
            return presence = nil
        }
        let now = readPresence()
        let state = now.state
        let look = Timer(timeInterval: TimeInterval(now.nextLookSeconds), repeats: false) { [weak self] _ in MainActor.assumeIsolated { self?.tick() } }
        // a look a little late is the same look: the system joins it with other wake-ups
        look.tolerance = state == "active" ? 1 : 10
        RunLoop.main.add(look, forMode: .common)
        nextLook = look
        if state == "idle" { watchForReturn() } else { endWatchForReturn() }
        guard state != presence else { return }
        var payload: [String: Any] = ["state": state, "idleSeconds": now.idleSeconds]
        if let presence { payload["was"] = presence }
        presence = state
        publish("device/presence-changed", payload, ephemeral: false)
        log.info("presence: \(state)")
    }

    /// While idle: the first key, click, move or scroll in any app looks again at once. Keys need
    /// Accessibility; the mouse needs none.
    private func watchForReturn() {
        guard returnWatch == nil else { return }
        let kinds: NSEvent.EventTypeMask = [.mouseMoved, .leftMouseDown, .rightMouseDown, .otherMouseDown, .scrollWheel, .keyDown, .flagsChanged]
        returnWatch = NSEvent.addGlobalMonitorForEvents(matching: kinds) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.endWatchForReturn()
                self?.tick()
            }
        }
    }

    private func endWatchForReturn() {
        if let returnWatch { NSEvent.removeMonitor(returnWatch) }
        returnWatch = nil
    }

    // MARK: - Keyboard and mouse

    /// Global monitors see the keys and the mouse in every other app. Keys need the Accessibility
    /// permission of macOS; the mouse needs none.
    private func watchInput() {
        monitors.forEach(NSEvent.removeMonitor)
        monitors = []
        guard sharesInput else { return focus.stop() }
        focus.start()
        let kinds: NSEvent.EventTypeMask = [.keyDown, .leftMouseDown, .rightMouseDown, .otherMouseDown, .scrollWheel, .mouseMoved, .leftMouseDragged]
        if let monitor = NSEvent.addGlobalMonitorForEvents(matching: kinds, handler: { [weak self] event in
            MainActor.assumeIsolated { self?.saw(event) }
        }) {
            monitors.append(monitor)
        }
        log.info("keyboard and mouse: shared\(Permission.accessibility.isGranted ? "" : ", but macOS has not given Accessibility, so no key arrives")")
    }

    /// One event of the global monitor; a test copy's `perf.input` gives its own.
    func saw(_ event: NSEvent) {
        Perf.count("inputSeen")
        // a move or a scroll inside 0.1 s of the last one is dropped before anything is read
        if [.mouseMoved, .leftMouseDragged, .scrollWheel].contains(event.type) {
            let now = Date()
            guard now.timeIntervalSince(lastMoveAt) > 0.1 else { return }
            lastMoveAt = now
        }
        let ephemeral = !keepsInput
        let point = NSEvent.mouseLocation
        let primary = NSScreen.screens.first?.frame.maxY ?? 0
        // points of the desktop from the top left of the first display, as Accessibility counts
        let place: [String: Any] = ["x": Int(point.x), "y": Int(primary - point.y)]
        switch event.type {
        case .keyDown:
            // a key typed into a password goes to no mind, not even as a key code (`SecretKeys`)
            guard !focus.isSecret() else { return }
            var payload: [String: Any] = ["keyCode": Int(event.keyCode), "isRepeat": event.isARepeat]
            if let key = event.charactersIgnoringModifiers, !key.isEmpty { payload["key"] = key }
            if let text = event.characters, !text.isEmpty { payload["text"] = text }
            let flags = event.modifierFlags
            let modifiers = [(NSEvent.ModifierFlags.command, "command"), (.option, "option"), (.control, "control"), (.shift, "shift")]
                .filter { flags.contains($0.0) }.map(\.1)
            if !modifiers.isEmpty { payload["modifiers"] = modifiers }
            if let app = focus.current()?.name { payload["app"] = app }
            publish("device/key-pressed", payload, ephemeral: ephemeral)
        case .leftMouseDown, .rightMouseDown, .otherMouseDown:
            var payload = place
            payload["button"] = event.type == .leftMouseDown ? "left" : event.type == .rightMouseDown ? "right" : "other"
            payload["clicks"] = event.clickCount
            if let app = focus.current()?.name { payload["app"] = app }
            publish("device/mouse-pressed", payload, ephemeral: ephemeral)
        case .scrollWheel:
            var payload = place
            payload["dx"] = Int(event.scrollingDeltaX)
            payload["dy"] = Int(event.scrollingDeltaY)
            publish("device/scrolled", payload, ephemeral: ephemeral)
        case .mouseMoved, .leftMouseDragged:
            // at most ten a second (above): a mouse reports hundreds
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
        Perf.count("published")
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
            if failure != nil { failure = nil }
        }
        if let why = said["failed"] as? String, said["job"] != nil, failure != why {
            log.error("not published: \(why)")
            failure = why
        }
        // the bridge connected again: the mind hears the presence of now, not of before
        if let up = said["connected"] as? Bool {
            if up, wasDown {
                log.info("connected again")
                if failure != nil { failure = nil }
                presence = nil
                tick()
                jobStarted()
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
            jobStarted()
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
        let _ = Perf.count("eventsSectionBodies")
        VStack(alignment: .leading, spacing: 7) {
            SectionTitle(title: "Events to the mind") {
                TitleNote("Presence and the app in front: always").help(help)
            }
            Card {
                HStack(alignment: .center, spacing: 8) {
                    Image(systemName: "keyboard")
                        .font(.system(size: 13, weight: .regular))
                        .frame(width: Theme.Metric.leadColumn)
                        .foregroundStyle(events.sharesInput ? Theme.liveText : Theme.t2)
                    VStack(alignment: .leading, spacing: 1) {
                        Text("Keyboard and mouse").font(.system(size: Theme.Size.row))
                        Text(events.sharesInput ? "Every key goes to the mind, but never a password" : "Every key you type, click, move and scroll")
                            .font(.system(size: 11))
                            .foregroundStyle(events.sharesInput ? Theme.liveText : Theme.t3)
                            .lineLimit(1)
                    }
                    Spacer(minLength: 6)
                    PanelSwitch(title: "Keyboard and mouse", isOn: $events.sharesInput)
                        .accessibilityIdentifier("device.input")
                }
                .padding(.leading, 6)
                .padding(.trailing, 8)
                .frame(minHeight: 42)
                VStack(alignment: .leading, spacing: 8) {
                    if events.sharesInput {
                        Toggle("Keep these events in the mind's log", isOn: $events.keepsInput)
                            .toggleStyle(.checkbox)
                            .font(.system(size: 12))
                            .tint(Theme.accent)
                            .accessibilityIdentifier("device.keep")
                            .help("Off: an event reaches whoever listens at that moment, and is in no log")
                        if accessibilityMissing {
                            MissingPermission(words: "macOS has not allowed Accessibility yet: no key arrives") { allow(.accessibility) }
                        }
                    }
                    if let failure = events.failure {
                        Text("Not published: \(failure)")
                            .font(.system(size: 11))
                            .foregroundStyle(Theme.warnText)
                            .lineLimit(2)
                            .textSelection(.enabled)
                    }
                }
                .padding(.leading, 44)
                .padding(.trailing, 8)
                .padding(.bottom, events.sharesInput || events.failure != nil ? 8 : 0)
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
