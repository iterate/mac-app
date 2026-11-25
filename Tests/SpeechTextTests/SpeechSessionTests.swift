import AVFoundation
import SpeechText
import VoiceMeetCore
import XCTest

/// A stand-in for the speech model: it "hears" `text`, and its one word starts at the first loud
/// sample of the stretch, as a model's would.
private struct Engine: SpeechEngine {
    var text = "hello there"

    func hear(_ samples: [Float], final: Bool) async throws -> Heard {
        let first = samples.firstIndex { abs($0) > 0.05 }
        guard let first else { return Heard(text: "") }
        let start = Double(first) / Double(SpeechStretch.rate)
        return Heard(text: text, words: [.init(start: start, end: start + 0.3, text: text)])
    }
}

/// Loud and quiet samples at 16 kHz.
private func loud(_ seconds: Double) -> [Float] { (0..<Int(seconds * 16_000)).map { 0.3 * sin(Float($0) * 0.2) } }
private func quiet(_ seconds: Double) -> [Float] { [Float](repeating: 0, count: Int(seconds * 16_000)) }

final class SpeechRecognizerTests: XCTestCase {
    private final class Heard: @unchecked Sendable {
        var events: [SpeechRecognizer.Event] = []
        let lock = NSLock()
        func add(_ event: SpeechRecognizer.Event) { lock.withLock { events.append(event) } }
        var notes: [String] { lock.withLock { events.compactMap { if case .note(let note) = $0 { return note } else { return nil } } } }
    }

    func testSegmentsHaveTheirTimesFromTheStartAndAGapIsFilled() async {
        let heard = Heard()
        let recognizer = SpeechRecognizer(model: .default, words: .empty, engine: { Engine() }) { heard.add($0) }
        recognizer.start()
        recognizer.push(loud(2.5), at: 0)
        recognizer.push(quiet(1))
        // the loop sees the pause and ends the first stretch
        try? await Task.sleep(nanoseconds: 1_200_000_000)
        // the source lost 1.5 s: the next samples are stamped at 5 s
        recognizer.push(loud(2), at: 5)
        let segments = await recognizer.finish()
        XCTAssertEqual(segments.count, 2)
        XCTAssertEqual(segments[0].start, 0, accuracy: 0.01)
        XCTAssertEqual(segments[1].start, 5, accuracy: 0.01)
        XCTAssertEqual(segments[1].end, 5.3, accuracy: 0.01)
        XCTAssertEqual(segments[1].text, "hello there")
    }

    func testTheWordListRepairsTheText() async {
        let words = WordList(markdown: "- Beelink: bee link\n")
        let recognizer = SpeechRecognizer(model: .default, words: words, engine: { Engine(text: "the bee link") }) { _ in }
        recognizer.start()
        recognizer.push(loud(1))
        let segments = await recognizer.finish()
        XCTAssertEqual(segments.map(\.text), ["the Beelink"])
        XCTAssertEqual(segments.first?.words.first?.text, "the bee link", "the words stay as the model heard them")
    }

    func testThePartialTextKeepsWhatWasHeardBesideItsCorrections() async {
        let heard = Heard()
        let words = WordList(markdown: "- Beelink: b-link\n")
        let recognizer = SpeechRecognizer(model: .default, words: words, engine: { Engine(text: "on the b link box") }) { heard.add($0) }
        recognizer.start()
        recognizer.push(loud(2.5))
        recognizer.push(quiet(1))
        try? await Task.sleep(nanoseconds: 1_200_000_000)
        let segments = await recognizer.finish()
        let partials = heard.lock.withLock { heard.events.compactMap { if case .partial(let said) = $0 { return said } else { return nil } } }
        let last = try? XCTUnwrap(partials.last)
        XCTAssertEqual(last?.heard, "on the b link box")
        XCTAssertEqual(last?.text, "on the Beelink box")
        XCTAssertEqual(last?.corrections.map(\.heard), ["b link"])
        XCTAssertEqual(segments.map(\.text), ["on the Beelink box"], "the written text has the term alone")
    }

