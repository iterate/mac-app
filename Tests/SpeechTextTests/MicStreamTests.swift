import AVFoundation
@testable import SpeechText
import VoiceMeetCore
import XCTest

/// A device that gives `pieces` buffers of 0.1 s at 48 kHz when it starts, and counts its runs.
private final class Device: SpeechSource, @unchecked Sendable {
    let lock = NSLock()
    var starts = 0
    var stops = 0
    var failed: (@Sendable (String) -> Void)?
    var take: (@Sendable (AVAudioPCMBuffer, UInt64) -> Void)?

    func start(_ take: @escaping @Sendable (AVAudioPCMBuffer, UInt64) -> Void, failed: @escaping @Sendable (String) -> Void) throws {
        lock.withLock {
            starts += 1
            self.take = take
            self.failed = failed
        }
    }

    func stop() { lock.withLock { stops += 1 } }

    private let zero = mach_absolute_time()
    private var given = 0

    /// One buffer of 0.1 s at 48 kHz, a tone or silence, stamped 0.1 s after the one before.
    func give(loud: Bool = true) {
        let format = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1)!
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 4800)!
        buffer.frameLength = 4800
        for index in 0..<4800 { buffer.floatChannelData![0][index] = loud ? 0.3 * sin(Float(index) * 0.05) : 0 }
        var info = mach_timebase_info()
        mach_timebase_info(&info)
        let host = lock.withLock {
            defer { given += 1 }
            return zero + UInt64(Double(given) * 0.1e9 * Double(info.denom) / Double(info.numer))
        }
        lock.withLock { take }?(buffer, host)
    }
}

private final class Got: @unchecked Sendable {
    let lock = NSLock()
    var frames: [MicFrame] = []
    var raw = 0
    var failures: [String] = []
    func add(_ event: MicEvent) {
        lock.withLock {
            switch event {
            case .frame(let frame): frames.append(frame)
            case .failed(let reason): failures.append(reason)
            }
        }
    }
}

final class MicStreamTests: XCTestCase {
    func testOneDeviceRunsWhileAnyoneReadsAndStopsWithTheLastReader() throws {
        let device = Device()
        let stream = MicStream(device: { device })
        let a = Got(), b = Got()
        let first = try stream.listen { a.add($0) }
        let second = try stream.listen { b.add($0) }
        let record = try stream.tapRaw({ _, _ in a.lock.withLock { a.raw += 1 } }, failed: { _ in })
        XCTAssertEqual(device.starts, 1, "one device for every reader")
        device.give()
        XCTAssertEqual(a.frames.count, 1)
        XCTAssertEqual(b.frames.count, 1)
        XCTAssertEqual(a.raw, 1)
        for _ in 0..<4 { device.give() }
        // 0.5 s at 48 kHz is 8000 samples at 16 kHz, made once for both readers; the one converter
        // of the run holds its filter's few milliseconds
        let total = a.frames.reduce(0) { $0 + $1.samples.count }
        XCTAssertEqual(total, 8000, accuracy: 500)
        XCTAssertEqual(b.frames.map(\.samples.count), a.frames.map(\.samples.count))
        XCTAssertEqual(a.frames.first?.time ?? 0, Date().timeIntervalSince1970, accuracy: 1)
        first.cancel()
        first.cancel()
        second.cancel()
        XCTAssertEqual(device.stops, 0, "the record still reads")
        record.cancel()
        XCTAssertEqual(device.stops, 1)
        XCTAssertFalse(stream.isRunning)
        // a buffer of the stopped run goes to no one
        device.give()
        XCTAssertEqual(b.frames.count, 5)
        _ = try stream.listen { b.add($0) }
        XCTAssertEqual(device.starts, 2, "a reader after the last one starts the device again")
    }

