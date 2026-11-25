import Foundation

/// THE WAIT FOR A PERMISSION after the guide: a look every `interval` for `lasts`, whether macOS
/// gave what a thing that is on waits for. Screen Recording shows only in a new process, so its
/// look starts one (`--check-screen-recording`): never two at a time, and never on the main thread.
/// Pure: the app's timer asks it at each look.
public struct GrantWatch: Equatable, Sendable {
    public static let interval: TimeInterval = 3
    public static let lasts: TimeInterval = 300

    public let startedAt: Date
    /// A new process asks now; its answer has not come.
    public private(set) var isProbing = false

    public init(startedAt: Date) {
        self.startedAt = startedAt
    }

    public func isOver(at now: Date) -> Bool { now.timeIntervalSince(startedAt) >= Self.lasts }

    /// At a look: true when a new process asks now. Not while one asks, nor after the wait.
    public mutating func probes(at now: Date, waitsForScreenRecording: Bool) -> Bool {
        guard waitsForScreenRecording, !isProbing, !isOver(at: now) else { return false }
        isProbing = true
        return true
    }

    /// The process answered (or did not start).
    public mutating func answered() {
        isProbing = false
    }
}
