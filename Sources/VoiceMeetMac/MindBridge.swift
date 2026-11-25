import Foundation
import VoiceMeetCore

/// THE MIND'S BRIDGE: one `bridge/mind.mjs` for a mind, with one connection to it as the person
/// (the iterate CLI's own sign-in; the lend, `iterate provide` with the Mac's key, is another
/// process and another identity). Every feature that reaches the mind as the person sends its
/// lines here, each tagged with its job: `events` (DeviceEvents), `live` (DeviceLive), `record`
/// (DeviceRecord), `capture` (Capture), `input` (MindInput) and `words` (Words).
///
/// There is one bridge for a mind, its name and its helpers (`of`). It runs while someone holds
/// it: the session while the Mac is lent to that mind (`AppModel`), a capture until it is sent, an
/// input until it went, a word list until it came. So a capture that began before a switch to
/// another mind ends on its own mind's process. When the last holder lets go, its stdin closes: the
/// script ends its jobs and exits, and the next `of` starts a new one.
///
/// A line of the script goes to the handler of its `job`; a line with no job (`{ connected }`,
/// `{ failed }`) goes to every handler. When the script exits while it is held, each handler hears
/// `{ exited: <status> }`, and after a wait a new one starts and each handler hears
/// `{ started: true }`: a job that runs from its start (events, live, record) starts again then.
/// The wait is 10 s, twice as long after each process that ended within a minute, at most 5
/// minutes: a node that is gone does not start a process every 10 s for ever.
///
/// A line sent while no process runs (the wait before a new one, or the end of one that drains)
/// waits for the next process, in order, at most `mostWaiting` of them: an input sent then is not
/// lost. A process that drains (its stdin closed, its jobs ending) is the only one of its mind
/// until it exits, or for at most 10 s: the next waits for it, so two never share a spool.
@MainActor
final class MindBridge {
    private struct Key: Hashable {
        let mind: String
        let name: String
        let helpers: MindSession.Helpers
    }

    private static var bridges: [Key: MindBridge] = [:]

    /// The bridge for this mind, as `name`: the one that runs, or a new one.
    static func of(mind: String, name: String, helpers: MindSession.Helpers) -> MindBridge {
        let key = Key(mind: mind, name: name, helpers: helpers)
        if let bridge = bridges[key] { return bridge }
        let bridge = MindBridge(key)
        bridges[key] = bridge
        return bridge
    }

    static func of(_ session: MindSession) -> MindBridge {
        of(mind: session.mind, name: session.name, helpers: session.helpers)
    }

    let mind: String
    /// The script's word: its connection to the mind is up.
    private(set) var isConnected = false

    private let key: Key
    private let log = AppLog("bridge")
    private var holders: Set<String> = []
    private var handlers: [String: ([String: Any]) -> Void] = [:]
    private var process: JSONLineProcess?
    private var restart: DispatchWorkItem?
    /// The process whose stdin closed when the last holder let go, until it exits.
    private var draining: JSONLineProcess?
    private var drainTimeout: DispatchWorkItem?
    /// The lines sent while no process runs, for the next one.
    private var waiting: [[String: Any]] = []
    private static let mostWaiting = 2_000
    /// Processes that ended within a minute of their start, one after the other.
    private var quickEnds = 0
    private var startedAt = Date()

    private init(_ key: Key) {
        self.key = key
        mind = key.mind
    }

    /// `holder` needs the process: it starts when none runs (after the one that drains).
    func hold(_ holder: String) {
        holders.insert(holder)
        if Self.bridges[key] == nil { Self.bridges[key] = self }
        if process == nil, restart == nil, draining == nil { run() }
    }

    /// `holder` is done. With no holder left, stdin closes: the process drains its jobs and exits.
    func release(_ holder: String) {
        guard holders.remove(holder) != nil, holders.isEmpty else { return }
        restart?.cancel()
        restart = nil
        waiting = []
        handlers = [:]
        isConnected = false
        log.info("\(mind): no job left, its process ends")
        guard let process else { return forget() }
        self.process = nil
        process.closeInput()
        draining = process
        let item = DispatchWorkItem { [weak self, weak process] in
            MainActor.assumeIsolated {
                guard let self, let process, self.draining === process else { return }
                self.log.error("\(self.mind): process \(process.pid) did not end 10 s after its stdin closed: it is terminated")
                process.terminate()
            }
        }
        drainTimeout = item
        DispatchQueue.main.asyncAfter(deadline: .now() + 10, execute: item)
    }

