import SpeechText
import VoiceMeetCore
import XCTest

/// A stand-in for Oruk Fourier: it hears the whole stretch at each pass, and says so. Each pass is
/// kept with its kind, its length and its time; a pass takes `takes` seconds.
private final class FakeFourier: SpeechEngine, @unchecked Sendable {
    struct Pass {
        let final: Bool
        let seconds: Double
        let at: Date
    }

    private let lock = NSLock()
    private var list: [Pass] = []
    let takes: Double
    var passes: [Pass] { lock.withLock { list } }

    init(takes: Double = 0) {
        self.takes = takes
    }

    func hear(_ samples: [Float], final: Bool) async throws -> Heard {
        lock.withLock { list.append(Pass(final: final, seconds: Double(samples.count) / Double(SpeechStretch.rate), at: Date())) }
        if takes > 0 { try await Task.sleep(nanoseconds: UInt64(takes * 1e9)) }
        return Heard(text: samples.contains { abs($0) > 0.05 } ? "heard \(samples.count / SpeechStretch.rate) s" : "")
    }
}

/// A clock that a test moves.
private final class Clock: @unchecked Sendable {
    private let lock = NSLock()
    private var seconds = 0.0
    var now: Double {
        get { lock.withLock { seconds } }
        set { lock.withLock { seconds = newValue } }
    }
}

private func loud(_ seconds: Double) -> [Float] { (0..<Int(seconds * 16_000)).map { 0.3 * sin(Float($0) * 0.2) } }

private final class Events: @unchecked Sendable {
    private let lock = NSLock()
    private var events: [SpeechRecognizer.Event] = []
    func add(_ event: SpeechRecognizer.Event) { lock.withLock { events.append(event) } }
    var partials: [String] { lock.withLock { events.compactMap { if case .partial(let said) = $0 { return said.text } else { return nil } } } }
    var notes: [String] { lock.withLock { events.compactMap { if case .note(let note) = $0 { return note } else { return nil } } } }
}

/// Talks for `seconds` in pieces of 0.1 s at the clock's pace, as a microphone does.
private func talk(_ listening: SpeechListening, seconds: Double) async {
    for _ in 0..<Int(seconds * 10) {
        listening.push(loud(0.1))
        try? await Task.sleep(nanoseconds: 100_000_000)
    }
}

final class PacedEngineTests: XCTestCase {
    func testAPartialPassRunsAtMostOnceASecondAndAFinalAtOnce() async throws {
        let clock = Clock()
        let model = FakeFourier()
        let paced = PacedEngine(model, now: { clock.now })
        let stretch = loud(3)

        var heard = try await paced.hear(Array(stretch.prefix(8_000)), final: false)
        XCTAssertEqual(heard.text, "heard 0 s")
        // 0.4 s later, the same stretch: the last pass's text, and no pass
        clock.now = 0.4
        heard = try await paced.hear(Array(stretch.prefix(14_400)), final: false)
        XCTAssertEqual(heard.text, "heard 0 s")
        XCTAssertEqual(model.passes.count, 1)
        // a second after the last one: a pass
        clock.now = 1.0
        heard = try await paced.hear(Array(stretch.prefix(24_000)), final: false)
        XCTAssertEqual(heard.text, "heard 1 s")
        // the stretch ends: the final runs at once, whatever the time
        clock.now = 1.2
        heard = try await paced.hear(stretch, final: true)
        XCTAssertEqual(heard.text, "heard 3 s")
        XCTAssertEqual(model.passes.map(\.final), [false, false, true])
        // the next stretch before its turn: nothing new, never the last stretch's text
        clock.now = 1.6
        heard = try await paced.hear(loud(0.5), final: false)
        XCTAssertEqual(heard.text, "")
        clock.now = 2.2
        heard = try await paced.hear(loud(0.6), final: false)
        XCTAssertEqual(heard.text, "heard 0 s")
        XCTAssertEqual(model.passes.count, 4)
        XCTAssertEqual(paced.ranPasses, 4)
    }

    func testASlowPassGetsTwiceItsTimeBeforeTheNext() async throws {
        let clock = Clock()
        /// A pass of 0.8 s on the test's clock.
        final class Slow: SpeechEngine, @unchecked Sendable {
            let clock: Clock
            init(_ clock: Clock) { self.clock = clock }
            func hear(_ samples: [Float], final: Bool) async throws -> Heard {
                clock.now += 0.8
                return Heard(text: "slow \(samples.count)")
            }
        }
        let paced = PacedEngine(Slow(clock), now: { clock.now })
        _ = try await paced.hear(loud(1), final: false)
        // it started at 0 and took 0.8 s: the next partial pass is at 1.6 s, not at 1 s
        clock.now = 1.2
        let early = try await paced.hear(loud(2), final: false)
        XCTAssertEqual(early.text, "slow 16000")
        clock.now = 1.6
        let next = try await paced.hear(loud(2), final: false)
        XCTAssertEqual(next.text, "slow 32000")
    }

