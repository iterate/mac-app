import Foundation

/// THIS MAC IN A CALL (README, "A call's camera or screen from this Mac"): the rules of
/// `call.publish`, pure. A member's page asks the Mac to send one of its screens or its camera into
/// the call on an agent's context; the app sends it to the call's SFU from the recorder's own
/// capture (`CallSender` in `Sources/Live`), through the job `call` of the mind's process.

/// What a call asks of this Mac: a screen by its number in `state().things`, or the camera.
public enum CallSource: Equatable, Hashable, Sendable {
    case screen(Int)
    case camera

    /// `"screen:<display>"` or `"camera"`; anything else is nil.
    public init?(_ text: String) {
        if text == "camera" { self = .camera; return }
        let parts = text.split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count == 2, parts[0] == "screen", let display = Int(parts[1]), display >= 0, display < 64 else { return nil }
        self = .screen(display)
    }

    public var text: String {
        switch self {
        case .camera: return "camera"
        case .screen(let display): return "screen:\(display)"
        }
    }

    /// The facet's name of the track: `camera` or `screen` (call/rules.ts `KINDS`).
    public var kind: String {
        switch self {
        case .camera: return "camera"
        case .screen: return "screen"
        }
    }
}

/// THE PUBLICATIONS: which calls this Mac sends what to. One screen and one camera for each call:
/// a second screen for the same call replaces the first. At most `most` in all.
public struct CallPublications: Equatable, Sendable {
    public struct Publication: Equatable, Sendable {
        public let id: String
        /// The agent's path whose call it is.
        public let context: String
        public let source: CallSource
        /// The asking page's subscription row: its leave ends this one.
        public let asker: String?
        /// Who asked, for Activity: the caller's words.
        public let who: String
        public let since: Date
        /// The SFU has the picture: the peer connection connected.
        public var connected = false

        public init(id: String, context: String, source: CallSource, asker: String?, who: String, since: Date) {
            self.id = id
            self.context = context
            self.source = source
            self.asker = asker
            self.who = who
            self.since = since
        }
    }

    public static let most = 4
    public private(set) var all: [Publication] = []

    public init() {}

    /// The ids a new publication of `source` into `context` replaces: the same call's same kind.
    public func replaced(by source: CallSource, in context: String) -> [String] {
        all.filter { $0.context == context && $0.source.kind == source.kind }.map(\.id)
    }

    /// Why a new one is refused, or nil. Replaced ones do not count.
    public func refusal(adding source: CallSource, in context: String) -> String? {
        let staying = all.count - replaced(by: source, in: context).count
        return staying >= Self.most ? "This Mac sends \(Self.most) pictures into calls already, its most. End one first (call.unpublish)." : nil
    }

    public mutating func add(_ publication: Publication) { all.append(publication) }

    @discardableResult
    public mutating func remove(_ id: String) -> Publication? {
        guard let index = all.firstIndex(where: { $0.id == id }) else { return nil }
        return all.remove(at: index)
    }

    public mutating func connected(_ id: String) {
        if let index = all.firstIndex(where: { $0.id == id }) { all[index].connected = true }
    }

    /// The ids `call.unpublish` names: one by its id, or every one of a context (and a source).
    /// Nothing named is nothing.
    public func named(publication: String?, context: String?, source: String?) -> [String] {
        if let publication { return all.filter { $0.id == publication }.map(\.id) }
        guard let context else { return [] }
        return all.filter { $0.context == context && (source == nil || $0.source.text == source) }.map(\.id)
    }

    /// The ones whose thing the owner turned off: `isOff(source)` reads the choice now.
    public func turnedOff(_ isOff: (CallSource) -> Bool) -> [String] { all.filter { isOff($0.source) }.map(\.id) }
}

/// THE GATE of a publication: a use of the display or the camera, as a snapshot is. Off refuses
/// with the owner's words; Ask asks once for the whole publication; Shared sends.
public enum CallGate {
    /// The words of a refusal for `gate`, or nil when the use may go on (perhaps after a question).
    public static func refusal(_ gate: UseGate, thing: String) -> String? {
        switch gate {
        case .off: return "The Mac's owner has \(thing) off in the iterate panel: a call cannot have it."
        case .notPermitted: return "macOS has not given this app the permission for \(thing). The Mac's owner gives it from the iterate panel."
        case .ask, .go: return nil
        }
    }
}

/// THE SIZE A SCREEN GOES AT: its own aspect, within 1920 × 1200, never larger than it is, in even
/// pixels (H.264 takes even sizes).
public enum CallFit {
    public static func screen(width: Int, height: Int, most: (Int, Int) = (1920, 1200)) -> (width: Int, height: Int) {
        guard width > 0, height > 0 else { return most }
        let scale = min(1, Double(most.0) / Double(width), Double(most.1) / Double(height))
        let even = { (value: Double) in max(2, Int(value.rounded(.down)) & ~1) }
        return (even(Double(width) * scale), even(Double(height) * scale))
    }
}

/// THE SFU'S DESCRIPTIONS, as the kit's call sends them (`udpOnly`, packages/ui call-rules.ts):
/// no TCP candidate straight to the SFU. A relay's candidate is UDP, so TURN stays whole.
public enum CallSDP {
    public static func udpOnly(_ sdp: String) -> String {
        sdp.components(separatedBy: "\n")
            .map { $0.hasSuffix("\r") ? String($0.dropLast()) : $0 }
            .filter { line in !(line.lowercased().hasPrefix("a=candidate:") && line.lowercased().contains(" tcp ")) }
            .joined(separator: "\r\n")
    }
}
