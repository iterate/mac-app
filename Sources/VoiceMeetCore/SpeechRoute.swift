import Foundation

/// Whether the lent mind opens OpenAI's sockets, as far as this session knows: found out with a
/// socket opened and closed at each new connection of its bridge, and by each dictation's socket.
public enum MindOpenAI: Sendable, Equatable {
    /// Not asked yet, or the last ask had no answer (no connection, no time).
    case unknown
    /// A socket opened: the mind has `/secrets/openai`, and OpenAI takes it.
    case yes
    /// It said no: no `/secrets/openai`, or OpenAI refused its key.
    case no
}

/// WHO PUTS SPEECH INTO WORDS: ONE RULE for every use (README, "Listening"). Speech-to-text is one
/// capability, and two providers satisfy it: OpenAI (through the lent mind, else this Mac's key) and
/// the local model (Oruk Fourier, or Parakeet when chosen). Dictation, the input bar, the capture
/// and Always listen ask this rule; none of them chooses a model.
///
/// OpenAI hears when it can be reached; the local model hears when it cannot. The person's choice
/// in Settings › Dictation ("On this Mac") overrides it for every use. A stretch whose OpenAI fails
/// while it goes (an error, no final) goes to the local model whole: that is the transcriber's
/// fallback, not this rule.
public struct SpeechRoute: Equatable, Sendable {
    public enum Provider: String, Equatable, Sendable {
        case openAI
        case local
    }

    /// The person's stored choice in Settings › Dictation.
    public enum Choice: Equatable, Sendable {
        /// No choice: the rule decides.
        case automatic
        /// "On this Mac": the local model, always.
        case onThisMac
        /// "OpenAI": OpenAI when it can be reached, as the rule does; else the local model, which
        /// must hear then.
        case openAI
    }

    public enum Why: Equatable, Sendable {
        /// OpenAI: the lent mind opens its sockets (or has not said no), or this Mac has a key.
        case reachable
        /// The local model: the person chose "On this Mac".
        case chosen
        /// The local model: this Mac has no network.
        case offline
        /// The local model: no lent mind opens OpenAI (none, or it said no) and this Mac has no key.
        case noOpenAI

        /// For the log and `ui.state`.
        public var words: String {
            switch self {
            case .reachable: "OpenAI can be reached"
            case .chosen: "\"On this Mac\" is chosen"
            case .offline: "the network is down"
            case .noOpenAI: "no mind with an OpenAI key and no key of this Mac"
            }
        }
    }

    public let provider: Provider
    public let why: Why

    public init(_ provider: Provider, _ why: Why) {
        self.provider = provider
        self.why = why
    }

    /// The rule. `mind` is what the lent mind can do (nil: lent to no mind); `hasKey`, whether this
    /// Mac has an OpenAI key of its own. A mind not asked yet comes first, as `OpenAIAccess` opens
    /// its sockets: when it says no, the stretch falls back and the next one is local.
    public static func pick(choice: Choice, isNetworkUp: Bool, mind: MindOpenAI?, hasKey: Bool) -> SpeechRoute {
        if choice == .onThisMac { return SpeechRoute(.local, .chosen) }
        if !isNetworkUp { return SpeechRoute(.local, .offline) }
        if let mind, mind != .no { return SpeechRoute(.openAI, .reachable) }
        return hasKey ? SpeechRoute(.openAI, .reachable) : SpeechRoute(.local, .noOpenAI)
    }
}

/// THE LOCAL MODEL LOADS ONLY WHEN IT MUST HEAR (README, "Listening"). Oruk Fourier's process
/// holds 2.6 GB, so on a normal day online it is never loaded. It is loaded when the rule picks it
/// (the network drops: loaded at once, so that an offline dictation finds it ready; no OpenAI; "On
/// this Mac"), or when OpenAI fails in a stretch (that stretch loads it). It is unloaded once the
/// rule picks OpenAI again and nothing used it for `idle` seconds.
public enum LocalModelLife {
    public enum Step: Equatable, Sendable {
        /// Load it now, for this reason.
        case load(String)
        /// Unload it now, for this reason.
        case unload(String)
        /// Ask again after this many seconds: the idle time is not over.
        case check(after: Double)
        /// Nothing to do until something changes.
        case stay
    }

    /// The next step. `isLoaded` counts a load that goes on; `users` are the stretches that the
    /// local model hears now; `idle` is the seconds since the last of: its last use ended, its load
    /// ended, OpenAI came back.
    public static func step(route: SpeechRoute, isLoaded: Bool, users: Int, idle: Double, limit: Double) -> Step {
        if route.provider == .local { return isLoaded ? .stay : .load(route.why.words) }
        // OpenAI hears: the model goes once nothing used it for the idle time
        guard isLoaded, users == 0 else { return .stay }
        if idle >= limit { return .unload("OpenAI hears again and the local model was unused for \(Int(limit)) s") }
        return .check(after: limit - idle)
    }
}