    /// No holder and no process: the bridge is no longer `of` its mind.
    private func forget() {
        if holders.isEmpty, process == nil, draining == nil, Self.bridges[key] === self { Self.bridges[key] = nil }
    }

    /// The handler of `job`'s lines: one for each job.
    func on(_ job: String, _ handler: @escaping ([String: Any]) -> Void) {
        handlers[job] = handler
    }

    func send(_ job: String, _ fields: [String: Any]) {
        var line = fields
        line["job"] = job
        if let process {
            if !process.send(line) { log.error("\(mind): a line of \(job) was dropped: the process does not read its stdin") }
        } else if !holders.isEmpty {
            if waiting.count >= Self.mostWaiting { waiting.removeFirst(waiting.count - Self.mostWaiting + 1) }
            waiting.append(line)
        }
    }

    private func run() {
        let made = JSONLineProcess(
            executable: key.helpers.node, arguments: [key.helpers.mindBridge, key.mind, "--name", key.name, "--iterate", key.helpers.iterateBin])
        // the process's callbacks hold it until its exit, when it lets them go
        made.said = { [weak self] line in self?.heard(line, from: made) }
        made.logged = { [log, mind] text in log.info("\(mind): \(text.prefix(400))") }
        made.exited = { [weak self] status in self?.ended(made, status: status) }
        do {
            try made.start()
            process = made
            startedAt = Date()
            log.info("\(mind): process \(made.pid) for itx.\(key.name), for \(holders.sorted().joined(separator: ", "))")
        } catch {
            log.error("\(mind): the process did not start: \(AppLog.describe(error))")
            ended(nil, status: -1)
        }
    }

    /// The lines that waited for this process, after the handlers heard that it started.
    private func flush() {
        guard let process else { return }
        for line in waiting { process.send(line) }
        waiting = []
    }

    private func heard(_ line: [String: Any], from made: JSONLineProcess) {
        Perf.count("bridgeLines.\(line["job"] as? String ?? "process")")
        guard made === process else { return }
        if let up = line["connected"] as? Bool {
            if up != isConnected { log.info("\(mind): \(up ? "connected" : "not connected: \(line["failed"] as? String ?? "")")") }
            isConnected = up
        }
        guard let job = line["job"] as? String else {
            if line["connected"] == nil, let why = line["failed"] as? String { log.error("\(mind): \(why)") }
            return handlers.values.forEach { $0(line) }
        }
        handlers[job]?(line)
    }

    /// The process ended. One that drained: the next may start now. One that was held: every
    /// handler hears it, and a new one starts after the wait.
    private func ended(_ made: JSONLineProcess?, status: Int32) {
        if let made, made === draining {
            draining = nil
            drainTimeout?.cancel()
            drainTimeout = nil
            log.info("\(mind): process \(made.pid) ended (status \(status)) after its last job")
            if holders.isEmpty { return forget() }
            // the new holders' lines, their starts too, waited in order: no `started` is needed
            run()
            return flush()
        }
        guard made == nil || made === process else { return }
        process = nil
        isConnected = false
        log.error("\(mind): the process ended (status \(status)) while \(holders.sorted().joined(separator: ", ")) held it")
        handlers.values.forEach { $0(["exited": Int(status)]) }
        guard !holders.isEmpty else { return forget() }
        quickEnds = made != nil && Date().timeIntervalSince(startedAt) >= 60 ? 0 : quickEnds + 1
        let wait = Self.restartWait(quickEnds: quickEnds)
        let item = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                guard let self, !self.holders.isEmpty else { return }
                self.restart = nil
                self.run()
                if self.process != nil { self.handlers.values.forEach { $0(["started": true]) } }
                self.flush()
            }
        }
        restart = item
        DispatchQueue.main.asyncAfter(deadline: .now() + .seconds(wait), execute: item)
    }

    /// The wait before a new process: 10 s, twice as long after each quick end, at most 300 s.
    static func restartWait(quickEnds: Int) -> Int { min(300, 10 << min(max(quickEnds - 1, 0), 5)) }
}
