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
/// cleanly (its last words are written and go where they belonged) and then starts. This is the
/// one owner of the microphone's source for both; a capture pushes its own sound into a
/// recognizer of its own.
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

    /// The model of dictation, the input bar and capture: the stored choice.
    public var model: () -> SpeechModel = { .default }
    /// False in a home of its own with no audio fixture: no microphone opens there.
    public var mayOpenMicrophone = true
    /// What macOS allows for the microphone. An audio fixture needs no permission.
    public var authorization: () -> AVAuthorizationStatus = { environmentFixture != nil ? .authorized : AVCaptureDevice.authorizationStatus(for: .audio) }
    /// A line for the app's log: counts and times, never the words.
    public var log: (String) -> Void = { _ in }

    private let makeSource: () -> SpeechSource
    private let engine: (@Sendable (SpeechModel, WordList) async throws -> SpeechEngine)?

    /// `source` and `engine` stand in for the microphone and the model, for a test.
    public init(source: @escaping () -> SpeechSource = { speechSource() }, engine: (@Sendable (SpeechModel, WordList) async throws -> SpeechEngine)? = nil) {
        makeSource = source
        self.engine = engine
    }

    private struct Listening {
        let client: SpeechClient
        let round: Int
        let source: SpeechSource
        let recognizer: SpeechRecognizer
    }

    private var current: Listening?
    private var round = 0

    public func isListening(for client: SpeechClient) -> Bool { current?.client === client }
    public var isListening: Bool { current != nil }

    /// The line while the model comes, for the pill and the bar alike.
    public static func loadingLine(_ downloading: Double?) -> String {
        downloading.map { "Getting the speech model: \(Int($0 * 100))%. Talk now, it is kept." } ?? "Loading the speech model. Talk now, it is kept."
    }

    /// Opens the microphone for `client`, with a word list that stays as it is for this listening.
    /// Nil when it listens; else why not. `allowed` runs when macOS asked and the person allowed.
    public func start(_ client: SpeechClient, words: WordList, allowed: (() -> Void)? = nil) -> Refusal? {
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
        round += 1
        let round = round
        let model = model()
        let engine = self.engine.map { make in { @Sendable in try await make(model, words) } }
        let recognizer = SpeechRecognizer(model: model, words: words, engine: engine) { [weak self] event in
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.heard(event, round: round, client: client) } }
        }
        let source = makeSource()
        let audio = SpeechAudio()
        do {
            try source.start({ [weak self] buffer in
                let samples = audio.samples(of: buffer)
                guard !samples.isEmpty else { return }
                recognizer.push(samples)
                let level = SpeechAudio.level(of: samples)
                DispatchQueue.main.async { MainActor.assumeIsolated { if self?.current?.round == round { client.speech(.level(level)) } } }
            }, failed: { [weak self] reason in
                // the source stopped by itself (the microphone went away): as a failed model
                DispatchQueue.main.async { MainActor.assumeIsolated { self?.heard(.failed(reason), round: round, client: client) } }
            })
        } catch {
            recognizer.cancel()
            return .failed(error.localizedDescription)
        }
        current = Listening(client: client, round: round, source: source, recognizer: recognizer)
        recognizer.start()
        log("listening \(round) starts with \(model.id), \(words.entries.count) terms\(hearsFixture ? ", from the audio fixture" : "")")
        client.speech(.phase(model.isOnDisk ? .listening : .loading(downloading: 0)))
        return nil
    }

    /// Closes the microphone; `.ended` brings the final text a moment later.
    public func finish(_ client: SpeechClient) {
        guard let listening = current, listening.client === client else { return }
        current = nil
        listening.source.stop()
        Task { @MainActor in
            let said = await listening.recognizer.finish().reduce("") { Spoken.join($0, $1.text) }
            listening.client.speech(.ended(said))
        }
    }

    /// Closes the microphone and drops what was not written.
    public func cancel(_ client: SpeechClient) {
        guard let listening = current, listening.client === client else { return }
        current = nil
        listening.source.stop()
        listening.recognizer.cancel()
    }

    private func heard(_ event: SpeechRecognizer.Event, round: Int, client: SpeechClient) {
        if case .note(let note) = event { return log("listening \(round): \(note)") }
        guard current?.round == round else { return }
        switch event {
        case .loading(.downloading(let part)): client.speech(.phase(.loading(downloading: part)))
        case .loading(.loading): client.speech(.phase(.loading(downloading: nil)))
        case .ready: client.speech(.phase(.listening))
        case .partial(let said): client.speech(.text(said))
        case .failed(let reason):
            current?.source.stop()
            current?.recognizer.cancel()
            current = nil
            log("listening \(round) failed: \(reason)")
            client.speech(.failed(reason))
        case .segment, .note: break
        }
    }
}
