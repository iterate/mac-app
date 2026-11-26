import XCTest

@testable import VoiceMeetCore

final class ControlOfferTests: XCTestCase {
    private let studio = ControlOffer.Display(display: 0, name: "Studio", screen: "shared")
    private let laptop = ControlOffer.Display(display: 1, name: "Built-in", screen: "off")

    func testAskOrSharedWithAShownDisplayIsAnOffer() {
        XCTAssertEqual(ControlOffer.of(control: "ask", permitted: true, displays: [studio, laptop]), .offered(control: "ask", displays: [studio]))
        XCTAssertEqual(ControlOffer.of(control: "shared", permitted: true, displays: [studio]), .offered(control: "shared", displays: [studio]))
    }

    func testOffNoAccessibilityOrNoDisplayIsNoOffer() {
        XCTAssertEqual(ControlOffer.of(control: "off", permitted: true, displays: [studio]), .withdrawn(why: "Control this Mac is Off"))
        XCTAssertEqual(ControlOffer.of(control: "shared", permitted: false, displays: [studio]), .withdrawn(why: "macOS has not given Accessibility"))
        XCTAssertEqual(ControlOffer.of(control: "shared", permitted: true, displays: [laptop]), .withdrawn(why: "every display is Off"))
    }

    func testThePayloadNamesTheLendAndEachDisplay() {
        let offer = ControlOffer.of(control: "ask", permitted: true, displays: [studio]).payload(lend: "jane.mac")
        XCTAssertEqual(offer["kind"] as? String, "mac")
        XCTAssertEqual(offer["lend"] as? String, "jane.mac")
        XCTAssertEqual(offer["control"] as? String, "ask")
        let displays = offer["displays"] as? [[String: Any]]
        XCTAssertEqual(displays?.count, 1)
        XCTAssertEqual(displays?.first?["display"] as? Int, 0)
        XCTAssertEqual(displays?.first?["screen"] as? String, "shared")
        let none = ControlOffer.withdrawn(why: "the app quits").payload(lend: "jane.mac")
        XCTAssertTrue(none["control"] is NSNull, "a withdrawal sets control to null")
        XCTAssertEqual(none["why"] as? String, "the app quits")
        XCTAssertNotNil(try? JSONSerialization.data(withJSONObject: offer))
        XCTAssertNotNil(try? JSONSerialization.data(withJSONObject: none))
    }

    /// Said at each connection, and otherwise only on a change; withdrawals in a row are one.
    func testTheTellerSaysAChangeOnce() {
        var teller = ControlOfferTeller()
        let offer = ControlOffer.offered(control: "shared", displays: [studio])
        XCTAssertEqual(teller.tell(.withdrawn(why: "Control this Mac is Off")), .withdrawn(why: "Control this Mac is Off"), "the first state is said, also no offer")
        XCTAssertNil(teller.tell(.withdrawn(why: "every display is Off")))
        XCTAssertEqual(teller.tell(offer), offer)
        XCTAssertNil(teller.tell(offer))
        XCTAssertEqual(teller.tell(offer, again: true), offer, "a new connection hears it again")
        let ask = ControlOffer.offered(control: "ask", displays: [studio])
        XCTAssertEqual(teller.tell(ask), ask)
        XCTAssertEqual(teller.tell(.withdrawn(why: "the app quits")), .withdrawn(why: "the app quits"))
        teller.forget()
        XCTAssertEqual(teller.tell(.withdrawn(why: "x")), .withdrawn(why: "x"), "a new events job hears the state")
    }
}
