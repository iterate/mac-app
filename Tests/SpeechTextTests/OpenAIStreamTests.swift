import Foundation
import Network
@testable import SpeechText
import VoiceMeetCore
import XCTest

/// A fake of OpenAI's realtime transcription on 127.0.0.1: a WebSocket server whose answer to each
/// message the test writes (`answer`). It records every message it got.
private final class FakeOpenAI: @unchecked Sendable {
    private let listener: NWListener
    private let queue = DispatchQueue(label: "fake-openai")
    private let lock = NSLock()
    private var got: [[String: Any]] = []
    private var authorization: String?
    private var connections: [NWConnection] = []
    /// The answer to one message: the events to send back.
    let answer: @Sendable ([String: Any]) -> [[String: Any]]
    var url: URL { URL(string: "ws://127.0.0.1:\(listener.port!.rawValue)/v1/realtime?intent=transcription")! }

    init(answer: @escaping @Sendable ([String: Any]) -> [[String: Any]]) throws {
        self.answer = answer
        let parameters = NWParameters.tcp
        let options = NWProtocolWebSocket.Options()
        options.autoReplyPing = true
        parameters.defaultProtocolStack.applicationProtocols.insert(options, at: 0)
        listener = try NWListener(using: parameters, on: .any)
        let ready = DispatchSemaphore(value: 0)
        listener.stateUpdateHandler = { state in if case .ready = state { ready.signal() } }
        listener.newConnectionHandler = { [weak self] connection in self?.serve(connection) }
        listener.start(queue: queue)
        _ = ready.wait(timeout: .now() + 5)
    }

    deinit { listener.cancel() }

    var messages: [[String: Any]] { lock.withLock { got } }
    /// The sockets opened so far.
    var connectionCount: Int { lock.withLock { connections.count } }
    /// The server closes every socket, as OpenAI or the network may.
    func closeAll() { lock.withLock { connections }.forEach { $0.cancel() } }
    func types() -> [String] { messages.compactMap { $0["type"] as? String } }

    private func serve(_ connection: NWConnection) {
        lock.withLock { connections.append(connection) }
        connection.start(queue: queue)
        receive(connection)
    }

    private func receive(_ connection: NWConnection) {
        connection.receiveMessage { [weak self] data, _, _, error in
            guard let self, error == nil else { return }
            if let data, let message = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] {
                lock.withLock { self.got.append(message) }
                for event in answer(message) { send(event, on: connection) }
            }
            receive(connection)
        }
    }

    private func send(_ event: [String: Any], on connection: NWConnection) {
        let data = try! JSONSerialization.data(withJSONObject: event)
        let metadata = NWProtocolWebSocket.Metadata(opcode: .text)
        let context = NWConnection.ContentContext(identifier: "event", metadata: [metadata])
        connection.send(content: data, contentContext: context, isComplete: true, completion: .idempotent)
    }
}

/// OpenAI as the bench saw it: the session is updated, a delta comes at each append, and the
/// commit gets its item's final.
private func openAI(deltas: [String], final: String, answersCommit: Bool = true, error: String? = nil) -> @Sendable ([String: Any]) -> [[String: Any]] {
    let count = Counter()
    return { message in
        switch message["type"] as? String {
        case "session.update": return [["type": "session.updated"]]
        case "input_audio_buffer.append":
            if let error { return [["type": "error", "error": ["message": error]]] }
            let index = count.next()
            return index < deltas.count ? [["type": "conversation.item.input_audio_transcription.delta", "item_id": "item_1", "delta": deltas[index]]] : []
        case "input_audio_buffer.commit":
            guard answersCommit else { return [] }
            return [
                ["type": "input_audio_buffer.committed", "item_id": "item_1"],
                ["type": "conversation.item.input_audio_transcription.completed", "item_id": "item_1", "transcript": final, "usage": ["type": "duration", "seconds": 4]],
            ]
        default: return []
        }
    }
}

private final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0
    func next() -> Int { lock.withLock { defer { value += 1 }; return value } }
}

