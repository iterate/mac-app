import Foundation

/// SPEECH AS TEXT: the pure rules of the app's dictation (README, "Dictation"). The speech model
/// and the microphone are in the `SpeechText` target; what is here needs neither.

/// The sound of one stretch of speech, at 16 kHz, while it grows. The listener writes the whole
/// stretch as text again and again while the person talks, so a stretch must stay short: it ends
/// at a pause, or at its quietest moment when it gets too long. The text of an ended stretch is
/// final, and the next stretch starts empty.
public struct SpeechStretch: Sendable {
    public static let rate = 16_000
    /// 20 ms: the piece whose loudness is measured.
    static let frame = 320
    /// A stretch ends at a pause this long, once it has `least` seconds.
    public static let pause = 0.7
    public static let least = 2.0
    /// The speech model takes 15 s at once; a longer stretch is cut.
    public static let most = 14.0

    public private(set) var samples: [Float] = []
    /// The loudness (RMS) of each whole frame.
    private var levels: [Float] = []

    public init() {}

    public var seconds: Double { Double(samples.count) / Double(Self.rate) }

    public mutating func append(_ more: [Float]) {
        samples.append(contentsOf: more)
        while (levels.count + 1) * Self.frame <= samples.count {
            let start = levels.count * Self.frame
            var sum: Float = 0
            for sample in samples[start..<start + Self.frame] { sum += sample * sample }
            levels.append((sum / Float(Self.frame)).squareRoot())
        }
    }

    /// A frame is quiet when it is far below the loudest one of the stretch. A room with no speech
    /// has no quiet frame by this rule, and so no pause: its stretch ends by its length.
    private var quiet: Float { max(0.002, (levels.max() ?? 0) * 0.1) }

    /// How long it has been quiet at the end.
    public var quietSeconds: Double {
        let quiet = quiet
        let frames = levels.reversed().prefix { $0 < quiet }.count
        return Double(frames * Self.frame) / Double(Self.rate)
    }

    /// Where the stretch ends now, as a count of samples, or nil while it goes on: all of it at a
    /// pause, or the quietest frame of its last 4 seconds when it is too long.
    public var end: Int? {
        if seconds >= Self.least, quietSeconds >= Self.pause, quietSeconds < seconds { return samples.count }
        guard seconds >= Self.most else { return nil }
        let from = max(0, levels.count - 4 * Self.rate / Self.frame)
        guard let quietest = levels.indices[from...].min(by: { levels[$0] < levels[$1] }) else { return samples.count }
        return max(Self.frame, quietest * Self.frame)
    }

    /// The first `count` samples go: they were one stretch. What came after them starts the next.
    public mutating func removeFirst(_ count: Int) {
        let rest = Array(samples.dropFirst(count))
        self = SpeechStretch()
        append(rest)
    }
}

public enum Spoken {
    /// Two pieces of text as one, with one space between them when both have words.
    public static func join(_ first: String, _ second: String) -> String {
        let first = first.trimmingCharacters(in: .whitespacesAndNewlines)
        let second = second.trimmingCharacters(in: .whitespacesAndNewlines)
        return first.isEmpty ? second : second.isEmpty ? first : "\(first) \(second)"
    }

    public static func wordCount(_ text: String) -> Int {
        text.split(whereSeparator: \.isWhitespace).count
    }

    /// What was said after the first `count` words. The person changed the text by hand: the words
    /// that were there at that moment are theirs now, and only later words still come in.
    public static func rest(of text: String, afterWords count: Int) -> String {
        text.split(whereSeparator: \.isWhitespace).dropFirst(count).joined(separator: " ")
    }

    /// Spoken words as they go into a text, between the character before them and the one after:
    /// a space on each side where two words would touch.
    public static func fitted(_ spoken: String, after before: Character?, before after: Character?) -> String {
        guard !spoken.isEmpty else { return "" }
        let lead = before.map { !$0.isWhitespace } ?? false
        let trail = after.map { !$0.isWhitespace && !$0.isPunctuation } ?? false
        return (lead ? " " : "") + spoken + (trail ? " " : "")
    }
}

/// THE DICTATION KEY: hold it and talk, and the text is written when the key comes up. A short
/// press (a tap) starts a dictation that goes on with no key held: the next press ends it.
public struct DictationKey: Equatable, Sendable {
    public enum Act: Equatable, Sendable {
        case nothing
        case start
        case finish
    }

    /// A press shorter than this is a tap.
    public static let tap: TimeInterval = 0.35

    public private(set) var isOn = false
    private var downAt: Date?

    public init() {}

    public mutating func pressed(at: Date) -> Act {
        if isOn {
            isOn = false
            downAt = nil
            return .finish
        }
        isOn = true
        downAt = at
        return .start
    }

    public mutating func released(at: Date) -> Act {
        guard isOn, let downAt else { return .nothing }
        self.downAt = nil
        if at.timeIntervalSince(downAt) < Self.tap { return .nothing }
        isOn = false
        return .finish
    }

    /// The dictation ended for another reason (it failed, or the app ended it).
    public mutating func ended() {
        isOn = false
        downAt = nil
    }
}

/// A text that the person types and speaks at once (the input bar). What they typed is theirs; the
/// words of the listening that is going come after it, and change while the model hears more.
/// When the person changes the text by hand, everything in it at that moment is theirs, and only
/// the words said after that still come in.
public struct SpokenText: Equatable, Sendable {
    public private(set) var base: String
    private var said = ""
    /// The words of `said` that are in `base` already.
    private var taken = 0

    public init(base: String) {
        self.base = base
    }

    public var text: String {
        base + Spoken.fitted(Spoken.rest(of: said, afterWords: taken), after: base.last, before: nil)
    }

    /// Everything said in this listening so far.
    public mutating func heard(_ said: String) {
        self.said = said
    }

    /// The person changed the text to this.
    public mutating func edited(_ text: String) {
        base = text
        taken = Spoken.wordCount(said)
    }
}
