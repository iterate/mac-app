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
/// `{ exited: <status> }`, and after 10 s a new one starts and each handler hears
/// `{ started: true }`: a job that runs from its start (events, live, record) starts again then.
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

    private init(_ key: Key) {
        self.key = key
        mind = key.mind
    }

    /// `holder` needs the process: it starts when none runs.
    func hold(_ holder: String) {
        holders.insert(holder)
        if process == nil, restart == nil { run() }
    }

    /// `holder` is done. With no holder left, stdin closes and the bridge is no longer `of` its mind.
    func release(_ holder: String) {
        guard holders.remove(holder) != nil, holders.isEmpty else { return }
        restart?.cancel()
        restart = nil
        process?.closeInput()
        process = nil
        handlers = [:]
        isConnected = false
        if Self.bridges[key] === self { Self.bridges[key] = nil }
        log.info("\(mind): no job left, its process ends")
    }

    /// The handler of `job`'s lines: one for each job.
    func on(_ job: String, _ handler: @escaping ([String: Any]) -> Void) {
        handlers[job] = handler
    }

    func send(_ job: String, _ fields: [String: Any]) {
        var line = fields
        line["job"] = job
        process?.send(line)
    }

    private func run() {
        let made = JSONLineProcess(
            executable: key.helpers.node, arguments: [key.helpers.mindBridge, key.mind, "--name", key.name, "--iterate", key.helpers.iterateBin])
        made.said = { [weak self] line in self?.heard(line, from: made) }
        made.logged = { [log, mind] text in log.info("\(mind): \(text.prefix(400))") }
        made.exited = { [weak self] status in self?.ended(made, status: status) }
        do {
            try made.start()
            process = made
            log.info("\(mind): process \(made.pid) for itx.\(key.name), for \(holders.sorted().joined(separator: ", "))")
        } catch {
            log.error("\(mind): the process did not start: \(AppLog.describe(error))")
            ended(nil, status: -1)
        }
    }

    private func heard(_ line: [String: Any], from made: JSONLineProcess) {
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

    /// The process ended while it was held: every handler hears it, and a new one starts in 10 s.
    private func ended(_ made: JSONLineProcess?, status: Int32) {
        guard made == nil || made === process else { return }
        process = nil
        isConnected = false
        log.error("\(mind): the process ended (status \(status)) while \(holders.sorted().joined(separator: ", ")) held it")
        handlers.values.forEach { $0(["exited": Int(status)]) }
        guard !holders.isEmpty else { return }
        let item = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                guard let self, !self.holders.isEmpty else { return }
                self.restart = nil
                self.run()
                if self.process != nil { self.handlers.values.forEach { $0(["started": true]) } }
            }
        }
        restart = item
        DispatchQueue.main.asyncAfter(deadline: .now() + 10, execute: item)
    }
}
