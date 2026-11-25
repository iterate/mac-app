import AVFoundation
import FluidAudio
import Foundation
import VoiceMeetCore

/// THE DEVICE OF THE MICROPHONE STREAM (`MicStream`): the microphone, or the audio fixture in its
/// place. Its buffers are in any format, each with the host time of its first frame; the stream
/// makes them 16 kHz mono once for every reader. A capture has no source of its own: it pushes the
/// buffers that ScreenCaptureKit gives it.
public protocol SpeechSource: AnyObject {
    /// Starts to give buffers to `take`. Throws a reason in words when it cannot start; `failed`
    /// tells the reason when it stops by itself later. Neither comes after `stop`.
    func start(_ take: @escaping @Sendable (AVAudioPCMBuffer, UInt64) -> Void, failed: @escaping @Sendable (String) -> Void) throws
    func stop()
}

/// The sound file that the environment's `ITERATE_MAC_AUDIO_FIXTURE` names, if any.
public let environmentFixture: URL? = ProcessInfo.processInfo.environment["ITERATE_MAC_AUDIO_FIXTURE"]
    .flatMap { $0.isEmpty ? nil : URL(fileURLWithPath: $0) }

/// The device of the stream: the audio fixture when one is set, else the microphone.
public func speechSource(fixture: URL? = environmentFixture) -> SpeechSource {
    fixture.map(FixturePlayer.init) ?? Microphone()
}

/// Buffers of any format as 16 kHz mono samples, and their loudness.
public final class SpeechAudio: @unchecked Sendable {
    private let converter = AudioConverter()

    public init() {}

    public func samples(of buffer: AVAudioPCMBuffer) -> [Float] {
        (try? converter.resampleBuffer(buffer)) ?? []
    }

    /// How loud the samples are, 0 to 1: speech is near 0.05 to 0.2 RMS, and the square root makes
    /// a quiet voice show.
    public static func level(of samples: [Float]) -> Float {
        guard !samples.isEmpty else { return 0 }
        var sum: Float = 0
        for sample in samples { sum += sample * sample }
        return min(1, ((sum / Float(samples.count)).squareRoot() * 4).squareRoot())
    }
}

/// THE MICROPHONE, through an audio engine of its own: one tap while it runs. The stream
/// (`MicStream`) is its only user: one engine for the whole app.
///
/// The engine starts and stops on a queue that all microphones share, never on the main thread:
/// a start of the audio hardware takes a moment. `start` throws only when this Mac has no input
/// now; an engine that does not start is told to `failed`. When the input changes (headphones
/// in, another microphone chosen), macOS stops the engine: the tap is made again in the new
/// format and the engine starts again, and when that fails, `failed` says so.
public final class Microphone: SpeechSource, @unchecked Sendable {
    /// Every microphone's work, in order: a stop before the next start.
    private static let queue = DispatchQueue(label: "com.iterate.speech.microphone", qos: .userInitiated)
    private let engine = AVAudioEngine()
    /// Used on `queue` alone.
    private var isRunning = false
    private var changes: NSObjectProtocol?
    private var take: (@Sendable (AVAudioPCMBuffer, UInt64) -> Void)?
    private var failed: (@Sendable (String) -> Void)?

    public init() {}

    public func start(_ take: @escaping @Sendable (AVAudioPCMBuffer, UInt64) -> Void, failed: @escaping @Sendable (String) -> Void) throws {
        Self.queue.async { [self] in
            self.take = take
            self.failed = failed
            isRunning = true
            changes = NotificationCenter.default.addObserver(forName: .AVAudioEngineConfigurationChange, object: engine, queue: nil) { [weak self] _ in
                guard let self else { return }
                Self.queue.async { self.run(again: true) }
            }
            run(again: false)
        }
    }

    /// On `queue`: the tap in the input's format now, and the engine started.
    private func run(again: Bool) {
        guard isRunning, let take else { return }
        let input = engine.inputNode
        if again {
            input.removeTap(onBus: 0)
            engine.stop()
        }
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else { return fail("This Mac has no microphone now.") }
        input.installTap(onBus: 0, bufferSize: 2048, format: format) { buffer, when in
            take(buffer, when.isHostTimeValid ? when.hostTime : mach_absolute_time())
        }
        do {
            engine.prepare()
            try engine.start()
        } catch {
            fail("The microphone did not start: \(error.localizedDescription)")
        }
    }

    private func fail(_ reason: String) {
        let failed = failed
        end()
        failed?(reason)
    }

    public func stop() {
        Self.queue.async { [self] in end() }
    }

    /// On `queue`.
    private func end() {
        guard isRunning else { return }
        isRunning = false
        if let changes { NotificationCenter.default.removeObserver(changes) }
        changes = nil
        take = nil
        failed = nil
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
    }
}

/// THE AUDIO FIXTURE in place of the microphone (README, "Testing with no hand"): the file at the
/// pace of the clock, then silence, as a microphone in a quiet room. No audio device opens.
public final class FixturePlayer: SpeechSource, @unchecked Sendable {
    private let url: URL
    private let lock = NSLock()
    private var isStopped = false

    public init(_ url: URL) {
        self.url = url
    }

    public func start(_ take: @escaping @Sendable (AVAudioPCMBuffer, UInt64) -> Void, failed: @escaping @Sendable (String) -> Void) throws {
        let audio: AudioFixture
        do {
            audio = try AudioFixture(url)
        } catch {
            throw SpeechSourceError("The audio fixture \(url.lastPathComponent) does not read: \(error.localizedDescription)")
        }
        DispatchQueue.global(qos: .userInitiated).async { [self] in
            while !lock.withLock({ isStopped }), let buffer = audio.next() {
                take(buffer, mach_absolute_time())
                Thread.sleep(forTimeInterval: Double(buffer.frameLength) / buffer.format.sampleRate)
            }
        }
    }

    public func stop() {
        lock.withLock { isStopped = true }
    }
}

public struct SpeechSourceError: LocalizedError {
    public let errorDescription: String?

    init(_ reason: String) {
        errorDescription = reason
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