    func testTheSoundThatWaitsForTheModelIsBounded() async {
        let heard = Heard()
        let recognizer = SpeechRecognizer(model: .default, words: .empty, engine: {
            try await Task.sleep(nanoseconds: 300_000_000)
            return Engine()
        }) { heard.add($0) }
        recognizer.start()
        for _ in 0..<70 { recognizer.push(quiet(1)) }
        _ = await recognizer.finish()
        XCTAssertTrue(heard.notes.contains { $0.contains("dropped the oldest 10.0 s") }, "\(heard.notes)")
    }

    /// Astra 7: a capture's end waits for its last words, but not for ever.
    func testAFinishWithinATimeAnswersTheWordsOrNilWhenTheModelIsLate() async {
        let quick = SpeechRecognizer(model: .default, words: .empty, engine: { Engine() }) { _ in }
        quick.start()
        quick.push(loud(1))
        let words = await quick.finish(within: 10)
        XCTAssertEqual(words?.map(\.text), ["hello there"])

        let heard = Heard()
        let late = SpeechRecognizer(model: .default, words: .empty, engine: {
            try await Task.sleep(nanoseconds: 3_000_000_000)
            return Engine()
        }) { heard.add($0) }
        late.start()
        late.push(loud(1))
        let started = Date()
        let none = await late.finish(within: 0.3)
        XCTAssertNil(none)
        XCTAssertLessThan(Date().timeIntervalSince(started), 2)
        // the model comes later: the cancelled recognizer writes nothing
        try? await Task.sleep(nanoseconds: 3_200_000_000)
        XCTAssertFalse(heard.lock.withLock { heard.events.contains { if case .segment = $0 { return true } else { return false } } })
    }

    func testAModelThatDoesNotLoadFails() async {
        let heard = Heard()
        struct Broken: Error {}
        let recognizer = SpeechRecognizer(model: .default, words: .empty, engine: { throw Broken() }) { heard.add($0) }
        recognizer.start()
        let segments = await recognizer.finish()
        XCTAssertEqual(segments, [])
        XCTAssertTrue(heard.lock.withLock { heard.events.contains { if case .failed = $0 { return true } else { return false } } })
    }
}

/// A source that gives one second of speech at its start, then nothing.
private final class Speech: SpeechSource {
    var stopped = false
    var failed: (@Sendable (String) -> Void)?
    func start(_ take: @escaping @Sendable (AVAudioPCMBuffer) -> Void, failed: @escaping @Sendable (String) -> Void) throws {
        self.failed = failed
        let format = AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1)!
        let samples = loud(1)
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count))!
        buffer.frameLength = buffer.frameCapacity
        for (index, sample) in samples.enumerated() { buffer.floatChannelData![0][index] = sample }
        take(buffer)
    }

    func stop() { stopped = true }
}

/// A source that does not start.
private final class Broken: SpeechSource {
    struct Refused: LocalizedError { var errorDescription: String? { "no microphone" } }
    func start(_ take: @escaping @Sendable (AVAudioPCMBuffer) -> Void, failed: @escaping @Sendable (String) -> Void) throws { throw Refused() }
    func stop() {}
}

@MainActor
private final class Client: SpeechClient {
    var events: [SpeechSession.Event] = []
    var ended: XCTestExpectation?

    func speech(_ event: SpeechSession.Event) {
        events.append(event)
        if case .ended = event { ended?.fulfill() }
    }

    var endedText: String? {
        events.lazy.compactMap { if case .ended(let text) = $0 { return text } else { return nil } }.first
    }
}

@MainActor
final class SpeechSessionTests: XCTestCase {
    func testASecondStartEndsTheFirstAndItsWordsGoWhereTheyBelonged() async {
        var sources: [Speech] = []
        let session = SpeechSession(source: {
            let source = Speech()
            sources.append(source)
            return source
        }, engine: { _, _ in Engine(text: "for the first") })
        session.authorization = { .authorized }
        let dictation = Client()
        let input = Client()
        dictation.ended = expectation(description: "the first listening's words")
        XCTAssertNil(session.start(dictation, words: .empty))
        XCTAssertTrue(session.isListening(for: dictation))
        XCTAssertNil(session.start(input, words: .empty))
        XCTAssertTrue(session.isListening(for: input))
        XCTAssertFalse(session.isListening(for: dictation))
        XCTAssertTrue(sources[0].stopped, "one microphone at a time")
        XCTAssertFalse(sources[1].stopped)
        await fulfillment(of: [dictation.ended!], timeout: 5)
        XCTAssertEqual(dictation.endedText, "for the first")
        XCTAssertNil(input.endedText, "the second listening goes on")

        input.ended = expectation(description: "the second listening's words")
        session.finish(input)
        await fulfillment(of: [input.ended!], timeout: 5)
        XCTAssertEqual(input.endedText, "for the first")
        XCTAssertFalse(session.isListening)
    }

