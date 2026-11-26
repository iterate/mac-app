import XCTest

@testable import VoiceMeetCore

final class RecordRuleTests: XCTestCase {
    private func mark(
        banner: Bool = false, inUse: Bool = false, on: Bool = false, glance: LendGlance = .live, recording: Bool = false, paused: Bool = false
    ) -> MenuBarMark {
        MenuBarMark.of(bannerShows: banner, inUse: inUse, microphoneOrCameraOn: on, glance: glance, isRecording: recording, isPaused: paused)
    }

    // MARK: - The mark

    func testTheRecordAddsADotAndLeavesTheInk() {
        XCTAssertEqual(mark(recording: true), MenuBarMark(ink: .live, dot: .recording))
        XCTAssertEqual(mark(glance: .down, recording: true, paused: true), MenuBarMark(ink: .down, dot: .paused))
        XCTAssertEqual(mark(glance: .connecting), MenuBarMark(ink: .connecting, dot: .none))
    }

    func testACameraTurnedOnDuringARecordStillShowsOrange() {
        XCTAssertEqual(mark(on: true, recording: true), MenuBarMark(ink: .orange, dot: .recording))
    }

    func testTheInkGoesBannerThenUseThenMicrophoneOrCamera() {
        XCTAssertEqual(mark(banner: true, inUse: true, on: true, recording: true).ink, .green)
        XCTAssertEqual(mark(inUse: true, on: true).ink, .red)
        XCTAssertEqual(mark(on: true, glance: .down).ink, .orange)
    }

    func testSomebodyDrivingMakesTheMarkPurpleOverEverythingAndTheWordsSayWho() {
        let driven = MenuBarMark.of(
            drivenBy: "Misha", bannerShows: true, inUse: true, microphoneOrCameraOn: true, glance: .connecting, isRecording: true,
            isPaused: false)
        XCTAssertEqual(driven, MenuBarMark(ink: .purple, dot: .recording))
        XCTAssertEqual(MenuBarFace(mark: driven, glance: .live, listens: false).ring, .purple)
        let words = MenuBarMark.label(
            drivenBy: "Misha", banner: ("Jonas", true), inUse: true, isCapturing: false, microphoneOrCameraOn: false, glance: .live,
            dot: .none, tracks: 0, pausedBecause: nil)
        XCTAssertEqual(words, "iterate: Misha drives this Mac (⌃⌥⌘Esc ends it)")
    }

    func testPausedSharingShowsThePausedRingAndSaysSo() {
        let paused = MenuBarMark.of(
            bannerShows: false, inUse: false, microphoneOrCameraOn: false, glance: .live, isRecording: false, isPaused: false, sharingPaused: true)
        XCTAssertEqual(paused, MenuBarMark(ink: .live, dot: .paused))
        let words = MenuBarMark.label(
            sharingPaused: true, banner: nil, inUse: false, isCapturing: false, microphoneOrCameraOn: false, glance: .live, dot: .paused,
            tracks: 0, pausedBecause: nil)
        XCTAssertEqual(words, "iterate: sharing paused, a mind can use nothing of this Mac")
    }

    func testPausedIsADotOnlyWhileARecorderRuns() {
        XCTAssertEqual(RecordDot.of(isRecording: false, isPaused: true), .none)
        XCTAssertEqual(RecordDot.of(isRecording: true, isPaused: false), .recording)
        XCTAssertEqual(RecordDot.of(isRecording: true, isPaused: true), .paused)
    }

    func testTheDotsWordsAndTheLogsName() {
        XCTAssertEqual(RecordDot.recording.words(tracks: 4, pausedBecause: nil), "recording 4 tracks")
        XCTAssertEqual(RecordDot.recording.words(tracks: 1, pausedBecause: nil), "recording 1 track")
        XCTAssertEqual(RecordDot.paused.words(tracks: 4, pausedBecause: "locked"), "recording paused: locked")
        XCTAssertNil(RecordDot.none.words(tracks: 0, pausedBecause: nil))
        XCTAssertEqual(mark(on: true).name, "orange")
        XCTAssertEqual(mark(recording: true, paused: true).name, "live+paused")
    }

