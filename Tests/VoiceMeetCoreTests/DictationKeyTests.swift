import VoiceMeetCore
import XCTest

/// Every row of `DictationKey`'s table, and the ⌥⇧D shortcut.
final class DictationKeyTests: XCTestCase {
    private let zero = Date(timeIntervalSince1970: 1_000)
    private func at(_ seconds: TimeInterval) -> Date { zero.addingTimeInterval(seconds) }

    func testIdleFnDownStartsListening() {
        var key = DictationKey()
        XCTAssertEqual(key.down(at: at(0)), .start)
        XCTAssertEqual(key.state, .pressed(since: at(0)))
        XCTAssertTrue(key.wantsOtherKeys)
    }

    func testPressedUpAfterHoldFinishes() {
        var key = DictationKey()
        _ = key.down(at: at(0))
        XCTAssertEqual(key.up(at: at(DictationKey.hold)), .finish)
        XCTAssertEqual(key.state, .idle)
    }

    func testPressedUpBeforeHoldWaitsUntilTheWindowEnds() {
        var key = DictationKey()
        _ = key.down(at: at(0))
        // the window counts from the first press, not from the release
        XCTAssertEqual(key.up(at: at(0.1)), .wait(until: at(DictationKey.window)))
        XCTAssertEqual(key.state, .tapped(until: at(DictationKey.window)))
        XCTAssertFalse(key.wantsOtherKeys)
    }

    func testPressedAnotherKeyCancelsQuietlyAndItsReleaseDoesNothing() {
        var key = DictationKey()
        _ = key.down(at: at(0))
        XCTAssertEqual(key.otherKey(), .cancel(quietly: true))
        XCTAssertEqual(key.state, .idle)
        XCTAssertEqual(key.up(at: at(2)), .nothing)
        XCTAssertEqual(key.down(at: at(3)), .start)
    }

    func testPressedEscWithFnHeldIsAnotherKey() {
        var key = DictationKey()
        _ = key.down(at: at(0))
        XCTAssertEqual(key.escape(), .cancel(quietly: true))
        XCTAssertEqual(key.up(at: at(0.1)), .nothing)
        XCTAssertEqual(key.state, .idle)
    }

    func testTappedDownBeforeTheWindowEndsLocks() {
        var key = DictationKey()
        _ = key.down(at: at(0))
        _ = key.up(at: at(0.1))
        XCTAssertEqual(key.down(at: at(0.3)), .lock)
        XCTAssertTrue(key.isLocked)
    }

    func testTappedWindowEndCancelsQuietly() {
        var key = DictationKey()
        _ = key.down(at: at(0))
        _ = key.up(at: at(0.1))
        // a timer that fires early does nothing
        XCTAssertEqual(key.windowEnded(at: at(0.4)), .nothing)
        XCTAssertEqual(key.windowEnded(at: at(DictationKey.window)), .cancel(quietly: true))
        XCTAssertEqual(key.state, .idle)
        XCTAssertEqual(key.down(at: at(1)), .start)
    }

    func testTappedDownAfterTheWindowWhoseEndWasNotSeenIsANewHold() {
        var key = DictationKey()
        _ = key.down(at: at(0))
        _ = key.up(at: at(0.1))
        XCTAssertEqual(key.down(at: at(0.6)), .nothing)
        XCTAssertEqual(key.state, .pressed(since: at(0.6)))
        XCTAssertEqual(key.up(at: at(2)), .finish)
    }

    func testTappedOtherKeysDoNothing() {
        var key = DictationKey()
        _ = key.down(at: at(0))
        _ = key.up(at: at(0.1))
        XCTAssertEqual(key.otherKey(), .nothing)
        XCTAssertEqual(key.state, .tapped(until: at(DictationKey.window)))
    }

