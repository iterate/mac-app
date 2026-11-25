import FluidAudio
import Foundation
import VoiceMeetCore

/// ONE SPEECH MODEL that the app can use (README, "Dictation"): the list of them is `all`, which
/// Settings › Dictation shows. The local ones (`local`, which `harness/speech-bench` runs too) run
/// on this Mac: no sound and no text leaves it. Oruk Fourier 2B, the default, runs on MLX in a
/// Python process of its own (`FourierModel`); it hears the word list's terms in its prompt. The
/// Parakeet models run through FluidAudio as Core ML; they share Parakeet v3's tokenizer, so the
/// small CTC model that hears the word list's terms rescores their text. Then the list repairs the
/// wrong forms of each model's text. One model runs at OpenAI (`gptLiveTranscribe`,
/// `OpenAIStream`): the sound goes there, and a local model hears it when OpenAI fails.
public struct SpeechModel: Equatable, Hashable, Sendable, Identifiable {
    /// Where a model runs.
    public enum Runs: Equatable, Hashable, Sendable {
        case onThisMac(AsrModelVersion)
        /// MLX, in the Python process of `FourierModel`, with the files of `FourierRuntime`.
        case mlx
        /// OpenAI's realtime transcription, through the lent mind with its key (`OpenAIAccess`), else
        /// the OpenAI key of this Mac (`OpenAIKey`).
        case openAI
    }

    public let id: String
    public let name: String
    /// The download, in MB: 0 for a model that runs online.
    public let megabytes: Int
    public let license: String
    /// How it runs: "Core ML (FluidAudio)", or "MLX (mlx-audio)" for Oruk Fourier, whose engine is
    /// its own behind `SpeechEngine` (`FourierEngine`).
    public let runtime: String
    public let runs: Runs

    public var isLocal: Bool { runs != .openAI }

    public static let parakeetV3 = SpeechModel(
        id: "parakeet-v3", name: "Parakeet TDT 0.6B v3", megabytes: 480, license: "CC BY 4.0", runtime: "Core ML (FluidAudio)",
        runs: .onThisMac(.v3))
    public static let parakeetUltra = SpeechModel(
        id: "parakeet-ultra", name: "Parakeet Ultra", megabytes: 632, license: "CC BY 4.0", runtime: "Core ML (FluidAudio)",
        runs: .onThisMac(.ultra))
    /// Oruk Fourier 2B, a fine-tune of Qwen3-ASR, as Oruk's MLX 8-bit form. On the bench's
    /// synthetic set (25 Nov 2026, no word list) it had WER 16.3, where Parakeet v3 had 27.4; BF16
    /// had 16.1 at twice the time and 1.6 GB more (README, "Dictation"). CC BY-NC 4.0: the licence is
    /// non-commercial, and Oruk's permission is needed before it ships to others. The download is the
    /// model (2.46 GB) and its runtime (uv, Python and mlx-audio, about 200 MB).
    public static let fourier2b = SpeechModel(
        id: "oruk-fourier-2b", name: "Oruk Fourier 2B", megabytes: 2680, license: "CC BY-NC 4.0, non-commercial", runtime: "MLX (mlx-audio)",
        runs: .mlx)
    /// `gpt-live-transcribe` with delay `low`, which writes the words while the sound streams in.
    /// On the owner's own voice (speech-bench, 25 Nov 2026) it had half the word errors of
    /// Parakeet v3 (WER 10.3 against 21.8) and got 130 of 146 terms. $0.017 a minute of sound.
    public static let gptLiveTranscribe = SpeechModel(
        id: "gpt-live-transcribe", name: "GPT Live Transcribe", megabytes: 0, license: "OpenAI", runtime: "OpenAI realtime (WebSocket)",
        runs: .openAI)
    /// The local models. Tried and left out (speech-bench, 24 Nov 2026): Fluid Speech Pro
    /// (`FluidVoice-Labs/fluid-speech-pro-coreml`): FluidAudio 0.18.4 cuts its text short; through
    /// its fork (altic-dev/FluidAudio) it reads right, but it got 67 of 146 terms on the synthetic
    /// set where v3 got 124. Phonon-2.5 English (Core ML) got 60.
    public static let local = [fourier2b, parakeetV3, parakeetUltra]
    /// The models the app offers.
    public static let all = local + [gptLiveTranscribe]

