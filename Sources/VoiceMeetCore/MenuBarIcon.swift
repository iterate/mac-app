import Foundation

/// WHAT THE MENU BAR SHOWS: the face of the mind the Mac is lent to, or the iterate mark. Pure: the
/// app (`AppDelegate`) reads the lend, the face kept on disk and the mark's state, and asks this.
///
/// The face is the mind's icon in a circle, in colour. Every state of the mark stays on it:
/// - the lend at a glance is the face's tone: plain while live, dimmed while it connects, dimmed with
///   a slash through it while it is not lent (the mark's own three);
/// - green, red and orange (a banner, a use, the microphone or a camera on) are a ring at its edge;
/// - the record is the red dot at its lower right: filled while it records, a ring while paused;
/// - Always listen is the orange dot at its upper left.
///
/// With no mind, or a mind with no icon kept (none read yet, or one that did not load), the mark.
public enum MenuBarIcon: Equatable, Sendable {
    /// The iterate mark (`MenuBarMark`), with Always listen's dot or not.
    case mark(MenuBarMark, listens: Bool)
    /// The face of the mind at `mind`, with its badges.
    case face(mind: String, MenuBarFace)

    /// `mind` is the active mind's address (nil with none); `hasIcon` whether its icon is kept.
    /// `glance` is the lend's, which the face shows under a colour as well.
    public static func of(mark: MenuBarMark, glance: LendGlance, listens: Bool, mind: String?, hasIcon: Bool) -> MenuBarIcon {
        guard let mind, hasIcon else { return .mark(mark, listens: listens) }
        return .face(mind: mind, MenuBarFace(mark: mark, glance: glance, listens: listens))
    }

    /// One line for the log: "the iterate mark, live+recording", "the face of example.com, live, ring red".
    public var name: String {
        switch self {
        case .mark(let mark, let listens): return "the iterate mark, \(mark.name)\(listens ? ", listening" : "")"
        case .face(let mind, let face): return "the face of \(mind), \(face.name)"
        }
    }
}

/// The badges on a face in the menu bar (`MenuBarIcon`).
public struct MenuBarFace: Equatable, Sendable {
    /// The lend at a glance, as the face's tone.
    public enum Tone: String, Equatable, Sendable, CaseIterable {
        /// Lent: the face as it is.
        case plain
        /// Connecting: the face dimmed.
        case dimmed
        /// Not lent: the face dimmed, with a slash through it.
        case slashed
    }

    /// The colour at the face's edge: the mark's green, red and orange.
    public enum Ring: String, Equatable, Sendable, CaseIterable {
        case none, purple, green, red, orange
    }

    public let tone: Tone
    public let ring: Ring
    public let dot: RecordDot
    /// Always listen: the orange dot at the upper left.
    public let listens: Bool

    public init(tone: Tone, ring: Ring, dot: RecordDot, listens: Bool) {
        self.tone = tone
        self.ring = ring
        self.dot = dot
        self.listens = listens
    }

    /// The face of `mark`: its colour is the ring, and the lend's `glance` is the tone, also under
    /// a colour (the mark loses the glance while it is coloured; the face keeps it).
    public init(mark: MenuBarMark, glance: LendGlance, listens: Bool) {
        switch glance {
        case .live: tone = .plain
        case .connecting: tone = .dimmed
        case .down: tone = .slashed
        }
        switch mark.ink {
        case .purple: ring = .purple
        case .green: ring = .green
        case .red: ring = .red
        case .orange: ring = .orange
        case .live, .connecting, .down: ring = .none
        }
        dot = mark.dot
        self.listens = listens
    }

    /// A key for one drawing of it, and the log's words: "live", "dimmed, ring red, recording, listening".
    public var name: String {
        var words = [tone == .plain ? "live" : tone.rawValue]
        if ring != .none { words.append("ring \(ring.rawValue)") }
        if dot != .none { words.append(dot.rawValue) }
        if listens { words.append("listening") }
        return words.joined(separator: ", ")
    }
}
