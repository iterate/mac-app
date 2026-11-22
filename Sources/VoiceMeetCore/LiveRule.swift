import Foundation

/// LIVE: a watcher's page sees this Mac now, over WebRTC (README, "Live"). Pure: who gets which
/// track, and the signalling of each watch. `Sources/Live` runs the peer connections by these
/// rules; the app (`DeviceLive`) asks the owner's switches.

extension UseGate {
    /// One gate for a power that has several things (the cameras): the strictest of theirs. No
    /// thing at all is off.
    public static func strictest(_ gates: [UseGate]) -> UseGate {
        for gate in [UseGate.off, .notPermitted, .ask] where gates.contains(gate) { return gate }
        return gates.isEmpty ? .off : .go
    }
}

/// Which tracks a watcher gets, by the owner's switches: Off and a permission macOS has not given:
/// not offered. Ask: offered when the person approved the watch (one question for all of them).
/// Shared: offered.
public enum LiveTracks {
    /// Whether the watch needs the person's approval first.
    public static func asks(_ gates: [(track: String, gate: UseGate)]) -> Bool { gates.contains { $0.gate == .ask } }

    public static func offered(_ gates: [(track: String, gate: UseGate)], approved: Bool) -> [String] {
        gates.filter { $0.gate == .go || ($0.gate == .ask && approved) }.map(\.track)
    }

    /// The reason in the `bye` to a watcher who may see nothing.
    public static func nothing(asked: Bool, approved: Bool) -> String {
        asked && !approved ? "the owner did not approve the watch" : "nothing to show: the owner shares no screen, camera or microphone"
    }
}

/// One ICE candidate, as the contract carries it.
public struct LiveCandidate: Equatable, Sendable {
    public let candidate: String
    public let sdpMid: String?
    public let sdpMLineIndex: Int

    public init(candidate: String, sdpMid: String?, sdpMLineIndex: Int) {
        (self.candidate, self.sdpMid, self.sdpMLineIndex) = (candidate, sdpMid, sdpMLineIndex)
    }
}

/// A signal from the device to one watcher: `device/live-signal { from: "device", to, … }`.
public enum LiveSignal: Equatable, Sendable {
    case offer(to: String, sdp: String, tracks: [String: String])
    case candidate(to: String, LiveCandidate)
    case bye(to: String, reason: String)
}

/// What the device does next, in order.
public enum LiveEffect: Equatable, Sendable {
    /// Ask the owner's switches which tracks this watcher gets; answer with `decided`.
    case decide(watcher: String, who: String)
    /// Make a peer connection with these tracks, send only, and its offer; answer with `offerMade`.
    case makeOffer(watcher: String, tracks: [String])
    case send(LiveSignal)
    case setAnswer(watcher: String, sdp: String)
    case addCandidate(watcher: String, LiveCandidate)
    /// Close the watcher's peer connection.
    case close(watcher: String)
    /// The watch began: `device/live-watch-started`, and a running act in Activity.
    case started(watcher: String, who: String, tracks: [String])
    /// The watch ended: `device/live-watch-ended`, and the act ends.
    case ended(watcher: String, who: String, seconds: Int, why: String)
}

/// The watchers of this device and the signalling of each. The watcher asks (`want`); the device
/// always offers, so there is no glare. The device's candidates wait for its offer, the watcher's
/// for its answer: each side's signals go out and are used in order. At most `most` watchers.
public struct LiveWatchers: Equatable, Sendable {
    public static let most = 4

    public enum Phase: Equatable, Sendable {
        /// The owner's switches are asked (an Ask may wait for the person).
        case deciding
        /// The peer connection and its offer are being made.
        case offering
        /// The offer is sent; the answer has not come.
        case offered
        case answered
        case connected
    }

    public struct Watch: Equatable, Sendable {
        public let id: String
        /// Who asked: a short name or an email, from the `want` event's source.
        public let who: String
        public internal(set) var phase: Phase
        public internal(set) var tracks: [String] = []
        public let asked: Date
        public internal(set) var connected: Date?
        /// The device's candidates made before its offer went out.
        var held: [LiveCandidate] = []
        /// The watcher's candidates that came before its answer.
        var early: [LiveCandidate] = []
    }

    public private(set) var watches: [Watch] = []

    public init() {}

    /// Every track some watcher gets (from the owner's decision on): the capture runs for these.
    public var tracks: Set<String> { Set(watches.flatMap(\.tracks)) }

    public func watch(_ id: String) -> Watch? { watches.first { $0.id == id } }

    private func index(_ id: String) -> Int? { watches.firstIndex { $0.id == id } }

    /// `device/live-signal { from, to: "device", want: true }`.
    public mutating func want(from id: String, who: String, now: Date) -> [LiveEffect] {
        let before = end(id, why: "asked again", tell: false, now: now)
        guard watches.count < Self.most else { return before + [.send(.bye(to: id, reason: "too many watchers (\(Self.most))"))] }
        watches.append(Watch(id: id, who: who, phase: .deciding, asked: now))
        return before + [.decide(watcher: id, who: who)]
    }

    /// The owner's switches answered for this watcher. No track: `bye` with `reason`.
    public mutating func decided(_ id: String, tracks: [String], reason: String) -> [LiveEffect] {
        guard let i = index(id), watches[i].phase == .deciding else { return [] }
        guard !tracks.isEmpty else {
            watches.remove(at: i)
            return [.send(.bye(to: id, reason: reason))]
        }
        watches[i].tracks = tracks
        watches[i].phase = .offering
        return [.makeOffer(watcher: id, tracks: tracks)]
    }