    func testTappedEscCancels() {
        var key = DictationKey()
        _ = key.down(at: at(0))
        _ = key.up(at: at(0.1))
        XCTAssertEqual(key.escape(), .cancel(quietly: false))
        XCTAssertEqual(key.windowEnded(at: at(1)), .nothing)
    }

    func testLockedUpDoesNothing() {
        var key = locked()
        XCTAssertEqual(key.up(at: at(0.4)), .nothing)
        XCTAssertTrue(key.isLocked)
        XCTAssertEqual(key.windowEnded(at: at(1)), .nothing)
        XCTAssertTrue(key.isLocked)
    }

    func testLockedOtherKeysDoNothing() {
        var key = locked()
        _ = key.up(at: at(0.4))
        XCTAssertEqual(key.otherKey(), .nothing)
        XCTAssertTrue(key.isLocked)
    }

    func testLockedDownFinishesAndItsReleaseDoesNothing() {
        var key = locked()
        _ = key.up(at: at(0.4))
        XCTAssertEqual(key.down(at: at(60)), .finish)
        XCTAssertEqual(key.state, .idle)
        // a long press to end it is no hold of a new dictation
        XCTAssertEqual(key.up(at: at(62)), .nothing)
        XCTAssertEqual(key.down(at: at(63)), .start)
    }

    func testLockedEscCancels() {
        var key = locked()
        _ = key.up(at: at(0.4))
        XCTAssertEqual(key.escape(), .cancel(quietly: false))
        XCTAssertEqual(key.state, .idle)
        XCTAssertEqual(key.escape(), .nothing)
    }

    func testAnyStateEndedGoesIdle() {
        for state in 0..<3 {
            var key = DictationKey()
            _ = key.down(at: at(0))
            if state > 0 { _ = key.up(at: at(0.1)) }
            if state > 1 { _ = key.down(at: at(0.2)) }
            key.ended()
            XCTAssertEqual(key.state, .idle, "state \(state)")
        }
        // ended while fn is down: its release does nothing
        var key = DictationKey()
        _ = key.down(at: at(0))
        key.ended()
        XCTAssertEqual(key.up(at: at(2)), .nothing)
        XCTAssertEqual(key.down(at: at(3)), .start)
    }

    func testARepeatedDownOrAReleaseWithNoPressDoesNothing() {
        var key = DictationKey()
        XCTAssertEqual(key.up(at: at(0)), .nothing)
        _ = key.down(at: at(0))
        XCTAssertEqual(key.down(at: at(0.1)), .nothing)
        XCTAssertEqual(key.state, .pressed(since: at(0)))
    }

    func testTheShortcutHeldFinishesOnRelease() {
        var key = DictationKey()
        XCTAssertEqual(key.down(.shortcut, at: at(0)), .start)
        XCTAssertFalse(key.wantsOtherKeys)
        // its own key's repeats and modifiers are other keys: they do nothing
        XCTAssertEqual(key.otherKey(), .nothing)
        XCTAssertEqual(key.up(at: at(2)), .finish)
    }

    func testTheShortcutTappedLocksAtOnce() {
        var key = DictationKey()
        _ = key.down(.shortcut, at: at(0))
        XCTAssertEqual(key.up(at: at(0.1)), .lock)
        XCTAssertEqual(key.down(.shortcut, at: at(20)), .finish)
        XCTAssertEqual(key.up(at: at(20.1)), .nothing)
        XCTAssertEqual(key.state, .idle)
    }

    func testFnEndsADictationThatTheShortcutLocked() {
        var key = DictationKey()
        _ = key.down(.shortcut, at: at(0))
        _ = key.up(at: at(0.1))
        XCTAssertEqual(key.down(.fn, at: at(5)), .finish)
    }

    /// Tapped twice: locked, with fn still down from the second press.
    private func locked() -> DictationKey {
        var key = DictationKey()
        _ = key.down(at: at(0))
        _ = key.up(at: at(0.1))
        _ = key.down(at: at(0.3))
        return key
    }
}
