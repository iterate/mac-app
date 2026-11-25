import AVFoundation
import AppKit
import Combine
import Record
import VoiceMeetCore

/// Answers the local endpoint's callers (a mind, through `iterate provide`) from the Mac's screen,
/// camera, microphone, speakers and accessibility, and runs commands for them. Each power is off
/// until the person turns it on in the menu. Nothing is written to disk.
@MainActor
final class AppModel {
    private(set) var microphone = MicrophoneState()
    /// How often a caller used each thing in this run (by `Shareable.id`), and the last use.
    private(set) var uses: [String: Int] = [:]
    private(set) var lastUse: (thing: Shareable, at: Date)?
    var onChange: (() -> Void)?

    private let log = AppLog("state")
    private let audioOwner = AudioOwner()
    private var cameras: [String: CameraUnit] = [:]
    private let endpoint = LocalEndpoint()
    private let speaker = Speaker()
    /// Banners on the screen, a call's among them: the window, the sound, a button's page.
    let banners = Banners()
    /// The person's approvals, for things whose choice is "Ask".
    let approval = Approval()
    /// What a mind did with this Mac, for the pill on the screen and the panel's list: a view of
    /// the device's context, whose events go and come back through `deviceEvents`.
    let acts = ActivityLog()
    /// What this Mac tells its mind about itself: presence, and keyboard and mouse when shared.
    let deviceEvents = DeviceEvents()
    /// The record of the screens, cameras, microphones and speakers, into the mind (`DeviceRecord`).
    let record = DeviceRecord()
    /// The window in front, as events: `device/app-focused`, `device/window-read` (`DeviceWindow`).
    let deviceWindow = DeviceWindow()
    /// Live: a member's page watches this Mac now (`DeviceLive`).
    let live = DeviceLive()
    /// The lent mind's OpenAI tokens, for dictation (`MindToken`).
    let mindToken = MindToken()
    private var presenceWatch: AnyCancellable?
    private var activity: NSObjectProtocol?
    private var microphoneHolders = 0
    private var isListening = false
    private(set) var session: MindSession?
    /// The session's bridge, held while the session lasts.
    private var bridge: MindBridge?
    /// False while the mind refuses this Mac's key: the lend's calls are refused.
    private(set) var isAuthorized = true
    /// The lend's phase and its line, for this Mac's page (`PagePowers`): the app's delegate holds the lend.
    var lendState: () -> [String: Any] = { [:] }
    /// The live views of this Mac's page that run now (`PagePowers.swift`).
    let pageStreams = PageStreams()

    /// True while any camera runs, for the mark in the menu bar.
    var isAnyCameraRunning: Bool { cameras.values.contains { $0.state.isRunning } }

    /// The panel's preview of one camera draws this layer.
    func cameraPreviewLayer(for id: String) -> CALayer { unit(id).owner.previewLayer }
    /// The camera's newest picture as JPEG bytes, while it runs.
    func cameraSnapshot(_ id: String, maxWidth: Int) -> Data? { cameras[id]?.owner.snapshot(maxWidth: maxWidth)?.data }

    init() {
        audioOwner.onEvent = { [weak self] event in self?.send(event) }
        endpoint.onRequest = { [weak self] method, parameters in try await self?.answer(method, parameters) ?? [:] }
    }

