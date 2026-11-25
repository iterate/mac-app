import Foundation
import VoiceMeetCore

/// What `SpeechSession` drives for one listening: the samples in, the segments out. Two kinds:
/// `SpeechRecognizer` (a local model, which hears stretches again and again through
/// `SpeechEngine`) and `StreamRecognizer` (a model that hears as the sound streams). Both say what
/// they heard through `SpeechRecognizer.Event`.
public protocol SpeechListening: AnyObject, Sendable {
    func start()
    func push(_ samples: [Float], at seconds: Double?)
    func finish() async -> [SpeechSegment]
    func cancel()
}

extension SpeechListening {
    public func push(_ samples: [Float]) { push(samples, at: nil) }
}

extension SpeechRecognizer: SpeechListening {}

/// A SPEECH MODEL THAT HEARS AS THE SOUND COMES (OpenAI's realtime transcription). It is not a
/// `SpeechEngine`: `hear(samples, final:)` hears a whole stretch again at each pass, and its text
/// comes when asked; a stream hears each sample once, holds its own state on the server, and its
/// words come when the server sends them. So it has the smallest shape of its own: the sound in,
/// the words so far out (through the callback given when it opened), and the final at the end.
public protocol SpeechStream: AnyObject, Sendable {
    /// The next 16 kHz mono samples.
    func push(_ samples: [Float])
    /// The end of the sound: the final text.
    func finish() async throws -> String
    func cancel()
}

/// THE RECOGNIZER OF A STREAMING MODEL, with a local model behind it (README, "Dictation"). It
/// opens the stream at its start and keeps every sample (the last `kept` seconds), so a stream that
/// opens late loses no word: what was kept goes first. The stream's words so far are the
/// `partial`s, repaired by the word list; its final, repaired, is the one segment.
///
/// When the stream does not open, fails while the sound comes, or gives no final in time, the local
/// model hears what was kept and what comes after (`fallback`), and the log says why. Its events
/// are then this recognizer's.
public final class StreamRecognizer: SpeechListening, @unchecked Sendable {
    /// The stream, and where it came from for the log (`standby` or `new`).
    public typealias Open = @Sendable (_ text: @escaping @Sendable (String) -> Void, _ failed: @escaping @Sendable (String) -> Void) async throws -> (stream: SpeechStream, from: String)
    public typealias Fallback = @Sendable (_ heard: @escaping @Sendable (SpeechRecognizer.Event) -> Void) -> SpeechRecognizer

    /// The most seconds kept for the local model.
    public static let kept = 300.0
    private static let most = Int(kept) * SpeechStretch.rate

    private let name: String
    private let words: WordList
    private let open: Open
    private let fallback: Fallback
    private let heard: @Sendable (SpeechRecognizer.Event) -> Void
    private let ended: @Sendable () -> Void

    private let lock = NSLock()
    private var samples: [Float] = []
    /// Every sample given, the dropped ones too.
    private var given = 0
    private var stream: SpeechStream?
    private var local: SpeechRecognizer?
    private var isEnded = false
    private var isCancelled = false
    private var hasEnded = false
    private var opening: Task<Void, Never>?
    private let started = Date()

    /// `name` is the model's id, for the log. `ended` runs once, when the sound ends (`finish`) or
    /// at a cancel: the online model opens its next standby then.
    public init(
        name: String, words: WordList, open: @escaping Open, fallback: @escaping Fallback, ended: @escaping @Sendable () -> Void = {},
        heard: @escaping @Sendable (SpeechRecognizer.Event) -> Void
    ) {
        self.name = name
        self.words = words
        self.open = open
        self.fallback = fallback
        self.heard = heard
        self.ended = ended
    }

    public func start() {
        opening = Task { [self] in
            do {
                let (stream, from) = try await open({ [weak self] said in self?.said(said) }, { [weak self] reason in _ = self?.fallBack(reason) })
                let isLate: Bool = lock.withLock {
                    guard !isCancelled, local == nil else { return true }
                    // what was kept goes first, under the lock: a push waits for it
                    stream.push(samples)
                    self.stream = stream
                    return false
                }
                if isLate { return stream.cancel() }
                let milliseconds = Int((Date().timeIntervalSince(started) * 1000).rounded())
                heard(.note("\(name) is ready \(milliseconds) ms after the start (\(from)), with \(words.entries.count) terms"))
                heard(.ready)
            } catch {
                _ = fallBack(error.localizedDescription)
            }
        }
    }