    // MARK: - record.set

    func testOnlyASwitchTurnedOnIsAUse() {
        let on: Set<RecordSwitch> = [.mics]
        let wanted: [RecordSwitch: Bool] = [.screens: true, .mics: true, .cameras: false, .speakers: false, .windowText: true]
        XCTAssertEqual(RecordSwitch.turnedOn(from: on, by: wanted), [.screens, .windowText])
        XCTAssertEqual(RecordSwitch.turnedOff(from: on, by: [.mics: false, .screens: false]), [.mics])
        XCTAssertEqual(RecordSwitch.turnedOn(from: on, by: [:]), [])
    }

    func testEachSwitchGoesByItsPowersChoice() {
        XCTAssertEqual(RecordSwitch.screens.power, "screen")
        XCTAssertEqual(RecordSwitch.speakers.power, "screen")
        XCTAssertEqual(RecordSwitch.cameras.power, "camera")
        XCTAssertEqual(RecordSwitch.mics.power, "microphone")
        XCTAssertEqual(RecordSwitch.windowText.power, "accessibility")
    }

    func testTheGateOfAUse() {
        XCTAssertEqual(UseGate.decide(sharing: "off", permitted: true, approved: true), .off)
        XCTAssertEqual(UseGate.decide(sharing: "", permitted: true, approved: false), .off)
        XCTAssertEqual(UseGate.decide(sharing: "ask", permitted: true, approved: false), .ask)
        XCTAssertEqual(UseGate.decide(sharing: "ask", permitted: true, approved: true), .go)
        XCTAssertEqual(UseGate.decide(sharing: "ask", permitted: false, approved: true), .notPermitted)
        XCTAssertEqual(UseGate.decide(sharing: "shared", permitted: true, approved: false), .go)
        XCTAssertEqual(UseGate.decide(sharing: "shared", permitted: false, approved: false), .notPermitted)
    }

    // MARK: - The mark's words and its red

    func testTheMarksWords() {
        let label = { (banner: (String, Bool)?, inUse: Bool, capturing: Bool, on: Bool, glance: LendGlance, dot: RecordDot) in
            MenuBarMark.label(
                banner: banner.map { (title: $0.0, isCall: $0.1) }, inUse: inUse, isCapturing: capturing, microphoneOrCameraOn: on, glance: glance,
                dot: dot, tracks: 4, pausedBecause: "locked")
        }
        XCTAssertEqual(label(nil, false, false, false, .live, .none), "iterate: lent")
        XCTAssertEqual(label(nil, false, false, false, .connecting, .none), "iterate: connecting")
        XCTAssertEqual(label(nil, false, false, false, .down, .recording), "iterate: not lent, recording 4 tracks")
        XCTAssertEqual(label(("Misha", true), true, true, true, .live, .paused), "iterate: Misha calls, recording paused: locked")
        XCTAssertEqual(label(("Build done", false), false, false, false, .live, .none), "iterate: Build done")
        XCTAssertEqual(label(nil, true, true, true, .live, .none), "iterate: a mind uses this Mac now")
        XCTAssertEqual(label(nil, false, true, true, .live, .none), "iterate: your capture runs")
        XCTAssertEqual(label(nil, false, false, true, .live, .none), "iterate: microphone or camera on")
    }

    /// Fable 9: a use makes the mark red until 3 s after it, and that end is the one look again.
    func testTheRedOfAUseEndsOnce() {
        let use = Date(timeIntervalSince1970: 1_000)
        XCTAssertTrue(MenuBarMark.inUse(lastUse: use, now: use.addingTimeInterval(1)) == (true, use.addingTimeInterval(3)))
        XCTAssertTrue(MenuBarMark.inUse(lastUse: use, now: use.addingTimeInterval(3)) == (false, nil))
        XCTAssertTrue(MenuBarMark.inUse(lastUse: nil, now: use) == (false, nil))
    }
}
