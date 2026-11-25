import AVFoundation
import Foundation
import VoiceMeetCore

/// What a feature does with a foreground listening (dictation, the input bar).
@MainActor
public protocol SpeechClient: AnyObject {
    func speech(_ event: SpeechSession.Event)
}

/// THE FOREGROUND LISTENING: the microphone as text for dictation (⌥⇧D, fn) and for the input bar
/// (README, "Dictation"). One at a time: a second start, by the other feature, ends the first
/// cleanly (its last words are written and go where they belonged) and then starts. It reads the
/// microphone stream (`MicStream`, layer 1) from the start of a listening to its end, and it is a
/// feature of layer 4 on the transcription stream: each listening is a stretch (`dictation-<n>`,
/// `input-<n>`) that the one `Transcriber` hears (its rule picks OpenAI or the local model), and its
/// partials and final segments go to `transcribed`, with their wall times.
///
/// It holds what both features share: the permission, the model's progress, the numbering of the
/// listenings (a late word of an old one changes nothing) and the final text.
@MainActor
public final class SpeechSession {
    public enum Phase: Equatable, Sendable {
        /// The model comes: `downloading` is the part of its files from the network, nil while
        /// they are only loaded from this Mac. The microphone is open and what is said is kept.
        case loading(downloading: Double?)
        case listening
    }

    public enum Event: Sendable {
        case phase(Phase)
        /// Everything said so far.
        case text(String)
        case level(Float)
        case failed(String)
        /// The listening ended: everything said, final. It comes after `finish`, and after a start
        /// by the other feature; never after `cancel` or `failed`.
        case ended(String)
    }

    public enum Refusal: Equatable, Sendable {
        /// A home of its own opens no microphone unless an audio fixture is set.
        case ownHome
        /// macOS asks the person now.
        case asking
        /// macOS refused the microphone.
        case notAllowed
        /// The source did not start: the reason in words. No event comes.
        case failed(String)
    }

    /// Runs at each start, before the transcriber is asked (the app reads its key again then).
    public var willStart: () -> Void = {}
    /// False in a home of its own with no audio fixture: no microphone opens there.
    public var mayOpenMicrophone = true
    /// What macOS allows for the microphone. An audio fixture needs no permission.
    public var authorization: () -> AVAuthorizationStatus = { environmentFixture != nil ? .authorized : AVCaptureDevice.authorizationStatus(for: .audio) }
    /// A line for the app's log: counts and times, never the words.
    public var log: (String) -> Void = { _ in }
    /// The transcription stream: each listening's partials and final segments, on the main thread.
    public var transcribed: (TranscriptEvent) -> Void = { _ in }
    /// A listening started (`true`) or none listens now: Always listen holds while a key listens.
    public var onListening: (Bool) -> Void = { _ in }
    /// While `.ended` is told: the stretch that ended, the wall time of its first sample and of its
    /// end (the finish).
    public private(set) var ending: (stretch: String, start: Double, end: Double)?

    public let stream: MicStream
    public let transcriber: Transcriber

    public init(stream: MicStream = .shared, transcriber: Transcriber) {
        self.stream = stream
        self.transcriber = transcriber
    }

    /// `source` stands in for the microphone: a stream of its own on it.
    public convenience init(source: @escaping () -> SpeechSource, transcriber: Transcriber) {
        self.init(stream: MicStream(device: source), transcriber: transcriber)
    }

    /// The wall time of a listening's first sample: the zero of its segments' times.
    private final class Zero: @unchecked Sendable {
        private let lock = NSLock()
        private var time: Double?
        func set(_ value: Double) { lock.withLock { if time == nil { time = value } } }
        var value: Double { lock.withLock { time ?? Date().timeIntervalSince1970 } }
    }

    private struct Listening {
        let client: SpeechClient
        let round: Int
        let subscription: MicSubscription
        let recognizer: SpeechListening
        let stretch: String
        let origin: TranscriptSegment.Origin
        /// The model it started with: the rule's provider then.
        let model: SpeechModel
        let words: WordList
        let zero: Zero
    }

    private var current: Listening? {
        didSet { if (oldValue == nil) != (current == nil) { onListening(current != nil) } }
    }
    private var round = 0
    /// The segments of each listening that went to `transcribed` while it listened.
    private var published: [Int: Int] = [:]
    /// The newest text of the listening that goes, as heard and with its corrections.
    private var newest: HeardText?

    public func isListening(for client: SpeechClient) -> Bool { current?.client === client }

    /// What `client`'s listening heard so far, with the word list's corrections: the text of its
    /// newest `.text` event is this one's `text`. Nil when another one listens, or none.
    public func heard(for client: SpeechClient) -> HeardText? {
        isListening(for: client) ? newest : nil
    }
    public var isListening: Bool { current != nil }

    /// The line while the model comes, for the pill and the bar alike.
    public static func loadingLine(_ downloading: Double?) -> String {
        downloading.map { "Getting the speech model: \(Int($0 * 100))%. Talk now, it is kept." } ?? "Loading the speech model. Talk now, it is kept."
    }

