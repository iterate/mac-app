import XCTest

@testable import VoiceMeetCore

final class LiveTracksTests: XCTestCase {
    func testOffAskAndSharedDecideEachTrack() {
        let gates: [(track: String, gate: UseGate)] = [("screen-1", .go), ("screen-2", .off), ("camera-0", .ask), ("mic-0", .notPermitted)]
        XCTAssertTrue(LiveTracks.asks(gates))
        XCTAssertEqual(LiveTracks.offered(gates, approved: true), ["screen-1", "camera-0"])
        XCTAssertEqual(LiveTracks.offered(gates, approved: false), ["screen-1"])
        XCTAssertFalse(LiveTracks.asks([("screen-1", .go), ("mic-0", .off)]))
        XCTAssertEqual(LiveTracks.offered([("screen-1", .off), ("mic-0", .off)], approved: true), [])
        XCTAssertEqual(LiveTracks.nothing(asked: true, approved: false), "the owner did not approve the watch")
        XCTAssertTrue(LiveTracks.nothing(asked: false, approved: false).hasPrefix("nothing to show"))
    }

    func testSeveralCamerasGoByTheStrictest() {
        XCTAssertEqual(UseGate.strictest([.go, .ask]), .ask)
        XCTAssertEqual(UseGate.strictest([.go, .notPermitted, .ask]), .notPermitted)
        XCTAssertEqual(UseGate.strictest([.ask, .off]), .off)
        XCTAssertEqual(UseGate.strictest([.go, .go]), .go)
        XCTAssertEqual(UseGate.strictest([]), .off)  // no camera
    }
}

final class LiveWatchersTests: XCTestCase {
    let t0 = Date(timeIntervalSince1970: 1_800_000_000)
    let c = { (n: Int) in LiveCandidate(candidate: "candidate:\(n) 1 udp 1 127.0.0.1 \(5000 + n) typ host", sdpMid: "0", sdpMLineIndex: 0) }

    /// A watcher from `want` to connected; answers the effects of each step.
    private func connect(_ w: inout LiveWatchers, _ id: String, at t: Date) {
        _ = w.want(from: id, who: "\(id)@example.com", now: t)
        _ = w.decided(id, tracks: ["screen-1", "mic-0"], reason: "")
        _ = w.offerMade(id, sdp: "offer", mids: ["0": "screen-1", "1": "mic-0"])
        _ = w.answer(from: id, sdp: "answer")
        _ = w.connected(id, now: t)
    }

    func testWantOfferAnswerCandidatesInOrderAndBye() {
        var w = LiveWatchers()
        XCTAssertEqual(w.want(from: "a", who: "ann@example.com", now: t0), [.decide(watcher: "a", who: "ann@example.com")])
        XCTAssertEqual(w.watch("a")?.phase, .deciding)
        XCTAssertEqual(w.tracks, [])  // nothing captured before the owner's answer
        XCTAssertEqual(w.decided("a", tracks: ["screen-1", "camera-0"], reason: ""), [.makeOffer(watcher: "a", tracks: ["screen-1", "camera-0"])])
        XCTAssertEqual(w.tracks, ["screen-1", "camera-0"])
        // the device's candidates before its offer wait; the watcher's before its answer too
        XCTAssertEqual(w.deviceCandidate("a", c(1)), [])
        XCTAssertEqual(w.deviceCandidate("a", c(2)), [])
        XCTAssertEqual(w.candidate(from: "a", c(9)), [])
        XCTAssertEqual(
            w.offerMade("a", sdp: "offer", mids: ["0": "screen-1", "1": "camera-0"]),
            [.send(.offer(to: "a", sdp: "offer", tracks: ["0": "screen-1", "1": "camera-0"])), .send(.candidate(to: "a", c(1))), .send(.candidate(to: "a", c(2)))])
        XCTAssertEqual(w.deviceCandidate("a", c(3)), [.send(.candidate(to: "a", c(3)))])
        XCTAssertEqual(w.candidate(from: "a", c(10)), [])
        XCTAssertEqual(w.answer(from: "a", sdp: "answer"), [.setAnswer(watcher: "a", sdp: "answer"), .addCandidate(watcher: "a", c(9)), .addCandidate(watcher: "a", c(10))])
        XCTAssertEqual(w.answer(from: "a", sdp: "again"), [])  // one answer
        XCTAssertEqual(w.candidate(from: "a", c(11)), [.addCandidate(watcher: "a", c(11))])
        XCTAssertEqual(w.connected("a", now: t0), [.started(watcher: "a", who: "ann@example.com", tracks: ["screen-1", "camera-0"])])
        XCTAssertEqual(w.connected("a", now: t0), [])  // once
        // the watcher leaves: no bye back, the watch's end with its seconds
        XCTAssertEqual(
            w.end("a", why: "the watcher left", tell: false, now: t0.addingTimeInterval(42.4)),
            [.close(watcher: "a"), .ended(watcher: "a", who: "ann@example.com", seconds: 42, why: "the watcher left")])
        XCTAssertEqual(w.watches, [])
        XCTAssertEqual(w.end("a", why: "again", tell: true, now: t0), [])
    }

