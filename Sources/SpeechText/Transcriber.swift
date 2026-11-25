import Foundation
import VoiceMeetCore

/// How the transcriber gets the local model's engine: `LocalSpeech` loads it (with the reason, for
/// the log) and counts each use until `done`. A test's engines stand in for the model.
public struct LocalEngines: Sendable {
    public typealias Engine = @Sendable (
        _ model: SpeechModel, _ words: WordList, _ why: String, _ progress: @escaping @Sendable (SpeechLoad) -> Void
    ) async throws -> SpeechEngine

    public var engine: Engine
    /// A use that got its engine ended.
    public var done: @Sendable () -> Void

    public init(engine: @escaping Engine, done: @escaping @Sendable () -> Void = {}) {
        self.engine = engine
        self.done = done
    }

    /// One engine for every model, with no load and no count: a test's.
    public static func fixed(_ make: @escaping @Sendable (SpeechModel, WordList) async throws -> SpeechEngine) -> LocalEngines {
        LocalEngines(engine: { model, words, _, _ in try await make(model, words) })
    }
}

/// THE TRANSCRIBER: speech-to-text as ONE capability (README, "Listening", layer 3). Every feature
/// gets its listening here and chooses no model: dictation and the input bar (`live`), the capture
/// (`capture`), Always listen (`stretch`). The rule (`SpeechRoute`, set by the app with `set`)
/// picks the provider at each start: OpenAI when it can be reached, through the lent mind's socket
/// (`RelaySocket`) else this Mac's key (`OpenAIAccess`), with the local model behind it; the local
/// model (Oruk Fourier, or Parakeet when chosen) when it cannot. A stretch whose OpenAI fails goes
/// to the local model whole (`StreamRecognizer`).
public final class Transcriber: @unchecked Sendable {
    public enum Use: String, Sendable {
        /// A key's listening (dictation, the input bar): partials while it goes, one segment at
        /// the end, and the standby socket, so the first words come at once.
        case live
        /// A capture: partials, and a segment with its times at each pause; the sound comes with
        /// its times (`push(_:at:)`).
        case capture
        /// A stretch of Always listen, heard once when it ended.
        case stretch
    }

    private let lock = NSLock()
    private var route = SpeechRoute(.local, .noOpenAI)
    private var local = SpeechModel.default
    private let access: OpenAIAccess?
    private let standby: OpenAIStandby?
    private let setup: OpenAIStream.Setup
    private let engines: LocalEngines

    /// `access` opens OpenAI's sockets (nil: only the local model); `standby` is the socket that
    /// waits for the next key's listening; `setup` stands in for OpenAI's address and time outs, for
    /// a test.
    public init(access: OpenAIAccess?, standby: OpenAIStandby? = nil, setup: OpenAIStream.Setup = OpenAIStream.Setup(), engines: LocalEngines) {
        self.access = access
        self.standby = standby
        self.setup = setup
        self.engines = engines
    }

    /// The rule's answer now, and the local model: the app sets them at each change of their
    /// inputs (the network, the lent mind, the key, the person's choice).
    public func set(_ route: SpeechRoute, local: SpeechModel) {
        lock.withLock {
            self.route = route
            self.local = local
        }
    }

    public var current: (route: SpeechRoute, local: SpeechModel) { lock.withLock { (route, local) } }

    /// A listening for `use`, by the provider that the rule picks now, and its model.
    public func listening(_ use: Use, words: WordList, heard: @escaping @Sendable (SpeechRecognizer.Event) -> Void) -> (listening: SpeechListening, model: SpeechModel) {
        let (route, local) = current
        guard route.provider == .openAI, let access else {
            return (recognizer(local, words: words, start: 0, why: route.why.words, heard: heard), local)
        }
        var setup = setup
        setup.keywords = words.entries.map(\.term)
        // a key's listening takes the standby and opens the next; the others open a socket each
        let standby = use == .live ? standby : nil
        let listening = StreamRecognizer(
            name: SpeechModel.gptLiveTranscribe.id, words: words, segmentsAtPauses: use == .capture,
            open: { [setup] text, failed in
                if let standby, let (stream, from) = await standby.take(setup, source: await access.source()) {
                    // it may have closed since the ping: then a new one, as with no standby
                    if stream.attach(text: text, failed: failed) { return (stream, "standby, \(from.words)") }
                    stream.cancel()
                }
                let (stream, source) = try await access.open(setup, text, failed)
                return (stream, "new, \(source.words)")
            },
            fallback: { [self] start, reason, heard in recognizer(local, words: words, start: start, why: "OpenAI failed (\(reason))", heard: heard) },
            ended: { [setup] in standby?.prepare(setup, access: access) },
            heard: heard)
        return (listening, .gptLiveTranscribe)
    }

    /// A whole stretch of 16 kHz samples into words, once: Always listen's. `note` hears the lines
    /// for the log (a fallback and its reason).
    public func transcribe(_ samples: [Float], words: WordList, note: @escaping @Sendable (String) -> Void = { _ in }) async -> [SpeechSegment] {
        let (listening, _) = listening(.stretch, words: words) { event in if case .note(let line) = event { note(line) } }
        listening.start()
        listening.push(samples)
        return await listening.finish()
    }

    /// The local model's recognizer: `LocalSpeech` loads it for `why` and counts the use.
    private func recognizer(_ model: SpeechModel, words: WordList, start: Double, why: String, heard: @escaping @Sendable (SpeechRecognizer.Event) -> Void) -> SpeechRecognizer {
        final class Used: @unchecked Sendable {
            private let lock = NSLock()
            private var isUsed = false
            func set() { lock.withLock { isUsed = true } }
            func take() -> Bool { lock.withLock { defer { isUsed = false }; return isUsed } }
        }
        let engines = engines
        let used = Used()
        return SpeechRecognizer(
            model: model, words: words, start: start,
            engine: {
                let engine = try await engines.engine(model, words, why) { heard(.loading($0)) }
                used.set()
                return engine
            },
            done: { if used.take() { engines.done() } }, heard: heard)
    }
}
