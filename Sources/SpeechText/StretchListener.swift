import AVFoundation
import Accelerate
import FluidAudio
import Foundation
import VoiceMeetCore

/// The speech probability of each 256 ms piece of the stream (layer 2, README "Listening"):
/// Silero VAD through FluidAudio (`VadManager`, 0.18.4), and the energy gate
/// (`SpeechGate.energy`) while its model loads, when it failed, and for a piece that is quieter
/// than `floor`: a silent room never wakes the model.
actor SpeechProbability {
    /// About −46 dBFS: quieter pieces are silence, with no model.
    static let floor: Float = 0.2

    private var vad: VadManager?
    private var state: VadStreamState?
    private var loading: Task<Void, Never>?
    private(set) var failure: String?
    private let useModel: Bool

    init(useModel: Bool) {
        self.useModel = useModel
    }

    /// Who answers now: `silero`, `energy (loading)`, `energy (<why>)`.
    var source: String {
        if vad != nil { return "silero" }
        if let failure { return "energy (\(failure))" }
        return useModel ? "energy (silero loads)" : "energy"
    }

    func probability(of piece: [Float]) async -> Float {
        let energy = SpeechGate.energy(of: piece)
        guard energy >= Self.floor else {
            // the model's memory of the voice ends with the silence
            state = nil
            return energy
        }
        guard let vad else {
            load()
            return energy
        }
        do {
            let result = try await vad.processStreamingChunk(piece, state: state ?? VadStreamState.initial())
            state = result.state
            return result.probability
        } catch {
            failure = "silero failed: \(error.localizedDescription)"
            self.vad = nil
            return energy
        }
    }

    /// Once: the model (about 2 MB) downloads into FluidAudio's folder at its first use.
    private func load() {
        guard useModel, loading == nil, failure == nil else { return }
        loading = Task {
            do {
                // the gate's own onset and offset decide; the model's threshold is not used
                let made = try await VadManager(config: VadConfig(defaultThreshold: 0.5))
                vad = made
            } catch {
                failure = "silero did not load: \(error.localizedDescription)"
            }
        }
    }
}

/// ALWAYS LISTEN: layers 2 and 3 with no key (README, "Listening"). It reads the microphone stream,
/// finds each stretch of speech (`SpeechGate` on `SpeechProbability`), and when a stretch ends it is
/// put into words by the LOCAL model, once, with the word list: no sound leaves the Mac. Each
/// stretch is one final segment (`listen-<n>`) of the transcription stream.
///
/// While a key listens (dictation, the input bar) it is held: the stretch that goes on is cut at
/// that moment and put into words, and nothing is detected until the hold ends, so that one stretch
/// is never put into words twice.
public final class StretchListener: @unchecked Sendable {
    public enum Event: Sendable {
        case started(at: Double)
        case ended(start: Double, end: Double)
        case segment(TranscriptSegment)
        /// A line for the log: counts and times, never the words.
        case note(String)
    }

    /// The seconds of sound kept before a wake: the gate's pad and more.
    static let before = 0.6
    static let piece = VadManager.chunkSize

    private enum Input {
        case frame(MicFrame)
        case hold(Bool, at: Double)
    }

    private let stream: MicStream
    private let heard: @Sendable (Event) -> Void
    private let probability: SpeechProbability
    private let engine: (@Sendable (SpeechModel, WordList) async throws -> SpeechEngine)?
    private let lock = NSLock()
    private var model = SpeechModel.default
    private var words = WordList.empty
    private var subscription: MicSubscription?
    private var inputs: AsyncStream<Input>.Continuation?
    private var work: Task<Void, Never>?
    private var count = 0

    /// `useModel`: Silero (false in a test: the energy gate alone). `engine` stands in for the
    /// speech model, for a test.
    public init(
        stream: MicStream, useModel: Bool = true, engine: (@Sendable (SpeechModel, WordList) async throws -> SpeechEngine)? = nil,
        heard: @escaping @Sendable (Event) -> Void
    ) {
        self.stream = stream
        self.heard = heard
        self.engine = engine
        probability = SpeechProbability(useModel: useModel)
    }

    public var isRunning: Bool { lock.withLock { subscription != nil } }

    /// THE WAKE ON THE DEVICE'S THREAD: a silent room costs a loudness per buffer and nothing more.
    /// A buffer at least as loud as the energy gate's floor wakes the listener: from then on, and
    /// while a stretch goes on, the buffers are resampled to 16 kHz and judged, the `before`
    /// seconds kept before the wake first. It sleeps `awake` seconds after the last loud buffer, once
    /// no stretch goes on.
    final class Wake: @unchecked Sendable {
        /// −46 dBFS, the floor of `SpeechProbability`.
        static let floor: Float = 0.005
        static let awake = 1.5