    func testNothingToShowIsAByeWithTheReason() {
        var w = LiveWatchers()
        _ = w.want(from: "a", who: "ann", now: t0)
        XCTAssertEqual(w.decided("a", tracks: [], reason: "nothing to show"), [.send(.bye(to: "a", reason: "nothing to show"))])
        XCTAssertEqual(w.watches, [])
    }

    func testAWatcherWhoLeftBeforeTheAnswerIsForgotten() {
        var w = LiveWatchers()
        _ = w.want(from: "a", who: "ann", now: t0)
        // it left while the owner was asked: no act, no kept event
        XCTAssertEqual(w.end("a", why: "the watcher left", tell: false, now: t0), [.close(watcher: "a")])
        XCTAssertEqual(w.decided("a", tracks: ["screen-1"], reason: ""), [])
    }

    func testASecondWatcherAndTheFifthIsRefused() {
        var w = LiveWatchers()
        connect(&w, "a", at: t0)
        connect(&w, "b", at: t0)
        XCTAssertEqual(w.watches.map(\.phase), [.connected, .connected])
        _ = w.want(from: "c", who: "c", now: t0)
        _ = w.want(from: "d", who: "d", now: t0)
        XCTAssertEqual(w.want(from: "e", who: "e", now: t0), [.send(.bye(to: "e", reason: "too many watchers (4)"))])
        XCTAssertEqual(w.watches.map(\.id), ["a", "b", "c", "d"])
        // one leaves: the next one may watch
        _ = w.end("c", why: "the watcher left", tell: false, now: t0)
        XCTAssertEqual(w.want(from: "e", who: "e", now: t0), [.decide(watcher: "e", who: "e")])
    }

    func testAskingAgainEndsTheWatchBefore() {
        var w = LiveWatchers()
        connect(&w, "a", at: t0)
        XCTAssertEqual(
            w.want(from: "a", who: "a@example.com", now: t0.addingTimeInterval(5)),
            [.close(watcher: "a"), .ended(watcher: "a", who: "a@example.com", seconds: 5, why: "asked again"), .decide(watcher: "a", who: "a@example.com")])
        XCTAssertEqual(w.watch("a")?.phase, .deciding)
    }

    func testTheDeviceEndsEveryWatchAndSaysBye() {
        var w = LiveWatchers()
        connect(&w, "a", at: t0)
        _ = w.want(from: "b", who: "b", now: t0)
        XCTAssertEqual(
            w.endAll(why: "the device stopped", now: t0.addingTimeInterval(10)),
            [
                .close(watcher: "a"), .send(.bye(to: "a", reason: "the device stopped")),
                .ended(watcher: "a", who: "a@example.com", seconds: 10, why: "the device stopped"),
                .close(watcher: "b"), .send(.bye(to: "b", reason: "the device stopped")),
            ])
        XCTAssertEqual(w.tracks, [])
    }

    func testSignalsOfAStrangerChangeNothing() {
        var w = LiveWatchers()
        XCTAssertEqual(w.answer(from: "x", sdp: "answer"), [])
        XCTAssertEqual(w.candidate(from: "x", c(1)), [])
        XCTAssertEqual(w.connected("x", now: t0), [])
        XCTAssertEqual(w.deviceCandidate("x", c(1)), [])
        XCTAssertEqual(w.watches, [])
    }
}