private final class Events: @unchecked Sendable {
    private let lock = NSLock()
    private var events: [SpeechRecognizer.Event] = []
    func add(_ event: SpeechRecognizer.Event) { lock.withLock { events.append(event) } }
    var partials: [String] { lock.withLock { events.compactMap { if case .partial(let said) = $0 { return said.text } else { return nil } } } }
    var notes: [String] { lock.withLock { events.compactMap { if case .note(let note) = $0 { return note } else { return nil } } } }
}

/// The local model behind OpenAI: it always "hears" `text`.
private struct LocalEngine: SpeechEngine {
    var text = "heard on this Mac"
    func hear(_ samples: [Float], final: Bool) async throws -> Heard {
        samples.contains { abs($0) > 0.05 } ? Heard(text: text) : Heard(text: "")
    }
}

private func loud(_ seconds: Double) -> [Float] { (0..<Int(seconds * 16_000)).map { 0.3 * sin(Float($0) * 0.2) } }

private let words = WordList(markdown: "- Beelink: bee link\n- iterate\n")

/// The recognizer of the app, against the fake, with a fake local model behind it.
private func recognizer(
    _ server: FakeOpenAI, heard: Events, key: String? = "sk-test", connect: Double = 2, final: Double = 2, standby: OpenAIStandby? = nil
) -> SpeechListening {
    OnlineSpeech.recognizer(
        .gptLiveTranscribe, words: words, key: { key }, setup: setup(server, connect: connect, final: final),
        fallback: { heard in SpeechRecognizer(model: .default, words: words, engine: { LocalEngine() }, heard: heard) }, standby: standby
    ) { heard.add($0) }!
}

/// The setup of `recognizer`, with the word list's keywords as `OnlineSpeech` sets them.
private func setup(_ server: FakeOpenAI, connect: Double = 2, final: Double = 2, keywords: [String] = words.entries.map(\.term)) -> OpenAIStream.Setup {
    var setup = OpenAIStream.Setup(keywords: keywords)
    setup.url = server.url
    setup.connectTimeout = connect
    setup.finalTimeout = final
    return setup
}

/// Waits for `condition`, at most 5 s.
private func until(_ what: String, _ condition: () -> Bool) async throws {
    let started = Date()
    while !condition() {
        if Date().timeIntervalSince(started) > 5 { throw NSError(domain: "until", code: 1, userInfo: [NSLocalizedDescriptionKey: "no \(what) in 5 s"]) }
        try await Task.sleep(nanoseconds: 10_000_000)
    }
}

/// The clock of a standby test: the time moves when the test says, and the timers run when it says.
private final class TestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var time = Date(timeIntervalSince1970: 1_800_000_000)
    private var timers: [(Double, @Sendable () -> Void)] = []
    var clock: OpenAIStandby.Clock {
        OpenAIStandby.Clock(now: { [self] in lock.withLock { time } }, after: { [self] seconds, run in lock.withLock { timers.append((seconds, run)) } })
    }
    var delays: [Double] { lock.withLock { timers.map(\.0) } }
    func advance(_ seconds: Double) { lock.withLock { time += seconds } }
    func fireTimers() { lock.withLock { defer { timers = [] }; return timers }.forEach { $0.1() } }
}

private final class Lines: @unchecked Sendable {
    private let lock = NSLock()
    private var lines: [String] = []
    func add(_ line: String) { lock.withLock { lines.append(line) } }
    var all: [String] { lock.withLock { lines } }
}

/// Pushes `seconds` of sound in 0.1 s pieces at the pace of the clock, as a microphone does.
private func talk(_ listening: SpeechListening, seconds: Double) async {
    let sound = loud(seconds)
    for start in stride(from: 0, to: sound.count, by: 1_600) {
        listening.push(Array(sound[start..<min(start + 1_600, sound.count)]))
        try? await Task.sleep(nanoseconds: 20_000_000)
    }
}