        private let lock = NSLock()
        private var speaking = false
        private var held = false
        private var awakeUntil = -Double.infinity
        private var kept: [(buffer: AVAudioPCMBuffer, time: Double)] = []
        private var resampler: StreamResampler?

        func set(speaking: Bool) { lock.withLock { self.speaking = speaking } }
        func set(held: Bool) { lock.withLock { self.held = held } }

        /// The frames to judge now: none while asleep.
        func frames(of buffer: AVAudioPCMBuffer, time: Double) -> [MicFrame] {
            let (speaking, held) = lock.withLock { (self.speaking, self.held) }
            guard !held else {
                kept = []
                resampler = nil
                return []
            }
            let frames = Int(buffer.frameLength)
            guard frames > 0 else { return [] }
            var loudness: Float = 0
            if let data = buffer.floatChannelData { vDSP_rmsqv(data[0], 1, &loudness, vDSP_Length(buffer.format.isInterleaved ? frames * Int(buffer.format.channelCount) : frames)) }
            if loudness >= Self.floor || buffer.floatChannelData == nil { awakeUntil = max(awakeUntil, time + Self.awake) }
            guard speaking || time < awakeUntil else {
                // asleep: the last `before` seconds wait, as they came
                resampler = nil
                if let copy = Self.copy(buffer) { kept.append((copy, time)) }
                var seconds = kept.reduce(0) { $0 + Double($1.buffer.frameLength) / $1.buffer.format.sampleRate }
                while let first = kept.first, seconds - Double(first.buffer.frameLength) / first.buffer.format.sampleRate >= StretchListener.before - 1e-6 {
                    seconds -= Double(first.buffer.frameLength) / first.buffer.format.sampleRate
                    kept.removeFirst()
                }
                return []
            }
            var made: [MicFrame] = []
            if resampler == nil {
                let fresh = StreamResampler()
                resampler = fresh
                made = kept.map { MicFrame(samples: fresh.samples(of: $0.buffer), time: $0.time) }
                kept = []
            }
            made.append(MicFrame(samples: resampler!.samples(of: buffer), time: time))
            return made
        }

