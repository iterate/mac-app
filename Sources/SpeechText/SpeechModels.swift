import FluidAudio
import Foundation
import VoiceMeetCore

/// ONE SPEECH MODEL that the app can use (README, "Dictation"): the list of them is `all`, which
/// the panel's picker and `harness/speech-bench` show. Every model here runs on this Mac through
/// FluidAudio as Core ML: no sound and no text leaves it. Each one shares Parakeet v3's tokenizer,
/// so the small CTC model that hears the word list's terms rescores the text of all of them; then
/// the list repairs the wrong forms.
public struct SpeechModel: Equatable, Hashable, Sendable, Identifiable {
    public let id: String
    public let name: String
    /// The download, in MB.
    public let megabytes: Int
    public let license: String
    /// How it runs: "Core ML (FluidAudio)" for each model here. Another runtime (MLX) needs an
    /// engine of its own behind `SpeechEngine`.
    public let runtime: String
    public let version: AsrModelVersion

    public static let parakeetV3 = SpeechModel(
        id: "parakeet-v3", name: "Parakeet TDT 0.6B v3", megabytes: 480, license: "CC BY 4.0", runtime: "Core ML (FluidAudio)",
        version: .v3)
    public static let parakeetUltra = SpeechModel(
        id: "parakeet-ultra", name: "Parakeet Ultra", megabytes: 632, license: "CC BY 4.0", runtime: "Core ML (FluidAudio)",
        version: .ultra)
    /// The models the app offers. Tried and left out (speech-bench, 24 Nov 2026): Fluid Speech Pro
    /// (`FluidVoice-Labs/fluid-speech-pro-coreml`) loads as an Ultra-type folder, but its joint is
    /// the older contract and FluidAudio 0.18.4 cuts its text short; it needs FluidAudio's own
    /// support for it (its model card names a fork).
    public static let all = [parakeetV3, parakeetUltra]

    /// The model of a stored choice; the default for none, or for an id the list does not have.
    public static func chosen(_ id: String?) -> SpeechModel {
        all.first { $0.id == id } ?? .default
    }

    /// The model the app uses until the person chooses another (README, "Dictation": the bench's
    /// result on the owner's own voice decided it).
    public static let `default` = parakeetV3

    /// Whether its files are on this Mac, so that a load downloads nothing.
    public var isOnDisk: Bool {
        AsrModels.modelsExist(at: AsrModels.defaultCacheDirectory(for: version), version: version)
    }
}

/// What a load of a model does now.
public enum SpeechLoad: Equatable, Sendable {
    /// Files come from the network: 0 to 1 of them.
    case downloading(Double)
    /// The files are on this Mac; Core ML reads them and prepares them for the Neural Engine.
    case loading
}

/// A stretch of speech as text, with the times of its words in seconds from the stretch's start.
public struct Heard: Equatable, Sendable {
    public var text: String
    public var words: [SpeechSegment.Word]

    public init(text: String, words: [SpeechSegment.Word] = []) {
        self.text = text
        self.words = words
    }
}

/// A RECOGNIZER'S MODEL, ready for one word list. The one small protocol behind every model: an
/// engine on another runtime (MLX, for a model such as Oruk Fourier) implements this and nothing
/// else.
public protocol SpeechEngine: Sendable {
    /// A stretch of 16 kHz mono samples as text. `final` asks for the better and slower pass: the
    /// word list's terms are listened for.
    func hear(_ samples: [Float], final: Bool) async throws -> Heard
}

