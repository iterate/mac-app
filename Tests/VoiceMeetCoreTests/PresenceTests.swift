import XCTest

@testable import VoiceMeetCore

final class PresenceTests: XCTestCase {
    private let onConsole: [String: Any] = ["kCGSSessionOnConsoleKey": 1, "kCGSessionLoginDoneKey": 1]

    func testAnUnlockedSessionInFrontWithADisplayAwake() {
        let presence = Presence.read(idle: 42.7, session: onConsole, displaysAsleep: [false, true])
        XCTAssertEqual(presence, Presence(idleSeconds: 42, screenLocked: false, displayAsleep: false))
        XCTAssertEqual(presence.dictionary["idleSeconds"] as? Int, 42)
    }

    func testTheLockKeyIsThereOnlyWhileLocked() {
        var locked = onConsole
        locked["CGSSessionScreenIsLocked"] = 1
        XCTAssertTrue(Presence.read(idle: 1, session: locked, displaysAsleep: [false]).screenLocked)
        locked["CGSSessionScreenIsLocked"] = true
        XCTAssertTrue(Presence.read(idle: 1, session: locked, displaysAsleep: [false]).screenLocked)
    }

    func testASessionNotOnTheConsoleOrNoSessionIsLocked() {
        XCTAssertTrue(Presence.read(idle: 1, session: ["kCGSSessionOnConsoleKey": 0], displaysAsleep: [false]).screenLocked)
        XCTAssertTrue(Presence.read(idle: 1, session: nil, displaysAsleep: [false]).screenLocked)
        // a dictionary with no console key is taken as on the console
        XCTAssertFalse(Presence.read(idle: 1, session: [:], displaysAsleep: [false]).screenLocked)
    }

    func testEveryDisplayAsleepOrNoneOnlineIsAsleep() {
        XCTAssertTrue(Presence.read(idle: 1, session: onConsole, displaysAsleep: [true, true]).displayAsleep)
        XCTAssertTrue(Presence.read(idle: 1, session: onConsole, displaysAsleep: []).displayAsleep)
    }

    func testAnOddIdleValueIsKeptInBounds() {
        XCTAssertEqual(Presence.read(idle: .nan, session: onConsole, displaysAsleep: [false]).idleSeconds, 0)
        XCTAssertEqual(Presence.read(idle: .infinity, session: onConsole, displaysAsleep: [false]).idleSeconds, Int(Int32.max))
        XCTAssertEqual(Presence.read(idle: -3, session: onConsole, displaysAsleep: [false]).idleSeconds, 0)
        XCTAssertEqual(Presence.read(idle: 1e300, session: onConsole, displaysAsleep: [false]).idleSeconds, Int(Int32.max))
    }

    /// Fable 18: the state, and one look at the moment it would change, not a poll each 2 s.
    func testTheStateAndTheNextLook() {
        let at = { (idle: Int, locked: Bool, asleep: Bool) in Presence(idleSeconds: idle, screenLocked: locked, displayAsleep: asleep) }
        XCTAssertEqual(at(0, false, false).state, "active")
        XCTAssertEqual(at(0, false, false).nextLookSeconds, 120)
        XCTAssertEqual(at(100, false, false).nextLookSeconds, 20)
        XCTAssertEqual(at(119, false, false).nextLookSeconds, 1)
        XCTAssertEqual(at(120, false, false).state, "idle")
        XCTAssertEqual(at(120, false, false).nextLookSeconds, Presence.fallbackSeconds)
        XCTAssertEqual(at(5, true, true).state, "locked")
        XCTAssertEqual(at(5, false, true).state, "asleep")
        XCTAssertEqual(at(5, false, true).nextLookSeconds, Presence.fallbackSeconds)
        // over 20 minutes of a person who types now and then, and is away for 10: few looks
        var looks = 0, t = 0, lastInput = 0
        while t < 1200 {
            if t < 600, t % 37 == 0 { lastInput = t }
            let presence = at(t - lastInput, false, false)
            looks += 1
            t += presence.nextLookSeconds
        }
        XCTAssertLessThan(looks, 40, "a poll each 2 s is 600 looks")
    }
}
