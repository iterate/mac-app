import AVFoundation
import FluidAudio
import Foundation
import VoiceMeetCore

/// THE SPEECH MODEL, loaded once for the app: NVIDIA's Parakeet (TDT 0.6B v3) as Core ML, through
/// FluidAudio, the library that the Swift app Hex used. It runs on this Mac: no sound and no text
/// leaves it. The first use downloads the model (about 480 MB, and 100 MB more for the model that
/// hears the word list's terms) into ~/Library/Application Support/FluidAudio.
public actor SpeechModels {
    public static let shared = SpeechModels()

    public struct Loaded: Sendable {
        let speech: AsrModels
        /// The second, small model that hears the terms of a word list. Nil when it did not load:
        /// dictation then works without it.
        let terms: CtcModels?
    }

    private var loading: Task<Loaded, Error>?

    /// Whether the model is on this Mac already, so that a load is quick and downloads nothing.
    public nonisolated static var isOnDisk: Bool {
        AsrModels.modelsExist(at: AsrModels.defaultCacheDirectory(for: .v3), version: .v3)
    }

    /// The models, loaded. Many callers share one load; a failed load is tried again by the next
    /// caller. `progress` hears 0 to 1 while a download or a load goes.
    public func load(progress: @escaping @Sendable (Double) -> Void = { _ in }) async throws -> Loaded {
        if let loading { return try await loading.value }
        let task = Task<Loaded, Error> {
            let speech = try await AsrModels.downloadAndLoad(version: .v3, progressHandler: { progress($0.fractionCompleted * 0.85) })
            let terms = try? await CtcModels.downloadAndLoad(progressHandler: { progress(0.85 + $0.fractionCompleted * 0.15) })
            progress(1)
            return Loaded(speech: speech, terms: terms)
        }
        loading = task
        do {
            return try await task.value
        } catch {
            loading = nil
            throw error
        }
    }
}

/// ONE LISTENING: the microphone, heard as text while the person talks (README, "Dictation").
///
/// `start` opens the microphone at once and keeps what it hears while the model loads. Twice a
/// second the listener writes the stretch of speech that is going as text again, so the text
/// follows the voice; a stretch ends at a pause (`SpeechStretch`), and then its text is final.
/// The mind's word list does two things: its terms are what the second model listens for in each
/// ended stretch, and its wrong forms are repaired in every text.
///
/// With an audio fixture (`fixture`, or the environment's `ITERATE_MAC_AUDIO_FIXTURE`), the
/// listener opens no audio device: it plays that file at the pace of the clock through the same
/// path as the microphone's buffers, and then silence, as a microphone in a quiet room.
public final class SpeechListener: @unchecked Sendable {
    public enum Event: Sendable {
        /// The model loads or downloads: 0 to 1.
        case loading(Double)
        /// The model is ready: what was said since `start` comes as text now.
        case listening
        /// Everything said so far.
        case text(String)
        /// How loud the microphone is now, 0 to 1.
        case level(Float)
        /// A line for the log: counts and times, never the words.
        case note(String)
        case failed(String)
    }

    private let lock = NSLock()
    private var pending: [Float] = []
    private var isEnded = false
    private var isDropped = false

    private let engine = AVAudioEngine()
    private let converter = AudioConverter()
    private var work: Task<String, Never>?
    private let fixture: URL?

    /// The sound file that the environment's `ITERATE_MAC_AUDIO_FIXTURE` names, if any.
    public static let environmentFixture: URL? = ProcessInfo.processInfo.environment["ITERATE_MAC_AUDIO_FIXTURE"]
        .flatMap { $0.isEmpty ? nil : URL(fileURLWithPath: $0) }

    /// `fixture` is a sound file (WAV, AIFF, M4A) heard in place of the microphone.
    public init(fixture: URL? = SpeechListener.environmentFixture) {
        self.fixture = fixture
    }

    /// Opens the microphone and starts to write. Call it once for a listener.
    public func start(words: WordList, heard: @escaping @Sendable (Event) -> Void) {
        if let fixture {
            let audio: AudioFixture
            do {
                audio = try AudioFixture(fixture)
            } catch {
                heard(.failed("The audio fixture \(fixture.lastPathComponent) does not read: \(error.localizedDescription)"))
                return
            }
            heard(.note("hears the audio fixture \(fixture.lastPathComponent), \(String(format: "%.1f", audio.seconds)) s, in place of the microphone"))
            DispatchQueue.global(qos: .userInitiated).async { [self] in
                while !lock.withLock({ isEnded }) {
                    guard let buffer = audio.next() else { break }
                    feed(buffer, heard: heard)
                    Thread.sleep(forTimeInterval: Double(buffer.frameLength) / buffer.format.sampleRate)
                }
            }
            work = Task { [self] in await write(words: words, heard: heard) }
            return
        }
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else {
            heard(.failed("This Mac has no microphone now."))
            return
        }
        input.installTap(onBus: 0, bufferSize: 2048, format: format) { [weak self] buffer, _ in
            self?.feed(buffer, heard: heard)
        }
        do {
            engine.prepare()
            try engine.start()
        } catch {
            input.removeTap(onBus: 0)
            heard(.failed("The microphone did not start: \(error.localizedDescription)"))
            return
        }
        work = Task { [self] in await write(words: words, heard: heard) }
    }

