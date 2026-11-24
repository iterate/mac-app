import Foundation

/// THE FN KEY (🌐) FOR DICTATION, as Wispr Flow has it (README, "Dictation"): hold fn and talk, let
/// go and the text is written (push to talk); tap fn twice and talk with no key held, until the
/// next tap of fn (hands-free); Escape cancels. One short tap alone does nothing, and fn with
/// another key is that key's combination, not dictation.
///
/// The app feeds every change of fn, every other key and a tick while fn is down; this answers
/// what dictation does.
public struct FnKey: Equatable, Sendable {
    public enum Act: Equatable, Sendable {
        case nothing
        /// Push to talk: fn is held.
        case startHolding
        /// Hands-free: fn was tapped twice.
        case startHandsFree
        /// Write what was said.
        case finish
        /// Drop what was said.
        case cancel
    }

    public enum Mode: Equatable, Sendable {
        case holding
        case handsFree
    }

    /// fn down longer than this is a hold.
    public static let hold: TimeInterval = 0.2
    /// A second press this soon after a tap's release makes a double tap.
    public static let doubleTap: TimeInterval = 0.35

    private enum State: Equatable {
        case idle
        /// fn is down since `at`: a tap or a hold, not known yet.
        case down(at: Date)
        /// fn is down with another key: nothing until it comes up.
        case spoiled
        case holding
        case handsFree
        /// The press that ended hands-free: its release does nothing.
        case stopping
    }

    private var state = State.idle
    private var isDown = false
    /// When the last short tap came up.
    private var tappedAt: Date?

    public init() {}

    /// The dictation that this key runs now, if any.
    public var mode: Mode? {
        switch state {
        case .holding: return .holding
        case .handsFree: return .handsFree
        case .idle, .down, .spoiled, .stopping: return nil
        }
    }

    public mutating func fnDown(at time: Date) -> Act {
        guard !isDown else { return .nothing }
        isDown = true
        switch state {
        case .handsFree:
            state = .stopping
            return .finish
        case .idle:
            if let tappedAt, time.timeIntervalSince(tappedAt) <= Self.doubleTap {
                self.tappedAt = nil
                state = .handsFree
                return .startHandsFree
            }
            state = .down(at: time)
            return .nothing
        case .down, .spoiled, .holding, .stopping:
            return .nothing
        }
    }

    public mutating func fnUp(at time: Date) -> Act {
        guard isDown else { return .nothing }
        isDown = false
        switch state {
        case .down(let at):
            state = .idle
            // a tap: the first half of a double tap. A long press that no tick saw is no tap.
            tappedAt = time.timeIntervalSince(at) <= Self.hold ? time : nil
            return .nothing
        case .holding:
            state = .idle
            return .finish
        case .spoiled, .stopping:
            state = .idle
            return .nothing
        case .idle, .handsFree:
            return .nothing
        }
    }

    /// While fn is down, a few times a second: a press becomes a hold.
    public mutating func tick(at time: Date) -> Act {
        guard case .down(let at) = state, time.timeIntervalSince(at) > Self.hold else { return .nothing }
        state = .holding
        return .startHolding
    }

    /// Another key went down. With fn held it is a combination: a hold that started is cancelled.
    public mutating func otherKey() -> Act {
        tappedAt = nil
        guard isDown else { return .nothing }
        switch state {
        case .down:
            state = .spoiled
            return .nothing
        case .holding:
            state = .spoiled
            return .cancel
        case .idle, .spoiled, .handsFree, .stopping:
            return .nothing
        }
    }

    public mutating func escape() -> Act {
        switch state {
        case .holding, .handsFree:
            state = isDown ? .spoiled : .idle
            return .cancel
        case .idle, .down, .spoiled, .stopping:
            return .nothing
        }
    }

    /// The dictation ended for another reason (it failed, or another key started one).
    public mutating func ended() {
        tappedAt = nil
        state = isDown ? .spoiled : .idle
    }
}
