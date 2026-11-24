import Foundation

/// A FACT ON THE DEVICE'S CONTEXT `/devices/<name>` that the activity log shows. Each act of the
/// app with this Mac for the mind is two kept events, by one act id unique to it:
///
/// - `device/act-started { act, thing, doing, detail? }`: `thing` is the thing of the Mac (its id
///   in the settings: `commands`, `screen.1`, `microphone`), `doing` the words while it runs.
/// - `device/act-ended { act, did, failure? }`: `did` the words when it is over, `failure` why
///   it failed.
///
/// `device/presence-changed { state }` is the presence that the context last heard.
public enum DeviceFact: Equatable, Sendable {
    case actStarted(act: String, thing: String, doing: String, detail: String?)
    case actEnded(act: String, did: String, failure: String?)
    case presenceChanged(state: String)

    public static let actStartedType = "device/act-started"
    public static let actEndedType = "device/act-ended"
    public static let presenceChangedType = "device/presence-changed"

    public var type: String {
        switch self {
        case .actStarted: Self.actStartedType
        case .actEnded: Self.actEndedType
        case .presenceChanged: Self.presenceChangedType
        }
    }

    /// The event's payload, as it is appended.
    public var payload: [String: Any] {
        switch self {
        case let .actStarted(act, thing, doing, detail):
            var payload: [String: Any] = ["act": act, "thing": thing, "doing": doing]
            if let detail { payload["detail"] = detail }
            return payload
        case let .actEnded(act, did, failure):
            var payload: [String: Any] = ["act": act, "did": did]
            if let failure { payload["failure"] = failure }
            return payload
        case let .presenceChanged(state):
            return ["state": state]
        }
    }

    /// The idempotency key of an act's event (`<type>/<act>`): an event sent again is in the
    /// mind once. A presence event has none.
    public var idempotencyKey: String? {
        switch self {
        case let .actStarted(act, _, _, _): "\(Self.actStartedType)/\(act)"
        case let .actEnded(act, _, _): "\(Self.actEndedType)/\(act)"
        case .presenceChanged: nil
        }
    }

    /// The fact of an event's type and payload; nil for another type or a payload without its
    /// fields.
    public init?(type: String, payload: [String: Any]) {
        let text = { (key: String) in payload[key] as? String }
        switch type {
        case Self.actStartedType:
            guard let act = text("act"), let thing = text("thing"), let doing = text("doing") else { return nil }
            self = .actStarted(act: act, thing: thing, doing: doing, detail: text("detail"))
        case Self.actEndedType:
            guard let act = text("act"), let did = text("did") else { return nil }
            self = .actEnded(act: act, did: did, failure: text("failure"))
        case Self.presenceChangedType:
            guard let state = text("state") else { return nil }
            self = .presenceChanged(state: state)
        default:
            return nil
        }
    }
}

/// One event of the context as the log takes it: the fact, when it happened, and its offset in
/// the context. An event that this app made and the context has not echoed yet has no offset.
public struct ContextEvent: Equatable, Sendable {
    public let fact: DeviceFact
    public let at: Date
    public let offset: Int?

    public init(_ fact: DeviceFact, at: Date, offset: Int? = nil) {
        self.fact = fact
        self.at = at
        self.offset = offset
    }

    /// An event as the device-events bridge writes it: `{ type, payload, offset, createdAt }`.
    public init?(json: [String: Any]) {
        guard let type = json["type"] as? String, let payload = json["payload"] as? [String: Any],
            let fact = DeviceFact(type: type, payload: payload), let offset = json["offset"] as? Int,
            let createdAt = json["createdAt"] as? String, let at = Self.time(createdAt)
        else { return nil }
        self.init(fact, at: at, offset: offset)
    }

    private static func time(_ text: String) -> Date? {
        let withFraction = ISO8601DateFormatter()
        withFraction.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return withFraction.date(from: text) ?? ISO8601DateFormatter().date(from: text)
    }
}

/// THE ACTIVITY LOG AS A VIEW OF THE CONTEXT: the started and ended events, folded by act id into
/// one row each, the newest first. An event that this app made goes in at once, before the
/// context echoes it; the echo is the same act, so a row is never shown twice. A row whose events
/// the context has not echoed yet is not yet in the mind.
public struct ActivityFold: Equatable, Sendable {
    public struct Row: Identifiable, Equatable, Sendable {
        public let act: String
        /// The order in which the fold first saw the act.
        public let order: Int
        public var thing: String
        public var doing: String
        public var detail: String?
        public var startedAt: Date
        public var did: String?
        public var failure: String?
        public var endedAt: Date?
        /// This app made the act in this session: only such an act can still run. An act in the
        /// context with no end was cut short (the app ended while it ran).
        public var isMadeHere: Bool
        var startIsInMind: Bool
        var endIsInMind: Bool

        public var id: String { act }
        public var isRunning: Bool { endedAt == nil && isMadeHere }
        /// The context holds each event of the act.
        public var isInMind: Bool { startIsInMind && (endedAt == nil || endIsInMind) }
    }

    public struct Presence: Equatable, Sendable {
        public let state: String
        public let at: Date
    }

    /// At most `kept` rows, the newest start first.
    public private(set) var rows: [Row] = []
    /// The newest presence fact.
    public private(set) var presence: Presence?
    public static let kept = 50
    private var seen = 0

    public init() {}

    /// Takes one event. The answer is true when the event started an act the fold did not have.
    @discardableResult
    public mutating func take(_ event: ContextEvent) -> Bool {
        let isEcho = event.offset != nil
        switch event.fact {
        case let .presenceChanged(state):
            if presence.map({ $0.at <= event.at }) ?? true { presence = Presence(state: state, at: event.at) }
            return false
        case let .actStarted(act, thing, doing, detail):
            if let index = rows.firstIndex(where: { $0.act == act }) {
                rows[index].thing = thing
                rows[index].doing = doing
                rows[index].detail = detail
                // the context's time is the fact's; the app's own was a guess until the echo
                if isEcho { rows[index].startedAt = event.at }
                rows[index].startIsInMind = rows[index].startIsInMind || isEcho
                rows[index].isMadeHere = rows[index].isMadeHere || !isEcho
                sort()
                return false
            }
            seen += 1
            rows.append(Row(
                act: act, order: seen, thing: thing, doing: doing, detail: detail, startedAt: event.at,
                isMadeHere: !isEcho, startIsInMind: isEcho, endIsInMind: false))
            sort()
            return rows.contains { $0.act == act }
        case let .actEnded(act, did, failure):
            // the end of an act whose start the fold does not hold (older than its rows) is dropped
            guard let index = rows.firstIndex(where: { $0.act == act }) else { return false }
            rows[index].did = did
            rows[index].failure = failure
            if rows[index].endedAt == nil || isEcho { rows[index].endedAt = event.at }
            rows[index].endIsInMind = rows[index].endIsInMind || isEcho
            return false
        }
    }

    private mutating func sort() {
        rows.sort { $0.startedAt != $1.startedAt ? $0.startedAt > $1.startedAt : $0.order > $1.order }
        if rows.count > Self.kept { rows.removeLast(rows.count - Self.kept) }
    }
}