    /// A stereo input is the mean of its channels: 0.2 and 0.4 are 0.3, at 16 kHz.
    func testTheChannelsAreMixedToTheirMean() throws {
        final class Stereo: SpeechSource, @unchecked Sendable {
            var take: (@Sendable (AVAudioPCMBuffer, UInt64) -> Void)?
            func start(_ take: @escaping @Sendable (AVAudioPCMBuffer, UInt64) -> Void, failed: @escaping @Sendable (String) -> Void) throws { self.take = take }
            func stop() {}
        }
        let device = Stereo()
        let stream = MicStream(device: { device })
        let got = Got()
        _ = try stream.listen { got.add($0) }
        let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 2))
        for _ in 0..<5 {
            let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 4800))
            buffer.frameLength = 4800
            buffer.floatChannelData![0].update(repeating: 0.2, count: 4800)
            buffer.floatChannelData![1].update(repeating: 0.4, count: 4800)
            device.take?(buffer, mach_absolute_time())
        }
        let samples = got.frames.flatMap(\.samples)
        XCTAssertGreaterThan(samples.count, 7000)
        XCTAssertEqual(samples[samples.count / 2], 0.3, accuracy: 0.01)
    }

    func testAFailureTellsEveryReaderAndLeavesNone() throws {
        let device = Device()
        let stream = MicStream(device: { device })
        let got = Got()
        let raw = Got()
        _ = try stream.listen { got.add($0) }
        _ = try stream.tapRaw({ _, _ in }, failed: { raw.add(.failed($0)) })
        device.lock.withLock { device.failed }?("This Mac has no microphone now.")
        XCTAssertEqual(got.failures, ["This Mac has no microphone now."])
        XCTAssertEqual(raw.failures, ["This Mac has no microphone now."])
        XCTAssertEqual(stream.readers, 0)
        XCTAssertEqual(device.stops, 1)
    }

    func testADeviceThatDoesNotStartAddsNoReader() {
        struct Refused: Error {}
        final class Broken: SpeechSource {
            func start(_ take: @escaping @Sendable (AVAudioPCMBuffer, UInt64) -> Void, failed: @escaping @Sendable (String) -> Void) throws { throw Refused() }
            func stop() {}
        }
        let stream = MicStream(device: { Broken() })
        XCTAssertThrowsError(try stream.listen { _ in })
        XCTAssertEqual(stream.readers, 0)
        XCTAssertFalse(stream.isRunning)
    }
}

/// A model that hears "for the Beelink" in any loud stretch.
private struct Engine: SpeechEngine {
    func hear(_ samples: [Float], final: Bool) async throws -> Heard {
        samples.contains { abs($0) > 0.05 } ? Heard(text: "for the b link") : Heard(text: "")
    }
}

@MainActor
final class SpeechSessionTranscriptTests: XCTestCase {
    @MainActor private final class Client: SpeechClient {
        var ended: XCTestExpectation?
        func speech(_ event: SpeechSession.Event) { if case .ended = event { ended?.fulfill() } }
    }

    /// A listening is a stretch of the transcription stream: its final segment has the wall time,
    /// the heard words, the word list's correction and the model.
    func testAListeningsSegmentsGoToTheTranscriptionStreamWithTheirWallTimes() async throws {
        let device = Device()
        let session = SpeechSession(source: { device }, engine: { _, _ in Engine() })
        session.authorization = { .authorized }
        var events: [TranscriptEvent] = []
        session.transcribed = { events.append($0) }
        let client = Client()
        let words = WordList(markdown: "- Beelink: b link\n")
        let before = Date().timeIntervalSince1970
        XCTAssertNil(session.start(client, words: words, origin: .input))
        let stretch = try XCTUnwrap(session.stretch(for: client))
        XCTAssertEqual(stretch.id, "input-1")
        for _ in 0..<10 { device.give() }
        client.ended = expectation(description: "the end")
        session.finish(client)
        await fulfillment(of: [client.ended!], timeout: 5)
        let segments = events.compactMap { if case .segment(let segment) = $0 { return segment } else { return nil } }
        XCTAssertEqual(segments.count, 1, "each segment once")
        let segment = try XCTUnwrap(segments.first)
        XCTAssertEqual(segment.text, "for the Beelink")
        XCTAssertEqual(segment.heard, "for the b link")
        XCTAssertEqual(segment.corrections.map(\.term), ["Beelink"])
        XCTAssertEqual(segment.origin, .input)
        XCTAssertEqual(segment.stretch, "input-1")
        XCTAssertEqual(segment.start, before, accuracy: 1)
        XCTAssertGreaterThan(segment.end, segment.start)
        XCTAssertEqual(device.stops, 1, "the end of the listening closes the microphone")
    }
}

