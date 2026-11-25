import Foundation

/// WHERE A PERSON'S CAPTURE IS (⌥⇧S, `Capture`), and what a press of its key does then. One
/// capture at a time: a press while one starts or ends does nothing, so that a second press
/// during the start's waits makes no second capture.
public enum CapturePhase: Equatable, Sendable {
    case idle
    /// From the press to the first frame: the permission, the display, the stream.
    case starting
    case running
    /// From the press that ends it to the last line to its job: the last picture, the movie, the voice.
    case ending

    public enum Act: Equatable, Sendable {
        case start
        case end
        case nothing
    }

    /// ⌥⇧S, the pill's Send, `capture.toggle`, and the end of the longest capture.
    public var toggle: Act {
        switch self {
        case .idle: return .start
        case .running: return .end
        case .starting, .ending: return .nothing
        }
    }

    /// Whether the capture's voice comes from the microphone, and whether to ask macOS first.
    public enum Microphone: Equatable, Sendable {
        /// macOS has not asked the person: ask, then hear when they allow it.
        case ask
        case on
        case off
    }

    /// A copy with a home of its own (the harness) opens no microphone and asks for none: what it
    /// does must not depend on this Mac's real permissions. Else: what macOS allows.
    public static func microphone(hasOwnHome: Bool, isAuthorized: Bool, isUndetermined: Bool) -> Microphone {
        if hasOwnHome { return .off }
        if isAuthorized { return .on }
        return isUndetermined ? .ask : .off
    }
}