    /// The model of a stored choice. With no choice (or an id the list does not have) it is
    /// `gptLiveTranscribe` when OpenAI can be reached (`isOnline`: the lent mind opens its sockets, or
    /// this Mac has a key of its own), else `localDefault`. A choice of an online model that cannot
    /// be reached is `localDefault` too. `isOnDisk` says which files are on this Mac.
    public static func chosen(_ id: String?, isOnline: Bool = false, isOnDisk: (SpeechModel) -> Bool = { $0.isOnDisk }) -> SpeechModel {
        if let model = all.first(where: { $0.id == id }), model.isLocal || isOnline { return model }
        return isOnline ? gptLiveTranscribe : localDefault(isOnDisk: isOnDisk)
    }

    /// The local model the app uses until the person chooses another, and the one that hears
    /// when OpenAI fails: Oruk Fourier 2B (README, "Dictation": the bench decided it among the
    /// local models).
    public static let `default` = fourier2b

    /// `default`, or Parakeet v3 while only Parakeet v3 is on this Mac: a Mac that had it before
    /// Fourier became the default waits for no download of 2.7 GB in a dictation. Fourier comes in
    /// the background then (`SpeechChoice`), and is the model once it loaded.
    public static func localDefault(isOnDisk: (SpeechModel) -> Bool = { $0.isOnDisk }) -> SpeechModel {
        !isOnDisk(.default) && isOnDisk(parakeetV3) ? parakeetV3 : .default
    }

    /// The size, licence and runtime, in a few words for the list in Settings.
    public var detail: String {
        isLocal ? "\(megabytes) MB · \(license)" : "OpenAI, $1/hour of talking, the sound leaves this Mac"
    }

    /// Whether its files are on this Mac, so that a load downloads nothing. An online model has
    /// no files: always true.
    public var isOnDisk: Bool {
        switch runs {
        case .onThisMac(let version): AsrModels.modelsExist(at: AsrModels.defaultCacheDirectory(for: version), version: version)
        case .mlx: FourierRuntime.standard.isReady
        case .openAI: true
        }
    }
}

/// A model that runs online has no load and no `SpeechEngine`: its recognizer is a
/// `StreamRecognizer`.
public enum SpeechModelError: Error, LocalizedError {
    case online(String)
    public var errorDescription: String? {
        if case .online(let id) = self { return "\(id) runs online: it has no files to load" }
        return nil
    }
}

/// What a load of a model does now.
public enum SpeechLoad: Equatable, Sendable {
    /// Files come from the network: 0 to 1 of them.
    case downloading(Double)
    /// The files are on this Mac; Core ML reads them and prepares them for the Neural Engine (or
    /// MLX's process starts and reads them).
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

/// THE SPEECH MODELS, loaded for the app: one local model at a time is held, and only while it
/// must hear (`LocalSpeech`).
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
        if model.runs == .mlx {
            // a whole stretch at each pass: the pill's words at most once a second (`PacedEngine`)
            let engine = PacedEngine(try await FourierModel.shared.engine(words: words, progress: progress))
            letGo()
            return engine
        }
        let loaded = try await loadCoreML(model, progress: progress)
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
    /// other. `LocalSpeech` calls it when the rule needs the local model.
    public func load(_ model: SpeechModel, progress: @escaping @Sendable (SpeechLoad) -> Void = { _ in }) async throws {
        if model.runs == .mlx {
            try await FourierModel.shared.load(progress: progress)
            letGo()
        } else {
            try await loadCoreML(model, progress: progress)
        }
    }

    /// The Core ML model goes, once Fourier is ready; its engines that still hear keep it until
    /// they end.
    private func letGo() {
        loading = nil
        ready = nil
    }

    @discardableResult
    private func loadCoreML(_ model: SpeechModel, progress: @escaping @Sendable (SpeechLoad) -> Void) async throws -> Loaded {
        guard case .onThisMac(let version) = model.runs else { throw SpeechModelError.online(model.id) }
        // one model is held: Fourier's process ends (a download of its files goes on)
        await FourierModel.shared.letGo()
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
            let speech = try await AsrModels.downloadAndLoad(version: version, progressHandler: report)
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

    /// Unloads `model`: Fourier's process ends, the Core ML model goes. An engine that still hears
    /// keeps it until it ends. `LocalSpeech` decides when (README, "Listening").
    public func unload(_ model: SpeechModel) async {
        if model.runs == .mlx { return await FourierModel.shared.letGo() }
        if loading?.id == model.id { letGo() }
    }

    /// Gets the files of `model` when they are not on this Mac, and loads nothing that is not
    /// needed: Fourier's process does not start (a Core ML model loads, as FluidAudio downloads it
    /// with its load). For a download in the background or a choice in Settings.
    public func download(_ model: SpeechModel, progress: @escaping @Sendable (SpeechLoad) -> Void = { _ in }) async throws {
        if model.runs == .mlx { return try await FourierModel.shared.prepare(progress: progress) }
        try await loadCoreML(model, progress: progress)
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