    func testACancelledListeningEndsWithNoWords() async throws {
        let session = SpeechSession(source: { Speech() }, engine: { _, _ in Engine() })
        session.authorization = { .authorized }
        let client = Client()
        XCTAssertNil(session.start(client, words: .empty))
        session.cancel(client)
        XCTAssertFalse(session.isListening)
        try await Task.sleep(nanoseconds: 600_000_000)
        XCTAssertNil(client.endedText)
    }

    func testAHomeOfItsOwnOpensNoMicrophone() {
        let session = SpeechSession(source: { Speech() }, engine: { _, _ in Engine() })
        session.mayOpenMicrophone = false
        XCTAssertEqual(session.start(Client(), words: .empty), .ownHome)
        XCTAssertFalse(session.isListening)
    }

    /// Fable 11: a source that does not start is a refusal, with no event: the pill is not shown.
    func testASourceThatDoesNotStartIsARefusalWithNoEvent() {
        let session = SpeechSession(source: { Broken() }, engine: { _, _ in Engine() })
        session.authorization = { .authorized }
        let client = Client()
        XCTAssertEqual(session.start(client, words: .empty), .failed("no microphone"))
        XCTAssertFalse(session.isListening)
        XCTAssertTrue(client.events.isEmpty)
    }

    /// Fable 11, Carbon 12b: a source that stops by itself (the input went away) ends the listening as a failure.
    func testASourceThatStopsByItselfFails() async {
        var source: Speech?
        let session = SpeechSession(source: {
            let made = Speech()
            source = made
            return made
        }, engine: { _, _ in Engine() })
        session.authorization = { .authorized }
        let client = Client()
        XCTAssertNil(session.start(client, words: .empty))
        source?.failed?("The microphone did not start")
        for _ in 0..<50 where session.isListening { try? await Task.sleep(nanoseconds: 20_000_000) }
        XCTAssertFalse(session.isListening)
        XCTAssertTrue(source?.stopped == true)
        XCTAssertTrue(client.events.contains { if case .failed("The microphone did not start") = $0 { return true } else { return false } })
    }

    /// Astra 16: the client starts again before the last words of its first listening came. They
    /// come once, and while the second listening runs: the client must not take them as the end of that one.
    func testAStartBeforeTheLastWordsCameKeepsTheNewListening() async {
        let session = SpeechSession(source: { Speech() }, engine: { _, _ in Engine(text: "first") })
        session.authorization = { .authorized }
        @MainActor final class Again: SpeechClient {
            weak var session: SpeechSession?
            var endings: [(text: String, listening: Bool)] = []
            var ended: XCTestExpectation?
            func speech(_ event: SpeechSession.Event) {
                guard case .ended(let text) = event else { return }
                endings.append((text, session?.isListening(for: self) ?? false))
                ended?.fulfill()
            }
        }
        let client = Again()
        client.session = session
        client.ended = expectation(description: "the first listening's words")
        XCTAssertNil(session.start(client, words: .empty))
        session.finish(client)
        XCTAssertNil(session.start(client, words: .empty))
        await fulfillment(of: [client.ended!], timeout: 5)
        XCTAssertEqual(client.endings.count, 1)
        XCTAssertEqual(client.endings.first?.text, "first")
        XCTAssertEqual(client.endings.first?.listening, true, "the second listening runs: Dictation keeps its key")
        XCTAssertTrue(session.isListening(for: client))
        client.ended = expectation(description: "the second listening's words")
        session.finish(client)
        await fulfillment(of: [client.ended!], timeout: 5)
        XCTAssertEqual(client.endings.count, 2)
        XCTAssertEqual(client.endings.last?.listening, false)
    }
}