final class StretchListenerTests: XCTestCase {
    private final class Heard: @unchecked Sendable {
        let lock = NSLock()
        var events: [StretchListener.Event] = []
        func add(_ event: StretchListener.Event) { lock.withLock { events.append(event) } }
        var segments: [TranscriptSegment] { lock.withLock { events.compactMap { if case .segment(let s) = $0 { return s } else { return nil } } } }
        var stretches: Int { lock.withLock { events.filter { if case .ended = $0 { return true } else { return false } }.count } }
    }

    private func waitFor(_ check: () -> Bool) async {
        for _ in 0..<200 where !check() { try? await Task.sleep(nanoseconds: 20_000_000) }
    }

    /// 1 s of voice, then silence: one stretch, one segment `listen-1` with the word list's
    /// correction, on the wall clock of the sound.
    func testAStretchOfSpeechIsDetectedAndPutIntoWordsOnce() async throws {
        let device = Device()
        let stream = MicStream(device: { device })
        let heard = Heard()
        let listener = StretchListener(stream: stream, useModel: false, engine: { _, _ in Engine() }) { heard.add($0) }
        listener.use(.default, words: WordList(markdown: "- Beelink: b link\n"))
        let before = Date().timeIntervalSince1970
        try listener.start()
        for _ in 0..<5 { device.give(loud: false) }
        for _ in 0..<10 { device.give() }
        for _ in 0..<20 { device.give(loud: false) }
        await waitFor { heard.segments.count == 1 }
        let segment = try XCTUnwrap(heard.segments.first)
        XCTAssertEqual(segment.text, "for the Beelink")
        XCTAssertEqual(segment.stretch, "listen-1")
        XCTAssertEqual(segment.origin, .listen)
        XCTAssertEqual(heard.stretches, 1)
        // the voice is from 0.5 s to 1.5 s of the sound; the stretch is padded and in pieces of 0.256 s
        XCTAssertEqual(segment.start - before, 0.5, accuracy: 0.6)
        listener.stop()
        XCTAssertFalse(stream.isRunning)
    }

    /// While a key listens, Always listen hears nothing: the stretch that went on ends at the key.
    func testAHoldCutsTheStretchAndDetectsNothingUntilItsEnd() async throws {
        let device = Device()
        let stream = MicStream(device: { device })
        let heard = Heard()
        let listener = StretchListener(stream: stream, useModel: false, engine: { _, _ in Engine() }) { heard.add($0) }
        try listener.start()
        for _ in 0..<10 { device.give() }
        await waitFor { heard.lock.withLock { !heard.events.isEmpty } }
        listener.hold(true)
        for _ in 0..<20 { device.give() }
        await waitFor { heard.segments.count == 1 }
        XCTAssertEqual(heard.stretches, 1, "the hold ended the stretch")
        try await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertEqual(heard.stretches, 1, "no stretch while held")
        listener.stop()
    }
}

final class WakeTests: XCTestCase {
    private func buffer(loud: Bool) -> AVAudioPCMBuffer {
        let format = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1)!
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 4800)!
        buffer.frameLength = 4800
        for index in 0..<4800 { buffer.floatChannelData![0][index] = loud ? 0.3 * sin(Float(index) * 0.05) : 0.0001 }
        return buffer
    }

    /// Silence is not resampled; a loud buffer brings the kept 0.6 s before it; 1.5 s after the last
    /// loud one it sleeps again, unless a stretch goes on.
    func testSilenceSleepsAndALoudBufferWakesWithWhatCameBefore() {
        let wake = StretchListener.Wake()
        var time = 100.0
        func give(_ loud: Bool) -> [MicFrame] {
            defer { time += 0.1 }
            return wake.frames(of: buffer(loud: loud), time: time)
        }
        for _ in 0..<20 { XCTAssertTrue(give(false).isEmpty, "asleep") }
        let woken = give(true)
        XCTAssertEqual(woken.count, 7, "0.6 s kept, and the loud buffer")
        XCTAssertEqual(woken.first?.time ?? 0, 101.4, accuracy: 0.01)
        for _ in 0..<14 { XCTAssertEqual(give(false).count, 1, "awake for 1.5 s") }
        _ = give(false)
        XCTAssertTrue(give(false).isEmpty, "asleep again")
        wake.set(speaking: true)
        XCTAssertEqual(give(false).count, 2, "a stretch goes on: the buffer kept while asleep, and this one")
        wake.set(held: true)
        XCTAssertTrue(give(true).isEmpty, "a key listens: nothing")
    }
}
