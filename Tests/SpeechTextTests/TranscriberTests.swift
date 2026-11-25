import Foundation
@testable import SpeechText
import VoiceMeetCore
import XCTest

/// EVERY FEATURE READS THE ONE TRANSCRIBER (README, "Listening"): dictation, the capture and Always
/// listen, against the fake OpenAI of `OpenAIStreamTests` and a fake local engine. None chooses a
/// model: the rule's answer, set on the transcriber, decides.

private let terms = WordList(markdown: "- Beelink: bee link\n")
private func tone(_ seconds: Double) -> [Float] { (0..<Int(seconds * 16_000)).map { 0.3 * sin(Float($0) * 0.2) } }
private func silence(_ seconds: Double) -> [Float] { [Float](repeating: 0, count: Int(seconds * 16_000)) }

private final class Heard: @unchecked Sendable {
    private let lock = NSLock()
    private var events: [SpeechRecognizer.Event] = []
    func add(_ event: SpeechRecognizer.Event) { lock.withLock { events.append(event) } }
    var segments: [SpeechSegment] { lock.withLock { events.compactMap { if case .segment(let segment) = $0 { return segment } else { return nil } } } }
    var notes: [String] { lock.withLock { events.compactMap { if case .note(let note) = $0 { return note } else { return nil } } } }
}

/// OpenAI that answers each commit with an item of its own and the next of `finals`. With
/// `failAfter`, each append after that many commits is an error, as a quota that runs out.
private func commits(_ finals: [String], failAfter: Int? = nil) -> @Sendable ([String: Any]) -> [[String: Any]] {
    let count = Counter()
    let made = Lines()
    return { message in
        switch message["type"] as? String {
        case "session.update": return [["type": "session.updated"]]
        case "input_audio_buffer.append":
            if let failAfter, made.all.count >= failAfter { return [["type": "error", "error": ["message": "insufficient_quota"]]] }
            return []
        case "input_audio_buffer.commit":
            let index = count.next()
            made.add("item_\(index)")
            return [
                ["type": "input_audio_buffer.committed", "item_id": "item_\(index)"],
                ["type": "conversation.item.input_audio_transcription.completed", "item_id": "item_\(index)", "transcript": index < finals.count ? finals[index] : "", "usage": ["type": "duration", "seconds": 2]],
            ]
        default: return []
        }
    }
}

private func waitUntil(_ what: String, _ condition: () -> Bool) async throws {
    let started = Date()
    while !condition() {
        if Date().timeIntervalSince(started) > 5 { throw NSError(domain: "until", code: 1, userInfo: [NSLocalizedDescriptionKey: "no \(what) in 5 s"]) }
        try await Task.sleep(nanoseconds: 10_000_000)
    }
}

/// Pushes `samples` with their times, from `start` seconds, in pieces of 0.1 s: a capture's buffers.
private func feed(_ listening: SpeechListening, _ samples: [Float], from start: Double) async {
    for offset in stride(from: 0, to: samples.count, by: 1_600) {
        listening.push(Array(samples[offset..<min(offset + 1_600, samples.count)]), at: start + Double(offset) / 16_000)
        try? await Task.sleep(nanoseconds: 5_000_000)
    }
}

@MainActor
private final class Client: SpeechClient {
    var ended: XCTestExpectation?
    func speech(_ event: SpeechSession.Event) { if case .ended = event { ended?.fulfill() } }
}

