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

/// The person's approvals "for 30 minutes", each for one thing in one round: one session, until
/// the mind refuses this Mac's key. A new session or a refusal ends them all, and an approval
/// given in an older round is not kept.
public struct ApprovalGrants: Equatable, Sendable {
    /// A session (none while there is none), and the refusals of the lend so far.
    public struct Round: Equatable, Sendable {
        public let generation: Int?
        public let refusals: Int
    }

    private struct Key: Hashable, Sendable {
        let generation: Int
        let thing: String
    }

    public private(set) var round = Round(generation: nil, refusals: 0)
    private var until: [Key: Date] = [:]

    public init() {}

    /// Until when `thing` is approved in this round; nil when it is not.
    public func isApproved(_ thing: String, now: Date) -> Date? {
        guard let generation = round.generation, let date = until[Key(generation: generation, thing: thing)], date > now else { return nil }
        return date
    }

    /// False, and nothing kept, when `round` is not this one.
    @discardableResult
    public mutating func approve(_ things: [String], round: Round, until date: Date) -> Bool {
        guard round == self.round, let generation = round.generation else { return false }
        for thing in things { until[Key(generation: generation, thing: thing)] = date }
        return true
    }

    public mutating func end(_ thing: String) {
        until = until.filter { $0.key.thing != thing }
    }

    /// Another session, or none: every approval ends.
    public mutating func use(generation: Int?) {
        round = Round(generation: generation, refusals: round.refusals)
        until = [:]
    }

    /// The mind refused this Mac's key: every approval ends, and the session stays.
    public mutating func refuse() {
        round = Round(generation: round.generation, refusals: round.refusals + 1)
        until = [:]
    }
}
