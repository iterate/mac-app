import XCTest
@testable import VoiceMeetCore

final class SecretKeysTests: XCTestCase {
    func testAKeyInAnOrdinaryFieldGoes() {
        XCTAssertFalse(SecretKeys.withholds(secureInput: false, app: "com.google.Chrome", focusedSubrole: nil, focusedRole: "AXTextField"))
        XCTAssertFalse(SecretKeys.withholds(secureInput: false, app: nil, focusedSubrole: nil))
    }

    func testSecureInputWithholdsEveryKey() {
        XCTAssertTrue(SecretKeys.withholds(secureInput: true, app: "com.apple.Terminal", focusedSubrole: nil))
    }

    func testAPasswordManagerOrASystemPromptInFrontWithholdsItsKeys() {
        XCTAssertTrue(SecretKeys.withholds(secureInput: false, app: "com.1password.1password", focusedSubrole: nil))
        XCTAssertTrue(SecretKeys.withholds(secureInput: false, app: "com.apple.SecurityAgent", focusedSubrole: nil))
        XCTAssertTrue(SecretKeys.withholds(secureInput: false, app: "com.apple.loginwindow", focusedSubrole: nil))
    }

    func testAPasswordFieldInABrowserWithholdsItsKeys() {
        XCTAssertTrue(SecretKeys.withholds(secureInput: false, app: "com.google.Chrome", focusedSubrole: "AXSecureTextField"))
        XCTAssertTrue(SecretKeys.withholds(secureInput: false, app: "com.apple.Safari", focusedSubrole: nil, focusedRole: "AXSecureTextField"))
    }

    func testAKeptVerdictHoldsForItsAppAlone() {
        var focus = FocusVerdict()
        focus.front(10)
        XCTAssertNil(focus.verdict(for: 10), "a new app in front: its focus is not read yet, so the key asks")
        focus.read(pid: 10, role: "AXTextField", subrole: "AXSecureTextField", read: true)
        XCTAssertEqual(focus.verdict(for: 10), true)
        XCTAssertNil(focus.verdict(for: 11), "another app in front: the verdict is not its")
        focus.read(pid: 10, role: "AXTextArea", subrole: nil, read: true)
        XCTAssertEqual(focus.verdict(for: 10), false)
    }

    func testAnotherAppOrAFailedReadLeavesNoVerdict() {
        var focus = FocusVerdict()
        focus.front(10)
        focus.read(pid: 10, role: "AXSecureTextField", subrole: nil, read: true)
        focus.read(pid: 11, role: "AXTextField", subrole: nil, read: true)
        XCTAssertEqual(focus.verdict(for: 10), true, "a late read of another app changes nothing")
        focus.read(pid: 10, role: nil, subrole: nil, read: false)
        XCTAssertNil(focus.verdict(for: 10), "the app did not answer: the key asks")
        focus.read(pid: 10, role: "AXSecureTextField", subrole: nil, read: true)
        focus.front(11)
        XCTAssertNil(focus.verdict(for: 11))
        focus.front(10)
        XCTAssertNil(focus.verdict(for: 10), "back in front: its focus may have moved meanwhile")
        focus.read(pid: 10, role: "AXSecureTextField", subrole: nil, read: true)
        focus.forget()
        XCTAssertNil(focus.verdict(for: 10))
    }

    func testANotAPasswordVerdictHoldsOneSecondAndAPasswordVerdictHoldsUntilTheFocusMoves() {
        let start = Date(timeIntervalSince1970: 1_000)
        var verdict = FocusVerdict()
        verdict.front(7)
        verdict.read(pid: 7, role: "AXTextField", subrole: nil, read: true, at: start)
        XCTAssertEqual(verdict.verdict(for: 7, at: start.addingTimeInterval(0.5)), false)
        XCTAssertNil(verdict.verdict(for: 7, at: start.addingTimeInterval(1.5)), "an old 'not a password' asks the app again")
        verdict.read(pid: 7, role: "AXTextField", subrole: "AXSecureTextField", read: true, at: start)
        XCTAssertEqual(verdict.verdict(for: 7, at: start.addingTimeInterval(60)), true)
    }
}
