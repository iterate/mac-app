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

/// The first answer of a finish within a time: the words, or nil when the time ran out.
private final class FinishOnce: @unchecked Sendable {
    let lock = NSLock()
    var continuation: CheckedContinuation<[SpeechSegment]?, Never>?
    func resume(_ answer: [SpeechSegment]?) {
        lock.withLock {
            continuation?.resume(returning: answer)
            continuation = nil
        }
    }
}

extension SpeechListening {
    public func push(_ samples: [Float]) { push(samples, at: nil) }

    /// `finish`, waiting at most `seconds`: nil when the time ran out (a model that still comes over
    /// a slow network). Then the listening is cancelled, and no segment comes after the answer.
    public func finish(within seconds: Double) async -> [SpeechSegment]? {
        let once = FinishOnce()
        let answer = await withCheckedContinuation { continuation in
            once.lock.withLock { once.continuation = continuation }
            Task { once.resume(await self.finish()) }
            Task {
                try? await Task.sleep(nanoseconds: UInt64(max(0, seconds) * 1_000_000_000))
                once.resume(nil)
            }
        }
        if answer == nil { cancel() }
        return answer
    }
}

extension SpeechRecognizer: SpeechListening {}

/// A SPEECH MODEL THAT HEARS AS THE SOUND COMES (OpenAI's realtime transcription). It is not a
/// `SpeechEngine`: `hear(samples, final:)` hears a whole stretch again at each pass, and its text
/// comes when asked; a stream hears each sample once, holds its own state on the server, and its
/// words come when the server sends them. So it has the smallest shape of its own: the sound in,
/// the words so far out (through the callback given when it opened), a commit for each segment, and
/// the final at the end.
public protocol SpeechStream: AnyObject, Sendable {
    /// The next 16 kHz mono samples.
    func push(_ samples: [Float])
    /// Commits the sound since the last commit, now: the next samples are the next segment's. The
    /// answer waits for the committed sound's text.
    func commit() -> @Sendable () async throws -> String
    /// The end of the sound: the last commit's text.
    func finish() async throws -> String
    func cancel()
}

/// THE RECOGNIZER OF A STREAMING MODEL, with a local model behind it (README, "Dictation"). It
/// opens the stream at its start and keeps every sample not yet answered (at most `kept` seconds),
/// so a stream that opens late loses no word: what was kept goes first. The stream's words so far
/// are the `partial`s, repaired by the word list. By default the whole sound is one segment, its
/// final (dictation, the input bar, a stretch of Always listen). With `segmentsAtPauses` (a
/// capture) each pause of `SpeechStretch` commits the sound so far: a segment with its times.
///
/// When the stream does not open, fails while the sound comes, or gives no final in time, the local
/// model hears what was kept and what comes after (`fallback`): the sound from the end of the last
/// segment that OpenAI answered, so nothing is heard twice. The log says why. Its events are then
/// this recognizer's.
public final class StreamRecognizer: SpeechListening, @unchecked Sendable {
    /// The stream, and where it came from for the log (`standby, mind`, `new, own key`).
    public typealias Open = @Sendable (_ text: @escaping @Sendable (String) -> Void, _ failed: @escaping @Sendable (String) -> Void) async throws -> (stream: SpeechStream, from: String)
    /// The local recognizer: its first sample is at `start` seconds; `reason` is why OpenAI failed.
    public typealias Fallback = @Sendable (_ start: Double, _ reason: String, _ heard: @escaping @Sendable (SpeechRecognizer.Event) -> Void) -> SpeechListening

    /// The most seconds kept for the local model.
    public static let kept = 300.0
    private static let most = Int(kept) * SpeechStretch.rate
    private static let rate = Double(SpeechStretch.rate)

    private let name: String
    private let words: WordList
    private let open: Open
    private let fallback: Fallback
    private let segmentsAtPauses: Bool
    private let heard: @Sendable (SpeechRecognizer.Event) -> Void
    private let ended: @Sendable () -> Void

