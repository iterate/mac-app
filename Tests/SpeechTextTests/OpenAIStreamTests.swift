import Foundation
import Network
@testable import SpeechText
import VoiceMeetCore
import XCTest

/// A fake of OpenAI's realtime transcription on 127.0.0.1: a WebSocket server whose answer to each
/// message the test writes (`answer`). It records every message it got, and the Authorization
/// header of each socket.
final class FakeOpenAI: @unchecked Sendable {
    private let listener: NWListener
    private let queue = DispatchQueue(label: "fake-openai")
    private let lock = NSLock()
    private var got: [[String: Any]] = []
    private var connections: [NWConnection] = []
    /// The answer to one message: the events to send back.
    let answer: @Sendable ([String: Any]) -> [[String: Any]]
    var url: URL { URL(string: "ws://127.0.0.1:\(listener.port!.rawValue)/v1/realtime?intent=transcription")! }

    init(answer: @escaping @Sendable ([String: Any]) -> [[String: Any]]) throws {
        self.answer = answer
        let parameters = NWParameters.tcp
        let options = NWProtocolWebSocket.Options()
        options.autoReplyPing = true
        let headers = Lines()
        options.setClientRequestHandler(queue) { _, additional in
            headers.add(additional.first { $0.name.lowercased() == "authorization" }?.value ?? "none")
            return NWProtocolWebSocket.Response(status: .accept, subprotocol: nil)
        }
        self.headers = headers
        parameters.defaultProtocolStack.applicationProtocols.insert(options, at: 0)
        listener = try NWListener(using: parameters, on: .any)
        let ready = DispatchSemaphore(value: 0)
        listener.stateUpdateHandler = { state in if case .ready = state { ready.signal() } }
        listener.newConnectionHandler = { [weak self] connection in self?.serve(connection) }
        listener.start(queue: queue)
        _ = ready.wait(timeout: .now() + 5)
    }

    deinit { listener.cancel() }

    private let headers: Lines
    /// The Authorization header of each socket, in the order they opened.
    var authorizations: [String] { headers.all }
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
func openAI(deltas: [String], final: String, answersCommit: Bool = true, error: String? = nil) -> @Sendable ([String: Any]) -> [[String: Any]] {
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

final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0
    func next() -> Int { lock.withLock { defer { value += 1 }; return value } }
    var peek: Int { lock.withLock { value } }
}

private final class Events: @unchecked Sendable {
    private let lock = NSLock()
    private var events: [SpeechRecognizer.Event] = []
    func add(_ event: SpeechRecognizer.Event) { lock.withLock { events.append(event) } }
    var partials: [String] { lock.withLock { events.compactMap { if case .partial(let said) = $0 { return said.text } else { return nil } } } }
    var notes: [String] { lock.withLock { events.compactMap { if case .note(let note) = $0 { return note } else { return nil } } } }
}

/// The local model behind OpenAI: it always "hears" `text`.
struct LocalEngine: SpeechEngine {
    var text = "heard on this Mac"
    func hear(_ samples: [Float], final: Bool) async throws -> Heard {
        samples.contains { abs($0) > 0.05 } ? Heard(text: text) : Heard(text: "")
    }
}

private func loud(_ seconds: Double) -> [Float] { (0..<Int(seconds * 16_000)).map { 0.3 * sin(Float($0) * 0.2) } }

private let words = WordList(markdown: "- Beelink: bee link\n- iterate\n")

/// The app's one transcriber against the fake, with the rule's answer `route` and a fake local
/// model behind it: with this Mac's `key`, or with `access` (a mind's sockets).
func transcriber(
    _ server: FakeOpenAI, key: String? = "sk-test", access: OpenAIAccess? = nil, connect: Double = 2, final: Double = 2,
    standby: OpenAIStandby? = nil, route: SpeechRoute = SpeechRoute(.openAI, .reachable),
    local: @escaping @Sendable (SpeechModel, WordList) async throws -> SpeechEngine = { _, _ in LocalEngine() }
) -> Transcriber {
    let made = Transcriber(access: access ?? .ownKey({ key }), standby: standby, setup: setup(server, connect: connect, final: final), engines: .fixed(local))
    made.set(route, local: .default)
    return made
}

/// A key's listening of the transcriber (dictation, the input bar), or another use.
private func recognizer(
    _ server: FakeOpenAI, heard: Events, key: String? = "sk-test", access: OpenAIAccess? = nil, connect: Double = 2, final: Double = 2,
    standby: OpenAIStandby? = nil, use: Transcriber.Use = .live
) -> SpeechListening {
    transcriber(server, key: key, access: access, connect: connect, final: final, standby: standby)
        .listening(use, words: words) { heard.add($0) }.listening
}

/// The setup of `recognizer`, with the word list's keywords as the transcriber sets them.
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

final class Lines: @unchecked Sendable {
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

