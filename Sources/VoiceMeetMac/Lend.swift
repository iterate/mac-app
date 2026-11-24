import AppKit
import Foundation
import Network
import VoiceMeetCore

/// The lend of this Mac to one mind, kept by the app: it runs `iterate provide` of the bridge file
/// with the active mind's key and `--json`, as `npx @iterate-com/mac-app` set it up. `LendState`
/// turns the CLI's states (stdout) and the process's end into a phase and says what to do: start the process now, end it, or
/// start it after a wait. The app starts again at once when the Mac wakes and when the network
/// comes back. It watches its folder: a change of config.json (the panel's `use` and `remove`,
/// which the app writes itself, or the CLI's `add`) switches the lend. It owns the mind session (`MindSession`) and the lend's authorization:
/// the session changes when another mind is selected or the mind is removed; the authorization
/// ends while the mind refuses this Mac's key. `sessionChanged` says both, before the lend process
/// for a new mind starts. Once an hour it asks npm for a newer version and runs its `update`,
/// unless it was built from an owner's copy (`UpdateSource`).
@MainActor
final class Lend {
    /// One mind this Mac knows, with its own key.
    struct Mind: Decodable, Equatable {
        let mind: String
        let name: String
        let keyFile: String
    }

    /// What `npx @iterate-com/mac-app` wrote (cli.mjs `setup`, `add`, `use`, `remove`).
    struct Config: Decodable {
        let login: Bool
        let spec: String
        let node: String
        let iterateBin: String
        let bridge: String
        let version: String
        /// The installed copy of cli.mjs: the panel runs its commands.
        let cli: String
        /// The owner's copy the app was built from (`init`), when it was: see `UpdateSource`.
        let copy: String?
        let minds: [Mind]
        let active: String?

        private enum Keys: String, CodingKey {
            case login, spec, node, iterateBin, bridge, version, cli, copy, minds, active, mind, name, keyFile
        }

        init(from decoder: Decoder) throws {
            let values = try decoder.container(keyedBy: Keys.self)
            login = try values.decodeIfPresent(Bool.self, forKey: .login) ?? false
            spec = try values.decode(String.self, forKey: .spec)
            node = try values.decode(String.self, forKey: .node)
            iterateBin = try values.decode(String.self, forKey: .iterateBin)
            bridge = try values.decode(String.self, forKey: .bridge)
            version = try values.decode(String.self, forKey: .version)
            cli = try values.decodeIfPresent(String.self, forKey: .cli) ?? AppEnvironment.current.folder.appendingPathComponent("source/cli.mjs").path
            copy = try values.decodeIfPresent(String.self, forKey: .copy)
            if let minds = try values.decodeIfPresent([Mind].self, forKey: .minds) {
                self.minds = minds
                active = try values.decodeIfPresent(String.self, forKey: .active)
            } else {
                // the form before several minds; the CLI moves it at its next run
                let mind = try values.decode(String.self, forKey: .mind)
                minds = [Mind(mind: mind, name: try values.decode(String.self, forKey: .name), keyFile: try values.decode(String.self, forKey: .keyFile))]
                active = mind
            }
        }

        var activeMind: Mind? { minds.first { $0.mind == active } }

        var source: UpdateSource { .of(spec: spec, copy: copy, version: version) }
    }

    private(set) var state = LendState()
    private(set) var config: Config?
    /// The last words of what the panel did (`use`, `remove`, the CLI's `add`), and a link `add` printed.
    private(set) var commandLine: String?
    private(set) var commandLink: String?
    private(set) var isCommandRunning = false
    /// Node, the iterate CLI and the bridge's scripts of this config, resolved at each read of it.
    private(set) var helpers: MindSession.Helpers?
    /// The session of the mind this Mac is lent to, or none.
    var session: MindSession? { sessions.current }
    /// False while the mind refuses this Mac's key; the session stays.
    var isAuthorized: Bool { sessions.isAuthorized }
    /// The session changed (a new generation, or none), or the authorization did. Called once for
    /// each change.
    var sessionChanged: (_ session: MindSession?, _ isAuthorized: Bool) -> Void = { _, _ in }
    var onChange: (() -> Void)?
    /// True while a capture runs: an update waits for its end.
    var isBusy: () -> Bool = { false }