        /// The device reuses its buffer after the call.
        private static func copy(_ buffer: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
            guard let copy = AVAudioPCMBuffer(pcmFormat: buffer.format, frameCapacity: buffer.frameLength) else { return nil }
            copy.frameLength = buffer.frameLength
            let from = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: buffer.audioBufferList))
            let to = UnsafeMutableAudioBufferListPointer(copy.mutableAudioBufferList)
            for (source, target) in zip(from, to) {
                guard let data = source.mData, let into = target.mData else { continue }
                memcpy(into, data, Int(min(source.mDataByteSize, target.mDataByteSize)))
            }
            return copy
        }
    }

    private let wake = Wake()

    /// The local model and the word list of the next stretches.
    public func use(_ model: SpeechModel, words: WordList) {
        lock.withLock {
            self.model = model
            self.words = words
        }
    }

    /// Reads the stream. Throws when the microphone does not start.
    public func start() throws {
        guard !isRunning else { return }
        // at most 30 s of frames wait while a piece is judged: the gate is far faster than the clock
        let (inputs, continuation) = AsyncStream<Input>.makeStream(bufferingPolicy: .bufferingNewest(700))
        // the device's own buffers: a silent one is never resampled (`Wake`)
        let wake = self.wake
        let subscription = try stream.tapRaw({ buffer, host in
            for frame in wake.frames(of: buffer, time: MicStream.wallTime(ofHost: host)) { continuation.yield(.frame(frame)) }
        }, failed: { [weak self] reason in
            self?.heard(.note("the microphone failed: \(reason)"))
            self?.stop()
        })
        lock.withLock {
            self.subscription = subscription
            self.inputs = continuation
        }
        work = Task { [weak self] in await self?.run(inputs) }
    }

    public func stop() {
        let (subscription, inputs) = lock.withLock {
            defer {
                self.subscription = nil
                self.inputs = nil
            }
            return (self.subscription, self.inputs)
        }
        subscription?.cancel()
        inputs?.finish()
    }

    /// A key listens (`true`) from `time`, or let go (`false`).
    public func hold(_ isHeld: Bool, at time: Double = Date().timeIntervalSince1970) {
        wake.set(held: isHeld)
        _ = lock.withLock { inputs }?.yield(.hold(isHeld, at: time))
    }

    /// The stretches, one after the other: pieces of 256 ms into the gate, and each ended stretch
    /// to the model, in a task of its own so that the gate goes on meanwhile.
    private func run(_ inputs: AsyncStream<Input>) async {
        var gate = SpeechGate()
        /// The samples from `kept`'s wall time on: a piece that waits, and the stretch that goes.
        var kept: [Float] = []
        var keptStart = 0.0
        /// The samples of `kept` that the gate heard.
        var judged = 0
        var isHeld = false
        var transcribing: Task<Void, Never>?
        let rate = Double(SpeechStretch.rate)
        var detector = await probability.source
        heard(.note("listens: \(detector)"))

        func ended(_ start: Double, _ end: Double) {
            heard(.ended(start: start, end: end))
            let from = max(0, Int(((start - keptStart) * rate).rounded()))
            let to = min(kept.count, Int(((end - keptStart) * rate).rounded()))
            guard to > from else { return }
            let samples = Array(kept[from..<to])
            let previous = transcribing
            let number = lock.withLock {
                count += 1
                return count
            }
            transcribing = Task {
                await previous?.value
                await transcribe(samples, start: start, number: number)
            }
        }
        /// Drops what no stretch needs: all but `before` seconds while no one speaks.
        func trim() {
            let keep = gate.stretchStart.map { max(0, Int((($0 - keptStart) * rate).rounded())) } ?? max(0, judged - Int(Self.before * rate))
            guard keep > 0 else { return }
            let drop = min(keep, judged)
            kept.removeFirst(drop)
            judged -= drop
            keptStart += Double(drop) / rate
        }

        for await input in inputs {
            switch input {
            case .hold(let on, let time):
                if on, let event = gate.cut(at: time), case .ended(let start, let end) = event { ended(start, end) }
                isHeld = on
                wake.set(speaking: gate.isSpeaking)
                if !on {
                    gate = SpeechGate()
                    kept = []
                    judged = 0
                }
            case .frame(let frame):
                guard !isHeld else { continue }
                // a gap (a sleep, a restart of the device): the stretch ends where the sound did
                if !kept.isEmpty, abs(frame.time - (keptStart + Double(kept.count) / rate)) > 0.5 {
                    if let event = gate.cut(at: keptStart + Double(kept.count) / rate), case .ended(let start, let end) = event { ended(start, end) }
                    kept = []
                    judged = 0
                }
                if kept.isEmpty { keptStart = frame.time }
                kept.append(contentsOf: frame.samples)
                while kept.count - judged >= Self.piece {
                    let piece = Array(kept[judged..<judged + Self.piece])
                    let from = keptStart + Double(judged) / rate
                    judged += Self.piece
                    let p = await probability.probability(of: piece)
                    let now = await probability.source
                    if now != detector {
                        detector = now
                        heard(.note("speech detection: \(now)"))
                    }
                    for event in gate.hear(p, from: from, to: from + Double(Self.piece) / rate) {
                        switch event {
                        case .started(let at): heard(.started(at: at))
                        case .ended(let start, let end): ended(start, end)
                        }
                    }
                    wake.set(speaking: gate.isSpeaking)
                }
                trim()
            }
        }
        // the end of the stream: the stretch that goes on is put into words
        if let event = gate.cut(at: keptStart + Double(kept.count) / rate), case .ended(let start, let end) = event { ended(start, end) }
        await transcribing?.value
    }

    /// One stretch into words by the local model: one segment, or none when it heard no words.
    private func transcribe(_ samples: [Float], start: Double, number: Int) async {
        let (model, words) = lock.withLock { (self.model, self.words) }
        let began = Date()
        let engine = self.engine.map { make in { @Sendable in try await make(model, words) } }
        let recognizer = SpeechRecognizer(model: model, words: words, engine: engine) { _ in }
        recognizer.start()
        recognizer.push(samples)
        let segments = await recognizer.finish()
        let seconds = Double(samples.count) / Double(SpeechStretch.rate)
        guard let first = segments.first, let last = segments.last else {
            return heard(.note("stretch \(number): \(String(format: "%.1f", seconds)) s, no words"))
        }
        let said = segments.reduce(HeardText.empty) { HeardText.join($0, HeardText($1.heard, words: words)) }
        heard(.segment(TranscriptSegment(
            stretch: "listen-\(number)", origin: .listen, start: start + first.start, end: start + last.end, heard: said, model: model.id)))
        heard(.note("stretch \(number): \(String(format: "%.1f", seconds)) s, \(Spoken.wordCount(said.text)) words in \(String(format: "%.2f", Date().timeIntervalSince(began))) s"))
    }
}
