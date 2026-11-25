import Accelerate
import AVFoundation
import Foundation
import VoiceMeetCore

/// A piece of the microphone stream: 16 kHz mono samples, and the wall time of the first one.
public struct MicFrame: Sendable {
    public let samples: [Float]
    /// Unix seconds.
    public let time: Double

    public init(samples: [Float], time: Double) {
        self.samples = samples
        self.time = time
    }

    public var end: Double { time + Double(samples.count) / Double(SpeechStretch.rate) }
}

/// What the stream says to a reader of speech.
public enum MicEvent: Sendable {
    case frame(MicFrame)
    /// The device stopped by itself (the microphone went away): the reader is removed.
    case failed(String)
}

/// One reader of the stream: `cancel` removes it, once; the last one stops the device.
public final class MicSubscription: @unchecked Sendable {
    private let lock = NSLock()
    private var end: (() -> Void)?

    init(_ end: @escaping () -> Void) {
        self.end = end
    }

    public func cancel() {
        let end = lock.withLock {
            defer { self.end = nil }
            return self.end
        }
        end?()
    }
}

/// LAYER 1, THE MICROPHONE STREAM (README, "Listening"): the one owner of the input device.
/// Every feature that hears the microphone reads it: dictation and the input bar (`SpeechSession`),
/// Always listen (`StretchListener`), and the record's `mic-0` (`tapRaw`). The device runs while
/// anyone reads, and only then; its change (headphones in, another microphone chosen) is handled
/// once, by the device (`Microphone`).
///
/// Two kinds of reader: `listen` gets 16 kHz mono frames with their wall time, made once for all of
/// them, and `tapRaw` gets the device's own buffers with their host time (the record keeps 48 kHz).
/// Readers are called on the device's thread, in the order they came: a reader does its work
/// elsewhere.
public final class MicStream: @unchecked Sendable {
    /// The app's stream. A home of its own with no audio fixture opens none (`SpeechSession`).
    public static let shared = MicStream()

    private let makeDevice: () -> SpeechSource
    private let speech = FanOut<MicEvent>()
    private let raw = FanOut<(AVAudioPCMBuffer, UInt64)>()
    private let rawFailed = FanOut<String>()
    /// Guards `device` and `generation`: a start and a stop are one decision.
    private let lock = NSRecursiveLock()
    private var device: SpeechSource?
    /// Counts the device's runs: a late buffer of a stopped run goes nowhere.
    private var generation = 0
    /// How many times the device started, for `ui.state`.
    public private(set) var starts = 0

    /// `device` makes the device of each run: the microphone, the audio fixture, or a test's.
    public init(device: @escaping () -> SpeechSource = { speechSource() }) {
        makeDevice = device
    }

    public var isRunning: Bool { lock.withLock { device != nil } }
    public var readers: Int { speech.count + raw.count }

    /// Reads the stream as 16 kHz mono frames. Throws when the device does not start (no reader is
    /// added then).
    public func listen(_ read: @escaping @Sendable (MicEvent) -> Void) throws -> MicSubscription {
        try add(to: speech, read)
    }

    /// Reads the device's own buffers, with the host time of their first frame. `failed` tells when
    /// the device stopped by itself; the reader is removed then.
    public func tapRaw(_ read: @escaping @Sendable (AVAudioPCMBuffer, UInt64) -> Void, failed: @escaping @Sendable (String) -> Void) throws
        -> MicSubscription
    {
        let failedID = rawFailed.add(failed).id
        do {
            let subscription = try add(to: raw, read)
            return MicSubscription { [rawFailed] in
                rawFailed.remove(failedID)
                subscription.cancel()
            }
        } catch {
            rawFailed.remove(failedID)
            throw error
        }
    }

    private func add<Value>(to fan: FanOut<Value>, _ read: @escaping @Sendable (Value) -> Void) throws -> MicSubscription {
        try lock.withLock {
            let id = fan.add(read).id
            if device == nil {
                do {
                    try startDevice()
                } catch {
                    fan.remove(id)
                    throw error
                }
            }
            return MicSubscription { [weak self] in
                guard let self else { return }
                self.lock.withLock {
                    fan.remove(id)
                    if self.speech.count + self.raw.count == 0 { self.stopDevice() }
                }
            }
        }
    }

    /// Under the lock.
    private func startDevice() throws {
        generation += 1
        let run = generation
        let made = makeDevice()
        let converter = StreamResampler()
        let take: @Sendable (AVAudioPCMBuffer, UInt64) -> Void = { [weak self] buffer, host in
            guard let self, self.lock.withLock({ self.generation == run && self.device != nil }) else { return }
            if self.raw.count > 0 { self.raw.send((buffer, host)) }
            guard self.speech.count > 0 else { return }
            let samples = converter.samples(of: buffer)
            guard !samples.isEmpty else { return }
            self.speech.send(.frame(MicFrame(samples: samples, time: Self.wallTime(ofHost: host))))
        }
        // before its start: a device may give its first buffer inside `start`
        device = made
        do {
            try made.start(take, failed: { [weak self] reason in self?.deviceFailed(reason, run: run) })
        } catch {
            device = nil
            generation += 1
            throw error
        }
        starts += 1
    }

