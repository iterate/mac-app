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
}
