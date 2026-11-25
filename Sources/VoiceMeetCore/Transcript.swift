import Foundation

/// ONE FINAL SEGMENT OF THE TRANSCRIPTION STREAM (README, "Listening"): what a transcriber wrote
/// for a stretch of speech, with its times on the wall clock. The record keeps each one as a line
/// of its `transcript` track.
public struct TranscriptSegment: Equatable, Sendable {
    /// What heard it: a dictation (fn, ⌥⇧D), the input bar, or Always listen.
    public enum Origin: String, Sendable {
        case dictation, input, listen
    }

    /// The stretch it is part of (`listen-4`, `dictation-12`): a dictation with a local model has
    /// a segment for each pause, and all of them are one stretch.
    public let stretch: String
    public let origin: Origin
    /// Unix seconds.
    public let start: Double
    public let end: Double
    /// The text with the word list's corrections, as it is written.
    public let text: String
    /// As the model heard it.
    public let heard: String
    public let corrections: [WordCorrection]
    /// The model's id (`parakeet-v3`, `gpt-live-transcribe`).
    public let model: String

    public init(stretch: String, origin: Origin, start: Double, end: Double, heard: HeardText, model: String) {
        self.stretch = stretch
        self.origin = origin
        self.start = start
        self.end = end
        text = heard.text
        self.heard = heard.heard
        corrections = heard.corrections
        self.model = model
    }

    /// The segment as a line of the record's `transcript` track: JSON with sorted keys, times in
    /// Unix milliseconds, and a newline.
    public var line: Data {
        let ms = { (seconds: Double) in Int64((seconds * 1000).rounded()) }
        let object: [String: Any] = [
            "t": ms(start), "to": ms(end), "text": text, "heard": heard, "model": model, "by": origin.rawValue, "stretch": stretch,
            "corrections": corrections.map { ["heard": $0.heard, "term": $0.term] },
        ]
        let data = (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes])) ?? Data()
        return data + Data("\n".utf8)
    }
}

/// THE TRANSCRIPTION STREAM'S FINAL SEGMENTS, the newest `kept` of them, in memory: what the
/// features ask of what was said (README, "Listening").
public struct Transcript: Sendable {
    public static let kept = 200

    public private(set) var segments: [TranscriptSegment] = []

    public init() {}

    /// A new final segment. They come in the order they end, about.
    public mutating func add(_ segment: TranscriptSegment) {
        let index = segments.lastIndex { $0.end <= segment.end }.map { $0 + 1 } ?? 0
        segments.insert(segment, at: index)
        if segments.count > Self.kept { segments.removeFirst(segments.count - Self.kept) }
    }

    /// The words said between two times: each segment whose middle is in `from…to`, in time order.
    /// `of` keeps only the segments of one stretch.
    public func words(from: Double, to: Double, of stretch: String? = nil) -> String {
        segments
            .filter { stretch == nil || $0.stretch == stretch }
            .filter { (from...to).contains(($0.start + $0.end) / 2) }
            .sorted { $0.start < $1.start }
            .reduce("") { Spoken.join($0, $1.text) }
    }

    /// The last finished stretch: all segments of the stretch that ended last. `origin` keeps only
    /// those stretches (Always listen's alone).
    public func lastStretch(of origin: TranscriptSegment.Origin? = nil) -> (stretch: String, start: Double, end: Double, text: String)? {
        guard let last = segments.last(where: { origin == nil || $0.origin == origin }) else { return nil }
        let parts = segments.filter { $0.stretch == last.stretch }
        let text = parts.sorted { $0.start < $1.start }.reduce("") { Spoken.join($0, $1.text) }
        return (last.stretch, parts.map(\.start).min() ?? last.start, parts.map(\.end).max() ?? last.end, text)
    }
}

/// What the transcription stream says (README, "Listening").
public enum TranscriptEvent: Sendable {
    /// Ephemeral: the words so far of a stretch that goes on, with the word list's corrections.
    case partial(stretch: String, origin: TranscriptSegment.Origin, heard: HeardText)
    /// Final: recorded.
    case segment(TranscriptSegment)
}
