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

/// The fn tap's own rule, on its thread (`FnTap`).
final class KeyTapRuleTests: XCTestCase {
    /// Astra 19, Carbon 12a: fn down, an arrow at once, fn up, while the main actor is busy. The
    /// tap knows fn is down from its own event, so the arrow is fn's combination; in their order
    /// the events cancel the dictation that fn started, and its release does nothing.
    func testAKeyAMomentAfterFnIsItsCombinationBeforeTheMainActorHeardFn() {
        var rule = KeyTapRule()
        var queued: [KeyTapRule.Heard] = []
        XCTAssertFalse(rule.wantsKeyDowns, "idle: no key press passes the tap")
        queued += [rule.flagsChanged(code: 63, fn: true)].compactMap { $0 }
        XCTAssertTrue(rule.wantsKeyDowns, "the key tap is on before the next key")
        let arrow = rule.keyDown(code: 123)
        XCTAssertFalse(arrow.swallow)
        queued += [arrow.heard].compactMap { $0 }
        queued += [rule.flagsChanged(code: 63, fn: false)].compactMap { $0 }
        XCTAssertFalse(rule.wantsKeyDowns)
        XCTAssertEqual(queued, [.fn(down: true), .otherKey, .fn(down: false)])

        // the main actor drains them now
        var key = DictationKey()
        let zero = Date(timeIntervalSince1970: 0)
        var acts: [DictationKey.Act] = []
        for heard in queued {
            switch heard {
            case .fn(let down): acts.append(down ? key.down(at: zero) : key.up(at: zero.addingTimeInterval(1)))
            case .otherKey: acts.append(key.otherKey())
            case .escape: acts.append(key.escape())
            }
        }
        XCTAssertEqual(acts, [.start, .cancel(quietly: true), .nothing])
        XCTAssertEqual(key.state, .idle)
    }

    func testAnotherModifierWhileFnIsDownIsACombinationAndAloneIsNothing() {
        var rule = KeyTapRule()
        XCTAssertNil(rule.flagsChanged(code: 56, fn: false), "⇧ alone")
        XCTAssertEqual(rule.flagsChanged(code: 179, fn: true), .fn(down: true), "the 🌐 key")
        XCTAssertEqual(rule.flagsChanged(code: 56, fn: true), .otherKey)
    }

    func testEscGoesToADictationAndIsSwallowedOnlyWhileItIsLocked() {
        var rule = KeyTapRule()
        XCTAssertEqual(rule.keyDown(code: KeyTapRule.escapeCode).heard, nil)
        rule.escape = true
        XCTAssertTrue(rule.wantsKeyDowns)
        XCTAssertEqual(rule.keyDown(code: KeyTapRule.escapeCode).heard, .escape)
        XCTAssertFalse(rule.keyDown(code: KeyTapRule.escapeCode).swallow)
        rule.swallowsEscape = true
        XCTAssertTrue(rule.keyDown(code: KeyTapRule.escapeCode).swallow)
        XCTAssertEqual(rule.keyDown(code: 0).heard, nil, "a letter while a locked dictation goes")
    }

    /// Carbon 12a: macOS switched the tap off while fn was held and fn went up meanwhile.
    func testATapOnAgainTellsTheFnReleaseItMissed() {
        var rule = KeyTapRule()
        _ = rule.flagsChanged(code: 63, fn: true)
        XCTAssertEqual(rule.resumed(fn: false), .fn(down: false))
        XCTAssertFalse(rule.wantsKeyDowns)
        XCTAssertNil(rule.resumed(fn: false), "nothing changed")
    }
}