    private let log = AppLog("lend")
    private var sessions = MindSessions()
    private var process: Process?
    /// Goes up with each process: the end or a line of an older one changes nothing.
    private var generation = 0
    private var startedAt = Date()
    /// What each pipe printed after its last whole line.
    private var pending: [Stream: String] = [:]
    private enum Stream { case states, human }
    private var wait: DispatchWorkItem?
    private var updateTimer: Timer?
    private var ticker: Timer?
    private var folderWatch: DispatchSourceFileSystemObject?
    private var reloadSoon: DispatchWorkItem?
    private let network = NWPathMonitor()
    private var networkIsUp = true
    private var wakeObserver: NSObjectProtocol?

    var activeMind: Mind? { config?.activeMind }

    func start() {
        reload(isStart: true)
        watchFolder()
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.send(.reconnectNow(why: "the Mac woke from sleep")) }
        }
        network.pathUpdateHandler = { [weak self] path in
            let isUp = path.status == .satisfied
            Task { @MainActor in self?.networkChanged(isUp: isUp) }
        }
        network.start(queue: .main)
        // the panel's "next try in" counts down
        let ticker = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                switch self.state.phase {
                case .reconnecting, .stopped, .notAllowed, .incompatible: self.onChange?()
                default: break
                }
            }
        }
        RunLoop.main.add(ticker, forMode: .common)
        self.ticker = ticker
        let timer = Timer(timeInterval: 3600, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.checkForUpdate() }
        }
        RunLoop.main.add(timer, forMode: .common)
        updateTimer = timer
        DispatchQueue.main.asyncAfter(deadline: .now() + 60) { [weak self] in self?.checkForUpdate() }
    }

    func stop() {
        send(.stopRequested)
        network.cancel()
    }

    /// The owner opened the panel: a lend that waits for its next start starts at once.
    func panelOpened() {
        send(.panelOpened)
    }

    /// The panel's "Reconnect now".
    func reconnectNow() {
        send(.reconnectNow(why: "the person pressed Reconnect now"))
    }

    // MARK: - The state machine and its effects

    private func send(_ event: LendEvent) {
        let before = state.phase
        let effects = state.handle(event, now: Date())
        if state.phase != before {
            log.info("\(Self.describe(event)) -> \(state.phase.name): \(state.statusLine(now: Date(), clock: Self.clock))")
        }
        // the old session's work ends before a process for another mind starts
        let selected = config?.activeMind.flatMap { mind in helpers.map { MindSession.Selected(mind: mind.mind, name: mind.name, helpers: $0) } }
        let changed = sessions.update(selected: selected, phase: state.phase)
        if changed.session {
            log.info(sessions.current.map { "session \($0.generation): \($0.mind) as itx.\($0.name)" } ?? "no session: no mind is selected")
        }
        if changed.authorization {
            log.info(sessions.isAuthorized ? "the mind lets this Mac's key in again" : "the mind refuses this Mac's key: the lend's powers and approvals end; the session stays")
        }
        if changed.session || changed.authorization { sessionChanged(sessions.current, sessions.isAuthorized) }
        for effect in effects {
            switch effect {
            case .startProcess:
                endProcess()
                run()
            case .stopProcess:
                endProcess()
            case .startProcessAfter(let seconds):
                cancelWait()
                let item = DispatchWorkItem { [weak self] in self?.send(.timerFired) }
                wait = item
                // by the wall clock: a monotonic deadline stretches by the time the Mac slept
                DispatchQueue.main.asyncAfter(wallDeadline: .now() + .seconds(seconds), execute: item)
            }
        }
        onChange?()
    }

    private func cancelWait() {
        wait?.cancel()
        wait = nil
    }

    /// Ends the process, if one runs, and the wait. Its end is not an event: a newer process, or
    /// none, is the lend now.
    private func endProcess() {
        cancelWait()
        generation += 1
        pending = [:]
        if let process, process.isRunning {
            log.info("ends the lend process \(process.processIdentifier)")
            process.terminate()
        }
        process = nil
    }

    private func run() {
        guard let config, let mind = config.activeMind else { return send(.stopRequested) }
        guard AppEnvironment.current.lends else {
            log.info("no lend: a home of its own lends only with --lend")
            return send(.stopRequested)
        }
        guard FileManager.default.isExecutableFile(atPath: config.node) else {
            send(.humanLine("Node is gone from \(config.node): run npx @iterate-com/mac-app again"))
            return send(.processEnded(status: -1, ranFor: 0))
        }
        let child = Process()
        child.executableURL = URL(fileURLWithPath: config.node)
        child.arguments = [config.iterateBin, "provide", config.bridge, "--key", mind.keyFile, "--name", mind.name, "--mind", mind.mind, "--json"]
        var environment = ProcessInfo.processInfo.environment
        environment["ITERATE_MAC_APP_SUPERVISED"] = "1"
        child.environment = environment
        // stdout carries the states, one JSON object per line; stderr the lines for a person
        let states = Pipe()
        let human = Pipe()
        child.standardOutput = states
        child.standardError = human
        let generation = generation
        for (pipe, stream) in [(states, Stream.states), (human, Stream.human)] {
            pipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
                let data = handle.availableData
                guard !data.isEmpty else { return handle.readabilityHandler = nil }
                let text = String(decoding: data, as: UTF8.self)
                Task { @MainActor in self?.read(text, from: stream, of: generation) }
            }
        }
        child.terminationHandler = { [weak self] ended in
            let status = ended.terminationStatus
            // after the last of its output: the pipe's reader runs on another queue
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                MainActor.assumeIsolated {
                    guard let self, generation == self.generation else { return }
                    self.read("\n", from: .states, of: generation)
                    self.read("\n", from: .human, of: generation)
                    self.process = nil
                    self.log.info("the lend process ended (exit \(status))")
                    self.send(.processEnded(status: status, ranFor: Date().timeIntervalSince(self.startedAt)))
                }
            }
        }
        do {
            try child.run()
            process = child
            startedAt = Date()
            log.info("lends to \(mind.mind) as itx.\(mind.name): process \(child.processIdentifier)")
        } catch {
            send(.humanLine("the lend did not start: \(AppLog.describe(error))"))
            send(.processEnded(status: -1, ranFor: 0))
        }
    }

    /// Whole lines only: a chunk of the pipe can end in the middle of one. Both streams go to the
    /// log; the human lines stay there as the CLI wrote them.
    private func read(_ text: String, from stream: Stream, of generation: Int) {
        guard generation == self.generation else { return }
        var lines = ((pending[stream] ?? "") + text).components(separatedBy: "\n")
        pending[stream] = lines.removeLast()
        for line in lines {
            if !line.isEmpty { log.info("provide\(stream == .states ? " state" : ""): \(line.prefix(400))") }
            send(stream == .states ? .stateLine(line) : .humanLine(line))
        }
    }

    private func networkChanged(isUp: Bool) {
        guard isUp != networkIsUp else { return }
        networkIsUp = isUp
        log.info("the network is \(isUp ? "back" : "gone")")
        if isUp { send(.networkCameBack) }
    }

    // MARK: - The config and the CLI's commands

    /// Reads config.json again. A new active mind, or new paths to run with, start the lend anew.
    private func reload(isStart: Bool = false) {
        let file = AppEnvironment.current.folder.appendingPathComponent("config.json")
        let old = config
        do {
            config = try JSONDecoder().decode(Config.self, from: Data(contentsOf: file))
        } catch {
            config = nil
            helpers = nil
            if isStart || old != nil { log.info("not set up: \(file.path) does not read (\(AppLog.describe(error))); run npx @iterate-com/mac-app") }
        }
        helpers = config.map { MindSession.Helpers(node: $0.node, iterateBin: $0.iterateBin, bridge: $0.bridge) }
        let wanted = config.map { ($0.activeMind, $0.node, $0.iterateBin, $0.bridge) }
        let had = old.map { ($0.activeMind, $0.node, $0.iterateBin, $0.bridge) }
        if !isStart, wanted?.0 == had?.0, wanted?.1 == had?.1, wanted?.2 == had?.2, wanted?.3 == had?.3 {
            onChange?()
            return
        }
        if let config {
            let minds = config.minds.map { "\($0.mind) (itx.\($0.name))" }.joined(separator: ", ")
            log.info("config: version \(config.version) from \(config.spec); minds \(minds.isEmpty ? "none" : minds); active \(config.active ?? "none")")
        }
        if let mind = config?.activeMind {
            if !isStart { log.info("the active mind is \(mind.mind) (itx.\(mind.name)) now: the lend starts anew") }
            send(.started)
        } else {
            send(.stopRequested)
        }
    }

    /// The folder holds config.json, which the CLI replaces by a rename: a change of the folder's
    /// list of files is a change of the config.
    private func watchFolder() {
        try? FileManager.default.createDirectory(at: AppEnvironment.current.folder, withIntermediateDirectories: true)
        let descriptor = Darwin.open(AppEnvironment.current.folder.path, O_EVTONLY)
        guard descriptor >= 0 else { return log.error("cannot watch \(AppEnvironment.current.folder.path)") }
        let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: descriptor, eventMask: [.write, .rename, .delete], queue: .main)
        source.setEventHandler { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.reloadSoon?.cancel()
                let item = DispatchWorkItem { [weak self] in self?.reload() }
                self.reloadSoon = item
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: item)
            }
        }
        source.setCancelHandler { close(descriptor) }
        source.resume()
        folderWatch = source
    }

    private static var configFile: URL { AppEnvironment.current.folder.appendingPathComponent("config.json") }

    /// `use <mind>`: config.json names it active; the folder's watch switches the lend.
    func use(_ mind: String) {
        edit("use \(mind)") {
            try ConfigFile.write(ConfigFile.using(mind, in: ConfigFile.read(Self.configFile)), to: Self.configFile)
            return "The app lends this Mac to \(mind.lowercased()) now."
        }
    }

    /// `remove <mind>`: it leaves config.json, and its key file is deleted.
    func remove(_ mind: String) {
        edit("remove \(mind)") {
            let (state, keyFile) = try ConfigFile.removing(mind, from: ConfigFile.read(Self.configFile))
            if let keyFile { try? FileManager.default.removeItem(atPath: keyFile) }
            try ConfigFile.write(state, to: Self.configFile)
            return "Removed \(mind.lowercased()) and deleted its key. The key stays listed on the mind's /keys page until you remove it there; it can do nothing now."
        }
    }

    /// One change of config.json, said in the panel and the log.
    private func edit(_ what: String, _ change: () throws -> String) {
        do {
            let line = try change()
            log.info("\(what): \(line)")
            commandLink = nil
            say(line)
        } catch {
            log.error("\(what): \(error)")
            say("\(error)")
        }
        reload()
    }

    /// `add`: the CLI makes the key, prints the link where a member allows it (and opens it), and
    /// makes the mind active once it is allowed.
    func add(mind: String, name: String) {
        command(["add", "--mind", mind, "--name", name])
    }

    /// The minds of the iterate CLI's profiles, for "Add a mind…".
    func profiles(_ done: @escaping ([String]) -> Void) {
        done(ConfigFile.profileMinds())
    }

    /// Runs the installed cli.mjs with the app's node. Its lines go to the log, and the last one
    /// to the panel.
    private func command(_ arguments: [String]) {
        guard let config else { return say("Not set up: run npx @iterate-com/mac-app in a terminal") }
        guard FileManager.default.fileExists(atPath: config.cli) else {
            return say("This version has no \(config.cli): run npx @iterate-com/mac-app update")
        }
        let child = Process()
        child.executableURL = URL(fileURLWithPath: config.node)
        child.arguments = [config.cli] + arguments
        child.standardInput = FileHandle.nullDevice
        let errors = Pipe()
        child.standardOutput = FileHandle.nullDevice
        child.standardError = errors
        errors.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else { return handle.readabilityHandler = nil }
            let text = String(decoding: data, as: UTF8.self)
            Task { @MainActor in
                guard let self else { return }
                for line in text.split(separator: "\n") where !line.trimmingCharacters(in: .whitespaces).isEmpty {
                    self.log.info("cli \(arguments[0]): \(line.prefix(400))")
                    if let link = line.range(of: #"https://\S+/keys/enrol\S*"#, options: .regularExpression) {
                        self.commandLink = String(line[link])
                    }
                    self.say(String(line))
                }
            }
        }
        child.terminationHandler = { [weak self] ended in
            let status = ended.terminationStatus
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.isCommandRunning = false
                    self.log.info("cli \(arguments[0]) ended (exit \(status))")
                    if status == 0 { self.commandLink = nil }
                    self.reload()
                }
            }
        }
        log.info("runs cli.mjs \(arguments.joined(separator: " "))")
        do {
            try child.run()
            isCommandRunning = true
            commandLink = nil
        } catch {
            say("cli.mjs did not start: \(AppLog.describe(error))")
        }
        onChange?()
    }

    private func say(_ line: String) {
        commandLine = line
        onChange?()
    }

    // MARK: - Words

    static var clock: (Date) -> String { AppEnvironment.current.clock }

    /// A time of day to the minute, for the panel's "since 14:01" and "until 14:32": UTC and a
    /// fixed form in a drawing, as `clock`.
    static var shortClock: (Date) -> String {
        guard AppEnvironment.current.isRendering else { return { $0.formatted(date: .omitted, time: .shortened) } }
        return { date in
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.timeZone = TimeZone(identifier: "UTC")
            formatter.dateFormat = "HH:mm"
            return formatter.string(from: date)
        }
    }

    private static func describe(_ event: LendEvent) -> String {
        switch event {
        case .started: return "started"
        case .stopRequested: return "stop"
        case .stateLine(let text): return "state \(text.prefix(160))"
        case .humanLine(let text): return "line \"\(text.prefix(120))\""
        case .processEnded(let status, let ranFor): return "process ended (exit \(status), ran \(Int(ranFor)) s)"
        case .timerFired: return "wait over"
        case .reconnectNow(let why): return "reconnect now (\(why))"
        case .networkCameBack: return "network back"
        case .panelOpened: return "the panel opened"
        }
    }

    /// Asks npm for the newest version. Only for the registry: a pkg.pr.new link or a folder is a
    /// trial, updated by hand, and an app built from an owner's copy runs what was built.
    private func checkForUpdate() {
        guard let config, config.source.updatesItself, !AppEnvironment.current.hasOwnHome else { return }
        guard let url = URL(string: "https://registry.npmjs.org/@iterate-com/mac-app/latest") else { return }
        Task { @MainActor in
            guard let (data, _) = try? await URLSession.shared.data(from: url),
                let latest = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["version"] as? String,
                latest != config.version
            else { return }
            guard !isBusy() else { return log.info("version \(latest) is out; the update waits for the capture to end") }
            log.info("version \(latest) is out (this is \(config.version)): updating")
            let npx = URL(fileURLWithPath: config.node).deletingLastPathComponent().appendingPathComponent("npx")
            let update = Process()
            update.executableURL = npx
            update.arguments = ["--yes", config.spec, "update"]
            var environment = ProcessInfo.processInfo.environment
            environment["PATH"] = "\(npx.deletingLastPathComponent().path):/usr/bin:/bin:/usr/sbin:/sbin"
            update.environment = environment
            // The update quits this app and opens the new one; it must outlive this process.
            try? update.run()
        }
    }
}
