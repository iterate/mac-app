import XCTest

@testable import VoiceMeetCore

final class MenuBarIconTests: XCTestCase {
    private func icon(
        ink: MenuBarMark.Ink = .live, dot: RecordDot = .none, glance: LendGlance = .live, listens: Bool = false,
        mind: String? = "example.com", hasIcon: Bool = true
    ) -> MenuBarIcon {
        MenuBarIcon.of(mark: MenuBarMark(ink: ink, dot: dot), glance: glance, listens: listens, mind: mind, hasIcon: hasIcon)
    }

    private func face(_ icon: MenuBarIcon) -> MenuBarFace? {
        if case .face(_, let face) = icon { return face }
        return nil
    }

    // MARK: - Face or mark

    func testAMindWithAnIconShowsItsFace() {
        XCTAssertEqual(icon(), .face(mind: "example.com", MenuBarFace(tone: .plain, ring: .none, dot: .none, listens: false)))
    }

    func testNoMindIsTheMark() {
        let mark = MenuBarMark(ink: .down, dot: .recording)
        XCTAssertEqual(icon(ink: .down, dot: .recording, glance: .down, listens: true, mind: nil), .mark(mark, listens: true))
    }

    func testAMindWithNoIconKeptIsTheMark() {
        XCTAssertEqual(icon(ink: .orange, hasIcon: false), .mark(MenuBarMark(ink: .orange, dot: .none), listens: false))
    }

    func testAnotherMindIsAnotherFace() {
        XCTAssertNotEqual(icon(mind: "example.com"), icon(mind: "example.org"))
    }

    // MARK: - The badges

    func testTheLendIsTheTone() {
        XCTAssertEqual(face(icon(glance: .live))?.tone, .plain)
        XCTAssertEqual(face(icon(ink: .connecting, glance: .connecting))?.tone, .dimmed)
        XCTAssertEqual(face(icon(ink: .down, glance: .down))?.tone, .slashed)
    }

    func testTheMarksColourIsTheRing() {
        XCTAssertEqual(face(icon(ink: .green))?.ring, .green)
        XCTAssertEqual(face(icon(ink: .red))?.ring, .red)
        XCTAssertEqual(face(icon(ink: .orange))?.ring, .orange)
        for ink in [MenuBarMark.Ink.live, .connecting, .down] { XCTAssertEqual(face(icon(ink: ink))?.ring, MenuBarFace.Ring.none) }
    }

    func testAColourKeepsTheLendUnderIt() {
        // the mark is only orange; the face is orange and still slashed
        XCTAssertEqual(face(icon(ink: .orange, glance: .down)), MenuBarFace(tone: .slashed, ring: .orange, dot: .none, listens: false))
    }

    func testTheRecordAndAlwaysListenAreDots() {
        XCTAssertEqual(face(icon(dot: .recording))?.dot, .recording)
        XCTAssertEqual(face(icon(dot: .paused))?.dot, .paused)
        XCTAssertEqual(face(icon(listens: true))?.listens, true)
        XCTAssertEqual(face(icon())?.listens, false)
    }

    func testTheNameSaysEveryBadge() {
        XCTAssertEqual(icon().name, "the face of example.com, live")
        XCTAssertEqual(
            icon(ink: .red, dot: .paused, glance: .connecting, listens: true).name,
            "the face of example.com, dimmed, ring red, paused, listening")
        XCTAssertEqual(icon(dot: .recording, mind: nil).name, "the iterate mark, live+recording")
    }
}