    private let lock = NSLock()
    /// The samples not yet answered: `samples[0]` is sample `keptFrom` of the sound.
    private var samples: [Float] = []
    private var keptFrom = 0
    /// Every sample given, the dropped ones and the silence of a gap too: the clock of the times.
    private var given = 0
    private var stream: SpeechStream?
    private var local: SpeechListening?
    private var isEnded = false
    private var isCancelled = false
    private var hasEnded = false
    private var opening: Task<Void, Never>?
    private let started = Date()
    /// With `segmentsAtPauses`: the sound since the last cut, the cuts that wait for the stream to
    /// open, where the stream's next segment starts, the answers in their order, and the segments.
    private var pause = SpeechStretch()
    private var waitingCuts: [Int] = []
    private var segmentFrom = 0
    private var answering: Task<Void, Never>?
    private var segments: [SpeechSegment] = []

    /// `name` is the model's id, for the log and the segments. `ended` runs once, when the sound
    /// ends (`finish`) or at a cancel: the online model opens its next standby then.
    public init(
        name: String, words: WordList, segmentsAtPauses: Bool = false, open: @escaping Open, fallback: @escaping Fallback,
        ended: @escaping @Sendable () -> Void = {}, heard: @escaping @Sendable (SpeechRecognizer.Event) -> Void
    ) {
        self.name = name
        self.words = words
        self.segmentsAtPauses = segmentsAtPauses
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
                    // what was kept goes first, under the lock: a push waits for it. A cut that
                    // came meanwhile is committed where it was.
                    var from = keptFrom
                    for cut in waitingCuts {
                        stream.push(Array(samples[(from - keptFrom)..<(cut - keptFrom)]))
                        commit(stream, to: cut)
                        from = cut
                    }
                    waitingCuts = []
                    stream.push(Array(samples[(from - keptFrom)...]))
                    self.stream = stream
                    return false
                }
                if isLate { return stream.cancel() }
                let milliseconds = Int((Date().timeIntervalSince(started) * 1000).rounded())
                // a new socket's own opening: from its start to OpenAI's `session.created`
                let created = (stream as? OpenAIStream)?.createdAfter.map { "; session.created \(Int(($0 * 1000).rounded())) ms after the socket's start" } ?? ""
                heard(.note("\(name) is ready \(milliseconds) ms after the start (\(from)), with \(words.entries.count) terms\(from.hasPrefix("new") ? created : "")"))
                heard(.ready)
            } catch {
                _ = fallBack(error.localizedDescription)
            }
        }
    }

    /// `at` is the samples' time in seconds from the start, when the source knows it (a capture):
    /// a gap before them is silence, so that the segments' times stay true.
    public func push(_ samples: [Float], at seconds: Double? = nil) {
        lock.withLock {
            guard !isEnded else { return }
            var piece = samples
            if let seconds {
                let gap = Int(seconds * Self.rate) - given
                // a gap shorter than a frame is the clock's own jitter
                if gap > SpeechStretch.rate / 50 { piece = [Float](repeating: 0, count: min(gap, 60 * SpeechStretch.rate)) + samples }
            }
            self.samples.append(contentsOf: piece)
            given += piece.count
            // the oldest go 10 s at a time, not at each push
            if self.samples.count > Self.most + 10 * SpeechStretch.rate {
                let drop = self.samples.count - Self.most
                self.samples.removeFirst(drop)
                keptFrom += drop
            }
            if let local { local.push(piece) } else { stream?.push(piece) }
            guard segmentsAtPauses, local == nil else { return }
            pause.append(piece)
            guard pause.end != nil else { return }
            // the stream commits all it has: the cut is here, not at the pause's own end
            pause = SpeechStretch()
            if let stream { commit(stream, to: given) } else { waitingCuts.append(given) }
        }
    }

    /// Under the lock: the sound up to sample `to` is a segment. Its answer comes after the ones
    /// before it.
    private func commit(_ stream: SpeechStream, to: Int) {
        let wait = stream.commit()
        let from = segmentFrom
        segmentFrom = to
        let previous = answering
        answering = Task { [weak self] in
            let answer: Result<String, Error>
            do { answer = .success(try await wait()) } catch { answer = .failure(error) }
            await previous?.value
            switch answer {
            case .success(let text): self?.answered(text, from: from, to: to)
            case .failure(let error): _ = self?.fallBack(error.localizedDescription)
            }
        }
    }

    /// A segment's final: the kept sound up to its end goes. Nothing once the local model hears:
    /// it hears this sound too.
    private func answered(_ heardText: String, from: Int, to: Int) {
        let heardText = heardText.trimmingCharacters(in: .whitespacesAndNewlines)
        let text = words.repair(heardText)
        let segment: SpeechSegment? = lock.withLock {
            guard local == nil, !isCancelled else { return nil }
            let drop = min(max(0, to - keptFrom), samples.count)
            samples.removeFirst(drop)
            keptFrom += drop
            guard !text.isEmpty else { return nil }
            let segment = SpeechSegment(start: Double(from) / Self.rate, end: Double(to) / Self.rate, text: text, heard: heardText, model: name)
            segments.append(segment)
            return segment
        }
        if let segment { heard(.segment(segment)) }
    }

    public func finish() async -> [SpeechSegment] {
        let duration: Double = lock.withLock {
            isEnded = true
            return Double(given) / Self.rate
        }
        endOnce()
        // bounded: the stream's open has a time out of its own
        await opening?.value
        let (stream, local, from) = lock.withLock { (self.stream, self.local, segmentFrom) }
        if let local { return await localFinish(local) }
        guard let stream else { return [] }
        let ended = Date()
        do {
            let heardText = try await stream.finish()
            await lock.withLock { answering }?.value
            answered(heardText, from: from, to: Int(duration * Self.rate))
            if let local = lock.withLock({ self.local }) { return await localFinish(local) }
            let said = lock.withLock { segments }
            heard(.note("\(name): the final came \(seconds(since: ended)) s after the end of \(String(format: "%.1f", duration)) s, \(said.count) segments, \(Spoken.wordCount(said.map(\.text).joined(separator: " "))) words"))
            if let openAI = stream as? OpenAIStream {
                // what this listening costs: OpenAI's own count, against the sound and the socket's age
                let billed = openAI.billedSeconds.map { "\(Int($0)) s, $\(String(format: "%.4f", $0 / 60 * OpenAIStream.dollarsPerMinute))" } ?? "no usage given"
                heard(.note("\(name): OpenAI billed \(billed) for \(String(format: "%.1f", duration)) s of sound; the socket was open \(Int(Date().timeIntervalSince(openAI.made))) s"))
            }
            return said
        } catch {
            await lock.withLock { answering }?.value
            guard let local = fallBack(error.localizedDescription) else { return [] }
            return await localFinish(local)
        }
    }

    /// The stream's segments, then the local model's.
    private func localFinish(_ local: SpeechListening) async -> [SpeechSegment] {
        let rest = await local.finish()
        return lock.withLock { segments } + rest
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
    private func fallBack(_ reason: String) -> SpeechListening? {
        let (old, recognizer, isNew): (SpeechStream?, SpeechListening?, Bool) = lock.withLock {
            guard !isCancelled else { return (nil, nil, false) }
            if let local = self.local { return (nil, local, false) }
            let made = fallback(Double(keptFrom) / Self.rate, reason, heard)
            made.start()
            made.push(samples)
            self.local = made
            waitingCuts = []
            defer { self.stream = nil }
            return (self.stream, made, true)
        }
        old?.cancel()
        if isNew { heard(.note("\(name) failed after \(seconds(since: started)) s (\(reason)): the local model hears it")) }
        return recognizer
    }

    private func seconds(since date: Date) -> String { String(format: "%.2f", Date().timeIntervalSince(date)) }
}