final class OpenAIStreamTests: XCTestCase {
    func testTheSessionIsTheBenchsAndTheSoundGoesAs24kHzPcm16() async throws {
        let server = try FakeOpenAI(answer: openAI(deltas: ["the bee", " link is"], final: "the bee link is up"))
        let heard = Events()
        let listening = recognizer(server, heard: heard)
        listening.start()
        await talk(listening, seconds: 1)
        let segments = await listening.finish()

        let update = try XCTUnwrap(server.messages.first)
        XCTAssertEqual(update["type"] as? String, "session.update")
        let session = try XCTUnwrap(update["session"] as? [String: Any])
        XCTAssertEqual(session["type"] as? String, "transcription")
        let input = try XCTUnwrap((session["audio"] as? [String: Any])?["input"] as? [String: Any])
        XCTAssertEqual(input["format"] as? [String: AnyHashable], ["type": "audio/pcm", "rate": 24000])
        XCTAssertTrue(input["turn_detection"] is NSNull, "no turn detection")
        let transcription = try XCTUnwrap(input["transcription"] as? [String: Any])
        XCTAssertEqual(transcription["model"] as? String, "gpt-live-transcribe")
        XCTAssertEqual(transcription["delay"] as? String, "low")
        XCTAssertEqual(transcription["keywords"] as? [String], ["Beelink", "iterate"])
        XCTAssertEqual(transcription["languages"] as? [String], ["en"])
        XCTAssertEqual(transcription["prompt"] as? String, "A software engineer dictating to a coding agent about the iterate platform.")

        // every sample went, at 24 kHz, as 16-bit samples; then one commit
        let types = server.types()
        XCTAssertEqual(types.last, "input_audio_buffer.commit")
        XCTAssertEqual(types.filter { $0 == "input_audio_buffer.commit" }.count, 1)
        let bytes = server.messages.filter { $0["type"] as? String == "input_audio_buffer.append" }
            .compactMap { ($0["audio"] as? String).flatMap { Data(base64Encoded: $0) }?.count }.reduce(0, +)
        XCTAssertEqual(Double(bytes) / 2, 24_000, accuracy: 3)

        // the deltas are the words so far, and the final is the segment: both repaired by the list
        XCTAssertEqual(heard.partials, ["the bee", "the Beelink is"])
        XCTAssertEqual(segments.map(\.text), ["the Beelink is up"])
        XCTAssertEqual(segments.first?.end ?? 0, 1, accuracy: 0.01)
        XCTAssertFalse(heard.notes.contains { $0.contains("failed") }, "\(heard.notes)")
        // OpenAI's own count of the billed sound is in the log, with its price
        XCTAssertTrue(heard.notes.contains { $0.contains("OpenAI billed 4 s, $0.0011 for 1.0 s of sound") }, "\(heard.notes)")
    }

    func testTheSoundBeforeTheSessionOpensIsKeptAndSentFirst() async throws {
        let server = try FakeOpenAI(answer: openAI(deltas: [], final: "all of it"))
        let heard = Events()
        let listening = recognizer(server, heard: heard)
        // pushed before start: the socket is not there yet
        listening.push(loud(0.5))
        listening.start()
        await talk(listening, seconds: 0.5)
        let segments = await listening.finish()
        let bytes = server.messages.filter { $0["type"] as? String == "input_audio_buffer.append" }
            .compactMap { ($0["audio"] as? String).flatMap { Data(base64Encoded: $0) }?.count }.reduce(0, +)
        XCTAssertEqual(Double(bytes) / 2, 24_000, accuracy: 3)
        XCTAssertEqual(segments.map(\.text), ["all of it"])
    }

