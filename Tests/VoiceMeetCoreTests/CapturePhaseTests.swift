import VoiceMeetCore
import XCTest

final class CapturePhaseTests: XCTestCase {
    /// Astra 5, Fable 3: a second press while the first one's start waits makes no second capture.
    func testAPressWhileItStartsOrEndsDoesNothing() {
        XCTAssertEqual(CapturePhase.idle.toggle, .start)
        XCTAssertEqual(CapturePhase.starting.toggle, .nothing)
        XCTAssertEqual(CapturePhase.running.toggle, .end)
        XCTAssertEqual(CapturePhase.ending.toggle, .nothing)
    }

    /// Astra 24: a home of its own never opens the microphone and never asks for it.
    func testAHomeOfItsOwnOpensNoMicrophoneWhateverMacOSAllows() {
        for (authorized, undetermined) in [(true, false), (false, true), (false, false)] {
            XCTAssertEqual(CapturePhase.microphone(hasOwnHome: true, isAuthorized: authorized, isUndetermined: undetermined), .off)
        }
        XCTAssertEqual(CapturePhase.microphone(hasOwnHome: false, isAuthorized: true, isUndetermined: false), .on)
        XCTAssertEqual(CapturePhase.microphone(hasOwnHome: false, isAuthorized: false, isUndetermined: true), .ask)
        XCTAssertEqual(CapturePhase.microphone(hasOwnHome: false, isAuthorized: false, isUndetermined: false), .off)
    }
}
