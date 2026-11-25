import XCTest

@testable import VoiceMeetCore

final class CallRuleTests: XCTestCase {
    func testASourceIsAScreenByItsNumberOrTheCamera() {
        XCTAssertEqual(CallSource("camera"), .camera)
        XCTAssertEqual(CallSource("screen:0"), .screen(0))
        XCTAssertEqual(CallSource("screen:2")?.text, "screen:2")
        XCTAssertEqual(CallSource("screen:1")?.kind, "screen")
        for wrong in ["mic", "screen", "screen:", "screen:-1", "screen:x", "screen:1:2", "Camera", ""] {
            XCTAssertNil(CallSource(wrong), wrong)
        }
    }

    /// Off refuses before anything starts; Ask and Shared go on (Ask after its question).
    func testOffRefusesThePublication() {
        XCTAssertEqual(
            CallGate.refusal(UseGate.decide(sharing: "off", permitted: true, approved: false), thing: "the display “Studio”"),
            "The Mac's owner has the display “Studio” off in the iterate panel: a call cannot have it."
        )
        XCTAssertNotNil(CallGate.refusal(UseGate.decide(sharing: "shared", permitted: false, approved: false), thing: "the camera"))
        XCTAssertNil(CallGate.refusal(UseGate.decide(sharing: "ask", permitted: true, approved: false), thing: "the camera"))
        XCTAssertNil(CallGate.refusal(UseGate.decide(sharing: "shared", permitted: true, approved: false), thing: "the camera"))
    }

    func testOneScreenAndOneCameraForEachCall() {
        var list = CallPublications()
        let now = Date(timeIntervalSince1970: 0)
        list.add(.init(id: "a", context: "/agents/meet/x", source: .screen(0), asker: "sub-1", who: "jonas", since: now))
        list.add(.init(id: "b", context: "/agents/meet/x", source: .camera, asker: "sub-1", who: "jonas", since: now))
        list.add(.init(id: "c", context: "/agents/meet/y", source: .screen(0), asker: nil, who: "jonas", since: now))
        XCTAssertEqual(list.replaced(by: .screen(1), in: "/agents/meet/x"), ["a"], "a second screen replaces the first")
        XCTAssertEqual(list.replaced(by: .camera, in: "/agents/meet/y"), [])
        XCTAssertNil(list.refusal(adding: .camera, in: "/agents/meet/y"))
        list.add(.init(id: "d", context: "/agents/meet/y", source: .camera, asker: nil, who: "jonas", since: now))
        XCTAssertNotNil(list.refusal(adding: .camera, in: "/agents/meet/z"), "four at most")
        XCTAssertNil(list.refusal(adding: .screen(2), in: "/agents/meet/x"), "a replacement is no fifth")
    }

    func testUnpublishNamesByIdOrByCall() {
        var list = CallPublications()
        let now = Date(timeIntervalSince1970: 0)
        list.add(.init(id: "a", context: "/agents/x", source: .screen(0), asker: nil, who: "", since: now))
        list.add(.init(id: "b", context: "/agents/x", source: .camera, asker: nil, who: "", since: now))
        XCTAssertEqual(list.named(publication: "b", context: nil, source: nil), ["b"])
        XCTAssertEqual(list.named(publication: nil, context: "/agents/x", source: nil), ["a", "b"])
        XCTAssertEqual(list.named(publication: nil, context: "/agents/x", source: "screen:0"), ["a"])
        XCTAssertEqual(list.named(publication: nil, context: nil, source: "camera"), [], "nothing named is nothing")
        XCTAssertEqual(list.turnedOff { $0 == .camera }, ["b"])
        list.connected("a")
        XCTAssertTrue(list.all[0].connected)
        XCTAssertEqual(list.remove("a")?.id, "a")
        XCTAssertNil(list.remove("a"))
    }

    func testNoTCPCandidateGoesToTheSFU() {
        let sdp = "v=0\r\na=candidate:1 1 udp 2122260223 192.0.2.1 50000 typ host\r\na=candidate:2 1 tcp 1518280447 192.0.2.1 9 typ host tcptype active\r\na=mid:0\r\n"
        XCTAssertEqual(CallSDP.udpOnly(sdp), "v=0\r\na=candidate:1 1 udp 2122260223 192.0.2.1 50000 typ host\r\na=mid:0\r\n")
    }

    func testAScreenKeepsItsAspectWithin1920By1200() {
        XCTAssertTrue(CallFit.screen(width: 1280, height: 720) == (1280, 720), "smaller: as it is, not cropped to 16:10")
        XCTAssertTrue(CallFit.screen(width: 3024, height: 1964) == (1846, 1200))
        XCTAssertTrue(CallFit.screen(width: 5120, height: 1440) == (1920, 540))
        XCTAssertTrue(CallFit.screen(width: 1471, height: 957) == (1470, 956), "even pixels")
    }
}