    func testAnErrorWhileTalkingFallsBackToTheLocalModel() async throws {
        let server = try FakeOpenAI(answer: openAI(deltas: [], final: "", error: "insufficient_quota"))
        let heard = Events()
        let listening = recognizer(server, heard: heard)
        listening.start()
        await talk(listening, seconds: 1)
        let segments = await listening.finish()
        XCTAssertEqual(segments.map(\.text), ["heard on this Mac"])
        XCTAssertTrue(heard.notes.contains { $0.contains("gpt-live-transcribe failed") && $0.contains("insufficient_quota") && $0.contains("the local model hears it") }, "\(heard.notes)")
        XCTAssertFalse(server.types().contains("input_audio_buffer.commit"), "no commit after the failure")
    }

    func testAFinalThatDoesNotComeInTimeFallsBack() async throws {
        let server = try FakeOpenAI(answer: openAI(deltas: ["almost"], final: "", answersCommit: false))
        let heard = Events()
        let listening = recognizer(server, heard: heard, final: 0.4)
        listening.start()
        await talk(listening, seconds: 1)
        let started = Date()
        let segments = await listening.finish()
        XCTAssertLessThan(Date().timeIntervalSince(started), 3)
        XCTAssertEqual(segments.map(\.text), ["heard on this Mac"])
        XCTAssertTrue(heard.notes.contains { $0.contains("no final") }, "\(heard.notes)")
    }

    func testASessionThatDoesNotOpenInTimeFallsBack() async throws {
        let server = try FakeOpenAI { _ in [] }
        let heard = Events()
        let listening = recognizer(server, heard: heard, connect: 0.3)
        listening.start()
        await talk(listening, seconds: 1)
        let segments = await listening.finish()
        XCTAssertEqual(segments.map(\.text), ["heard on this Mac"])
        XCTAssertTrue(heard.notes.contains { $0.contains("no session") }, "\(heard.notes)")
    }

    func testNoKeyFallsBackAtOnce() async throws {
        let server = try FakeOpenAI(answer: openAI(deltas: [], final: "never"))
        let heard = Events()
        let listening = recognizer(server, heard: heard, key: nil)
        listening.start()
        await talk(listening, seconds: 1)
        let segments = await listening.finish()
        XCTAssertEqual(segments.map(\.text), ["heard on this Mac"])
        XCTAssertTrue(server.messages.isEmpty)
        XCTAssertTrue(heard.notes.contains { $0.contains("no OpenAI key") }, "\(heard.notes)")
    }

    func testACancelSendsNoCommitAndWritesNothing() async throws {
        let server = try FakeOpenAI(answer: openAI(deltas: [], final: "never"))
        let heard = Events()
        let listening = recognizer(server, heard: heard)
        listening.start()
        await talk(listening, seconds: 0.5)
        listening.cancel()
        try? await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertFalse(server.types().contains("input_audio_buffer.commit"))
    }

    func testOnlyTheOnlineModelGetsAStreamRecognizer() {
        XCTAssertNil(OnlineSpeech.recognizer(.parakeetV3, words: .empty, key: { "sk" }) { _ in })
        XCTAssertNotNil(OnlineSpeech.recognizer(.gptLiveTranscribe, words: .empty, key: { "sk" }) { _ in })
    }
}

/// The standby socket (`OpenAIStandby`): ready before fn goes down.
final class OpenAIStandbyTests: XCTestCase {
    /// One dictation on `standby`, against `server`: its notes and its text.
    private func dictate(_ server: FakeOpenAI, _ standby: OpenAIStandby) async -> (notes: [String], text: [String]) {
        let heard = Events()
        let listening = recognizer(server, heard: heard, standby: standby)
        listening.start()
        await talk(listening, seconds: 0.5)
        let segments = await listening.finish()
        return (heard.notes, segments.map(\.text))
    }