    /// Under the lock.
    private func stopDevice() {
        device?.stop()
        device = nil
        generation += 1
    }

    /// Every reader is told, and none is left: a new reader starts the device again. Under the
    /// lock, so that no reader comes between the end and the removal; it is recursive, so that a
    /// reader may cancel in its call.
    private func deviceFailed(_ reason: String, run: Int) {
        lock.withLock {
            guard generation == run, device != nil else { return }
            stopDevice()
            speech.send(.failed(reason))
            _ = speech.removeAll()
            _ = raw.removeAll()
            rawFailed.send(reason)
            _ = rawFailed.removeAll()
        }
    }

    private static let timebase: Double = {
        var info = mach_timebase_info()
        mach_timebase_info(&info)
        return Double(info.numer) / Double(info.denom) / 1e9
    }()

    /// The Unix time of a host time.
    public static func wallTime(ofHost host: UInt64) -> Double {
        let ago = Double(Int64(bitPattern: mach_absolute_time() &- host)) * timebase
        return Date().timeIntervalSince1970 - ago
    }
}

/// The device's buffers as 16 kHz mono, through ONE converter for the stream's run: FluidAudio's
/// converter (`SpeechAudio`) makes a new one for each buffer and flushes it, which costs a setup
/// for each 43 ms of sound and a seam at each buffer's end. The channels are mixed to their mean
/// and resampled with the same setting as FluidAudio's (mastering, medium quality). A buffer that
/// is not 32-bit float goes through FluidAudio's converter. Used on the device's thread alone.
final class StreamResampler: @unchecked Sendable {
    private static let target = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: Double(SpeechStretch.rate), channels: 1, interleaved: false)!
    private var converter: AVAudioConverter?
    private let fallback = SpeechAudio()

    func samples(of buffer: AVAudioPCMBuffer) -> [Float] {
        let frames = Int(buffer.frameLength)
        guard frames > 0, let data = buffer.floatChannelData else { return frames > 0 ? fallback.samples(of: buffer) : [] }
        let channels = Int(buffer.format.channelCount)
        let rate = buffer.format.sampleRate
        guard let monoFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: rate, channels: 1, interleaved: false),
            let mono = AVAudioPCMBuffer(pcmFormat: monoFormat, frameCapacity: AVAudioFrameCount(frames))
        else { return [] }
        mono.frameLength = AVAudioFrameCount(frames)
        let mixed = mono.floatChannelData![0]
        if buffer.format.isInterleaved {
            // one channel of every `channels`, added up
            mixed.update(repeating: 0, count: frames)
            for channel in 0..<channels {
                vDSP_vadd(data[0] + channel, vDSP_Stride(channels), mixed, 1, mixed, 1, vDSP_Length(frames))
            }
        } else {
            mixed.update(from: data[0], count: frames)
            for channel in 1..<max(1, channels) { vDSP_vadd(data[channel], 1, mixed, 1, mixed, 1, vDSP_Length(frames)) }
        }
        if channels > 1 {
            var scale = 1 / Float(channels)
            vDSP_vsmul(mixed, 1, &scale, mixed, 1, vDSP_Length(frames))
        }
        if rate == Self.target.sampleRate { return Array(UnsafeBufferPointer(start: mixed, count: frames)) }
        if converter?.inputFormat.sampleRate != rate {
            converter = AVAudioConverter(from: monoFormat, to: Self.target)
            converter?.sampleRateConverterAlgorithm = AVSampleRateConverterAlgorithm_Mastering
            converter?.sampleRateConverterQuality = AVAudioQuality.medium.rawValue
        }
        guard let converter,
            let out = AVAudioPCMBuffer(pcmFormat: Self.target, frameCapacity: AVAudioFrameCount(Double(frames) * Self.target.sampleRate / rate) + 64)
        else { return [] }
        var given = false
        var error: NSError?
        // the input once, then "no data now": the converter keeps its state for the next buffer
        _ = converter.convert(to: out, error: &error) { _, status in
            if given {
                status.pointee = .noDataNow
                return nil
            }
            given = true
            status.pointee = .haveData
            return mono
        }
        guard error == nil, let samples = out.floatChannelData?[0] else { return [] }
        return Array(UnsafeBufferPointer(start: samples, count: Int(out.frameLength)))
    }
}
