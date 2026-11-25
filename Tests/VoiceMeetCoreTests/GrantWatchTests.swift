import XCTest

@testable import VoiceMeetCore

final class GrantWatchTests: XCTestCase {
    /// Fable 13, Carbon 4, Astra 23: at most 20 processes a minute, and one at a time however
    /// slowly each answers; none after the 5 minutes.
    func testAtMostOneProcessAskesAtATime() {
        let start = Date(timeIntervalSince1970: 0)
        for answersAfter in [0.2, 7.0] {
            var watch = GrantWatch(startedAt: start)
            var probes = 0, answerAt: TimeInterval?
            var t: TimeInterval = 0
            while t < 60 {
                if let at = answerAt, t >= at { watch.answered(); answerAt = nil }
                if watch.probes(at: start.addingTimeInterval(t), waitsForScreenRecording: true) {
                    probes += 1
                    XCTAssertNil(answerAt, "a second process while one asks")
                    answerAt = t + answersAfter
                }
                t += GrantWatch.interval
            }
            XCTAssertLessThanOrEqual(probes, 20, "answers after \(answersAfter) s")
            XCTAssertGreaterThan(probes, 0)
        }
        var watch = GrantWatch(startedAt: start)
        XCTAssertFalse(watch.probes(at: start, waitsForScreenRecording: false), "no process for the other permissions")
        XCTAssertFalse(watch.probes(at: start.addingTimeInterval(GrantWatch.lasts), waitsForScreenRecording: true))
        XCTAssertTrue(watch.isOver(at: start.addingTimeInterval(GrantWatch.lasts)))
    }
}