    func testTheNextDictationTakesTheStandbyThatTheLastOneOpened() async throws {
        let server = try FakeOpenAI(answer: openAI(deltas: [], final: "on the standby"))
        let lines = Lines()
        let standby = OpenAIStandby(log: { lines.add($0) })
        let first = await dictate(server, standby)
        XCTAssertTrue(first.notes.contains { $0.contains("ready") && $0.contains("ms after the start (new)") }, "\(first.notes)")
        // the end of the first opened the standby, configured with the same session
        try await until("the standby") { standby.isHeld }
        XCTAssertEqual(server.connectionCount, 2)
        XCTAssertEqual(server.types().filter { $0 == "session.update" }.count, 2)
        XCTAssertTrue(lines.all.contains { $0.hasPrefix("a standby socket is ready after") && $0.hasSuffix("with 2 keywords") }, "\(lines.all)")

        let second = await dictate(server, standby)
        XCTAssertTrue(second.notes.contains { $0.contains("ms after the start (standby)") }, "\(second.notes)")
        XCTAssertEqual(second.text, ["on the standby"])
        XCTAssertFalse(second.notes.contains { $0.contains("failed") }, "\(second.notes)")
        // the second opened no socket: the one after it is the next standby, and the only one
        try await until("the next standby") { standby.isHeld }
        try await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertEqual(server.connectionCount, 3)
        XCTAssertEqual(server.types().filter { $0 == "session.update" }.count, 3, "each socket is configured once")
    }

    func testAStandbyOfOtherKeywordsIsClosedAndANewSocketOpens() async throws {
        let server = try FakeOpenAI(answer: openAI(deltas: [], final: "new"))
        let lines = Lines()
        let standby = OpenAIStandby(log: { lines.add($0) })
        standby.prepare(setup(server, keywords: ["Herdr"]), key: { "sk-test" })
        try await until("the standby") { standby.isHeld }

        let dictation = await dictate(server, standby)
        XCTAssertTrue(dictation.notes.contains { $0.contains("(new)") }, "\(dictation.notes)")
        XCTAssertEqual(dictation.text, ["new"])
        XCTAssertTrue(lines.all.contains("the standby socket has other keywords: closed, and a new one"), "\(lines.all)")
    }

    func testAStandbyThatTheServerClosedIsOpenedAgainWithinTenMinutesOfTheLastDictation() async throws {
        let server = try FakeOpenAI(answer: openAI(deltas: [], final: "again"))
        let lines = Lines()
        let time = TestClock()
        let standby = OpenAIStandby(clock: time.clock, log: { lines.add($0) })
        standby.prepare(setup(server), key: { "sk-test" })
        try await until("the standby") { standby.isHeld }

        // the server resets it (the owner's Mac: after 94 and 101 s): a new one is asked for at once
        time.advance(100)
        server.closeAll()
        try await until("the drop") { !standby.isHeld }
        XCTAssertTrue(lines.all.contains { $0.hasPrefix("the standby socket went") && $0.hasSuffix("a new one in 0 s") }, "\(lines.all)")
        time.fireTimers()
        try await until("the new standby") { standby.isHeld }

        let dictation = await dictate(server, standby)
        XCTAssertTrue(dictation.notes.contains { $0.contains("(standby)") }, "\(dictation.notes)")
        XCTAssertEqual(dictation.text, ["again"])

        // 10 minutes after the last dictation's ask, one that goes stays gone
        standby.prepare(setup(server), key: { "sk-test" })
        try await until("the third standby") { standby.isHeld }
        time.advance(600)
        server.closeAll()
        try await until("the last drop") { !standby.isHeld }
        XCTAssertTrue(lines.all.last?.hasSuffix(": dropped") == true, "\(lines.all)")
    }

