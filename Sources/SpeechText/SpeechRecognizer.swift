import Foundation
import VoiceMeetCore

/// A RECOGNIZER: 16 kHz mono samples in, text out (README, "Dictation"). It takes the samples of
/// one source (the microphone, the audio fixture, or a capture's pushed buffers) and a word list
/// that stays as it was at the start, and it writes:
///
/// - `partial`: everything said so far, with the stretch that goes on, twice a second, as heard and
///   with the word list's corrections (`HeardText`);
/// - `segment`: a stretch that ended at a pause (`SpeechStretch`), final, with its times in seconds
///   from the recognizer's first sample.
///
/// The samples are kept while the model loads, at most `kept` seconds: older ones are dropped,
/// and the log says how much.
public final class SpeechRecognizer: @unchecked Sendable {
    public enum Event: Sendable {
        case loading(SpeechLoad)
        /// The model is ready: what was said since the start comes as text now.
        case ready
        case partial(HeardText)
        case segment(SpeechSegment)
        /// A line for the log: counts and times, never the words.
        case note(String)
        case failed(String)
    }

    /// The most seconds of sound that wait for the model.
    public static let kept = 60.0

    private let lock = NSLock()
    private var pending: [Float] = []
    /// The samples given so far, dropped ones too: the clock of `push(at:)`.
    private var given = 0
    private var dropped = 0
    private var isEnded = false
    private var isDropped = false
    private var work: Task<[SpeechSegment], Never>?

    private let model: SpeechModel
    private let words: WordList
    private let heard: @Sendable (Event) -> Void
    private let engine: (@Sendable () async throws -> SpeechEngine)?
    private let done: @Sendable () -> Void

    /// `engine` gives the model's engine (the transcriber's: `LocalSpeech` counts its use; a test's
    /// stands in for the model); with none, `SpeechModels` loads it. `start` is the time in seconds
    /// of the first sample: a capture's fallback starts where OpenAI's last segment ended. `done`
    /// runs once, when it wrote its last segment or was cancelled.
    public init(
        model: SpeechModel, words: WordList, start: Double = 0, engine: (@Sendable () async throws -> SpeechEngine)? = nil,
        done: @escaping @Sendable () -> Void = {}, heard: @escaping @Sendable (Event) -> Void
    ) {
        self.model = model
        self.words = words
        self.engine = engine
        self.done = done
        self.heard = heard
        given = Int((start * Double(SpeechStretch.rate)).rounded())
    }

    /// Starts to load the model and to write. Call it once.
    public func start() {
        work = Task { [self] in await write() }
    }

    /// The next samples. `at` is their time in seconds from the start, when the source knows it:
    /// a gap before them is filled with silence, so that the segments' times stay true.
    public func push(_ samples: [Float], at seconds: Double? = nil) {
        lock.lock()
        defer { lock.unlock() }
        guard !isEnded else { return }
        if let seconds {
            let gap = Int(seconds * Double(SpeechStretch.rate)) - given
            // a gap shorter than a frame is the clock's own jitter
            if gap > SpeechStretch.rate / 50 {
                let filled = min(gap, Int(Self.kept) * SpeechStretch.rate)
                pending.append(contentsOf: [Float](repeating: 0, count: filled))
                given += filled
            }
        }
        pending.append(contentsOf: samples)
        given += samples.count
        // While the model loads the oldest go, 10 s at a time: one move of the kept samples each
        // 10 s, not one at each push. `take` cuts to `kept` exactly.
        if pending.count > Self.most + 10 * SpeechStretch.rate { trim() }
    }

    private static let most = Int(kept) * SpeechStretch.rate

    /// Under the lock: at most `kept` seconds wait.
    private func trim() {
        guard pending.count > Self.most else { return }
        dropped += pending.count - Self.most
        pending.removeFirst(pending.count - Self.most)
    }

