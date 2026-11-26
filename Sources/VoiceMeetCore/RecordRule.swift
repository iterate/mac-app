import Foundation

/// The record's dot on the menu-bar mark, the mark's ink, and the rule by which a caller of the
/// endpoint may turn a switch of the record on. Pure: the app (`AppDelegate`, `AppModel`) reads
/// macOS and the person's choices, and asks these.

/// The small red dot at the mark's lower right.
public enum RecordDot: String, Equatable, Sendable, CaseIterable {
    /// The record is off: no dot.
    case none
    /// The record runs: a filled dot.
    case recording
    /// The record is on and paused (the Mac is locked or its displays sleep): a ring.
    case paused

    public static func of(isRecording: Bool, isPaused: Bool) -> RecordDot {
        isRecording ? (isPaused ? .paused : .recording) : .none
    }

    /// The words that follow the mark's own in its tooltip: "recording 4 tracks", "recording paused: locked".
    public func words(tracks: Int, pausedBecause: String?) -> String? {
        switch self {
        case .none: return nil
        case .recording: return "recording \(tracks) track\(tracks == 1 ? "" : "s")"
        case .paused: return "recording paused" + (pausedBecause.map { ": \($0)" } ?? "")
        }
    }
}

/// What the mark in the menu bar shows: its ink and the record's dot. The record never changes the
/// ink: orange says that the microphone or a camera is on for a call or a capture, and the dot
/// says that the record runs, so a camera turned on during an all-day record still shows.
public struct MenuBarMark: Equatable, Sendable {
    public enum Ink: String, Equatable, Sendable, CaseIterable {
        /// Somebody drives the Mac (a control session runs): first of all, and in no other
        /// colour, so that the owner sees it at once.
        case purple
        /// A banner shows, a call's among them.
        case green
        /// A mind used the Mac in the last 3 seconds.
        case red
        /// The microphone or a camera is on, or the person's capture runs.
        case orange
        /// Else the lend at a glance (`LendGlance`): plain, dimmed, dimmed and slashed.
        case live, connecting, down
    }

    public let ink: Ink
    public let dot: RecordDot

    public init(ink: Ink, dot: RecordDot) {
        self.ink = ink
        self.dot = dot
    }

    public static func of(
        drivenBy: String? = nil, bannerShows: Bool, inUse: Bool, microphoneOrCameraOn: Bool, glance: LendGlance, isRecording: Bool,
        isPaused: Bool
    ) -> MenuBarMark {
        let ink: Ink
        if drivenBy != nil {
            ink = .purple
        } else if bannerShows {
            ink = .green
        } else if inUse {
            ink = .red
        } else if microphoneOrCameraOn {
            ink = .orange
        } else {
            switch glance {
            case .live: ink = .live
            case .connecting: ink = .connecting
            case .down: ink = .down
            }
        }
        return MenuBarMark(ink: ink, dot: .of(isRecording: isRecording, isPaused: isPaused))
    }

    /// One word for the log: "orange", "live+recording".
    public var name: String { dot == .none ? ink.rawValue : "\(ink.rawValue)+\(dot.rawValue)" }

    /// The mark's words, for its tooltip and VoiceOver: what shows, then the record's dot.
    /// `banner` is the banner's title and whether it is a call's; `isCapturing` the person's own
    /// capture (⌥⇧S), which `microphoneOrCameraOn` includes.
    public static func label(
        drivenBy: String? = nil, banner: (title: String, isCall: Bool)?, inUse: Bool, isCapturing: Bool, microphoneOrCameraOn: Bool,
        glance: LendGlance, dot: RecordDot, tracks: Int, pausedBecause: String?
    ) -> String {
        let lendWords: String
        switch glance {
        case .live: lendWords = "iterate: lent"
        case .connecting: lendWords = "iterate: connecting"
        case .down: lendWords = "iterate: not lent"
        }
        let words =
            drivenBy.map { "iterate: \($0) drives this Mac (⌃⌥⌘Esc ends it)" }
            ?? banner.map { $0.isCall ? "iterate: \($0.title) calls" : "iterate: \($0.title)" }
            ?? (inUse ? "iterate: a mind uses this Mac now"
                : isCapturing ? "iterate: your capture runs" : microphoneOrCameraOn ? "iterate: microphone or camera on" : lendWords)
        return [words, dot.words(tracks: tracks, pausedBecause: pausedBecause)].compactMap { $0 }.joined(separator: ", ")
    }

    /// How long the mark stays red after a use by a mind.
    public static let inUseSeconds: Double = 3

    /// Whether a use at `lastUse` makes the mark red at `now`, and when it ends: the one moment at
    /// which the mark is looked at again (nil when it is not red).
    public static func inUse(lastUse: Date?, now: Date) -> (isInUse: Bool, endsAt: Date?) {
        guard let lastUse, now.timeIntervalSince(lastUse) < inUseSeconds else { return (false, nil) }
        return (true, lastUse.addingTimeInterval(inUseSeconds))
    }
}

/// A switch of the record that a caller can set: `record.set` on the endpoint.
public enum RecordSwitch: String, Equatable, Hashable, Sendable, CaseIterable {
    case screens, cameras, mics, speakers, windowText

    /// The power whose choice in the panel decides whether a caller may turn this switch on.
    /// The speakers are recorded through the screen's capture, so the screen's choice decides.
    public var power: String {
        switch self {
        case .screens, .speakers: return "screen"
        case .cameras: return "camera"
        case .mics: return "microphone"
        case .windowText: return "accessibility"
        }
    }

    /// What the record does, for the approval and for Activity: "record the screens".
    public var does: String {
        switch self {
        case .screens: return "record the screens"
        case .cameras: return "record the cameras"
        case .mics: return "record the microphone"
        case .speakers: return "record the sound of the speakers"
        case .windowText: return "record the text of the window in front"
        }
    }

    /// The switches a caller turns on with `wanted`: those it sets true that are not on now. Only
    /// these are a use of the Mac's powers; a switch turned off, or left as it is, is none.
    public static func turnedOn(from on: Set<RecordSwitch>, by wanted: [RecordSwitch: Bool]) -> [RecordSwitch] {
        allCases.filter { wanted[$0] == true && !on.contains($0) }
    }

    /// The switches that `wanted` turns off.
    public static func turnedOff(from on: Set<RecordSwitch>, by wanted: [RecordSwitch: Bool]) -> [RecordSwitch] {
        allCases.filter { wanted[$0] == false && on.contains($0) }
    }
}

/// How the endpoint answers a caller's use of one thing: the rule of `AppModel.use`, for a
/// snapshot, a listen and a switch of the record turned on alike.
public enum UseGate: Equatable, Sendable {
    /// The owner has the thing off.
    case off
    /// macOS has not given the app the permission the thing needs.
    case notPermitted
    /// The choice is Ask and no approval holds: the person is asked.
    case ask
    /// Shared, or Ask with an approval that holds.
    case go

    /// `sharing` is the panel's choice: "off", "ask" or "shared"; anything else is off.
    public static func decide(sharing: String, permitted: Bool, approved: Bool) -> UseGate {
        switch sharing {
        case "shared": return permitted ? .go : .notPermitted
        case "ask": return !permitted ? .notPermitted : approved ? .go : .ask
        default: return .off
        }
    }
}
