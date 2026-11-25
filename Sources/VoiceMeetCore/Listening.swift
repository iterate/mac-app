import Foundation

/// ONE SOURCE, MANY READERS: the microphone stream's subscribers (README, "Listening"). A reader is
/// added and removed under a lock; `send` calls each reader outside it, on the caller's thread. The
/// answers of `add` and `remove` say when the source must start (the first reader) and stop (the
/// last one left).
public final class FanOut<Value>: @unchecked Sendable {
    public typealias Reader = @Sendable (Value) -> Void

    private let lock = NSLock()
    private var readers: [(id: Int, read: Reader)] = []
    private var next = 0

    public init() {}

    public var count: Int { lock.withLock { readers.count } }

    /// Adds `read`. `first`: no reader was there before it.
    public func add(_ read: @escaping Reader) -> (id: Int, first: Bool) {
        lock.withLock {
            next += 1
            readers.append((next, read))
            return (next, readers.count == 1)
        }
    }

    /// Removes the reader `id`. True when it was there and none is left now.
    @discardableResult
    public func remove(_ id: Int) -> Bool {
        lock.withLock {
            guard let index = readers.firstIndex(where: { $0.id == id }) else { return false }
            readers.remove(at: index)
            return readers.isEmpty
        }
    }

    /// Removes every reader: the source failed. The ids that were there.
    public func removeAll() -> [Int] {
        lock.withLock {
            defer { readers = [] }
            return readers.map(\.id)
        }
    }

    /// `value` to every reader, in the order they came.
    public func send(_ value: Value) {
        for reader in lock.withLock({ readers }) { reader.read(value) }
    }
}

/// SPEECH DETECTION: when someone speaks, from the speech probability of each piece of the stream
/// (README, "Listening"). The probability comes from a model (Silero, through FluidAudio) or from
/// `energy` while the model loads; this is the state machine on top of it, in seconds on the
/// stream's clock.
///
/// A stretch starts when a piece is at least `onset`, `pad` seconds before that piece. It ends
/// after `hangover` seconds below `offset`, `pad` seconds after the last piece that was above it.
/// A stretch of `most` seconds ends there, and the next one starts at once.
public struct SpeechGate: Equatable, Sendable {
    public struct Settings: Equatable, Sendable {
        public var onset: Float = 0.5
        public var offset: Float = 0.35
        public var hangover = 0.8
        public var pad = 0.2
        public var most = 30.0

        public init() {}
    }

    public enum Event: Equatable, Sendable {
        case started(at: Double)
        case ended(start: Double, end: Double)
    }

    public let settings: Settings
    /// The start of the stretch that goes on, nil while no one speaks.
    public private(set) var stretchStart: Double?
    /// The end of the last piece that was speech, in this stretch.
    private var lastVoice = 0.0
    /// The end of the last stretch: the next one does not start before it.
    private var lastEnd = -Double.infinity

    public init(_ settings: Settings = Settings()) {
        self.settings = settings
    }

    public var isSpeaking: Bool { stretchStart != nil }

    /// One piece, from `start` to `end`, and its probability of speech.
    public mutating func hear(_ probability: Float, from start: Double, to end: Double) -> [Event] {
        guard let began = stretchStart else {
            guard probability >= settings.onset else { return [] }
            let at = max(start - settings.pad, lastEnd)
            stretchStart = at
            lastVoice = end
            return [.started(at: at)]
        }
        if probability >= settings.offset { lastVoice = end }
        if end - lastVoice >= settings.hangover {
            return [finish(began, at: min(lastVoice + settings.pad, end))]
        }
        if end - began >= settings.most {
            let ended = finish(began, at: end)
            stretchStart = end
            lastVoice = end
            return [ended, .started(at: end)]
        }
        return []
    }

    /// Ends the stretch that goes on at `time`: a key took the microphone (a dictation). Nil when
    /// no one spoke.
    public mutating func cut(at time: Double) -> Event? {
        guard let began = stretchStart else { return nil }
        return finish(began, at: max(began, time))
    }

    private mutating func finish(_ began: Double, at end: Double) -> Event {
        stretchStart = nil
        lastEnd = end
        return .ended(start: began, end: end)
    }

    /// The speech probability of a piece by its loudness alone, 0 to 1: the stopgap while the model
    /// loads, and when it fails. Below −50 dBFS is 0, above −30 dBFS is 1. A piece that crosses
    /// zero at more than a third of its samples is hiss, not a voice: it counts half.
    public static func energy(of samples: [Float]) -> Float {
        guard !samples.isEmpty else { return 0 }
        var sum: Float = 0
        var crossings = 0
        var previous = samples[0]
        for sample in samples {
            sum += sample * sample
            if (sample >= 0) != (previous >= 0) { crossings += 1 }
            previous = sample
        }
        let rms = (sum / Float(samples.count)).squareRoot()
        let decibels = 20 * log10(max(rms, 1e-7))
        let loud = min(1, max(0, (decibels + 50) / 20))
        return Float(crossings) / Float(samples.count) > 1.0 / 3 ? loud / 2 : loud
    }
}