    func testAStandbyIsClosedAfterTenMinutesUnusedAndTheNextOpensOnlyAfterTheNextDictation() async throws {
        let server = try FakeOpenAI(answer: openAI(deltas: [], final: "new"))
        let lines = Lines()
        let time = TestClock()
        let standby = OpenAIStandby(clock: time.clock, log: { lines.add($0) })

        // the timer closes it after 10 minutes, and nothing opens after it
        standby.prepare(setup(server), key: { "sk-test" })
        try await until("the standby") { standby.isHeld }
        XCTAssertEqual(time.delays, [600])
        time.advance(600)
        time.fireTimers()
        XCTAssertFalse(standby.isHeld)
        XCTAssertTrue(lines.all.contains { $0.hasPrefix("the standby socket waited 10 min unused: closed") }, "\(lines.all)")
        try await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertEqual(server.connectionCount, 1)

        // a timer that came late (a Mac asleep): fn down sees its age and opens a new one
        standby.prepare(setup(server), key: { "sk-test" })
        try await until("the standby") { standby.isHeld }
        time.advance(601)
        let dictation = await dictate(server, standby)
        XCTAssertTrue(dictation.notes.contains { $0.contains("(new)") }, "\(dictation.notes)")
        XCTAssertTrue(lines.all.contains("the standby socket waited 10 min unused: closed, and a new one"), "\(lines.all)")
        // then the end of that dictation opens the next
        try await until("the next standby") { standby.isHeld }
    }

    func testADropClosesTheStandbyAndKeepsNoneThatOpens() async throws {
        let server = try FakeOpenAI(answer: openAI(deltas: [], final: "new"))
        let standby = OpenAIStandby()
        standby.prepare(setup(server), key: { "sk-test" })
        standby.drop("the speech model is parakeet-v3")
        try await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertFalse(standby.isHeld)
        // no key: none opens
        standby.prepare(setup(server), key: { nil })
        try await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertFalse(standby.isHeld)
        XCTAssertEqual(server.connectionCount, 1)
    }
}

final class OpenAIKeyTests: XCTestCase {
    /// A copy with a home of its own never reads or writes the owner's item; cli.mjs's
    /// `openAIService` makes the same name (the hash below is Node's, from `node:crypto`).
    func testACopyWithAHomeOfItsOwnHasAKeychainServiceOfItsOwn() {
        XCTAssertEqual(OpenAIKey.service(home: nil), "com.iterate.mac-app.openai")
        XCTAssertEqual(OpenAIKey.service(home: "/tmp/iterate-test-home"), "com.iterate.mac-app.openai.10155ab7ed0c")
        XCTAssertNotEqual(OpenAIKey.service(home: "/tmp/a"), OpenAIKey.service(home: "/tmp/b"))
        XCTAssertEqual(OpenAIKey.account, "api-key")
    }
}

final class SpeechModelChoiceTests: XCTestCase {
    func testGPTLiveTranscribeIsTheDefaultOnlyWithAKey() {
        XCTAssertEqual(SpeechModel.chosen(nil, hasKey: false), .parakeetV3)
        XCTAssertEqual(SpeechModel.chosen(nil, hasKey: true), .gptLiveTranscribe)
        // a stored choice wins; an online one with no key is the local default
        XCTAssertEqual(SpeechModel.chosen("parakeet-ultra", hasKey: true), .parakeetUltra)
        XCTAssertEqual(SpeechModel.chosen("gpt-live-transcribe", hasKey: false), .parakeetV3)
        XCTAssertEqual(SpeechModel.chosen("gone", hasKey: true), .gptLiveTranscribe)
        XCTAssertEqual(SpeechModel.local.map(\.id), ["parakeet-v3", "parakeet-ultra"], "the bench and captures run only local models")
    }
}

final class UpsamplerTests: XCTestCase {
    func testSixteenKilohertzBecomesTwentyFourAcrossPushes() {
        var whole = Upsampler()
        var pieces = Upsampler()
        let ramp = (0..<1_600).map { Float($0) / 1_600 }
        let once = whole.next(ramp)
        let inPieces = stride(from: 0, to: ramp.count, by: 7).flatMap { pieces.next(Array(ramp[$0..<min($0 + 7, ramp.count)])) }
        XCTAssertEqual(once, inPieces, "the pieces' edges change nothing")
        XCTAssertEqual(Double(once.count), 2_400, accuracy: 2)
        // a ramp stays a ramp: each output sample is between its neighbours
        XCTAssertEqual(once[3], Int16(Float(2) / 1_600 * Float(Int16.max)))
        XCTAssertTrue(zip(once, once.dropFirst()).allSatisfy { $0 <= $1 })
    }
}