    /// The recognizer asks each 0.4 s; with Fourier's pace the model hears the growing stretch at
    /// most once a second, then once at the end.
    func testTheRecognizerHearsTheGrowingStretchAtMostOnceASecondThenOnceAtTheEnd() async {
        let model = FakeFourier(takes: 0.05)
        let heard = Events()
        let recognizer = SpeechRecognizer(model: .fourier2b, words: .empty, engine: { PacedEngine(model) }) { heard.add($0) }
        recognizer.start()
        await talk(recognizer, seconds: 3.5)
        let segments = await recognizer.finish()
        XCTAssertEqual(segments.map(\.text), ["heard 3 s"])
        let partials = model.passes.filter { !$0.final }
        XCTAssertGreaterThanOrEqual(partials.count, 2, "the pill gets words while the speaker talks")
        XCTAssertLessThanOrEqual(partials.count, 4)
        for (before, after) in zip(partials, partials.dropFirst()) {
            XCTAssertGreaterThanOrEqual(after.at.timeIntervalSince(before.at), 0.95)
            XCTAssertGreaterThan(after.seconds, before.seconds, "each pass hears the stretch so far")
        }
        XCTAssertEqual(model.passes.last?.final, true)
        XCTAssertEqual(model.passes.filter(\.final).count, 1)
        XCTAssertTrue(heard.partials.contains { $0.hasPrefix("heard") })
    }
}

final class FourierChoiceTests: XCTestCase {
    func testFourierIsTheLocalDefaultAndParakeetStandsInUntilItIsOnThisMac() {
        XCTAssertEqual(SpeechModel.default, .fourier2b)
        XCTAssertEqual(SpeechModel.fourier2b.runs, .mlx)
        XCTAssertTrue(SpeechModel.fourier2b.isLocal)
        XCTAssertTrue(SpeechModel.fourier2b.license.contains("non-commercial"))
        let nothing: (SpeechModel) -> Bool = { _ in false }
        let parakeetOnly: (SpeechModel) -> Bool = { $0 == .parakeetV3 }
        let both: (SpeechModel) -> Bool = { $0 == .parakeetV3 || $0 == .fourier2b }
        // a new Mac downloads Fourier at its first use; a Mac that had Parakeet v3 keeps it until then
        XCTAssertEqual(SpeechModel.localDefault(isOnDisk: nothing), .fourier2b)
        XCTAssertEqual(SpeechModel.localDefault(isOnDisk: parakeetOnly), .parakeetV3)
        XCTAssertEqual(SpeechModel.localDefault(isOnDisk: both), .fourier2b)
        XCTAssertEqual(SpeechModel.chosen(nil, isOnline: false, isOnDisk: nothing), .fourier2b)
        XCTAssertEqual(SpeechModel.chosen(nil, isOnline: false, isOnDisk: parakeetOnly), .parakeetV3)
        XCTAssertEqual(SpeechModel.chosen("parakeet-v3", isOnline: false, isOnDisk: both), .parakeetV3, "a stored choice stays")
        XCTAssertEqual(SpeechModel.chosen("gpt-live-transcribe", isOnline: false, isOnDisk: both), .fourier2b)
    }

    /// OpenAI cannot be reached (no token, no key): the local model behind it, Fourier at its pace,
    /// hears what was kept and what came after.
    func testWhenOpenAIFailsFourierHearsItAtItsPace() async {
        let model = FakeFourier(takes: 0.05)
        let heard = Events()
        let listening = OnlineSpeech.recognizer(
            .gptLiveTranscribe, words: .empty, key: { nil },
            fallback: { heard in SpeechRecognizer(model: SpeechModel.default, words: .empty, engine: { PacedEngine(model) }, heard: heard) }
        ) { heard.add($0) }!
        listening.start()
        await talk(listening, seconds: 2.5)
        let segments = await listening.finish()
        XCTAssertEqual(segments.map(\.text), ["heard 2 s"])
        XCTAssertTrue(heard.notes.contains { $0.contains("no OpenAI key") && $0.contains("the local model hears it") }, "\(heard.notes)")
        XCTAssertTrue(heard.notes.contains { $0.contains("oruk-fourier-2b is ready") }, "\(heard.notes)")
        XCTAssertLessThanOrEqual(model.passes.filter { !$0.final }.count, 3)
        XCTAssertEqual(model.passes.filter(\.final).count, 1)
    }

    /// A folder with no files is not ready, and asks for nothing until `prepare`.
    func testAnEmptyFolderIsNotReady() {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("fourier-\(UUID().uuidString)")
        XCTAssertFalse(FourierRuntime(folder: folder).isReady)
        XCTAssertFalse(FileManager.default.fileExists(atPath: folder.path))
    }
}
