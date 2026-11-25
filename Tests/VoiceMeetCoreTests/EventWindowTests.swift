import XCTest

@testable import VoiceMeetCore

final class EventWindowTests: XCTestCase {
    private struct Event: OffsetEvent, Equatable {
        let offset: Int
    }

    private func page(_ offsets: ClosedRange<Int>) -> [Event] { offsets.reversed().map(Event.init) }

    func testPagesGoOlderUntilTheStartAndNewEventsGoFirst() {
        var window = EventWindow<Event>()
        XCTAssertNil(window.askOlder(), "no page is asked before the first came")
        window.take(page: page(151...250), before: 151, more: true)
        XCTAssertEqual(window.events.first?.offset, 250)
        XCTAssertEqual(window.askOlder(), 151)
        XCTAssertNil(window.askOlder(), "one page at a time")
        window.take(Event(offset: 251))
        window.take(page: page(51...150), before: 51, more: true)
        XCTAssertEqual(window.events.map(\.offset), Array((51...251).reversed()))
        XCTAssertEqual(window.askOlder(), 51)
        window.take(page: page(1...50), before: 1, more: false)
        XCTAssertNil(window.askOlder(), "the start of the context")
        XCTAssertEqual(window.events.count, 251)
    }

    func testEachEventOnceInOrder() {
        var window = EventWindow<Event>()
        window.take(page: page(1...10), before: 1, more: false)
        XCTAssertFalse(window.take(Event(offset: 10)))
        XCTAssertTrue(window.take(Event(offset: 12)))
        XCTAssertTrue(window.take(Event(offset: 11)))
        XCTAssertEqual(window.events.prefix(3).map(\.offset), [12, 11, 10])
    }

    func testTheWindowHoldsAtMostFiveHundredAndReadsNoOlderPageWhenFull() {
        var window = EventWindow<Event>()
        for start in stride(from: 901, through: 401, by: -100) {
            window.take(page: page(start...(start + 99)), before: start, more: true)
        }
        XCTAssertEqual(window.events.count, 500)
        XCTAssertTrue(window.isFull)
        XCTAssertNil(window.askOlder())
        window.take(Event(offset: 1_001))
        XCTAssertEqual(window.events.count, 500)
        XCTAssertEqual(window.events.first?.offset, 1_001)
        XCTAssertEqual(window.events.last?.offset, 502)
        XCTAssertTrue(window.hasOlder)
    }

    func testAResetEmptiesTheWindowAndAFailureAsksAgain() {
        var window = EventWindow<Event>()
        window.take(page: page(11...20), before: 11, more: true)
        XCTAssertEqual(window.askOlder(), 11)
        window.failed()
        XCTAssertEqual(window.askOlder(), 11)
        window.reset()
        XCTAssertTrue(window.events.isEmpty)
        XCTAssertFalse(window.isRead)
    }
}