    public func push(_ samples: [Float], at seconds: Double? = nil) {
        lock.withLock {
            guard !isEnded else { return }
            self.samples.append(contentsOf: samples)
            given += samples.count
            // the oldest go 10 s at a time, not at each push
            if self.samples.count > Self.most + 10 * SpeechStretch.rate { self.samples.removeFirst(self.samples.count - Self.most) }
            if let local { local.push(samples) } else { stream?.push(samples) }
        }
    }

    public func finish() async -> [SpeechSegment] {
        let duration: Double = lock.withLock {
            isEnded = true
            return Double(given) / Double(SpeechStretch.rate)
        }
        endOnce()
        // bounded: the stream's open has a time out of its own
        await opening?.value
        let (stream, local) = lock.withLock { (self.stream, self.local) }
        if let local { return await local.finish() }
        guard let stream else { return [] }
        let ended = Date()
        do {
            let text = words.repair(try await stream.finish().trimmingCharacters(in: .whitespacesAndNewlines))
            heard(.note("\(name): the final came \(seconds(since: ended)) s after the end of \(String(format: "%.1f", duration)) s, \(Spoken.wordCount(text)) words"))
            guard !text.isEmpty else { return [] }
            let segment = SpeechSegment(start: 0, end: duration, text: text)
            heard(.segment(segment))
            return [segment]
        } catch {
            guard let local = fallBack(error.localizedDescription) else { return [] }
            return await local.finish()
        }
    }

    public func cancel() {
        let (stream, local) = lock.withLock {
            isCancelled = true
            isEnded = true
            return (self.stream, self.local)
        }
        stream?.cancel()
        local?.cancel()
        opening?.cancel()
        endOnce()
    }

    private func endOnce() {
        let isFirst: Bool = lock.withLock {
            defer { hasEnded = true }
            return !hasEnded
        }
        if isFirst { ended() }
    }

    private func said(_ text: String) {
        guard lock.withLock({ local == nil && !isCancelled }) else { return }
        heard(.partial(HeardText(text, words: words)))
    }

    /// The local model hears from now on: what was kept, then what comes. Once; nil after a cancel.
    private func fallBack(_ reason: String) -> SpeechRecognizer? {
        let (old, recognizer, isNew): (SpeechStream?, SpeechRecognizer?, Bool) = lock.withLock {
            guard !isCancelled else { return (nil, nil, false) }
            if let local = self.local { return (nil, local, false) }
            let made = fallback(heard)
            made.start()
            made.push(samples)
            self.local = made
            defer { self.stream = nil }
            return (self.stream, made, true)
        }
        old?.cancel()
        if isNew { heard(.note("\(name) failed after \(seconds(since: started)) s (\(reason)): the local model hears it")) }
        return recognizer
    }

    private func seconds(since date: Date) -> String { String(format: "%.2f", Date().timeIntervalSince(date)) }
}

/// The recognizer of an online model for `SpeechSession`, or nil for a local one.
public enum OnlineSpeech {
    /// `key` reads the OpenAI key (off the main thread, at each start); `local` is the model that
    /// hears when OpenAI fails. `setup` and `fallback` stand in for OpenAI's address and time outs
    /// and for the local recognizer, for a test. `standby` is the socket that waits for the next
    /// listening (`OpenAIStandby`): taken at the start when it fits, opened again at the end.
    public static func recognizer(
        _ model: SpeechModel, words: WordList, key: @escaping @Sendable () -> String?, local: SpeechModel = .default,
        setup: OpenAIStream.Setup? = nil, fallback: StreamRecognizer.Fallback? = nil, standby: OpenAIStandby? = nil,
        heard: @escaping @Sendable (SpeechRecognizer.Event) -> Void
    ) -> SpeechListening? {
        guard model.runs == .openAI else { return nil }
        var setup = setup ?? OpenAIStream.Setup()
        setup.keywords = words.entries.map(\.term)
        return StreamRecognizer(
            name: model.id, words: words,
            open: { [setup] text, failed in
                guard let key = key() else { throw OpenAIStream.Failure.noKey }
                if let stream = await standby?.take(setup, key: key) {
                    // it may have closed since the ping: then a new one, as with no standby
                    if stream.attach(text: text, failed: failed) { return (stream, "standby") }
                    stream.cancel()
                }
                return (try await OpenAIStream.open(setup, key: key, text: text, failed: failed), "new")
            },
            fallback: fallback ?? { heard in SpeechRecognizer(model: local, words: words, heard: heard) },
            ended: { [setup] in standby?.prepare(setup, key: key) },
            heard: heard)
    }
}
