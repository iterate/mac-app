import Foundation

/// ONE FINAL SEGMENT of speech as a recognizer writes it: its text, and its times in seconds from
/// the recognizer's start. Its words carry their own times, as the model heard them (before the
/// word list's repair).
public struct SpeechSegment: Equatable, Sendable {
    public struct Word: Equatable, Sendable {
        public let start: Double
        public let end: Double
        public let text: String

        public init(start: Double, end: Double, text: String) {
            self.start = start
            self.end = end
            self.text = text
        }
    }

    public let start: Double
    public let end: Double
    public let text: String
    public let words: [Word]

    public init(start: Double, end: Double, text: String, words: [Word] = []) {
        self.start = start
        self.end = end
        self.text = text
        self.words = words
    }

    /// The segment as the transcript of a capture holds it, and as the app sends it to the job
    /// `capture` (`bridge/capture.mjs`): milliseconds, `{ t, to, text, words: [{ t, to, text }] }`.
    public var transcriptEntry: [String: Any] {
        let ms = { (seconds: Double) in Int((seconds * 1000).rounded()) }
        return [
            "t": ms(start), "to": ms(end), "text": text,
            "words": words.map { ["t": ms($0.start), "to": ms($0.end), "text": $0.text] as [String: Any] },
        ]
    }
}
