import Foundation
import SpeechText
import VoiceMeetCore

/// THE LENT MIND'S OPENAI TOKENS for dictation and the input bar (README, "Dictation"). The mind
/// keeps its OpenAI key at `/secrets/openai` and never hands it out; the job `openai` of its
/// bridge (`bridge/openai.mjs`) mints a token of 60 s with it, which opens one socket. Only the
/// bridge of the mind this Mac is lent to is asked: a token is for that mind's key.
///
/// What the mind can do (`mint`) is found out with one mint at each new connection of the bridge,
/// and each dictation's mint tells it again: a token is `yes`, the mind's or OpenAI's no
/// (`refused`) is `no`, and no answer (no connection, 5 s) leaves it as it was. A new mind starts
/// at `unknown`. A token is used at once to open a socket and never kept: the probe's is thrown
/// away. No token is ever logged.
@MainActor
final class MindToken {
    /// The most seconds a mint may take, the bridge's own bound with the hop to it.
    static let timeout = 5.0

    enum Failure: Error, LocalizedError {
        case noMind
        case failed(String)

        var errorDescription: String? {
            switch self {
            case .noMind: "this Mac is lent to no mind"
            case .failed(let why): why
            }
        }
    }

    /// The lent mind, or nil.
    private(set) var mind: String?
    private(set) var mint: MindMint = .unknown
    /// `mint` or the mind changed: the default speech model may follow.
    var onChange: () -> Void = {}

    private let log = AppLog("speech")
    private var bridge: MindBridge?
    private var next = 0
    /// The mints that wait for their answer, by id, with the mind they are of.
    private var pending: [String: (mind: String, isProbe: Bool, done: (Result<String, Error>) -> Void)] = [:]

    /// Another session, or none (`AppModel.use`): every mint that waits fails, and the new mind is
    /// asked once.
    func use(_ session: MindSession?, bridge: MindBridge?) {
        guard session?.mind != mind || bridge !== self.bridge else { return }
        failAll("the lent mind changed")
        mind = session?.mind
        self.bridge = bridge
        mint = .unknown
        if let bridge, let mind {
            bridge.on("openai") { [weak self, weak bridge] line in
                guard let self, let bridge, bridge === self.bridge else { return }
                self.heard(line, of: mind)
            }
            if bridge.isConnected { probe() }
        }
        onChange()
    }

    /// One token of the lent mind, within `timeout`.
    func token() async throws -> String {
        try await withCheckedThrowingContinuation { continuation in
            ask(isProbe: false) { continuation.resume(with: $0) }
        }
    }

    /// A mint whose token is thrown away: whether the mind can mint.
    private func probe() {
        ask(isProbe: true) { _ in }
    }

    private func ask(isProbe: Bool, done: @escaping (Result<String, Error>) -> Void) {
        guard let bridge, let mind else { return done(.failure(Failure.noMind)) }
        next += 1
        let id = "\(next)"
        pending[id] = (mind, isProbe, done)
        bridge.send("openai", ["openaiToken": id])
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.timeout) { [weak self] in
            MainActor.assumeIsolated {
                guard let self, let waiting = self.pending.removeValue(forKey: id) else { return }
                if !waiting.isProbe { self.log.info("no token from \(waiting.mind) in \(Int(Self.timeout)) s") }
                waiting.done(.failure(Failure.failed("no token from \(waiting.mind) in \(Int(Self.timeout)) s")))
            }
        }
    }

    private func heard(_ line: [String: Any], of mind: String) {
        // the process's own lines: a new connection is asked again; an exit fails what waits
        if line["job"] == nil {
            if line["connected"] as? Bool == true, mind == self.mind { probe() }
            if line["exited"] != nil { failAll("the mind's process ended") }
            return
        }
        guard let id = line["openaiToken"].map({ "\($0)" }), let waiting = pending.removeValue(forKey: id) else { return }
        guard waiting.mind == self.mind else { return waiting.done(.failure(Failure.failed("the lent mind changed"))) }
        if let value = line["value"] as? String, !value.isEmpty {
            set(.yes, why: "it mints tokens with its key")
            waiting.done(.success(value))
        } else {
            let why = line["failed"] as? String ?? "no token"
            if line["refused"] as? Bool == true { set(.no, why: why) }
            else if !waiting.isProbe { log.info("no token from \(waiting.mind): \(why)") }
            waiting.done(.failure(Failure.failed(why)))
        }
    }

    private func set(_ mint: MindMint, why: String) {
        guard mint != self.mint else { return }
        self.mint = mint
        log.info("OpenAI through \(mind ?? "no mind"): \(mint == .yes ? "the mind's key (\(why))" : "not this mind (\(why))")")
        onChange()
    }

    private func failAll(_ why: String) {
        let waiting = pending.values
        pending = [:]
        for each in waiting { each.done(.failure(Failure.failed(why))) }
    }
}