final class TranscriberTests: XCTestCase {
    /// A dictation, through the session and the one transcriber: online, OpenAI hears it, and its
    /// segment in the transcription stream names that model; offline, the same dictation is the
    /// local model's, and no socket opens.
    @MainActor
    func testADictationIsHeardByTheRulesProvider() async throws {
        for route in [SpeechRoute(.openAI, .reachable), SpeechRoute(.local, .offline)] {
            let server = try FakeOpenAI(answer: openAI(deltas: ["the bee"], final: "the bee link is up"))
            let device = FakeMicrophone()
            let session = SpeechSession(source: { device }, transcriber: transcriber(server, route: route) { _, _ in LocalEngine(text: "the bee link on this Mac") })
            session.authorization = { .authorized }
            var segments: [TranscriptSegment] = []
            session.transcribed = { if case .segment(let segment) = $0 { segments.append(segment) } }
            let client = Client()
            XCTAssertNil(session.start(client, words: terms))
            for _ in 0..<10 {
                device.give()
                try await Task.sleep(nanoseconds: 20_000_000)
            }
            client.ended = expectation(description: "the end")
            session.finish(client)
            await fulfillment(of: [client.ended!], timeout: 10)
            if route.provider == .openAI {
                XCTAssertEqual(segments.map(\.text), ["the Beelink is up"])
                XCTAssertEqual(segments.map(\.model), ["gpt-live-transcribe"])
                XCTAssertTrue(server.types().contains("input_audio_buffer.commit"))
            } else {
                XCTAssertEqual(segments.map(\.text), ["the Beelink on this Mac"])
                XCTAssertEqual(segments.map(\.model), ["oruk-fourier-2b"])
                XCTAssertTrue(server.messages.isEmpty, "offline, no socket opens")
            }
            XCTAssertEqual(segments.first?.stretch, "dictation-1")
        }
    }

    /// A capture at OpenAI: each pause commits, so each segment comes while the capture goes, with
    /// its times from the capture's start; a gap in the buffers' times is kept as silence.
    func testACaptureCommitsAtEachPauseAndItsSegmentsHaveTheirTimes() async throws {
        let server = try FakeOpenAI(answer: commits(["the bee link is up", "and so is herdr"]))
        let heard = Heard()
        let listening = transcriber(server).listening(.capture, words: terms) { heard.add($0) }.listening
        listening.start()
        await feed(listening, tone(1.5) + silence(1), from: 0)
        try await waitUntil("the first segment") { heard.segments.count == 1 }
        XCTAssertEqual(heard.segments.first?.text, "the Beelink is up", "it came while the capture goes")
        // the next buffers come 0.5 s later on the capture's clock
        await feed(listening, tone(1), from: 3)
        let segments = await listening.finish()
        XCTAssertEqual(segments.map(\.text), ["the Beelink is up", "and so is herdr"])
        XCTAssertEqual(segments.map(\.model), ["gpt-live-transcribe", "gpt-live-transcribe"])
        XCTAssertEqual(segments[0].start, 0, accuracy: 0.01)
        XCTAssertEqual(segments[0].end, 2.2, accuracy: 0.11, "cut where the pause of 0.7 s was heard")
        XCTAssertEqual(segments[1].start, segments[0].end, accuracy: 0.001)
        XCTAssertEqual(segments[1].end, 4, accuracy: 0.11)
        XCTAssertEqual(server.types().filter { $0 == "input_audio_buffer.commit" }.count, 2, "one socket, a commit for each segment")
        XCTAssertTrue(heard.notes.contains { $0.contains("OpenAI billed 4 s") }, "\(heard.notes)")
    }

    /// OpenAI fails in the middle of a capture: what it answered stays, and the local model hears
    /// the sound from the end of its last segment, with the capture's times. Nothing is heard twice.
    func testWhenOpenAIFailsMidCaptureTheLocalModelHearsFromTheLastAnsweredSegment() async throws {
        let server = try FakeOpenAI(answer: commits(["the bee link is up"], failAfter: 1))
        let heard = Heard()
        let listening = transcriber(server).listening(.capture, words: terms) { heard.add($0) }.listening
        listening.start()
        await feed(listening, tone(1.5) + silence(1), from: 0)
        try await waitUntil("the first segment") { heard.segments.count == 1 }
        await feed(listening, tone(1), from: 2.5)
        let segments = await listening.finish()
        XCTAssertEqual(segments.map(\.text), ["the Beelink is up", "heard on this Mac"])
        XCTAssertEqual(segments.map(\.model), ["gpt-live-transcribe", "oruk-fourier-2b"])
        XCTAssertGreaterThanOrEqual(segments[1].start, segments[0].end - 0.001, "the local model starts where OpenAI's segment ended")
        XCTAssertEqual(segments[1].end, 3.5, accuracy: 0.11)
        XCTAssertTrue(heard.notes.contains { $0.contains("insufficient_quota") && $0.contains("the local model hears it") }, "\(heard.notes)")
    }