    /// The offer is made: it goes out, then the candidates made meanwhile. `mids` maps each `mid`
    /// of the offer to a track id.
    public mutating func offerMade(_ id: String, sdp: String, mids: [String: String]) -> [LiveEffect] {
        guard let i = index(id), watches[i].phase == .offering else { return [] }
        watches[i].phase = .offered
        let held = watches[i].held
        watches[i].held = []
        return [.send(.offer(to: id, sdp: sdp, tracks: mids))] + held.map { .send(.candidate(to: id, $0)) }
    }

    /// The device's peer connection made a candidate.
    public mutating func deviceCandidate(_ id: String, _ candidate: LiveCandidate) -> [LiveEffect] {
        guard let i = index(id) else { return [] }
        if watches[i].phase == .offering {
            watches[i].held.append(candidate)
            return []
        }
        return [.send(.candidate(to: id, candidate))]
    }

    /// `{ description: { type: "answer", sdp } }`: then the watcher's candidates that came early.
    public mutating func answer(from id: String, sdp: String) -> [LiveEffect] {
        guard let i = index(id), watches[i].phase == .offered else { return [] }
        watches[i].phase = .answered
        let early = watches[i].early
        watches[i].early = []
        return [.setAnswer(watcher: id, sdp: sdp)] + early.map { .addCandidate(watcher: id, $0) }
    }

    /// `{ candidate }` from the watcher. Before the answer it waits (at most 40).
    public mutating func candidate(from id: String, _ candidate: LiveCandidate) -> [LiveEffect] {
        guard let i = index(id) else { return [] }
        switch watches[i].phase {
        case .answered, .connected:
            return [.addCandidate(watcher: id, candidate)]
        default:
            if watches[i].early.count < 40 { watches[i].early.append(candidate) }
            return []
        }
    }

    /// The peer connection is connected: the watch begins.
    public mutating func connected(_ id: String, now: Date) -> [LiveEffect] {
        guard let i = index(id), watches[i].connected == nil, watches[i].phase == .answered else { return [] }
        watches[i].phase = .connected
        watches[i].connected = now
        return [.started(watcher: id, who: watches[i].who, tracks: watches[i].tracks)]
    }

    /// The watch ends: the watcher's `bye` ("the watcher left", `tell` false), a failed connection,
    /// the owner's button, the device's stop (`tell` true: the watcher hears `bye`).
    public mutating func end(_ id: String, why: String, tell: Bool, now: Date) -> [LiveEffect] {
        guard let i = index(id) else { return [] }
        let watch = watches.remove(at: i)
        var effects: [LiveEffect] = [.close(watcher: id)]
        if tell { effects.append(.send(.bye(to: id, reason: why))) }
        if let connected = watch.connected {
            effects.append(.ended(watcher: id, who: watch.who, seconds: Int(now.timeIntervalSince(connected).rounded()), why: why))
        }
        return effects
    }

    public mutating func endAll(why: String, now: Date) -> [LiveEffect] {
        watches.map(\.id).flatMap { end($0, why: why, tell: true, now: now) }
    }
}

/// The watcher's answer, as the device applies it. A browser answers H.264 at the level it names by
/// default, often 3.1 (`profile-level-id=42e01f`): 1280×720 at most. A screen is larger (a MacBook
/// Pro's is 3024×1964), and the encoder then writes a stream that claims level 3.1 and is not: Chrome
/// decodes it, iOS Safari showed black (22 Nov 2026), while the camera at 1280×720 showed. So the
/// device reads the answer's H.264 level as at least 5.2 (`…34`: 36,864 macroblocks a frame, up to
/// 4096×2304), which every phone and Mac of the last years decodes in hardware, and the encoder writes
/// that level into the stream. A screen above 5.2's frame size (a 5K display) is still too large.
public enum LiveAnswer {
    /// The lowest H.264 level the device takes from an answer, in hex: 5.2.
    public static let lowestH264Level = "34"

    /// `sdp` with every H.264 format's `profile-level-id` level raised to `lowestH264Level` where
    /// it is lower. Other codecs and other parameters are untouched.
    public static func raisingH264Level(_ sdp: String) -> String {
        let lines = sdp.components(separatedBy: "\r\n")
        let h264 = Set(lines.compactMap { line -> String? in
            guard line.hasPrefix("a=rtpmap:"), line.uppercased().contains(" H264/") else { return nil }
            return line.dropFirst("a=rtpmap:".count).split(separator: " ").first.map(String.init)
        })
        return lines.map { line -> String in
            guard line.hasPrefix("a=fmtp:"),
                let type = line.dropFirst("a=fmtp:".count).split(separator: " ").first.map(String.init),
                h264.contains(type),
                let range = line.range(of: #"profile-level-id=[0-9a-fA-F]{6}"#, options: .regularExpression)
            else { return line }
            let value = line[range].suffix(6)
            let level = value.suffix(2)
            guard let current = Int(level, radix: 16), let lowest = Int(lowestH264Level, radix: 16), current < lowest else { return line }
            return line.replacingCharacters(in: range, with: "profile-level-id=\(value.prefix(4))\(lowestH264Level)")
        }.joined(separator: "\r\n")
    }
}
