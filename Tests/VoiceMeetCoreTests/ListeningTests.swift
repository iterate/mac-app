import Foundation
import XCTest

@testable import VoiceMeetCore

final class FanOutTests: XCTestCase {
    final class Seen: @unchecked Sendable {
        let lock = NSLock()
        var values: [String] = []
        func add(_ value: String) { lock.withLock { values.append(value) } }
    }

    func testTheFirstReaderStartsTheSourceAndTheLastOneStopsIt() {
        let fan = FanOut<Int>()
        let a = fan.add { _ in }
        let b = fan.add { _ in }
        XCTAssertTrue(a.first)
        XCTAssertFalse(b.first)
        XCTAssertFalse(fan.remove(a.id), "one reader is left")
        XCTAssertFalse(fan.remove(a.id), "a reader that is gone stops nothing")
        XCTAssertTrue(fan.remove(b.id))
        XCTAssertTrue(fan.add { _ in }.first, "a reader after the last one starts it again")
    }

    func testEachReaderGetsEachValueInOrderAndAReaderThatLeftGetsNone() {
        let fan = FanOut<Int>()
        let seen = Seen()
        let a = fan.add { seen.add("a\($0)") }
        _ = fan.add { seen.add("b\($0)") }
        fan.send(1)
        fan.remove(a.id)
        fan.send(2)
        XCTAssertEqual(seen.values, ["a1", "b1", "b2"])
    }

    func testAFailureRemovesEveryReader() {
        let fan = FanOut<Int>()
        let a = fan.add { _ in }
        let b = fan.add { _ in }
        XCTAssertEqual(fan.removeAll(), [a.id, b.id])
        XCTAssertEqual(fan.count, 0)
        XCTAssertFalse(fan.remove(a.id))
    }

    /// A reader that leaves while values come, on another thread: no crash, and no value after its `remove` returned.
    func testReadersComeAndGoWhileValuesAreSent() {
        let fan = FanOut<Int>()
        let done = expectation(description: "sent")
        DispatchQueue.global().async {
            for value in 0..<5000 { fan.send(value) }
            done.fulfill()
        }
        for _ in 0..<500 { fan.remove(fan.add { _ in }.id) }
        wait(for: [done], timeout: 10)
    }
}

final class SpeechGateTests: XCTestCase {
    /// Pieces of 0.25 s from `start`, each with its probability.
    private func hear(_ gate: inout SpeechGate, _ probabilities: [Float], from start: Double = 0) -> [SpeechGate.Event] {
        probabilities.enumerated().flatMap { index, p in
            gate.hear(p, from: start + Double(index) * 0.25, to: start + Double(index + 1) * 0.25)
        }
    }

    func testSilenceStartsNothing() {
        var gate = SpeechGate()
        XCTAssertEqual(hear(&gate, [0, 0.1, 0.3, 0.49, 0]), [])
        XCTAssertFalse(gate.isSpeaking)
    }

    func testAStretchStartsBeforeItsFirstPieceAndEndsAfterItsLastOne() {
        var gate = SpeechGate()
        // silence, 1 s of speech from 1 s, then silence
        let events = hear(&gate, [0, 0, 0, 0, 0.9, 0.8, 0.9, 0.7, 0.1, 0.1, 0.1, 0.1, 0.1])
        XCTAssertEqual(events, [.started(at: 0.8), .ended(start: 0.8, end: 2.2)])
        XCTAssertFalse(gate.isSpeaking)
    }

    func testAShortPauseBelowTheHangoverKeepsTheStretch() {
        var gate = SpeechGate()
        // speech, 0.5 s of pause (less than 0.8 s), speech, then a long pause
        let events = hear(&gate, [0.9, 0.9, 0.1, 0.1, 0.9, 0.9, 0, 0, 0, 0, 0], from: 1)
        XCTAssertEqual(events, [.started(at: 0.8), .ended(start: 0.8, end: 2.7)])
    }

    /// Between onset and offset: a stretch stays on, and none starts.
    func testTheHysteresisHoldsAStretchThatGetsQuieter() {
        var gate = SpeechGate()
        XCTAssertEqual(hear(&gate, [0.4, 0.4, 0.4]), [], "0.4 is under the onset")
        XCTAssertEqual(hear(&gate, [0.6, 0.4, 0.4, 0.4, 0.4, 0.4], from: 1), [.started(at: 0.8)], "0.4 is over the offset")
        XCTAssertTrue(gate.isSpeaking)
    }

    func testALongStretchIsCutAtItsMostAndGoesOn() {
        var settings = SpeechGate.Settings()
        settings.most = 2
        var gate = SpeechGate(settings)
        let events = hear(&gate, Array(repeating: 0.9, count: 10), from: 1)
        XCTAssertEqual(events, [.started(at: 0.8), .ended(start: 0.8, end: 3), .started(at: 3)])
    }