/// THE SPEECH MODELS, loaded for the app: one model at a time is held, the chosen one.
public actor SpeechModels {
    public static let shared = SpeechModels()

    public struct Loaded: Sendable {
        let speech: AsrModels
        /// The small model that hears the terms of a word list. Nil when it did not load: the text
        /// is then repaired by the list alone.
        let terms: CtcModels?
    }

    private var loading: (id: String, task: Task<Loaded, Error>)?
    /// The id of the held model once its load ended well.
    private var ready: String?

    /// An engine of `model` for `words`. Many callers share one load; a failed load is tried again
    /// by the next caller. `progress` hears whether files are downloaded (with their part) or only
    /// loaded.
    public func engine(_ model: SpeechModel, words: WordList, progress: @escaping @Sendable (SpeechLoad) -> Void = { _ in }) async throws -> SpeechEngine {
        let loaded = try await load(model, progress: progress)
        let manager = AsrManager(config: .default)
        try await manager.loadModels(loaded.speech)
        var boost: VocabularyBoostingSession?
        if let terms = loaded.terms, !words.entries.isEmpty {
            let vocabulary = CustomVocabularyContext(terms: words.entries.map { CustomVocabularyTerm(text: $0.term, aliases: $0.wrong.isEmpty ? nil : $0.wrong) })
            boost = try? await VocabularyBoostingSession(vocabulary: vocabulary, ctcModels: terms)
        }
        return ParakeetEngine(manager: manager, layers: await manager.decoderLayerCount, boost: boost)
    }

    /// Loads `model` (downloads it first when it is not on this Mac) and holds it, in place of any
    /// other. For the picker, and for a load at the app's start.
    @discardableResult
    public func load(_ model: SpeechModel, progress: @escaping @Sendable (SpeechLoad) -> Void = { _ in }) async throws -> Loaded {
        if let loading, loading.id == model.id {
            // a load that goes on (the one at the app's start): this caller waits for it too
            if ready != model.id { progress(.loading) }
            return try await loading.task.value
        }
        let onDisk = model.isOnDisk
        let terms = CtcModels.modelsExist(at: CtcModels.defaultCacheDirectory())
        // FluidAudio reports a fraction while it only compiles: a share is shown only for files
        // that really come from the network
        progress(onDisk ? .loading : .downloading(0))
        let share: Double = terms ? 1 : 0.85
        let report: @Sendable (DownloadProgress) -> Void = { step in
            guard !onDisk else { return }
            if case .downloading = step.phase { progress(.downloading(step.fractionCompleted * share)) } else if case .compiling = step.phase { progress(.loading) }
        }
        let task = Task<Loaded, Error> {
            let speech = try await AsrModels.downloadAndLoad(version: model.version, progressHandler: report)
            let ctc = try? await CtcModels.downloadAndLoad(progressHandler: { step in
                if !terms, case .downloading = step.phase { progress(.downloading(share + step.fractionCompleted * (1 - share))) }
            })
            return Loaded(speech: speech, terms: ctc)
        }
        loading = (model.id, task)
        ready = nil
        do {
            let loaded = try await task.value
            if loading?.id == model.id { ready = model.id }
            return loaded
        } catch {
            if loading?.id == model.id { loading = nil }
            throw error
        }
    }

    /// Loads `model` when its files are on this Mac, at a low priority: the first use is then
    /// at once (README, "Dictation"). Downloads nothing.
    public nonisolated func preload(_ model: SpeechModel) -> Task<Double?, Never>? {
        guard model.isOnDisk else { return nil }
        return Task.detached(priority: .background) {
            let started = Date()
            guard (try? await self.load(model)) != nil else { return nil }
            return Date().timeIntervalSince(started)
        }
    }
}

/// Parakeet and the models of its family, through FluidAudio.
struct ParakeetEngine: SpeechEngine {
    let manager: AsrManager
    let layers: Int
    let boost: VocabularyBoostingSession?

    func hear(_ samples: [Float], final: Bool) async throws -> Heard {
        // the model refuses less than 1 s
        var samples = samples
        if samples.count < SpeechStretch.rate { samples += [Float](repeating: 0, count: SpeechStretch.rate - samples.count) }
        var state = TdtDecoderState.make(decoderLayers: layers)
        let result = try await manager.transcribe(samples, decoderState: &state)
        var text = result.text
        if final, let boost, let timings = result.tokenTimings, !text.isEmpty,
            let rescored = await boost.rescore(text: text, tokenTimings: timings, audioSamples: samples), rescored.wasModified
        {
            text = rescored.text
        }
        return Heard(text: text, words: Self.words(result.tokenTimings ?? []))
    }

    /// The tokens as words: a token that starts with "▁" starts a word.
    static func words(_ tokens: [TokenTiming]) -> [SpeechSegment.Word] {
        var words: [SpeechSegment.Word] = []
        for token in tokens {
            let piece = token.token.replacingOccurrences(of: "▁", with: " ")
            if piece.hasPrefix(" ") || words.isEmpty {
                let text = piece.trimmingCharacters(in: .whitespaces)
                guard !text.isEmpty else { continue }
                words.append(.init(start: token.startTime, end: token.endTime, text: text))
            } else {
                let last = words.removeLast()
                words.append(.init(start: last.start, end: token.endTime, text: last.text + piece))
            }
        }
        return words
    }
}