    /// A key's listening whose OpenAI fails mid-stretch: the whole stretch goes to the local model.
    func testWhenOpenAIFailsMidStretchTheWholeStretchGoesToTheLocalModel() async throws {
        let server = try FakeOpenAI(answer: commits([], failAfter: 0))
        let heard = Heard()
        let listening = transcriber(server).listening(.live, words: terms) { heard.add($0) }.listening
        listening.start()
        await feed(listening, tone(1), from: 0)
        let segments = await listening.finish()
        XCTAssertEqual(segments.map(\.text), ["heard on this Mac"])
        XCTAssertEqual(segments.first?.start ?? -1, 0, accuracy: 0.01, "from the stretch's first sample")
    }

    /// Always listen: online, each stretch goes to OpenAI once; with the rule's local answer, to the
    /// local model. Speech detection gates it: the silence before it is never sent.
    func testAlwaysListensStretchesGoToTheRulesProvider() async throws {
        for route in [SpeechRoute(.openAI, .reachable), SpeechRoute(.local, .noOpenAI)] {
            let server = try FakeOpenAI(answer: openAI(deltas: [], final: "for the bee link"))
            let device = FakeMicrophone()
            let stream = MicStream(device: { device })
            let segments = Lines()
            let made = transcriber(server, route: route) { _, _ in LocalEngine(text: "for the bee link here") }
            let listener = StretchListener(stream: stream, transcriber: made, useModel: false) { event in
                if case .segment(let segment) = event { segments.add("\(segment.stretch) \(segment.model): \(segment.text)") }
            }
            listener.use(terms)
            try listener.start()
            for _ in 0..<5 { device.give(loud: false) }
            for _ in 0..<10 { device.give() }
            for _ in 0..<20 { device.give(loud: false) }
            try await waitUntil("the stretch's segment") { segments.all.count == 1 }
            listener.stop()
            if route.provider == .openAI {
                XCTAssertEqual(segments.all, ["listen-1 gpt-live-transcribe: for the Beelink"])
                let bytes = server.messages.filter { $0["type"] as? String == "input_audio_buffer.append" }
                    .compactMap { ($0["audio"] as? String).flatMap { Data(base64Encoded: $0) }?.count }.reduce(0, +)
                // the stretch alone: about 1 s of voice and the gate's pads, not the 3.5 s of the stream
                XCTAssertLessThan(Double(bytes) / 2 / 24_000, 2.5)
            } else {
                XCTAssertEqual(segments.all, ["listen-1 oruk-fourier-2b: for the Beelink here"])
                XCTAssertTrue(server.messages.isEmpty)
            }
        }
    }
}

/// THE LOCAL MODEL'S LIFE with fake models: loaded only when it must hear.
final class LocalSpeechTests: XCTestCase {
    private final class Models: @unchecked Sendable {
        let loads = Counter()
        let unloads = Counter()
        let lines = Lines()
        var standIn: LocalSpeech.Models {
            LocalSpeech.Models(
                isOnDisk: { _ in true }, load: { [loads] _ in _ = loads.next() }, unload: { [unloads] _ in _ = unloads.next() },
                engine: { [loads] _, _, _ in
                    _ = loads.next()
                    return LocalEngine()
                })
        }
        func make(idle: Double = 0.3) async -> LocalSpeech {
            let speech = LocalSpeech(models: standIn, idleSeconds: idle)
            await speech.logs { [lines] in lines.add($0) }
            return speech
        }
    }

    private func loaded(_ speech: LocalSpeech) async -> Bool { await speech.isLoaded }

