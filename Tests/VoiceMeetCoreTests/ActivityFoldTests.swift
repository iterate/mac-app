import XCTest

@testable import VoiceMeetCore

final class ActivityFoldTests: XCTestCase {
    private let at = Date(timeIntervalSince1970: 1_000)
    private func started(_ act: String, _ seconds: TimeInterval = 0, offset: Int? = nil) -> ContextEvent {
        ContextEvent(.actStarted(act: act, thing: "commands", doing: "Running a command", detail: "/bin/echo hi"), at: at + seconds, offset: offset)
    }
    private func ended(_ act: String, _ seconds: TimeInterval = 1, failure: String? = nil, offset: Int? = nil) -> ContextEvent {
        ContextEvent(.actEnded(act: act, did: "Ran a command", failure: failure), at: at + seconds, offset: offset)
    }

    func testAnActOfThisAppShowsAtOnceAndItsEchoIsTheSameRow() {
        var fold = ActivityFold()
        XCTAssertTrue(fold.take(started("a")))
        XCTAssertEqual(fold.rows.count, 1)
        XCTAssertTrue(fold.rows[0].isRunning)
        XCTAssertFalse(fold.rows[0].isInMind)

        fold.take(ended("a"))
        XCTAssertFalse(fold.rows[0].isRunning)
        XCTAssertEqual(fold.rows[0].did, "Ran a command")
        XCTAssertFalse(fold.rows[0].isInMind, "neither event is in the context yet")

        XCTAssertFalse(fold.take(started("a", 0.2, offset: 7)), "the echo starts no new act")
        XCTAssertFalse(fold.rows[0].isInMind, "the end is not echoed yet")
        fold.take(ended("a", 1.1, offset: 8))
        XCTAssertEqual(fold.rows.count, 1)
        XCTAssertTrue(fold.rows[0].isInMind)
        XCTAssertEqual(fold.rows[0].startedAt, at + 0.2, "the context's time is the fact's")
        XCTAssertEqual(fold.rows[0].endedAt, at + 1.1)
    }

    func testAnEchoBeforeTheLocalEndKeepsTheActRunning() {
        var fold = ActivityFold()
        fold.take(started("a"))
        fold.take(started("a", offset: 3))
        XCTAssertTrue(fold.rows[0].isRunning)
        XCTAssertTrue(fold.rows[0].isInMind)
        fold.take(ended("a", failure: "it ended with status 1"))
        XCTAssertEqual(fold.rows[0].failure, "it ended with status 1")
        XCTAssertFalse(fold.rows[0].isInMind)
    }

    func testAnActReadFromTheContextWithNoEndIsNotRunning() {
        var fold = ActivityFold()
        XCTAssertTrue(fold.take(started("old", offset: 1)))
        XCTAssertFalse(fold.rows[0].isMadeHere)
        XCTAssertFalse(fold.rows[0].isRunning, "the app that ran it ended")
        XCTAssertTrue(fold.rows[0].isInMind)
    }

    func testRowsAreTheNewestStartFirstWhateverOrderTheyCome() {
        var fold = ActivityFold()
        // a page of older events can come after newer ones
        fold.take(started("b", 20, offset: 20))
        fold.take(started("a", 10, offset: 10))
        fold.take(started("c", 30))
        XCTAssertEqual(fold.rows.map(\.act), ["c", "b", "a"])
    }

    func testTheFoldKeepsTheNewestFiftyAndDropsTheEndOfAnActItDoesNotHold() {
        var fold = ActivityFold()
        for n in 0..<60 { fold.take(started("\(n)", TimeInterval(n), offset: n + 1)) }
        XCTAssertEqual(fold.rows.count, ActivityFold.kept)
        XCTAssertEqual(fold.rows.first?.act, "59")
        XCTAssertEqual(fold.rows.last?.act, "10")
        fold.take(ended("3", offset: 100))
        XCTAssertFalse(fold.rows.contains { $0.act == "3" })
        XCTAssertFalse(fold.take(started("2", 2, offset: 3)), "an act older than every row kept is not kept")
    }

    func testPresenceIsTheNewestFact() {
        var fold = ActivityFold()
        fold.take(ContextEvent(.presenceChanged(state: "idle"), at: at + 5, offset: 2))
        fold.take(ContextEvent(.presenceChanged(state: "active"), at: at, offset: 1))
        XCTAssertEqual(fold.presence?.state, "idle")
        XCTAssertTrue(fold.rows.isEmpty)
    }

    func testAnEventGoesToTheContextAndComesBackAsTheSameFact() throws {
        let facts: [DeviceFact] = [
            .actStarted(act: "a", thing: "screen.1", doing: "Taking a picture", detail: nil),
            .actStarted(act: "a", thing: "commands", doing: "Running a command", detail: "/bin/ls"),
            .actEnded(act: "a", did: "Ran a command", failure: "it ended with status 1"),
            .actEnded(act: "a", did: "Ran a command", failure: nil),
            .presenceChanged(state: "locked"),
        ]
        for fact in facts {
            let line: [String: Any] = ["type": fact.type, "payload": fact.payload, "offset": 4, "createdAt": "2026-11-24T14:02:11.250Z"]
            let echo = try XCTUnwrap(ContextEvent(json: line))
            XCTAssertEqual(echo.fact, fact)
            XCTAssertEqual(echo.offset, 4)
            XCTAssertEqual(echo.at.timeIntervalSince1970, 1_795_528_931.25, accuracy: 0.001)
        }
        XCTAssertEqual(facts[1].idempotencyKey, "device/act-started/a")
        XCTAssertEqual(facts[2].idempotencyKey, "device/act-ended/a")
        XCTAssertNil(facts[4].idempotencyKey)
        XCTAssertNil(ContextEvent(json: ["type": "device/key-pressed", "payload": ["key": "a"], "offset": 1, "createdAt": "2026-11-24T14:02:11Z"]))
        XCTAssertNil(ContextEvent(json: ["type": "device/act-ended", "payload": ["act": "a"], "offset": 1, "createdAt": "2026-11-24T14:02:11Z"]))
    }
}
