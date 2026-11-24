import Foundation
import VoiceMeetCore

/// The lines of the job `live` of `bridge/mind.mjs` (`bridge/live.mjs`), which carries a
/// `LivePeer`'s signals to the mind and back:
///
/// - from the job: `{ signal: { from, want | description | candidate | bye }, who }`,
///   `{ iceServers: [...] }`, and `{ failed }` for the log;
/// - to the job: `{ signal: { to, description, tracks } | { to, candidate } | { to, bye, reason } }`,
///   `{ started: { watcher, who, tracks } }` and `{ ended: { watcher, who, seconds, why } }`
///   (`send` and `kept` of the peer).
extension LivePeer {
    /// A line of the job: a watcher's signal, or the ICE servers. False for any other line.
    public func take(_ line: [String: Any]) -> Bool {
        if let signal = line["signal"] as? [String: Any] {
            heard(signal, who: line["who"] as? String ?? "someone")
        } else if let servers = line["iceServers"] as? [[String: Any]] {
            setIceServers(servers)
        } else {
            return false
        }
        return true
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