    /// The stretch of `client`'s listening, and the wall time of its first sample.
    public func stretch(for client: SpeechClient) -> (id: String, start: Double)? {
        guard let current, current.client === client else { return nil }
        return (current.stretch, current.zero.value)
    }

    /// Opens the microphone for `client`, with a word list that stays as it is for this listening.
    /// Nil when it listens; else why not. `allowed` runs when macOS asked and the person allowed.
    /// `origin` names its stretches in the transcription stream.
    public func start(_ client: SpeechClient, words: WordList, origin: TranscriptSegment.Origin = .dictation, allowed: (() -> Void)? = nil) -> Refusal? {
        let hearsFixture = environmentFixture != nil
        guard mayOpenMicrophone else { return .ownHome }
        switch authorization() {
        case .authorized:
            break
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .audio) { isGranted in
                DispatchQueue.main.async { MainActor.assumeIsolated { if isGranted { allowed?() } } }
            }
            return .asking
        default:
            return .notAllowed
        }
        if let current { finish(current.client) }
        newest = nil
        round += 1
        let round = round
        willStart()
        let heard: @Sendable (SpeechRecognizer.Event) -> Void = { [weak self] event in
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.heard(event, round: round, client: client) } }
        }
        let (recognizer, model) = transcriber.listening(.live, words: words, heard: heard)
        let zero = Zero()
        let subscription: MicSubscription
        do {
            subscription = try stream.listen { [weak self] event in
                switch event {
                case .frame(let frame):
                    zero.set(frame.time)
                    recognizer.push(frame.samples)
                    let level = SpeechAudio.level(of: frame.samples)
                    DispatchQueue.main.async { MainActor.assumeIsolated { if self?.current?.round == round { client.speech(.level(level)) } } }
                case .failed(let reason):
                    // the microphone went away: as a failed model
                    DispatchQueue.main.async { MainActor.assumeIsolated { self?.heard(.failed(reason), round: round, client: client) } }
                }
            }
        } catch {
            recognizer.cancel()
            return .failed(error.localizedDescription)
        }
        current = Listening(
            client: client, round: round, subscription: subscription, recognizer: recognizer, stretch: "\(origin.rawValue)-\(round)", origin: origin,
            model: model, words: words, zero: zero)
        published[round] = 0
        recognizer.start()
        log("listening \(round) starts with \(model.id) (\(transcriber.current.route.why.words)), \(words.entries.count) terms\(hearsFixture ? ", from the audio fixture" : "")")
        client.speech(.phase(model.isOnDisk ? .listening : .loading(downloading: 0)))
        return nil
    }

    /// Closes the microphone; `.ended` brings the final text a moment later.
    public func finish(_ client: SpeechClient) {
        guard let listening = current, listening.client === client else { return }
        current = nil
        listening.subscription.cancel()
        let end = Date().timeIntervalSince1970
        Task { @MainActor in
            let segments = await listening.recognizer.finish()
            // the segments that came while it listened went already; the others go now, before the end
            for segment in segments.dropFirst(published.removeValue(forKey: listening.round) ?? 0) { publish(segment, of: listening) }
            let said = segments.reduce("") { Spoken.join($0, $1.text) }
            ending = (listening.stretch, listening.zero.value, end)
            listening.client.speech(.ended(said))
            ending = nil
        }
    }

    /// A final segment of `listening` into the transcription stream, with its wall times.
    private func publish(_ segment: SpeechSegment, of listening: Listening) {
        let zero = listening.zero.value
        transcribed(.segment(TranscriptSegment(
            stretch: listening.stretch, origin: listening.origin, start: zero + segment.start, end: zero + segment.end,
            heard: HeardText(segment.heard, words: listening.words), model: segment.model.isEmpty ? listening.model.id : segment.model)))
    }

    /// Closes the microphone and drops what was not written.
    public func cancel(_ client: SpeechClient) {
        guard let listening = current, listening.client === client else { return }
        current = nil
        published[listening.round] = nil
        listening.subscription.cancel()
        listening.recognizer.cancel()
    }

    private func heard(_ event: SpeechRecognizer.Event, round: Int, client: SpeechClient) {
        if case .note(let note) = event { return log("listening \(round): \(note)") }
        guard current?.round == round else { return }
        switch event {
        case .loading(.downloading(let part)): client.speech(.phase(.loading(downloading: part)))
        case .loading(.loading): client.speech(.phase(.loading(downloading: nil)))
        case .ready: client.speech(.phase(.listening))
        case .partial(let said):
            newest = said
            if let current { transcribed(.partial(stretch: current.stretch, origin: current.origin, heard: said)) }
            client.speech(.text(said.text))
        case .segment(let segment):
            guard let current else { break }
            publish(segment, of: current)
            published[round, default: 0] += 1
        case .failed(let reason):
            published[round] = nil
            current?.subscription.cancel()
            current?.recognizer.cancel()
            current = nil
            log("listening \(round) failed: \(reason)")
            client.speech(.failed(reason))
        case .note: break
        }
    }
}
