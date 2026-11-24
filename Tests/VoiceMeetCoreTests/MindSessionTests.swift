import XCTest

@testable import VoiceMeetCore

final class MindSessionTests: XCTestCase {
    private let helpers = MindSession.Helpers(node: "/n/node", iterateBin: "/i/bin/iterate.js", bridge: "/app/bridge/mac-endpoint.ts")
    private let at = Date(timeIntervalSince1970: 1_000)
    private func select(_ mind: String, _ name: String = "a.mac") -> MindSession.Selected {
        MindSession.Selected(mind: mind, name: name, helpers: helpers)
    }

    func testTheHelpersAreBesideTheBridge() {
        XCTAssertEqual(helpers.deviceEvents, "/app/bridge/device-events.mjs")
        XCTAssertEqual(helpers.deviceLive, "/app/bridge/device-live.mjs")
        XCTAssertEqual(helpers.recordUpload, "/app/bridge/record-upload.mjs")
        XCTAssertEqual(helpers.captureUpload, "/app/bridge/capture-upload.mjs")
        XCTAssertEqual(helpers.inputSend, "/app/bridge/input-send.mjs")
        XCTAssertEqual(helpers.wordsFetch, "/app/bridge/words-fetch.mjs")
    }

    func testASelectedMindHasASessionAndItsPath() {
        var sessions = MindSessions()
        XCTAssertTrue(sessions.update(selected: select("a.com"), phase: .idle).session)
        XCTAssertEqual(sessions.current?.mind, "a.com")
        XCTAssertEqual(sessions.current?.path, "/devices/a.mac")
        XCTAssertEqual(sessions.current?.generation, 1)
    }

    func testAReconnectOfTheSameMindKeepsTheSession() {
        var sessions = MindSessions()
        _ = sessions.update(selected: select("a.com"), phase: .connecting(since: at))
        XCTAssertFalse(sessions.update(selected: select("a.com"), phase: .live(since: at)).session)
        XCTAssertFalse(sessions.update(selected: select("a.com"), phase: .reconnecting(attempt: 1, of: 5, nextTryAt: at, lastFailure: "closed")).session)
        XCTAssertFalse(sessions.update(selected: select("a.com"), phase: .stopped(reason: "ended", nextStartAt: at)).session)
        XCTAssertFalse(sessions.update(selected: select("a.com"), phase: .live(since: at)).session)
        XCTAssertEqual(sessions.current?.generation, 1)
    }

    func testASwitchARenameOrNewHelpersIsANewGeneration() {
        var sessions = MindSessions()
        _ = sessions.update(selected: select("a.com"), phase: .idle)
        XCTAssertTrue(sessions.update(selected: select("b.com"), phase: .idle).session)
        XCTAssertEqual(sessions.current?.mind, "b.com")
        XCTAssertEqual(sessions.current?.generation, 2)
        XCTAssertTrue(sessions.update(selected: select("b.com", "b.mac"), phase: .idle).session)
        XCTAssertEqual(sessions.current?.generation, 3)
        let moved = MindSession.Selected(mind: "b.com", name: "b.mac", helpers: .init(node: "/other/node", iterateBin: "/i", bridge: "/b/x.ts"))
        XCTAssertTrue(sessions.update(selected: moved, phase: .idle).session)
        XCTAssertEqual(sessions.current?.generation, 4)
        // back to the first mind: a new session, not the old one
        XCTAssertTrue(sessions.update(selected: select("a.com"), phase: .idle).session)
        XCTAssertEqual(sessions.current?.generation, 5)
    }

    func testARemovalEndsTheSession() {
        var sessions = MindSessions()
        _ = sessions.update(selected: select("a.com"), phase: .live(since: at))
        XCTAssertTrue(sessions.update(selected: nil, phase: .idle).session)
        XCTAssertNil(sessions.current)
        XCTAssertFalse(sessions.update(selected: nil, phase: .idle).session)
    }