    /// One buffer of the microphone (or of the fixture): its loudness, and its samples for the model.
    private func feed(_ buffer: AVAudioPCMBuffer, heard: @Sendable (Event) -> Void) {
        guard let samples = try? converter.resampleBuffer(buffer), !samples.isEmpty else { return }
        var sum: Float = 0
        for sample in samples { sum += sample * sample }
        // speech is near 0.05 to 0.2 RMS: the square root makes a quiet voice show
        heard(.level(min(1, ((sum / Float(samples.count)).squareRoot() * 4).squareRoot())))
        lock.lock()
        pending.append(contentsOf: samples)
        lock.unlock()
    }

    /// Closes the microphone and answers everything that was said, with the last stretch final.
    public func finish() async -> String {
        closeMicrophone(dropped: false)
        return await work?.value ?? ""
    }

    /// Closes the microphone. What was said and not yet written is dropped.
    public func cancel() {
        closeMicrophone(dropped: true)
    }

    private func closeMicrophone(dropped: Bool) {
        lock.lock()
        let wasEnded = isEnded
        isEnded = true
        isDropped = isDropped || dropped
        lock.unlock()
        // a fixture opened no device: its player sees the end
        guard !wasEnded, fixture == nil else { return }
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
    }

    /// What the microphone gave since the last call, and whether the listening ended.
    private func take() -> (samples: [Float], ended: Bool, dropped: Bool) {
        lock.lock()
        defer { lock.unlock() }
        let samples = pending
        pending.removeAll(keepingCapacity: true)
        return (samples, isEnded, isDropped)
    }

    private func write(words: WordList, heard: @escaping @Sendable (Event) -> Void) async -> String {
        let started = Date()
        let models: SpeechModels.Loaded
        let manager = AsrManager(config: .default)
        do {
            models = try await SpeechModels.shared.load { heard(.loading($0)) }
            try await manager.loadModels(models.speech)
        } catch {
            closeMicrophone(dropped: true)
            heard(.failed("The speech model did not load: \(error.localizedDescription)"))
            return ""
        }
        let boost: VocabularyBoostingSession?
        if let terms = models.terms, !words.entries.isEmpty {
            let vocabulary = CustomVocabularyContext(terms: words.entries.map { CustomVocabularyTerm(text: $0.term, aliases: $0.wrong.isEmpty ? nil : $0.wrong) })
            boost = try? await VocabularyBoostingSession(vocabulary: vocabulary, ctcModels: terms)
        } else {
            boost = nil
        }
        heard(.note("the model is ready after \(String(format: "%.1f", Date().timeIntervalSince(started))) s; \(words.entries.count) terms, \(boost == nil ? "repaired in the text only" : "heard by the second model too")"))
        heard(.listening)

        let layers = await manager.decoderLayerCount
        /// A stretch as text. The final text of a stretch also asks the second model for the terms.
        func text(of samples: [Float], final: Bool) async -> String {
            // the model refuses less than 0.3 s
            var samples = samples
            if samples.count < SpeechStretch.rate { samples += [Float](repeating: 0, count: SpeechStretch.rate - samples.count) }
            var state = TdtDecoderState.make(decoderLayers: layers)
            guard let result = try? await manager.transcribe(samples, decoderState: &state) else { return "" }
            var text = result.text
            if final, let boost, let timings = result.tokenTimings, !text.isEmpty,
                let rescored = await boost.rescore(text: text, tokenTimings: timings, audioSamples: samples), rescored.wasModified
            {
                text = rescored.text
            }
            return words.repair(text.trimmingCharacters(in: .whitespacesAndNewlines))
        }

        var stretch = SpeechStretch()
        var said = ""
        var passes = 0
        var seconds = 0.0
        while true {
            let (samples, ended, dropped) = take()
            if dropped { return "" }
            stretch.append(samples)
            seconds += Double(samples.count) / Double(SpeechStretch.rate)
            if ended {
                if !stretch.samples.isEmpty { said = Spoken.join(said, await text(of: stretch.samples, final: true)) }
                heard(.note("heard \(String(format: "%.1f", seconds)) s as \(Spoken.wordCount(said)) words in \(passes + 1) passes"))
                return said
            }
            if !samples.isEmpty {
                passes += 1
                if let end = stretch.end {
                    said = Spoken.join(said, await text(of: Array(stretch.samples.prefix(end)), final: true))
                    stretch.removeFirst(end)
                    heard(.text(said))
                } else if stretch.seconds >= 0.4 {
                    heard(.text(Spoken.join(said, await text(of: stretch.samples, final: false))))
                }
            }
            try? await Task.sleep(nanoseconds: 400_000_000)
        }
    }
}

/// A sound file as the microphone's buffers, for a test: the file in pieces of 2048 frames, then
/// silence for as long as it is asked.
public final class AudioFixture: @unchecked Sendable {
    public static let frames: AVAudioFrameCount = 2048

    private let file: AVAudioFile
    public var format: AVAudioFormat { file.processingFormat }
    public var seconds: Double { Double(file.length) / file.processingFormat.sampleRate }

    public init(_ url: URL) throws {
        file = try AVAudioFile(forReading: url)
    }

    /// The next piece: of the file while it lasts, then of silence.
    public func next() -> AVAudioPCMBuffer? {
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: Self.frames) else { return nil }
        if file.framePosition < file.length, (try? file.read(into: buffer, frameCount: Self.frames)) != nil, buffer.frameLength > 0 {
            return buffer
        }
        buffer.frameLength = Self.frames
        for channel in 0..<Int(format.channelCount) {
            buffer.floatChannelData?[channel].update(repeating: 0, count: Int(Self.frames))
        }
        return buffer
    }
}