    /// Opens the local endpoint. Not in `init`: a copy of the app that only draws the panel to a
    /// file (`Panel.render`) must not take the running app's socket.
    func start() {
        endpoint.start()
        deviceEvents.readPresence = { Self.presence() }
        acts.publish = { [weak self] fact in self?.deviceEvents.publish(fact.type, fact.payload, ephemeral: false, idempotencyKey: fact.idempotencyKey) }
        deviceEvents.heard = { [weak self] event in self?.acts.heard(event) }
        deviceEvents.start()
        deviceWindow.publish = { [weak self] type, payload in self?.deviceEvents.publish(type, payload, ephemeral: false) }
        deviceWindow.isLent = { [weak self] in self?.deviceEvents.path != nil }
        deviceWindow.start()
        record.presence = { [weak self] in self?.deviceEvents.presence }
        // a lock pauses the screens at once: the record looks again as soon as presence changes
        // (on the next turn: `@Published` tells before it sets)
        presenceWatch = deviceEvents.$presence.removeDuplicates().sink { [weak self] _ in
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.record.tick() } }
        }
        live.peerMade = { [weak self] peer in self?.record.sink = peer }
        live.decide = { [weak self] who in await self?.liveTracks(who: who) ?? ([], "the app is closing") }
        live.sourcesChanged = { [weak self] sources in
            guard let self, sources != self.record.live else { return }
            self.record.live = sources
            self.record.tick()
        }
        live.began = { [weak self] who, tracks in
            self?.acts.began(.live, doing: "Watched live by \(who)", did: "Watched live by \(who)", detail: LiveSection.words(tracks)) ?? ""
        }
        live.finished = { [weak self] act, failure in self?.acts.ended(act, failure: failure) }
        record.start()
    }

    /// Another mind session, or none, or another authorization (`Lend.sessionChanged`). A refusal
    /// of this Mac's key ends every approval and refuses every call of the lend; the session's work
    /// goes on. Another session: the old one's approvals end, and its events, live, recorder and
    /// upload stop, all before any of them starts for the new one. The session holds its mind's
    /// bridge (`MindBridge`): the old one's process ends once no capture or input of it is left.
    func use(_ session: MindSession?, isAuthorized: Bool) {
        self.isAuthorized = isAuthorized
        if !isAuthorized { approval.refuse() }
        guard session != self.session else { return }
        self.session = session
        let old = bridge
        bridge = session.map(MindBridge.of)
        bridge?.hold("session")
        // live first: its watches end, and their byes, their records and their acts' ends go to
        // the old mind, before the device's events turn to the new one
        live.use(session, bridge: bridge)
        approval.use(session)
        deviceWindow.use(session)
        deviceEvents.use(session, bridge: bridge)
        record.use(session, bridge: bridge)
        acts.use(session)
        mindToken.use(session, bridge: bridge)
        // one hold for each name: the same bridge again keeps it
        if old !== bridge { old?.release("session") }
        deviceEvents.tick()
        record.tick()
    }

    func shutDown() {
        endpoint.stop()
        endPageStreams(why: "the app quits")
        live.stop()
        acts.stop()
        deviceEvents.stop()
        deviceWindow.stop()
        record.stop()
        // its stdin closes: the events that wait go, and the record's slot
        bridge?.release("session")
        audioOwner.stop()
        speaker.stop()
        banners.stop()
        cameras.values.forEach { $0.owner.stop() }
    }

    // MARK: - The local endpoint

    /// Whether a person is likely at this Mac now (VoiceMeetCore `Presence`): read at each
    /// `state()`, from calls that need no permission of macOS.
    private static func presence() -> Presence {
        // every kind of input: a key, a mouse move, a click, a scroll
        let anyInput = CGEventType(rawValue: ~0)!
        var displays = [CGDirectDisplayID](repeating: 0, count: 16)
        var count: UInt32 = 0
        if CGGetOnlineDisplayList(UInt32(displays.count), &displays, &count) != .success { count = 0 }
        return Presence.read(
            idle: CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: anyInput),
            session: CGSessionCopyCurrentDictionary() as? [String: Any],
            displaysAsleep: displays.prefix(Int(count)).map { CGDisplayIsAsleep($0) != 0 }
        )
    }

    /// A thing that is off, or whose permission macOS has not given, is a refusal with the reason.
    /// A thing on "Ask" waits for the person's approval. A caller can change no choice and can
    /// bring up no permission prompt: the person does both in the panel.
    private func answer(_ method: String, _ parameters: [String: Any]) async throws -> [String: Any] {
        guard isAuthorized else { throw EndpointRefusal("The mind refuses this Mac's key now: a member allows it again.") }
        let maxWidth = parameters["maxWidth"] as? Int ?? 1600
        switch method {
        case "state":
            return [
                "things": Shareable.all.map { thing -> [String: Any] in
                    var row: [String: Any] = [
                        "thing": thing.id, "kind": thing.power.rawValue, "name": thing.title,
                        "sharing": thing.sharing.rawValue, "permitted": thing.isPermitted, "uses": uses[thing.id] ?? 0,
                    ]
                    if thing.power == .screen { row["display"] = Screen.displays.firstIndex { Shareable.display($0) == thing } }
                    return row
                },
                "microphone": microphone.statusLine,
                "presence": Self.presence().dictionary,
                "record": ["recording": record.isRecording, "paused": record.isPaused, "line": record.line],
                "live": ["watchers": live.watchers.map(\.who)],
            ]
        case "record.state":
            return recordState()
        case "record.set":
            return try await setRecord(parameters)
        case "live.state":
            return live.state()
        case "live.end":
            // Ending a watch is no use of the Mac: always allowed.
            guard let watcher = parameters["watcher"] as? String, live.watchers.contains(where: { $0.id == watcher }) else {
                throw EndpointRefusal("live.end needs a watcher of live.state(): no such watcher now.")
            }
            live.end(watcher, why: "ended by a call to live.end")
            return live.state()
        case "screen.snapshot":
            let display = try Screen.resolve(parameters["display"] as? Int)
            return try await act(display, what: "A still picture of the display \"\(display.title)\".", doing: "Taking a picture of the display “\(display.title)”", did: "Took a picture of the display “\(display.title)”") {
                self.lend(try await Screen.snapshot(of: Screen.id(of: display), maxWidth: maxWidth), of: "the display \"\(display.title)\"")
            }
        case "camera.snapshot":
            let device = try Camera.resolve(parameters["camera"] as? String)
            let owner = unit(device.uniqueID).owner
            return try await act(.camera(device), what: "A still picture of the camera \"\(device.localizedName)\".", doing: "Taking a picture with the camera “\(device.localizedName)”", did: "Took a picture with the camera “\(device.localizedName)”") {
              try await self.withCamera(device.uniqueID) {
                // The first frames of a camera are dark: it sets its exposure for a moment.
                try await wait(seconds: 5, for: "the camera's first picture") { owner.hasPicture }
                try await Task.sleep(nanoseconds: 700_000_000)
                guard let picture = await owner.picture(maxWidth: maxWidth) else {
                    throw EndpointRefusal("The camera gave no picture.")
                }
                return self.lend(picture, of: "the camera \"\(device.localizedName)\"")
              }
            }
        case "microphone.listen":
            let seconds = min(max(parameters["seconds"] as? Double ?? 5, 0.5), 60)
            return try await act(.microphone, what: "\(String(format: "%.0f", seconds)) seconds of the microphone.", doing: "Listening to the microphone for \(String(format: "%.0f", seconds)) s", did: "Listened to the microphone for \(String(format: "%.0f", seconds)) s") {
              try await self.withMicrophone {
                // One recording at a time: a second caller waits for the first one's end.
                while self.isListening { try await Task.sleep(nanoseconds: 100_000_000) }
                self.isListening = true
                defer { self.isListening = false }
                let wave = await self.audioOwner.listen(seconds: seconds)
                self.log.info("endpoint: lent \(String(format: "%.1f", seconds)) s of the microphone, \(wave.count) bytes of WAV")
                return ["wavBase64": wave.base64EncodedString(), "seconds": seconds]
              }
            }
        case "speaker.play":
            guard let sound = Data(base64Encoded: parameters["soundBase64"] as? String ?? ""), !sound.isEmpty else {
                throw EndpointRefusal("speaker.play needs a sound: the bytes of a sound file.")
            }
            let player = try speaker.open(sound)
            return try await act(.speaker, what: "Play a sound of \(String(format: "%.1f", player.duration)) seconds through the speakers.", doing: "Playing a sound through the speakers", did: "Played a sound of \(String(format: "%.0f", player.duration)) s through the speakers") {
                self.log.info("endpoint: plays a sound of \(String(format: "%.1f", player.duration)) s, \(sound.count) bytes")
                try await self.speaker.play(player)
                return ["seconds": player.duration]
            }
        case "speaker.say":
            guard let words = parameters["words"] as? String, !words.isEmpty else {
                throw EndpointRefusal("speaker.say needs words.")
            }
            return try await act(.speaker, what: "Say through the speakers:\n\n\(words.prefix(700))", doing: "Speaking through the speakers", did: "Spoke through the speakers", detail: Self.oneLine(words)) {
                self.log.info("endpoint: says \(words.count) characters through the speakers")
                try await self.speaker.say(String(words.prefix(5_000)))
                return ["characters": min(words.count, 5_000)]
            }
        case "accessibility.frontWindow":
            return try await act(.accessibility, what: "The text and controls of the window in front.", doing: "Reading the text of the window in front", did: "Read the text of the window in front") {
                try await Accessibility.readFrontWindow(
                    maxDepth: parameters["maxDepth"] as? Int ?? 12,
                    maxNodes: parameters["maxNodes"] as? Int ?? 1_500
                )
            }
        case "run":
            guard let argv = parameters["argv"] as? [String] else {
                throw EndpointRefusal("run needs a command: argv is a list of strings.")
            }
            let stdin = Data(base64Encoded: parameters["stdinBase64"] as? String ?? "") ?? Data()
            let input = String(data: stdin, encoding: .utf8) ?? ""
            let shown = argv.joined(separator: " ").prefix(300) + (input.isEmpty ? "" : "\n\nWith this input:\n" + input.prefix(700))
            return try await act(
                .commands, what: "A command runs with this app’s permissions for the screen, the camera, the microphone and Accessibility.",
                asks: String(shown), doing: "Running a command", did: "Ran a command", detail: Self.oneLine(argv.joined(separator: " "))
            ) {
                self.log.info("endpoint: runs \(argv.joined(separator: " ").prefix(300))")
                return try await Commands.run(argv, stdin: stdin, timeout: parameters["timeoutSeconds"] as? Double ?? 120)
            }
        // No approval first: the banner is the question, and Ask and Shared both show it.
        case "banner.show":
            return try await shown(parameters, did: "Showed a banner") { try await self.banners.show(parameters) }
        case "call.ring":
            return try await shown(parameters, did: "Rang a call") { try await self.banners.ring(parameters) }
        case "pages.state", "pages.live.start", "pages.live.frame", "pages.live.stop":
            return try await pages(method, parameters)
        default:
            throw EndpointRefusal(
                "No method \"\(method)\". The methods are: state, screen.snapshot, camera.snapshot, microphone.listen, speaker.play, speaker.say, accessibility.frontWindow, run, banner.show, call.ring, record.state, record.set, live.state, live.end, pages.state, pages.live.start, pages.live.frame, pages.live.stop."
            )
        }
    }

    /// Refuses a thing that is off or not permitted, asks the person first when its choice is
    /// "Ask", then counts the use, so that the menu bar and the panel show it.
    /// `permitted`: in place of macOS's permission, for a source that needs none (the frame fixture).
    func use(_ thing: Shareable, what: String, asks detail: String? = nil, permitted: Bool? = nil) async throws {
        let round = approval.round
        switch UseGate.decide(sharing: thing.sharing.rawValue, permitted: permitted ?? thing.isPermitted, approved: approval.isApproved(thing) != nil) {
        case .off:
            throw EndpointRefusal("The Mac's owner has this off in the iterate panel: \(thing.title). A mind cannot \(thing.does).")
        case .notPermitted:
            throw EndpointRefusal(
                "macOS has not given this app \(thing.power.permission?.title ?? "a permission"). The Mac's owner gives it from the iterate panel, at \(thing.title)."
            )
        case .ask:
            try await approval.ask(for: thing, what: what, detail: detail)
            try stillAllowed(thing, in: round, permitted: permitted)
        case .go:
            break
        }
        count(thing)
    }

    /// After a question, which takes time: the use goes on only in the round it was asked in, while
    /// the mind allows this Mac's key, and while the thing is not turned off nor lost its permission.
    func stillAllowed(_ thing: Shareable, in round: ApprovalGrants.Round, permitted: Bool? = nil) throws {
        guard approval.holds(round), isAuthorized else {
            throw EndpointRefusal("The Mac is no longer lent to this mind, or the mind refused its key, while the owner was asked to \(thing.does).")
        }
        switch UseGate.decide(sharing: thing.sharing.rawValue, permitted: permitted ?? thing.isPermitted, approved: true) {
        case .off: throw EndpointRefusal("The Mac's owner turned \(thing.title) off while they were asked. A mind cannot \(thing.does).")
        case .notPermitted: throw EndpointRefusal("macOS took back \(thing.power.permission?.title ?? "a permission") while the owner was asked.")
        case .ask, .go: break
        }
    }

    // MARK: - Live

    /// The owner changed a choice in the panel: a watch that has a track whose thing is now Off
    /// (or lost its permission) ends at once, connected or still connecting. Ask and Shared go on:
    /// the watch was approved. A watch whose tracks are still being decided reads the choices
    /// again after its question (`liveTracks`).
    func liveChoicesChanged() {
        let cameras = Camera.devices.map(Shareable.camera)
        let things = { (track: String) -> [Shareable] in
            track == "camera-0" ? cameras : track == "mic-0" ? [.microphone] : Screen.displays.filter { "screen-\($0.id)" == track }.map(Shareable.display)
        }
        for watch in live.everyWatch {
            let off = watch.tracks.first { track in things(track).contains { $0.sharing == .off || !$0.isPermitted } }
            if let off { live.end(watch.id, why: "the owner turned \(off) off") }
        }
    }

    /// The tracks a watcher gets: a watch is a use of each display, the cameras and the
    /// microphone under their choices, through the same gate as every use (`UseGate`). Off: not
    /// offered. Ask: one question for the whole watch. Shared: offered. Live shows one camera,
    /// and goes by every camera's choice, as the record's switch does.
    private func liveTracks(who: String) async -> (tracks: [String], reason: String) {
        // (the watch is of the session it was asked in: `DeviceLive` drops an answer of an older one)
        let gate = { (thing: Shareable) in
            UseGate.decide(sharing: thing.sharing.rawValue, permitted: thing.isPermitted, approved: self.approval.isApproved(thing) != nil)
        }
        let read = { () -> (things: [(track: String, things: [Shareable])], gates: [(track: String, gate: UseGate)]) in
            let cameras = Camera.devices.map(Shareable.camera)
            let things: [(track: String, things: [Shareable])] =
                Screen.displays.map { ("screen-\($0.id)", [Shareable.display($0)]) } + [("camera-0", cameras), ("mic-0", [.microphone])]
            return (things, things.map { (track: $0.track, gate: UseGate.strictest($0.things.map(gate))) })
        }
        var (things, gates) = read()
        let asked = LiveTracks.asks(gates)
        var tracks = LiveTracks.offered(gates, approved: false)
        var approved = false
        if asked {
            let asking = zip(things, gates).filter { $0.1.gate == .ask }.flatMap { $0.0.things }
            let names = asking.map(\.title).joined(separator: ", ")
            do {
                try await approval.ask(for: asking, does: "show this Mac live to \(who)", what: "\(who) wants to watch this Mac live: \(names). It lasts until they leave or you end it in the panel.")
                approved = true
            } catch {
                log.info("live: \(who) is not approved: \(AppLog.describe(error))")
            }
            // the question took time: the owner may have changed a choice, or the round ended
            let before = gates
            (things, gates) = read()
            tracks = LiveTracks.offered(asked: before, now: gates, approved: approved)
        }
        for item in things where tracks.contains(item.track) { item.things.forEach(count) }
        return (tracks, LiveTracks.nothing(asked: asked, approved: approved))
    }

    // MARK: - The record's switches

    /// The record's switches and its state, for `state()` and `record.state()`. Reading it is no use.
    func recordState() -> [String: Any] {
        var answer = record.state()
        answer["windowText"] = deviceWindow.readsWindowText
        return answer
    }

    private var recordOn: Set<RecordSwitch> {
        var on = Set(record.on.compactMap { RecordSwitch(rawValue: $0.rawValue) })
        if deviceWindow.readsWindowText { on.insert(.windowText) }
        return on
    }

    /// `record.set`: a switch turned off is off at once; a switch turned on is a use of its power,
    /// under that power's choice in the panel (`use`), for each display or camera it records. The
    /// switches turned off stay off when a use is then refused; no switch is turned on then.
    private func setRecord(_ parameters: [String: Any]) async throws -> [String: Any] {
        var wanted: [RecordSwitch: Bool] = [:]
        for item in RecordSwitch.allCases {
            guard let value = parameters[item.rawValue] else { continue }
            guard let on = value as? Bool else { throw EndpointRefusal("record.set: \(item.rawValue) is true or false.") }
            wanted[item] = on
        }
        let unknown = Set(parameters.keys).subtracting(RecordSwitch.allCases.map(\.rawValue) + ["method"])
        guard unknown.isEmpty else {
            throw EndpointRefusal("record.set knows screens, cameras, mics, speakers and windowText, not \(unknown.sorted().joined(separator: ", ")).")
        }
        let on = recordOn
        for item in RecordSwitch.turnedOff(from: on, by: wanted) { setRecordSwitch(item, false) }
        let turnedOn = RecordSwitch.turnedOn(from: on, by: wanted)
        for item in turnedOn {
            let things = recordThings(item)
            guard !things.isEmpty else { throw EndpointRefusal("This Mac has nothing to \(item.does) now.") }
            for thing in things {
                try await use(thing, what: "To \(item.does) into the mind, \(thing.title) among them, until it is switched off in the panel or by a call.")
            }
        }
        for item in turnedOn {
            setRecordSwitch(item, true)
            let symbol = DeviceRecord.switches.first { $0.source.rawValue == item.rawValue }?.symbol ?? "text.viewfinder"
            let act = Shareable(id: "record.\(item.rawValue)", power: .screen, title: item.rawValue, does: item.does, symbol: symbol)
            let words = item.does.prefix(1).uppercased() + item.does.dropFirst()
            acts.ended(acts.began(act, doing: "\(words) until switched off", did: "Turned on: \(item.does) until switched off"))
        }
        return recordState()
    }

    private func setRecordSwitch(_ item: RecordSwitch, _ value: Bool) {
        log.info("endpoint: a caller turns the record's \(item.rawValue) \(value ? "on" : "off")")
        if item == .windowText {
            deviceWindow.readsWindowText = value
        } else if let source = RecordSource(rawValue: item.rawValue) {
            record.set(source, value)
        }
    }

    /// The things whose choice decides a switch: every display for the screens and the speakers
    /// (the record has them all), every camera, the microphone, the window text.
    private func recordThings(_ item: RecordSwitch) -> [Shareable] {
        switch item.power {
        case "screen": return Screen.displays.map(Shareable.display)
        case "camera": return Camera.devices.map(Shareable.camera)
        case "microphone": return [.microphone]
        default: return [.accessibility]
        }
    }

    /// One act of a caller with `thing`: `use` first, then `body`, and the person sees it in the
    /// pill on the screen and in the panel's list, from its start to its end. A refusal before
    /// the act (the thing is off, the person said no) is no act.
    private func act(
        _ thing: Shareable, what: String, asks: String? = nil, doing: String, did: String, detail: String? = nil,
        _ body: () async throws -> [String: Any]
    ) async throws -> [String: Any] {
        // what the question shows in monospace: the command and its input, else the act's detail
        try await use(thing, what: what, asks: asks ?? detail)
        let id = acts.began(thing, doing: doing, did: did, detail: detail)
        do {
            let answer = try await body()
            acts.ended(id)
            return answer
        } catch {
            acts.ended(id, failure: Self.oneLine(AppLog.describe(error), limit: 90))
            throw error
        }
    }

    /// A banner or a call: it has its own window, so the list has it and the pill is short.
    private func shown(_ parameters: [String: Any], did: String, _ body: () async throws -> [String: Any]) async throws -> [String: Any] {
        guard Shareable.banners.sharing != .off else { return try await body() }
        count(.banners)
        let id = acts.began(.banners, doing: did, did: did, detail: (parameters["title"] as? String).map { Self.oneLine($0) })
        // the answer comes when the person presses a button: the act for the list is the showing
        acts.ended(id)
        return try await body()
    }

    /// Words on one line, cut: for a line of the activity list.
    static func oneLine(_ words: String, limit: Int = 160) -> String {
        let line = words.split(whereSeparator: \.isNewline).joined(separator: " ")
        return line.count > limit ? line.prefix(limit) + "…" : line
    }

    /// One use of `thing`, for the menu bar and the panel.
    private func count(_ thing: Shareable) {
        uses[thing.id, default: 0] += 1
        lastUse = (thing, Date())
        log.info("endpoint: a caller uses \(thing.id) (\(thing.title)), use \(uses[thing.id] ?? 0) of this run")
        onChange?()
    }

    /// Runs `body` with one camera on.
    private func withCamera<Answer>(_ id: String, _ body: () async throws -> Answer) async throws -> Answer {
        holdCamera(id)
        defer { releaseCamera(id) }
        try await wait(seconds: 10, for: "the camera") { self.unit(id).state.isOn }
        return try await body()
    }

    /// A camera runs while it has a holder: a caller's snapshot, or the panel's preview while the
    /// panel is open. It stops when the last holder lets go.
    func holdCamera(_ id: String) {
        let unit = unit(id)
        unit.holders += 1
        if !unit.state.isRunning { send(.startRequested, to: id) }
    }

    func releaseCamera(_ id: String) {
        let unit = unit(id)
        unit.holders = max(0, unit.holders - 1)
        if unit.holders == 0 { send(.stopRequested, to: id) }
    }

    /// Each camera has its own state machine and its own owner, so several can run at once.
    private final class CameraUnit {
        var state = CameraState()
        var holders = 0
        let owner: Camera

        init(_ owner: Camera) {
            self.owner = owner
        }
    }

    private func unit(_ id: String) -> CameraUnit {
        if let unit = cameras[id] { return unit }
        let unit = CameraUnit(Camera(deviceID: id))
        unit.owner.onEvent = { [weak self] event in self?.send(event, to: id) }
        cameras[id] = unit
        return unit
    }

    /// Runs `body` with the microphone on. The microphone runs while it has a holder (a call), and
    /// stops when the last one lets go.
    private func withMicrophone<Answer>(_ body: () async throws -> Answer) async throws -> Answer {
        microphoneHolders += 1
        if !microphone.isRunning { send(MicrophoneEvent.startRequested) }
        defer {
            microphoneHolders -= 1
            if microphoneHolders == 0 { send(MicrophoneEvent.stopRequested) }
        }
        try await wait(seconds: 10, for: "the microphone") { self.microphone.phase == .on }
        // The engine starts twice on a Mac (the README's "Notes from the first runs"): let it settle.
        try await Task.sleep(nanoseconds: 1_500_000_000)
        try await wait(seconds: 10, for: "the microphone") { self.microphone.phase == .on }
        return try await body()
    }

    /// Waits, at most `seconds`, until `isReady`. The wait is bounded: a refusal names what did not come.
    private func wait(seconds: Double, for what: String, until isReady: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(seconds)
        while !isReady() {
            guard Date() < deadline else { throw EndpointRefusal("Gave up after \(Int(seconds)) s of waiting for \(what).") }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
    }

    private func lend(_ picture: (data: Data, width: Int, height: Int), of source: String) -> [String: Any] {
        log.info("endpoint: lent a picture of \(source), \(picture.width) × \(picture.height) px, \(picture.data.count) bytes of JPEG")
        return [
            "jpegBase64": picture.data.base64EncodedString(),
            "pixelWidth": picture.width,
            "pixelHeight": picture.height,
        ]
    }

    // MARK: - The two state machines

    private func send(_ event: MicrophoneEvent) {
        let effects = microphone.handle(event)
        log.info("microphone: \(Self.short(event)) -> \(Self.short(microphone.phase))\(Self.list(effects))")
        for effect in effects {
            switch effect {
            // `use` has checked the permission; a caller brings up no prompt.
            case .checkAccess: send(Permission.microphone.isGranted ? MicrophoneEvent.accessGranted : .accessDenied)
            case .startEngine: audioOwner.start()
            case .stopEngine: audioOwner.stop()
            case .restartEngine: audioOwner.restart()
            case .setMuted(let isMuted): audioOwner.setMuted(isMuted)
            }
        }
        stateDidChange()
    }

    private func send(_ event: CameraEvent, to id: String) {
        let unit = unit(id)
        let effects = unit.state.handle(event)
        log.info("camera \(id.suffix(6)): \(Self.short(event)) -> \(Self.short(unit.state.phase))\(Self.list(effects))")
        for effect in effects {
            switch effect {
            case .checkAccess: send(Permission.camera.isGranted ? .accessGranted : .accessDenied, to: id)
            case .startSession: unit.owner.start()
            case .stopSession: unit.owner.stop()
            }
        }
        stateDidChange()
    }

    /// One activity token while the microphone or the camera runs, so App Nap does not slow them.
    private func stateDidChange() {
        let isBusy = microphone.isRunning || isAnyCameraRunning
        if isBusy, activity == nil {
            activity = ProcessInfo.processInfo.beginActivity(
                options: [.userInitiated, .latencyCritical],
                reason: "The microphone or the camera is in use"
            )
        } else if !isBusy, let token = activity {
            ProcessInfo.processInfo.endActivity(token)
            activity = nil
        }
        onChange?()
    }

    /// `String(describing:)` puts the module's name before every type; the log is easier to read without.
    private static func short(_ value: Any) -> String {
        String(describing: value).replacingOccurrences(of: "VoiceMeetCore.", with: "")
    }

    private static func list(_ effects: [Any]) -> String {
        effects.isEmpty ? "" : "; effects: " + effects.map(short).joined(separator: ", ")
    }
}