    func testARefusalKeepsTheSessionAndEndsTheAuthorizationUntilTheLendIsLive() {
        var sessions = MindSessions()
        _ = sessions.update(selected: select("a.com"), phase: .live(since: at))
        let refused = sessions.update(selected: select("a.com"), phase: .notAllowed(reason: "removed", link: nil, nextStartAt: nil))
        XCTAssertFalse(refused.session)
        XCTAssertTrue(refused.authorization)
        XCTAssertEqual(sessions.current?.generation, 1)
        XCTAssertFalse(sessions.isAuthorized)
        // the lend tries again: still refused until the mind lets it in
        XCTAssertFalse(sessions.update(selected: select("a.com"), phase: .stopped(reason: "ended", nextStartAt: at)).authorization)
        XCTAssertFalse(sessions.update(selected: select("a.com"), phase: .connecting(since: at)).authorization)
        XCTAssertFalse(sessions.isAuthorized)
        let back = sessions.update(selected: select("a.com"), phase: .live(since: at))
        XCTAssertFalse(back.session)
        XCTAssertTrue(back.authorization)
        XCTAssertTrue(sessions.isAuthorized)
        XCTAssertEqual(sessions.current?.generation, 1)
    }

    func testAnotherMindAfterARefusalIsAuthorizedAtOnce() {
        var sessions = MindSessions()
        _ = sessions.update(selected: select("a.com"), phase: .notAllowed(reason: "not yet", link: nil, nextStartAt: nil))
        XCTAssertEqual(sessions.current?.mind, "a.com")
        XCTAssertFalse(sessions.isAuthorized)
        let switched = sessions.update(selected: select("b.com"), phase: .stopped(reason: "switch", nextStartAt: at))
        XCTAssertTrue(switched.session)
        XCTAssertTrue(switched.authorization)
        XCTAssertEqual(sessions.current?.mind, "b.com")
        XCTAssertTrue(sessions.isAuthorized)
    }

    func testARefusalClearsTheGrantsAndALateAnswerOfTheRoundBefore() {
        var grants = ApprovalGrants()
        grants.use(generation: 1)
        let before = grants.round
        grants.approve(["commands"], round: before, until: at.addingTimeInterval(1800))
        grants.refuse()
        XCTAssertEqual(grants.round.generation, 1)
        XCTAssertNil(grants.isApproved("commands", now: at))
        // a question asked before the refusal, answered after it
        XCTAssertFalse(grants.approve(["commands"], round: before, until: at.addingTimeInterval(1800)))
        XCTAssertNil(grants.isApproved("commands", now: at))
        XCTAssertTrue(grants.approve(["commands"], round: grants.round, until: at.addingTimeInterval(1800)))
        XCTAssertNotNil(grants.isApproved("commands", now: at))
    }

    func testAnApprovalHoldsInItsSessionOnly() {
        var grants = ApprovalGrants()
        grants.use(generation: 1)
        XCTAssertTrue(grants.approve(["commands"], round: grants.round, until: at.addingTimeInterval(1800)))
        XCTAssertEqual(grants.isApproved("commands", now: at), at.addingTimeInterval(1800))
        XCTAssertNil(grants.isApproved("speaker", now: at))
        XCTAssertNil(grants.isApproved("commands", now: at.addingTimeInterval(1800)))
        // another mind: the approval is gone, and it does not come back with the first mind
        grants.use(generation: 2)
        XCTAssertNil(grants.isApproved("commands", now: at))
        grants.use(generation: 3)
        XCTAssertNil(grants.isApproved("commands", now: at))
    }

    func testALateApprovalOfAnOldSessionIsNotKept() {
        var grants = ApprovalGrants()
        grants.use(generation: 1)
        let first = grants.round
        grants.use(generation: 2)
        XCTAssertFalse(grants.approve(["commands"], round: first, until: at.addingTimeInterval(60)))
        XCTAssertNil(grants.isApproved("commands", now: at))
        grants.use(generation: nil)
        XCTAssertFalse(grants.approve(["commands"], round: grants.round, until: at.addingTimeInterval(60)))
        XCTAssertNil(grants.isApproved("commands", now: at))
    }

    func testEndingAnApprovalEndsItForThatThing() {
        var grants = ApprovalGrants()
        grants.use(generation: 1)
        grants.approve(["commands", "speaker"], round: grants.round, until: at.addingTimeInterval(60))
        grants.end("commands")
        XCTAssertNil(grants.isApproved("commands", now: at))
        XCTAssertNotNil(grants.isApproved("speaker", now: at))
    }
}
