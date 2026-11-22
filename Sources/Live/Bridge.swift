import Foundation
import VoiceMeetCore

/// `bridge/device-live.mjs` as a child process: it carries a `LivePeer`'s signals to the mind and
/// back, as JSON lines.
///
/// - from the bridge: `{ signal: { from, want | description | candidate | bye }, who }`,
///   `{ iceServers: [...] }`, `{ connected: true | false, failed? }` (the signalling is up or
///   down), and `{ failed }` for the log;
/// - to the bridge: `{ signal: { to, description, tracks } | { to, candidate } | { to, bye, reason } }`,
///   `{ started: { watcher, who, tracks } }` and `{ ended: { watcher, who, seconds, why } }`.
public final class LiveBridge: @unchecked Sendable {
    private let process = Process()
    private let input = Pipe()
    private let lock = NSLock()
    private var pending = ""
    /// A line of the bridge for the log: `{ failed }`, and `{ connected: true | false }`.
    public var said: ([String: Any]) -> Void = { _ in }
    public var exited: (Int32) -> Void = { _ in }

    /// `node script arguments…`; `peer` hears the watchers' signals and says its own through here.
    public init(node: String, script: String, arguments: [String], peer: LivePeer) {
        process.executableURL = URL(fileURLWithPath: node)
        process.arguments = [script] + arguments
        process.standardInput = input
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        output.fileHandleForReading.readabilityHandler = { [weak self, weak peer] handle in
            let data = handle.availableData
            guard let self, let peer, !data.isEmpty else { return }
            for line in self.lines(data) {
                if let signal = line["signal"] as? [String: Any] {
                    peer.heard(signal, who: line["who"] as? String ?? "someone")
                } else if let servers = line["iceServers"] as? [[String: Any]] {
                    peer.setIceServers(servers)
                } else {
                    self.said(line)
                }
            }
        }
        process.terminationHandler = { [weak self] ended in
            output.fileHandleForReading.readabilityHandler = nil
            self?.exited(ended.terminationStatus)
        }
        peer.send = { [weak self] signal in self?.write(["signal": signal.json]) }
        peer.kept = { [weak self] facts in self?.write(facts) }
    }

    public var pid: Int32 { process.processIdentifier }

    public func start() throws { try process.run() }

    /// Its stdin closes: it appends what waits, then exits.
    public func stop() { try? input.fileHandleForWriting.close() }

    private func write(_ line: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: line, options: [.withoutEscapingSlashes]) else { return }
        lock.withLock { try? input.fileHandleForWriting.write(contentsOf: data + Data("\n".utf8)) }
    }

    private func lines(_ data: Data) -> [[String: Any]] {
        lock.withLock {
            var lines = (pending + String(decoding: data, as: UTF8.self)).components(separatedBy: "\n")
            pending = lines.removeLast()
            return lines.compactMap { try? JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any] }
        }
    }
}

extension LiveSignal {
    /// The payload of `device/live-signal` without its `from: "device"` (the bridge adds it).
    public var json: [String: Any] {
        switch self {
        case let .offer(to, sdp, tracks): return ["to": to, "description": ["type": "offer", "sdp": sdp], "tracks": tracks]
        case let .candidate(to, c):
            var candidate: [String: Any] = ["candidate": c.candidate, "sdpMLineIndex": c.sdpMLineIndex]
            if let mid = c.sdpMid { candidate["sdpMid"] = mid }
            return ["to": to, "candidate": candidate]
        case let .bye(to, reason): return ["to": to, "bye": true, "reason": reason]
        }
    }
}
