import Foundation
import SpeechText
import VoiceMeetCore

/// THE LENT MIND'S OPENAI SOCKETS for dictation and the input bar (README, "Dictation"). The mind
/// keeps its OpenAI key at `/secrets/openai` and never hands it out; the job `openai` of its bridge
/// (`bridge/openai.mjs`) opens each socket through the mind with `itx.fetch`, and the vault puts the
/// key in on the way. Each socket here is a `RelaySocket`: its lines go to the bridge, and the
/// bridge's lines for its id come back to it. Only the bridge of the mind this Mac is lent to is
/// asked: a socket is of that mind's key.
///
/// What the mind can do (`state`) is found out with one socket opened and closed at each new
/// connection of the bridge (no sound: OpenAI bills none), and each dictation's socket tells it
/// again: `opened` is `yes`, the mind's or OpenAI's no (`refused`) is `no`, and a failure with no
/// answer (no connection, 5 s) leaves it as it was. A new mind starts at `unknown`. When the lent
/// mind changes or its bridge's process ends, every socket of it fails, and a dictation on one of
/// them falls back. No frame and no key is ever logged.
@MainActor
final class MindSockets {
    enum Failure: Error, LocalizedError {
        case noMind

        var errorDescription: String? { "this Mac is lent to no mind" }
    }

    /// The lent mind, or nil.
    private(set) var mind: String?
    private(set) var state: MindOpenAI = .unknown
    /// `state` or the mind changed: the default speech model may follow.
    var onChange: () -> Void = {}

    private let log = AppLog("speech")
    private var bridge: MindBridge?
    private var next = 0
    /// The sockets that the bridge has, or opens, by id. `probe` is the one of a connection's ask.
    private var sockets: [String: RelaySocket] = [:]
    private var probes: Set<String> = []

    /// Another session, or none (`AppModel.use`): every socket of the old mind fails, and the new
    /// mind is asked once.
    func use(_ session: MindSession?, bridge: MindBridge?) {
        guard session?.mind != mind || bridge !== self.bridge else { return }
        failAll("the lent mind changed")
        mind = session?.mind
        self.bridge = bridge
        state = .unknown
        if let bridge, let mind {
            bridge.on("openai") { [weak self, weak bridge] line in
                guard let self, let bridge, bridge === self.bridge else { return }
                self.heard(line, of: mind)
            }
            if bridge.isConnected { probe() }
        }
        onChange()
    }

    /// A socket of the lent mind, not started: the stream starts it (`OpenAIStream.open`).
    func socket() throws -> RelaySocket {
        guard let bridge else { throw Failure.noMind }
        next += 1
        let id = "\(next)"
        let socket = RelaySocket(id: id) { [weak self, weak bridge] line in
            // the lines of every socket go in the order they were sent: through the main queue
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    bridge?.send("openai", line)
                    // the stream's close is its end: the bridge says nothing more of it
                    if line["close"] != nil { self?.forget(id) }
                }
            }
        }
        sockets[id] = socket
        return socket
    }

    /// A socket opened and closed at once: whether the mind can open one.
    private func probe() {
        guard let socket = try? socket() else { return }
        probes.insert(socket.id)
        socket.start(heard: { _ in }, ended: { _ in })
    }

    private func heard(_ line: [String: Any], of mind: String) {
        // the process's own lines: a new connection is asked again; an exit fails every socket
        if line["job"] == nil {
            if line["connected"] as? Bool == true, mind == self.mind { probe() }
            if line["exited"] != nil { failAll("the mind's process ended") }
            return
        }
        guard let id = line["socket"].map({ "\($0)" }), let socket = sockets[id] else { return }
        let isProbe = probes.contains(id)
        if line["opened"] as? Bool == true {
            set(.yes, why: "a socket opened through it")
            if isProbe {
                forget(id)
                socket.close(normal: true)
            }
            return
        }
        if let why = line["failed"] as? String {
            if line["refused"] as? Bool == true { set(.no, why: why) }
            else if !isProbe { log.info("no socket through \(mind): \(why)") }
        }
        if socket.take(line) { forget(id) }
    }

    private func forget(_ id: String) {
        sockets[id] = nil
        probes.remove(id)
    }

    private func set(_ state: MindOpenAI, why: String) {
        guard state != self.state else { return }
        self.state = state
        log.info("OpenAI through \(mind ?? "no mind"): \(state == .yes ? "the mind's key (\(why))" : "not this mind (\(why))")")
        onChange()
    }

    private func failAll(_ why: String) {
        let all = sockets.values
        sockets = [:]
        probes = []
        // the bridge closes its end too, if it still runs
        for socket in all { socket.fail(why, closing: true) }
    }
}