    /// Ends the input and answers every segment, the last stretch's too.
    public func finish() async -> [SpeechSegment] {
        end(dropped: false)
        return await work?.value ?? []
    }

    /// Ends the input. What was not yet written is dropped.
    public func cancel() {
        end(dropped: true)
    }

    private func end(dropped: Bool) {
        lock.lock()
        isEnded = true
        isDropped = isDropped || dropped
        lock.unlock()
    }

    /// What came since the last call: the samples, the index of the first one, and the state.
    private func take() -> (samples: [Float], first: Int, ended: Bool, dropped: Bool, overrun: Int) {
        lock.lock()
        defer { lock.unlock() }
        trim()
        let samples = pending
        pending.removeAll(keepingCapacity: true)
        let overrun = dropped
        dropped = 0
        return (samples, given - samples.count, isEnded, isDropped, overrun)
    }

    private func write() async -> [SpeechSegment] {
        defer { done() }
        let started = Date()
        let engine: SpeechEngine
        do {
            if let make = self.engine {
                engine = try await make()
            } else {
                engine = try await SpeechModels.shared.engine(model, words: words) { [heard] in heard(.loading($0)) }
            }
        } catch {
            end(dropped: true)
            heard(.failed("The speech model did not load: \(error.localizedDescription)"))
            return []
        }
        heard(.note("\(model.id) is ready after \(String(format: "%.1f", Date().timeIntervalSince(started))) s, with \(words.entries.count) terms"))
        heard(.ready)

        let rate = Double(SpeechStretch.rate)
        var segments: [SpeechSegment] = []
        var said = HeardText.empty
        var stretch = SpeechStretch()
        /// The index of the stretch's first sample.
        var stretchStart = 0
        var passes = 0
        /// A stretch as text: final, a segment with its times, and the text as heard.
        func segment(_ count: Int) async -> (SpeechSegment, HeardText)? {
            let samples = Array(stretch.samples.prefix(count))
            guard let heard = try? await engine.hear(samples, final: true) else { return nil }
            let corrected = HeardText(heard.text, words: words)
            let text = corrected.text
            guard !text.isEmpty else { return nil }
            let offset = Double(stretchStart) / rate
            let timed = heard.words.map { SpeechSegment.Word(start: offset + $0.start, end: offset + $0.end, text: $0.text) }
            // the words' own times, where the model gave them: the stretch starts before the voice
            let segment = SpeechSegment(
                start: timed.first?.start ?? offset, end: timed.last?.end ?? offset + Double(count) / rate, text: text, heard: corrected.heard,
                words: timed, model: model.id)
            return (segment, corrected)
        }
        func ended(_ count: Int) async {
            if let (done, corrected) = await segment(count) {
                segments.append(done)
                said = HeardText.join(said, corrected)
                heard(.segment(done))
            }
            stretch.removeFirst(count)
            stretchStart += count
        }
        while true {
            let (samples, first, isEnded, isDropped, overrun) = take()
            if isDropped { return [] }
            if overrun > 0 {
                heard(.note("dropped the oldest \(String(format: "%.1f", Double(overrun) / rate)) s: the model was not ready"))
            }
            if stretch.samples.isEmpty { stretchStart = first }
            stretch.append(samples)
            if isEnded {
                if !stretch.samples.isEmpty { await ended(stretch.samples.count) }
                heard(.note("heard \(String(format: "%.1f", Double(first + samples.count) / rate)) s as \(segments.count) segments, \(Spoken.wordCount(said.text)) words, in \(passes + 1) passes"))
                return segments
            }
            if !samples.isEmpty {
                passes += 1
                if let end = stretch.end {
                    await ended(end)
                    heard(.partial(said))
                } else if stretch.seconds >= 0.4, let partial = try? await engine.hear(stretch.samples, final: false) {
                    heard(.partial(HeardText.join(said, HeardText(partial.text, words: words))))
                }
            }
            try? await Task.sleep(nanoseconds: 400_000_000)
        }
    }
}