    func testTheRulesProviderHearsAndTheLocalModelWhenItPicksIt() async throws {
        let server = try FakeOpenAI(answer: openAI(deltas: [], final: "from OpenAI"))
        let online = transcriber(server)
        XCTAssertTrue(online.listening(.live, words: words) { _ in }.listening is StreamRecognizer)
        XCTAssertEqual(online.listening(.capture, words: words) { _ in }.model, .gptLiveTranscribe)
        let offline = transcriber(server, route: SpeechRoute(.local, .offline))
        let (listening, model) = offline.listening(.live, words: words) { _ in }
        XCTAssertTrue(listening is SpeechRecognizer)
        XCTAssertEqual(model, .default)
        listening.start()
        await talk(listening, seconds: 1)
        let segments = await listening.finish()
        XCTAssertEqual(segments.map(\.text), ["heard on this Mac"])
        XCTAssertEqual(segments.map(\.model), ["oruk-fourier-2b"])
        XCTAssertTrue(server.messages.isEmpty, "offline, no socket opens")
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
        XCTAssertTrue(first.notes.contains { $0.contains("ready") && $0.contains("ms after the start (new, own key)") }, "\(first.notes)")
        // the end of the first opened the standby, configured with the same session
        try await until("the standby") { standby.isHeld }
        XCTAssertEqual(server.connectionCount, 2)
        XCTAssertEqual(server.types().filter { $0 == "session.update" }.count, 2)
        XCTAssertTrue(lines.all.contains { $0.hasPrefix("a standby socket is ready after") && $0.hasSuffix("with 2 keywords (own key)") }, "\(lines.all)")

        let second = await dictate(server, standby)
        XCTAssertTrue(second.notes.contains { $0.contains("ms after the start (standby, own key)") }, "\(second.notes)")
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
        XCTAssertTrue(dictation.notes.contains { $0.contains("(new, own key)") }, "\(dictation.notes)")
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
        XCTAssertTrue(dictation.notes.contains { $0.contains("(standby, own key)") }, "\(dictation.notes)")
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
        XCTAssertTrue(dictation.notes.contains { $0.contains("(new, own key)") }, "\(dictation.notes)")
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

/// The mind's bridge as `RelaySocket` sees it (`bridge/openai.mjs`): it opens each socket "through
/// the mind" and answers its frames as OpenAI would (`answer`), on a queue of its own. It records
/// every line it got. `refuses` is the mind's no (no /secrets/openai); `drop()` is a drop of its
/// link: every socket fails.
private final class FakeBridge: @unchecked Sendable {
    private let queue = DispatchQueue(label: "fake-bridge")
    private let lock = NSLock()
    private var sockets: [String: RelaySocket] = [:]
    private var open: Set<String> = []
    private var got: [[String: Any]] = []
    private var next = 0
    let answer: @Sendable ([String: Any]) -> [[String: Any]]
    var refuses = false
    var answersPings = true

    init(answer: @escaping @Sendable ([String: Any]) -> [[String: Any]]) {
        self.answer = answer
    }

    /// A socket of the mind, as `MindSockets.socket()` makes one.
    func socket() -> RelaySocket {
        let id: String = lock.withLock { next += 1; return "\(next)" }
        let socket = RelaySocket(id: id) { [weak self] line in self?.queue.async { self?.take(line) } }
        lock.withLock { sockets[id] = socket }
        return socket
    }

    var lines: [[String: Any]] { lock.withLock { got } }
    /// The frames sent to OpenAI, as their types.
    var types: [String] {
        lines.compactMap { ($0["frame"] as? String).flatMap { try? JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any] }?["type"] as? String }
    }
    var opens: Int { lines.filter { $0["open"] as? Bool == true }.count }
    var closes: [Int] { lines.compactMap { $0["close"] as? Bool == true ? $0["code"] as? Int : nil } }
    var openCount: Int { lock.withLock { open.count } }

    func drop() {
        queue.async { [self] in
            let all: [RelaySocket] = lock.withLock {
                defer { open = [] }
                return open.compactMap { sockets[$0] }
            }
            for socket in all { socket.take(["socket": socket.id, "failed": "the connection to the mind ended"]) }
        }
    }

    private func take(_ line: [String: Any]) {
        lock.withLock { got.append(line) }
        guard let id = line["socket"] as? String, let socket = lock.withLock({ sockets[id] }) else { return }
        if line["open"] as? Bool == true {
            if refuses { socket.take(["socket": id, "failed": "itx.fetch: no stored mind secret for getSecret(\"/secrets/openai\")", "refused": true]); return }
            lock.withLock { _ = open.insert(id) }
            socket.take(["socket": id, "opened": true])
            socket.take(["socket": id, "frame": #"{"type":"session.created"}"#])
        } else if let frame = line["frame"] as? String {
            guard lock.withLock({ open.contains(id) }), let message = (try? JSONSerialization.jsonObject(with: Data(frame.utf8))) as? [String: Any] else { return }
            for event in answer(message) {
                let text = String(decoding: try! JSONSerialization.data(withJSONObject: event), as: UTF8.self)
                socket.take(["socket": id, "frame": text])
            }
        } else if let ping = line["ping"] as? Int {
            if answersPings, lock.withLock({ open.contains(id) }) { socket.take(["socket": id, "pong": ping]) }
        } else if line["close"] as? Bool == true {
            lock.withLock { _ = open.remove(id) }
        }
    }
}

/// A socket of the mind (`OpenAIAccess.mindFirst`, `RelaySocket`, `bridge/openai.mjs`): the same
/// stream, standby and fallbacks on the bridge's relay as on the direct socket, and this Mac's key
/// behind the mind.
final class OpenAIAccessTests: XCTestCase {
    private final class Mind: @unchecked Sendable {
        let name: String
        let state: MindOpenAI
        init(_ name: String = "example.com", state: MindOpenAI = .unknown) {
            self.name = name
            self.state = state
        }
    }

    private func access(_ mind: Mind?, bridge: FakeBridge, key: String? = nil, log: Lines = Lines()) -> OpenAIAccess {
        .mindFirst(mind: { mind.map { ($0.name, $0.state) } }, socket: { bridge.socket() }, key: { key }, log: { log.add($0) })
    }

    private func dictate(
        _ server: FakeOpenAI, _ access: OpenAIAccess, standby: OpenAIStandby? = nil, seconds: Double = 0.5, during: () -> Void = {}
    ) async -> (notes: [String], text: [String]) {
        let heard = Events()
        let listening = recognizer(server, heard: heard, access: access, standby: standby)
        listening.start()
        await talk(listening, seconds: seconds / 2)
        during()
        await talk(listening, seconds: seconds / 2)
        let segments = await listening.finish()
        return (heard.notes, segments.map(\.text))
    }

    func testTheOrderIsTheLentMindUnlessItSaidNoThenTheOwnKey() {
        XCTAssertEqual(OpenAIAccess.order(mind: "a.com", state: .unknown, hasKey: true), .mind("a.com"))
        XCTAssertEqual(OpenAIAccess.order(mind: "a.com", state: .yes, hasKey: false), .mind("a.com"))
        XCTAssertEqual(OpenAIAccess.order(mind: "a.com", state: .no, hasKey: true), .ownKey)
        XCTAssertEqual(OpenAIAccess.order(mind: "a.com", state: .no, hasKey: false), nil)
        XCTAssertEqual(OpenAIAccess.order(mind: nil, state: .unknown, hasKey: true), .ownKey)
        XCTAssertEqual(OpenAIAccess.order(mind: nil, state: .unknown, hasKey: false), nil)
        XCTAssertEqual(OpenAISource.mind("a.com").words, "mind")
        XCTAssertEqual(OpenAISource.ownKey.words, "own key")
    }

    func testADictationThroughTheMindRelaysEveryFrameAndOpensNoDirectSocket() async throws {
        let server = try FakeOpenAI(answer: openAI(deltas: [], final: "never"))
        let bridge = FakeBridge(answer: openAI(deltas: ["the bee"], final: "the bee link is up"))
        let dictation = await dictate(server, access(Mind(), bridge: bridge, key: "sk-own"))
        XCTAssertEqual(dictation.text, ["the Beelink is up"])
        XCTAssertEqual(server.connectionCount, 0, "no direct socket: the mind's key")
        XCTAssertEqual(bridge.opens, 1)
        XCTAssertEqual(bridge.types.first, "session.update")
        XCTAssertEqual(bridge.types.last, "input_audio_buffer.commit")
        let bytes = bridge.lines.compactMap { ($0["frame"] as? String).flatMap { try? JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any] } }
            .filter { $0["type"] as? String == "input_audio_buffer.append" }
            .compactMap { ($0["audio"] as? String).flatMap { Data(base64Encoded: $0) }?.count }.reduce(0, +)
        XCTAssertEqual(Double(bytes) / 2, 12_000, accuracy: 3, "every sample went, at 24 kHz")
        // the stream closed it at its end: the bridge closes the upstream with 1000
        try await until("the close") { bridge.closes == [1000] }
        XCTAssertTrue(dictation.notes.contains { $0.contains("ms after the start (new, mind)") && $0.contains("session.created") }, "\(dictation.notes)")
        XCTAssertTrue(dictation.notes.contains { $0.contains("OpenAI billed 4 s") }, "the billed log on the relay too: \(dictation.notes)")
        XCTAssertFalse(bridge.lines.contains { "\($0)".contains("sk-") }, "no key goes to the bridge")
    }

    func testTheStandbyOpensThroughTheMindAndAnswersItsPingThere() async throws {
        let server = try FakeOpenAI(answer: openAI(deltas: [], final: "never"))
        let bridge = FakeBridge(answer: openAI(deltas: [], final: "on the standby"))
        let lines = Lines()
        let standby = OpenAIStandby(log: { lines.add($0) })
        let access = access(Mind(state: .yes), bridge: bridge)
        _ = await dictate(server, access, standby: standby)
        try await until("the standby") { standby.isHeld }
        XCTAssertTrue(lines.all.contains { $0.contains("with 2 keywords (mind); session.created ") }, "\(lines.all)")
        let second = await dictate(server, access, standby: standby)
        XCTAssertTrue(second.notes.contains { $0.contains("(standby, mind)") }, "\(second.notes)")
        XCTAssertEqual(second.text, ["on the standby"])
        XCTAssertTrue(bridge.lines.contains { $0["ping"] != nil }, "the ping goes to the bridge")
        try await until("the next standby") { standby.isHeld }
        XCTAssertEqual(bridge.opens, 3)
        XCTAssertEqual(bridge.types.filter { $0 == "session.update" }.count, 3, "each socket is configured once, with the keywords")
    }

    func testAStandbyWhoseBridgeDoesNotAnswerThePingIsClosedAndANewSocketOpens() async throws {
        let server = try FakeOpenAI(answer: openAI(deltas: [], final: "never"))
        let bridge = FakeBridge(answer: openAI(deltas: [], final: "new"))
        let lines = Lines()
        let standby = OpenAIStandby(log: { lines.add($0) })
        let access = access(Mind(), bridge: bridge)
        standby.prepare(setup(server), access: access)
        try await until("the standby") { standby.isHeld }
        bridge.answersPings = false
        let dictation = await dictate(server, access, standby: standby)
        XCTAssertTrue(dictation.notes.contains { $0.contains("(new, mind)") }, "\(dictation.notes)")
        XCTAssertTrue(lines.all.contains("the standby socket did not answer a ping: closed, and a new one"), "\(lines.all)")
        XCTAssertEqual(bridge.closes.first, 1001, "the bridge closes the standby's upstream")
    }

    func testAStandbyThroughAnotherMindIsClosedAndANewSocketOpens() async throws {
        let server = try FakeOpenAI(answer: openAI(deltas: [], final: "never"))
        let bridge = FakeBridge(answer: openAI(deltas: [], final: "new"))
        let lines = Lines()
        let standby = OpenAIStandby(log: { lines.add($0) })
        standby.prepare(setup(server), access: access(Mind("old.com"), bridge: bridge))
        try await until("the standby") { standby.isHeld }
        let dictation = await dictate(server, access(Mind("new.com"), bridge: bridge), standby: standby)
        XCTAssertTrue(dictation.notes.contains { $0.contains("(new, mind)") }, "\(dictation.notes)")
        XCTAssertTrue(lines.all.contains("the standby socket is of another source (mind): closed, and a new one"), "\(lines.all)")
    }

    func testAMindThatRefusesFallsBackToTheOwnKey() async throws {
        let server = try FakeOpenAI(answer: openAI(deltas: [], final: "with my key"))
        let bridge = FakeBridge(answer: openAI(deltas: [], final: "never"))
        bridge.refuses = true
        let log = Lines()
        let dictation = await dictate(server, access(Mind(), bridge: bridge, key: "sk-own", log: log))
        XCTAssertEqual(server.authorizations, ["Bearer sk-own"])
        XCTAssertEqual(dictation.text, ["with my key"])
        XCTAssertTrue(dictation.notes.contains { $0.contains("(new, own key)") }, "\(dictation.notes)")
        XCTAssertEqual(log.all, [#"no socket through example.com (itx.fetch: no stored mind secret for getSecret("/secrets/openai")): your own key"#])
    }

    func testADropOfTheBridgesLinkWhileTalkingFallsBackToTheLocalModel() async throws {
        let server = try FakeOpenAI(answer: openAI(deltas: [], final: "never"))
        let bridge = FakeBridge(answer: openAI(deltas: [], final: "never"))
        let dictation = await dictate(server, access(Mind(), bridge: bridge), seconds: 1) { bridge.drop() }
        XCTAssertEqual(dictation.text, ["heard on this Mac"])
        XCTAssertTrue(dictation.notes.contains { $0.contains("the connection to the mind ended") && $0.contains("the local model hears it") }, "\(dictation.notes)")
        XCTAssertFalse(bridge.types.contains("input_audio_buffer.commit"), "no commit after the failure")
    }

    func testAMindThatSaidNoIsNotAskedAndTheOwnKeyOpens() async throws {
        let server = try FakeOpenAI(answer: openAI(deltas: [], final: "with my key"))
        let bridge = FakeBridge(answer: openAI(deltas: [], final: "never"))
        _ = await dictate(server, access(Mind(state: .no), bridge: bridge, key: "sk-own"))
        XCTAssertEqual(bridge.opens, 0)
        XCTAssertEqual(server.authorizations, ["Bearer sk-own"])
    }

    func testNoSocketThroughTheMindAndNoKeyIsTheLocalModel() async throws {
        let server = try FakeOpenAI(answer: openAI(deltas: [], final: "never"))
        let bridge = FakeBridge(answer: openAI(deltas: [], final: "never"))
        bridge.refuses = true
        let refused = await dictate(server, access(Mind(), bridge: bridge))
        XCTAssertEqual(refused.text, ["heard on this Mac"])
        XCTAssertTrue(refused.notes.contains { $0.contains("no stored mind secret") && $0.contains("the local model hears it") }, "\(refused.notes)")
        let none = await dictate(server, access(nil, bridge: bridge))
        XCTAssertEqual(none.text, ["heard on this Mac"])
        XCTAssertTrue(none.notes.contains { $0.contains("no OpenAI key") }, "\(none.notes)")
        XCTAssertEqual(server.connectionCount, 0)
    }
}

/// The relay socket alone, against lines the test writes as the bridge.
final class RelaySocketTests: XCTestCase {
    func testItsLinesAndItsEnd() async throws {
        let sent = Lines()
        let socket = RelaySocket(id: "9") { line in
            sent.add(String(decoding: try! JSONSerialization.data(withJSONObject: line, options: .sortedKeys), as: UTF8.self))
        }
        let heard = Lines()
        let ended = Lines()
        socket.start(heard: { heard.add($0) }, ended: { ended.add($0) })
        socket.send("a")
        XCTAssertFalse(socket.take(["socket": "9", "frame": "b"]))
        XCTAssertEqual(sent.all, [#"{"open":true,"socket":"9"}"#, #"{"frame":"a","socket":"9"}"#])
        XCTAssertEqual(heard.all, ["b"])
        // a ping with no pong is no, within its bound
        let started = Date()
        let answered = await socket.ping(within: 0.1)
        XCTAssertFalse(answered)
        XCTAssertLessThan(Date().timeIntervalSince(started), 1)
        // OpenAI's close ends it once: nothing is heard or sent after it
        XCTAssertTrue(socket.take(["socket": "9", "closed": true, "code": 1011, "reason": "server error"]))
        XCTAssertEqual(ended.all, ["the socket closed (1011: server error)"])
        socket.take(["socket": "9", "frame": "late"])
        socket.send("late")
        socket.close(normal: true)
        socket.fail("again")
        XCTAssertEqual(heard.all, ["b"])
        XCTAssertEqual(ended.all.count, 1)
        XCTAssertEqual(sent.all.count, 3, "\(sent.all)")
        let pinged = await socket.ping(within: 1)
        XCTAssertFalse(pinged)
    }

    func testTheAppsCloseTellsTheBridgeAndHearsNothing() {
        let sent = Lines()
        let socket = RelaySocket(id: "1") { line in sent.add("\(line["close"] != nil ? "close \(line["code"]!)" : "other")") }
        let ended = Lines()
        socket.start(heard: { _ in }, ended: { ended.add($0) })
        socket.close(normal: false)
        socket.take(["socket": "1", "failed": "the connection to the mind ended"])
        XCTAssertEqual(sent.all, ["other", "close 1001"])
        XCTAssertEqual(ended.all, [])
    }

    func testAFailureThatClosesTellsTheBridgeAndTheStream() {
        let sent = Lines()
        let socket = RelaySocket(id: "1") { line in sent.add("\(line["close"] != nil ? "close \(line["code"]!)" : "other")") }
        let ended = Lines()
        socket.start(heard: { _ in }, ended: { ended.add($0) })
        socket.fail("the lent mind changed", closing: true)
        XCTAssertEqual(sent.all, ["other", "close 1001"])
        XCTAssertEqual(ended.all, ["the lent mind changed"])
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
        // what is on this Mac decides the local default (`FourierChoiceTests`): here, nothing
        let none: (SpeechModel) -> Bool = { _ in false }
        XCTAssertEqual(SpeechModel.chosen(nil, isOnline: false, isOnDisk: none), .fourier2b)
        XCTAssertEqual(SpeechModel.chosen(nil, isOnline: true, isOnDisk: none), .gptLiveTranscribe)
        // a stored choice wins; an online one with no key is the local default
        XCTAssertEqual(SpeechModel.chosen("parakeet-ultra", isOnline: true, isOnDisk: none), .parakeetUltra)
        XCTAssertEqual(SpeechModel.chosen("gpt-live-transcribe", isOnline: false, isOnDisk: none), .fourier2b)
        XCTAssertEqual(SpeechModel.chosen("gone", isOnline: true, isOnDisk: none), .gptLiveTranscribe)
        XCTAssertEqual(SpeechModel.local.map(\.id), ["oruk-fourier-2b", "parakeet-v3", "parakeet-ultra"], "the bench and captures run only local models")
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
