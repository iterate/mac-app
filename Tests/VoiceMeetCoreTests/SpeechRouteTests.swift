import VoiceMeetCore
import XCTest

/// The one rule that picks who hears every use, and when the local model loads (README, "Listening").
final class SpeechRouteTests: XCTestCase {
    private func pick(_ choice: SpeechRoute.Choice = .automatic, up: Bool = true, mind: MindOpenAI? = nil, key: Bool = false) -> SpeechRoute {
        SpeechRoute.pick(choice: choice, isNetworkUp: up, mind: mind, hasKey: key)
    }

    func testOpenAIHearsWhenItCanBeReached() {
        XCTAssertEqual(pick(mind: .yes), SpeechRoute(.openAI, .reachable))
        XCTAssertEqual(pick(key: true), SpeechRoute(.openAI, .reachable), "this Mac's own key")
        XCTAssertEqual(pick(mind: .unknown), SpeechRoute(.openAI, .reachable), "a mind not asked yet is tried, as OpenAIAccess opens it")
        XCTAssertEqual(pick(.openAI, mind: .yes), SpeechRoute(.openAI, .reachable))
    }

    func testTheLocalModelHearsWhenOpenAICannotBeReached() {
        XCTAssertEqual(pick(up: false, mind: .yes, key: true), SpeechRoute(.local, .offline), "the network is down")
        XCTAssertEqual(pick(mind: .no), SpeechRoute(.local, .noOpenAI), "the mind refused, and no key")
        XCTAssertEqual(pick(mind: .no, key: true), SpeechRoute(.openAI, .reachable), "the mind refused: the own key")
        XCTAssertEqual(pick(), SpeechRoute(.local, .noOpenAI), "lent to no mind, and no key")
        XCTAssertEqual(pick(.openAI, up: false, key: true), SpeechRoute(.local, .offline), "OpenAI chosen, offline: the local model must hear")
    }

    func testThePersonsChoiceOverridesTheRuleForEveryUse() {
        XCTAssertEqual(pick(.onThisMac, mind: .yes, key: true), SpeechRoute(.local, .chosen))
        XCTAssertEqual(pick(.onThisMac, up: false), SpeechRoute(.local, .chosen))
    }

    func testTheLocalModelLoadsAtOnceWhenTheRulePicksIt() {
        let offline = SpeechRoute(.local, .offline)
        XCTAssertEqual(LocalModelLife.step(route: offline, isLoaded: false, users: 0, idle: 0, limit: 300), .load("the network is down"))
        XCTAssertEqual(LocalModelLife.step(route: offline, isLoaded: true, users: 0, idle: 900, limit: 300), .stay, "needed: it stays, however long unused")
        XCTAssertEqual(
            LocalModelLife.step(route: SpeechRoute(.local, .chosen), isLoaded: false, users: 0, idle: 0, limit: 300), .load("\"On this Mac\" is chosen"))
    }

    func testOnANormalDayOnlineItIsNeverLoaded() {
        XCTAssertEqual(LocalModelLife.step(route: SpeechRoute(.openAI, .reachable), isLoaded: false, users: 0, idle: 9999, limit: 300), .stay)
    }

    func testItIsUnloadedAfterTheIdleTimeOnceOpenAIIsBackAndNothingUsesIt() {
        let online = SpeechRoute(.openAI, .reachable)
        XCTAssertEqual(LocalModelLife.step(route: online, isLoaded: true, users: 0, idle: 120, limit: 300), .check(after: 180))
        guard case .unload(let why) = LocalModelLife.step(route: online, isLoaded: true, users: 0, idle: 300, limit: 300) else {
            return XCTFail("not unloaded")
        }
        XCTAssertTrue(why.contains("unused for 300 s"), why)
        // a stretch that it hears now (OpenAI failed in it) keeps it, however long ago it began
        XCTAssertEqual(LocalModelLife.step(route: online, isLoaded: true, users: 1, idle: 900, limit: 300), .stay)
    }
}
