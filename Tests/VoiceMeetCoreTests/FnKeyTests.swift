import VoiceMeetCore
import XCTest

final class FnKeyTests: XCTestCase {
    private let zero = Date(timeIntervalSince1970: 1_000)
    private func at(_ seconds: Double) -> Date { zero.addingTimeInterval(seconds) }

    func testATapAloneDoesNothing() {
        var key = FnKey()
        XCTAssertEqual(key.fnDown(at: at(0)), .nothing)
        XCTAssertEqual(key.tick(at: at(0.1)), .nothing)
        XCTAssertEqual(key.fnUp(at: at(0.15)), .nothing)
        XCTAssertNil(key.mode)
    }

    func testAHoldTalksUntilFnComesUp() {
        var key = FnKey()
        XCTAssertEqual(key.fnDown(at: at(0)), .nothing)
        XCTAssertEqual(key.tick(at: at(0.19)), .nothing)
        XCTAssertEqual(key.tick(at: at(0.22)), .startHolding)
        XCTAssertEqual(key.mode, .holding)
        XCTAssertEqual(key.fnUp(at: at(3)), .finish)
        XCTAssertNil(key.mode)
    }

    func testADoubleTapTalksHandsFreeUntilTheNextTap() {
        var key = FnKey()
        _ = key.fnDown(at: at(0))
        _ = key.fnUp(at: at(0.1))
        XCTAssertEqual(key.fnDown(at: at(0.3)), .startHandsFree)
        XCTAssertEqual(key.mode, .handsFree)
        // the second press's release, and a tick, change nothing
        XCTAssertEqual(key.tick(at: at(0.6)), .nothing)
        XCTAssertEqual(key.fnUp(at: at(0.4)), .nothing)
        XCTAssertEqual(key.otherKey(), .nothing, "typing while hands-free")
        XCTAssertEqual(key.fnDown(at: at(9)), .finish)
        XCTAssertEqual(key.fnUp(at: at(9.1)), .nothing)
        XCTAssertNil(key.mode)
    }

    func testTwoTapsFurtherApartThanTheThresholdAreTwoTaps() {
        var key = FnKey()
        _ = key.fnDown(at: at(0))
        _ = key.fnUp(at: at(0.1))
        XCTAssertEqual(key.fnDown(at: at(0.1 + FnKey.doubleTap + 0.01)), .nothing)
        XCTAssertEqual(key.fnUp(at: at(0.6)), .nothing)
        XCTAssertNil(key.mode)
    }

    func testFnWithAnotherKeyIsNotDictation() {
        var key = FnKey()
        _ = key.fnDown(at: at(0))
        XCTAssertEqual(key.otherKey(), .nothing)
        XCTAssertEqual(key.tick(at: at(0.5)), .nothing)
        XCTAssertEqual(key.fnUp(at: at(0.6)), .nothing)
        // a key after a tap ends the double tap
        _ = key.fnDown(at: at(1))
        _ = key.fnUp(at: at(1.1))
        _ = key.otherKey()
        XCTAssertEqual(key.fnDown(at: at(1.2)), .nothing)
    }

    func testAKeyDuringAHoldCancelsIt() {
        var key = FnKey()
        _ = key.fnDown(at: at(0))
        XCTAssertEqual(key.tick(at: at(0.3)), .startHolding)
        XCTAssertEqual(key.otherKey(), .cancel)
        XCTAssertEqual(key.fnUp(at: at(1)), .nothing)
    }

    func testEscapeCancelsHandsFree() {
        var key = FnKey()
        _ = key.fnDown(at: at(0))
        _ = key.fnUp(at: at(0.1))
        _ = key.fnDown(at: at(0.2))
        _ = key.fnUp(at: at(0.3))
        XCTAssertEqual(key.escape(), .cancel)
        XCTAssertNil(key.mode)
        XCTAssertEqual(key.escape(), .nothing)
    }

    func testADictationThatEndedElsewhereLeavesNoMode() {
        var key = FnKey()
        _ = key.fnDown(at: at(0))
        _ = key.tick(at: at(0.3))
        key.ended()
        XCTAssertNil(key.mode)
        XCTAssertEqual(key.fnUp(at: at(1)), .nothing)
    }
}

final class SpeechSegmentTests: XCTestCase {
    func testASegmentIsAnEntryOfACapturesTranscript() throws {
        let segment = SpeechSegment(start: 1.2345, end: 2.5, text: "the Beelink", words: [.init(start: 1.2345, end: 1.6, text: "the"), .init(start: 1.7, end: 2.5, text: "bee link")])
        let line = try JSONSerialization.data(withJSONObject: segment.transcriptEntry)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: line) as? [String: Any])
        XCTAssertEqual(json["t"] as? Int, 1235)
        XCTAssertEqual(json["to"] as? Int, 2500)
        XCTAssertEqual(json["text"] as? String, "the Beelink")
        let words = try XCTUnwrap(json["words"] as? [[String: Any]])
        XCTAssertEqual(words.count, 2)
        XCTAssertEqual(words[1]["t"] as? Int, 1700)
        XCTAssertEqual(words[1]["text"] as? String, "bee link")
    }
}