    func testACutEndsTheStretchAndTheNextOneStartsNoEarlier() {
        var gate = SpeechGate()
        _ = hear(&gate, [0.9, 0.9, 0.9], from: 1)
        XCTAssertEqual(gate.cut(at: 1.6), .ended(start: 0.8, end: 1.6))
        XCTAssertNil(gate.cut(at: 1.7), "no stretch goes on")
        // speech at once after the cut: its padding does not reach back into the cut stretch
        XCTAssertEqual(hear(&gate, [0.9], from: 1.7), [.started(at: 1.6)])
    }

    func testEnergyIsZeroInSilenceAndOneForALoudVoice() {
        XCTAssertEqual(SpeechGate.energy(of: []), 0)
        XCTAssertEqual(SpeechGate.energy(of: Array(repeating: 0, count: 4096)), 0)
        // a 200 Hz tone at a tenth of full scale: −23 dBFS, few crossings
        let voice = (0..<4096).map { Float(0.1 * sin(2 * Double.pi * 200 * Double($0) / 16_000)) }
        XCTAssertEqual(SpeechGate.energy(of: voice), 1)
        // as loud, and crossing zero at every sample: hiss counts half
        let hiss = (0..<4096).map { Float($0 % 2 == 0 ? 0.1 : -0.1) }
        XCTAssertEqual(SpeechGate.energy(of: hiss), 0.5)
    }
}

final class TranscriptTests: XCTestCase {
    private func segment(_ stretch: String, _ start: Double, _ end: Double, _ text: String, origin: TranscriptSegment.Origin = .listen) -> TranscriptSegment {
        TranscriptSegment(stretch: stretch, origin: origin, start: start, end: end, heard: HeardText(text, words: .empty), model: "parakeet-v3")
    }

    func testTheWordsBetweenTwoTimesAreTheSegmentsWhoseMiddleIsBetweenThem() {
        var transcript = Transcript()
        transcript.add(segment("listen-1", 10, 12, "before"))
        transcript.add(segment("dictation-1", 20, 22, "first", origin: .dictation))
        transcript.add(segment("dictation-1", 22.5, 25, "second", origin: .dictation))
        // starts before the window, its middle is in it
        transcript.add(segment("listen-2", 29, 31.5, "edge"))
        transcript.add(segment("listen-3", 40, 41, "after"))
        XCTAssertEqual(transcript.words(from: 19.5, to: 31), "first second edge")
        XCTAssertEqual(transcript.words(from: 19.5, to: 31, of: "dictation-1"), "first second")
        XCTAssertEqual(transcript.words(from: 50, to: 60), "")
    }

    func testSegmentsThatEndOutOfOrderAreKeptInTheOrderOfTheirEnds() {
        var transcript = Transcript()
        transcript.add(segment("a", 10, 15, "late"))
        transcript.add(segment("b", 5, 8, "early"))
        XCTAssertEqual(transcript.segments.map(\.text), ["early", "late"])
        XCTAssertEqual(transcript.words(from: 0, to: 20), "early late")
    }

    func testTheLastStretchIsEveryPieceOfTheStretchThatEndedLast() {
        var transcript = Transcript()
        XCTAssertNil(transcript.lastStretch())
        transcript.add(segment("listen-1", 1, 2, "old"))
        transcript.add(segment("dictation-2", 3, 4, "said", origin: .dictation))
        transcript.add(segment("dictation-2", 4.5, 6, "with a key", origin: .dictation))
        let last = transcript.lastStretch()
        XCTAssertEqual(last?.stretch, "dictation-2")
        XCTAssertEqual(last?.text, "said with a key")
        XCTAssertEqual(last?.start, 3)
        XCTAssertEqual(last?.end, 6)
        XCTAssertEqual(transcript.lastStretch(of: .listen)?.text, "old")
    }

    func testOnlyTheNewestAreKept() {
        var transcript = Transcript()
        for n in 0..<(Transcript.kept + 5) { transcript.add(segment("s\(n)", Double(n), Double(n) + 0.5, "w\(n)")) }
        XCTAssertEqual(transcript.segments.count, Transcript.kept)
        XCTAssertEqual(transcript.segments.first?.text, "w5")
    }

    func testALineHasTheTextTheHeardWordsTheirCorrectionsAndTheTimesInMilliseconds() throws {
        let words = WordList(markdown: "- Beelink: b link\n")
        let segment = TranscriptSegment(
            stretch: "listen-7", origin: .listen, start: 1_764_000_000.25, end: 1_764_000_002.5, heard: HeardText("on the b link box", words: words),
            model: "parakeet-v3")
        let line = segment.line
        XCTAssertEqual(line.last, UInt8(ascii: "\n"))
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: line) as? [String: Any])
        XCTAssertEqual(object["text"] as? String, "on the Beelink box")
        XCTAssertEqual(object["heard"] as? String, "on the b link box")
        XCTAssertEqual(object["t"] as? Int64, 1_764_000_000_250)
        XCTAssertEqual(object["to"] as? Int64, 1_764_000_002_500)
        XCTAssertEqual(object["by"] as? String, "listen")
        XCTAssertEqual(object["stretch"] as? String, "listen-7")
        XCTAssertEqual(object["model"] as? String, "parakeet-v3")
        XCTAssertEqual(object["corrections"] as? [[String: String]], [["heard": "b link", "term": "Beelink"]])
    }
}