    func testTheNetworkDropsAndItLoadsAtOnceThenOpenAIIsBackAndItIsUnloadedAfterItsIdleTime() async throws {
        let models = Models()
        let speech = await models.make()
        await speech.set(SpeechRoute(.openAI, .reachable), model: .default, mayLoad: true)
        try await Task.sleep(nanoseconds: 100_000_000)
        var isLoaded = await loaded(speech)
        XCTAssertFalse(isLoaded, "online: never loaded")
        await speech.set(SpeechRoute(.local, .offline), model: .default, mayLoad: true)
        try await waitUntil("the load") { models.lines.all.contains { $0.contains("is loaded in") } }
        XCTAssertTrue(models.lines.all.contains("oruk-fourier-2b loads: the network is down"), "\(models.lines.all)")
        XCTAssertTrue(models.lines.all.contains { $0.hasPrefix("oruk-fourier-2b is loaded in ") && $0.hasSuffix("s: the network is down") }, "\(models.lines.all)")
        try await Task.sleep(nanoseconds: 500_000_000)
        isLoaded = await loaded(speech)
        XCTAssertTrue(isLoaded, "offline it stays, however long unused")
        await speech.set(SpeechRoute(.openAI, .reachable), model: .default, mayLoad: true)
        isLoaded = await loaded(speech)
        XCTAssertTrue(isLoaded, "OpenAI is back: it stays for its idle time")
        try await waitUntil("the unload") { models.unloads.peek == 1 }
        isLoaded = await loaded(speech)
        XCTAssertFalse(isLoaded)
        XCTAssertTrue(models.lines.all.contains { $0.contains("is unloaded after") && $0.contains("OpenAI hears again") }, "\(models.lines.all)")
    }

    func testAFailureOfOpenAILoadsItForItsStretchAndTheStretchKeepsIt() async throws {
        let models = Models()
        let speech = await models.make()
        await speech.set(SpeechRoute(.openAI, .reachable), model: .default, mayLoad: true)
        _ = try await speech.engines.engine(.default, .empty, "OpenAI failed (no session in time)") { _ in }
        XCTAssertTrue(models.lines.all.contains("oruk-fourier-2b loads: OpenAI failed (no session in time)"), "\(models.lines.all)")
        try await Task.sleep(nanoseconds: 600_000_000)
        var isLoaded = await loaded(speech)
        XCTAssertTrue(isLoaded, "a stretch in progress keeps it, past the idle time")
        speech.engines.done()
        try await waitUntil("the unload") { models.unloads.peek == 1 }
        isLoaded = await loaded(speech)
        XCTAssertFalse(isLoaded, "unused for its idle time after the stretch")
    }

    func testNothingLoadsBeforeAUseWhereNothingWouldHear() async throws {
        let models = Models()
        let speech = await models.make()
        await speech.set(SpeechRoute(.local, .noOpenAI), model: .default, mayLoad: false)
        try await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertEqual(models.loads.peek, 0)
        XCTAssertTrue(models.lines.all.contains { $0.contains("is not loaded") && $0.contains("nothing here would hear it") }, "\(models.lines.all)")
    }

    func testAnotherLocalModelChosenUnloadsTheOneBefore() async throws {
        let models = Models()
        let speech = await models.make()
        await speech.set(SpeechRoute(.local, .chosen), model: .fourier2b, mayLoad: true)
        try await waitUntil("the load") { models.lines.all.contains { $0.contains("oruk-fourier-2b is loaded") } }
        await speech.set(SpeechRoute(.local, .chosen), model: .parakeetV3, mayLoad: true)
        try await waitUntil("the new load") { models.lines.all.contains { $0.contains("parakeet-v3 is loaded") } }
        XCTAssertEqual(models.unloads.peek, 1)
        XCTAssertTrue(models.lines.all.contains { $0.contains("oruk-fourier-2b is unloaded") && $0.contains("now parakeet-v3") }, "\(models.lines.all)")
    }
}
