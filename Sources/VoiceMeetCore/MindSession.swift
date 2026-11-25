import Foundation

/// ONE MIND'S AUTHORITY OVER THIS MAC: the mind it is lent to, the name it has there, the helpers
/// that reach it, and a generation. Every feature that works for the lent mind (the device's
/// events, live, the record, the approvals) takes the session as a value. A new generation is a
/// new session: the old one's work ends, its approvals end, and a late answer of the old one
/// changes nothing.
public struct MindSession: Equatable, Sendable {
    /// Node, the iterate CLI, and `mind.mjs` beside `mac-endpoint.ts`, resolved once.
    public struct Helpers: Hashable, Sendable {
        public let node: String
        public let iterateBin: String
        /// `bridge/mind.mjs`: the one process for a mind (`MindBridge`).
        public let mindBridge: String

        /// `bridge` is the path of `mac-endpoint.ts`: `mind.mjs` is in its folder.
        public init(node: String, iterateBin: String, bridge: String) {
            self.node = node
            self.iterateBin = iterateBin
            mindBridge = ((bridge as NSString).deletingLastPathComponent as NSString).appendingPathComponent("mind.mjs")
        }
    }

    /// The selected mind, as the config has it: what a session is made of.
    public struct Selected: Equatable, Sendable {
        public let mind: String
        public let name: String
        public let helpers: Helpers

        public init(mind: String, name: String, helpers: Helpers) {
            self.mind = mind
            self.name = name
            self.helpers = helpers
        }
    }

    public let generation: Int
    /// The mind's address, as the config names it (`example.com`).
    public let mind: String
    /// This Mac's name in the mind: the lend is `itx.<name>`, the device's context `/devices/<name>`.
    public let name: String
    public let helpers: Helpers

    public var path: String { "/devices/\(name)" }
}

/// The rule that makes sessions, and whether the lend is authorized. "Selected" (the config's
/// active mind), "connected" (the lend is live) and "authorized" (the mind did not refuse this
/// Mac's key) are three things. The session is the selected mind: a reconnect or a refusal keeps it
/// (the same generation), and only another mind, another name, other helpers or a removal change
/// it. A refusal ends the lend's authority alone: the features that use the person's own sign-in
/// (the device's events, the record, live, the input) go on. The lend is authorized again once it
/// is live, or once another mind is selected.
public struct MindSessions: Equatable, Sendable {
    public private(set) var current: MindSession?
    public private(set) var isAuthorized = true
    private var generation = 0

    public init() {}

    /// The session for the selection, and the authorization for the lend's phase now. Each is
    /// true when it changed.
    public mutating func update(selected: MindSession.Selected?, phase: LendPhase) -> (session: Bool, authorization: Bool) {
        let had = current.map { MindSession.Selected(mind: $0.mind, name: $0.name, helpers: $0.helpers) }
        let wasAuthorized = isAuthorized
        let isNew = selected != had
        if isNew {
            generation += 1
            current = selected.map { MindSession(generation: generation, mind: $0.mind, name: $0.name, helpers: $0.helpers) }
            isAuthorized = true
        }
        switch phase {
        case .notAllowed: isAuthorized = false
        case .live: isAuthorized = true
        default: break
        }
        return (isNew, isAuthorized != wasAuthorized)
    }
}

/// WORK THAT STARTED IN ONE SESSION LANDS IN THAT SESSION ONLY. A read of the window, a live
/// signal, a question to the person, a listing of the spool: each takes the stamp when it starts and
/// is let land (published, sent, applied) only while the stamp is still the current one. Another
/// session, or none, makes every older stamp stale (`use`), and so does the end of a feature's work
/// in a session: a setting turned off, a refusal of this Mac's key (`end`). With no session nothing
/// lands. The one rule for every late answer: a check where the work lands, not a cancel at each
/// place that starts it.
public struct SessionWork: Equatable, Sendable {
    public struct Stamp: Hashable, Sendable {
        /// The session's generation; nil while there is none.
        public let generation: Int?
        let turn: Int
    }

    public private(set) var stamp = Stamp(generation: nil, turn: 0)

    public init() {}

    /// Another session (its generation), or none: the work of every earlier stamp lands nowhere.
    public mutating func use(generation: Int?) {
        stamp = Stamp(generation: generation, turn: stamp.turn + 1)
    }

    /// The work of this session so far ends; the session stays.
    public mutating func end() {
        stamp = Stamp(generation: stamp.generation, turn: stamp.turn + 1)
    }

    /// Whether work that started at `started` may land now.
    public func lands(_ started: Stamp) -> Bool {
        started.generation != nil && started == stamp
    }
}

/// What a session's work sends from other queues, in order, to the main queue: each item with the
/// stamp of the moment it was made. `take` gives the items that still land, in their order, and
/// drops those of an older stamp. `put` is true when the box was empty: one drain is enough for
/// everything put until it runs.
public struct SessionOutbox<Item> {
    private var items: [(stamp: SessionWork.Stamp, item: Item)] = []

    public init() {}

    public var isEmpty: Bool { items.isEmpty }

    public mutating func put(_ item: Item, at stamp: SessionWork.Stamp) -> Bool {
        items.append((stamp, item))
        return items.count == 1
    }

    public mutating func take(for work: SessionWork) -> [Item] {
        defer { items = [] }
        return items.filter { work.lands($0.stamp) }.map(\.item)
    }
}

/// The person's approvals "for N minutes" (`approval.minutes`), each for one thing in one round: one session, until
/// the mind refuses this Mac's key. A new session or a refusal ends them all, and an approval
/// given in an older round is not kept.
public struct ApprovalGrants: Equatable, Sendable {
    /// A session (none while there is none), until the mind refuses this Mac's key: a stamp of
    /// `SessionWork`, which a refusal ends.
    public typealias Round = SessionWork.Stamp

    private struct Key: Hashable, Sendable {
        let generation: Int
        let thing: String
    }

    private var work = SessionWork()
    private var until: [Key: Date] = [:]

    public init() {}

    public var round: Round { work.stamp }

    /// Whether a use that began in `round` may still go on: no session and no refusal came since.
    /// (A use with no session is asked and goes on once; only `approve` needs a session.)
    public func holds(_ round: Round) -> Bool { round == work.stamp }

    /// Until when `thing` is approved in this round; nil when it is not.
    public func isApproved(_ thing: String, now: Date) -> Date? {
        guard let generation = round.generation, let date = until[Key(generation: generation, thing: thing)], date > now else { return nil }
        return date
    }

    /// False, and nothing kept, when `round` is not this one.
    @discardableResult
    public mutating func approve(_ things: [String], round: Round, until date: Date) -> Bool {
        guard work.lands(round), let generation = round.generation else { return false }
        for thing in things { until[Key(generation: generation, thing: thing)] = date }
        return true
    }

    public mutating func end(_ thing: String) {
        until = until.filter { $0.key.thing != thing }
    }

    /// Another session, or none: every approval ends.
    public mutating func use(generation: Int?) {
        work.use(generation: generation)
        until = [:]
    }

    /// The mind refused this Mac's key: every approval ends, and the session stays.
    public mutating func refuse() {
        work.end()
        until = [:]
    }
}
