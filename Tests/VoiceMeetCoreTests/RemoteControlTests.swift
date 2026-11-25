import XCTest

@testable import VoiceMeetCore

final class RemoteControlTests: XCTestCase {
    /// A Retina display at the default size: 1512 × 982 points, 3024 × 1964 pixels.
    private let laptop = ControlDisplay(id: 1, x: 0, y: 0, width: 1512, height: 982, pixelWidth: 3024, pixelHeight: 1964)
    /// A second display at 1×, to the left of the main one and higher.
    private let left = ControlDisplay(id: 2, x: -1920, y: -200, width: 1920, height: 1080, pixelWidth: 1920, pixelHeight: 1080)
    private let start = Date(timeIntervalSince1970: 1_800_000_000)

    // MARK: - Keys

    func testKeyCodesArePhysicalKeysOfmacOS() {
        XCTAssertEqual(ControlKeys.codes["KeyA"], 0x00)
        XCTAssertEqual(ControlKeys.codes["KeyZ"], 0x06)
        XCTAssertEqual(ControlKeys.codes["KeyQ"], 0x0C)
        XCTAssertEqual(ControlKeys.codes["Digit0"], 0x1D)
        XCTAssertEqual(ControlKeys.codes["Enter"], 0x24)
        XCTAssertEqual(ControlKeys.codes["Backspace"], 0x33)
        XCTAssertEqual(ControlKeys.codes["Delete"], 0x75)
        XCTAssertEqual(ControlKeys.codes["Escape"], 0x35)
        XCTAssertEqual(ControlKeys.codes["MetaLeft"], 0x37)
        XCTAssertEqual(ControlKeys.codes["MetaRight"], 0x36)
        XCTAssertEqual(ControlKeys.codes["ArrowLeft"], 0x7B)
        XCTAssertEqual(ControlKeys.codes["ArrowUp"], 0x7E)
        XCTAssertEqual(ControlKeys.codes["F1"], 0x7A)
        XCTAssertEqual(ControlKeys.codes["F12"], 0x6F)
        XCTAssertEqual(ControlKeys.codes["F20"], 0x5A)
        XCTAssertEqual(ControlKeys.codes["Numpad5"], 0x57)
        XCTAssertEqual(ControlKeys.codes["IntlBackslash"], 0x0A)
    }

    func testEveryLetterAndDigitHasItsOwnCode() {
        let names = "ABCDEFGHIJKLMNOPQRSTUVWXYZ".map { "Key\($0)" } + (0...9).map { "Digit\($0)" }
        let codes = names.compactMap { ControlKeys.codes[$0] }
        XCTAssertEqual(codes.count, 36)
        XCTAssertEqual(Set(codes).count, 36)
    }

    func testModifierKeysAreModifiers() {
        XCTAssertEqual(ControlKeys.modifier(of: 0x37), .command)
        XCTAssertEqual(ControlKeys.modifier(of: 0x3C), .shift)
        XCTAssertEqual(ControlKeys.modifier(of: 0x3D), .option)
        XCTAssertEqual(ControlKeys.modifier(of: 0x3B), .control)
        XCTAssertNil(ControlKeys.modifier(of: 0x00))
    }

    // MARK: - Coordinates

    func testCornersAndCentreOfARetinaDisplay() {
        XCTAssertEqual(laptop.scale, 2)
        XCTAssertEqual(laptop.point(0, 0).x, 0)
        XCTAssertEqual(laptop.point(0.5, 0.5).x, 756)
        XCTAssertEqual(laptop.point(0.5, 0.5).y, 491)
        // the right and bottom edges are the last pixel: half a point on Retina
        XCTAssertEqual(laptop.point(1, 1).x, 1511.5)
        XCTAssertEqual(laptop.point(1, 1).y, 981.5)
    }

    func testASecondDisplayAtNegativeCoordinates() {
        XCTAssertEqual(left.scale, 1)
        XCTAssertEqual(left.point(0, 0).x, -1920)
        XCTAssertEqual(left.point(0, 0).y, -200)
        XCTAssertEqual(left.point(1, 1).x, -1)
        XCTAssertEqual(left.point(1, 1).y, 879)
        XCTAssertEqual(left.point(0.25, 0.5).x, -1440)
    }

    func testPointsOutsideAreHeldOnTheDisplay() {
        XCTAssertEqual(left.point(-3, 2).x, -1920)
        XCTAssertEqual(left.point(-3, 2).y, 879)
        XCTAssertEqual(laptop.point(1.4, -0.1).x, 1511.5)
    }

    func testAScaledModeHasItsOwnScale() {
        // "More Space" on a 14-inch: 1800 × 1169 points on 3024 × 1964 pixels
        let more = ControlDisplay(id: 3, x: 0, y: 0, width: 1800, height: 1169, pixelWidth: 3024, pixelHeight: 1964)
        XCTAssertEqual(more.scale, 1.68, accuracy: 0.001)
        XCTAssertEqual(more.point(0.5, 0).x, 900)
        XCTAssertEqual(more.dictionary["pointWidth"] as? Double, 1800)
        XCTAssertEqual(more.dictionary["pixelWidth"] as? Int, 3024)
    }

    // MARK: - Events

    func testEventsParseFromJSON() throws {
        let json = #"[{"t":"move","x":0.5,"y":1},{"t":"down","x":0,"y":0,"button":2},{"t":"key","code":"KeyC","down":true,"mods":["meta"]},{"t":"scroll","dy":120},{"t":"text","text":"hé"}]"#
        let list = try JSONSerialization.jsonObject(with: Data(json.utf8)) as! [Any]
        let events = try list.map(ControlEvent.parse)
        XCTAssertEqual(events[0], .move(x: 0.5, y: 1))
        XCTAssertEqual(events[1], .button(x: 0, y: 0, button: .right, down: true, clicks: nil, mods: []))
        XCTAssertEqual(events[2], .key(code: 0x08, down: true, mods: .command))
        XCTAssertEqual(events[3], .scroll(dx: 0, dy: 120))
        XCTAssertEqual(events[4], .text("hé"))
    }

    func testBadEventsSayWhy() {
        let bad: [[String: Any]] = [
            ["t": "move", "x": 0.5], ["t": "key", "code": "Hyper", "down": true], ["t": "down", "x": 0, "y": 0, "button": 7],
            ["t": "key", "code": "KeyA", "down": true, "mods": ["super"]], ["t": "jump"], ["t": "move", "x": Double.nan, "y": 0],
            ["t": "text", "text": String(repeating: "a", count: 2_001)],
        ]
        for event in bad {
            XCTAssertThrowsError(try ControlEvent.parse(event), "\(event)")
        }
    }

    func testConsecutiveMovesAreTheLast() {
        let events: [ControlEvent] = [
            .move(x: 0.1, y: 0.1), .move(x: 0.2, y: 0.2), .button(x: 0.2, y: 0.2, button: .left, down: true, clicks: nil, mods: []),
            .move(x: 0.3, y: 0.3), .move(x: 0.4, y: 0.4), .move(x: 0.5, y: 0.5),
        ]
        XCTAssertEqual(
            ControlEvent.coalesce(events),
            [.move(x: 0.2, y: 0.2), .button(x: 0.2, y: 0.2, button: .left, down: true, clicks: nil, mods: []), .move(x: 0.5, y: 0.5)])
    }

    func testTextIsTypedInChunksAndLinesArePressedReturns() {
        let actions = ControlAction.typing("abcdefghijklmnopqrstuvwxyz\nok 👍🏽")
        XCTAssertEqual(actions[0], .text("abcdefghijklmnopqrst"))
        XCTAssertEqual(actions[1], .text("uvwxyz"))
        XCTAssertEqual(actions[2], .key(code: 0x24, down: true, mods: [], isModifier: false))
        XCTAssertEqual(actions[3], .key(code: 0x24, down: false, mods: [], isModifier: false))
        XCTAssertEqual(actions[4], .text("ok 👍🏽"))
        // a character of several UTF-16 units is never cut
        let emoji = ControlAction.typing(String(repeating: "👍🏽", count: 6))
        XCTAssertEqual(emoji, [.text(String(repeating: "👍🏽", count: 5)), .text("👍🏽")])
    }

    // MARK: - Sessions

    private func session(_ table: inout ControlSessions, display: ControlDisplay? = nil) throws -> String {
        try table.start(who: "Misha", display: display ?? laptop, now: start, id: "s1").id
    }

    func testABatchMapsCoalescesAndCountsClicks() throws {
        var table = ControlSessions()
        let id = try session(&table)
        let result = table.input(
            id,
            events: [
                ["t": "move", "x": 0.1, "y": 0.1], ["t": "move", "x": 0.5, "y": 0.5],
                ["t": "down", "x": 0.5, "y": 0.5, "button": 0], ["t": "up", "x": 0.5, "y": 0.5, "button": 0],
                ["t": "down", "x": 0.5, "y": 0.5, "button": 0], ["t": "up", "x": 0.5, "y": 0.5, "button": 0],
            ], now: start.addingTimeInterval(1), isSecret: { false })!
        XCTAssertEqual(result.applied, 6)
        XCTAssertFalse(result.paused)
        XCTAssertEqual(
            result.actions,
            [
                .move(x: 756, y: 491, dragging: nil),
                .button(x: 756, y: 491, button: .left, down: true, clicks: 1, mods: []),
                .button(x: 756, y: 491, button: .left, down: false, clicks: 1, mods: []),
                .button(x: 756, y: 491, button: .left, down: true, clicks: 2, mods: []),
                .button(x: 756, y: 491, button: .left, down: false, clicks: 2, mods: []),
            ])
    }

    func testADownLaterOrFartherIsASingleClick() throws {
        var clicks = ControlClicks()
        XCTAssertEqual(clicks.down(.left, x: 10, y: 10, at: start, interval: 0.5), 1)
        XCTAssertEqual(clicks.down(.left, x: 12, y: 10, at: start.addingTimeInterval(0.2), interval: 0.5), 2)
        XCTAssertEqual(clicks.down(.left, x: 12, y: 10, at: start.addingTimeInterval(0.4), interval: 0.5), 3)
        XCTAssertEqual(clicks.down(.left, x: 12, y: 10, at: start.addingTimeInterval(1.2), interval: 0.5), 1)
        XCTAssertEqual(clicks.down(.left, x: 40, y: 10, at: start.addingTimeInterval(1.3), interval: 0.5), 1)
        XCTAssertEqual(clicks.down(.right, x: 40, y: 10, at: start.addingTimeInterval(1.4), interval: 0.5), 1)
        XCTAssertEqual(clicks.up(.right), 1)
    }

    func testAMoveWithAButtonDownIsADrag() throws {
        var table = ControlSessions()
        let id = try session(&table, display: left)
        let result = table.input(
            id, events: [["t": "down", "x": 0, "y": 0], ["t": "move", "x": 0.5, "y": 0.5], ["t": "up", "x": 0.5, "y": 0.5]], now: start,
            isSecret: { false })!
        XCTAssertEqual(result.actions[1], .move(x: -960, y: 340, dragging: .left))
        XCTAssertEqual(table.session(id)?.buttons, [])
    }

    func testHeldModifierKeysGoWithTheKeys() throws {
        var table = ControlSessions()
        let id = try session(&table)
        let result = table.input(
            id,
            events: [
                ["t": "key", "code": "MetaLeft", "down": true], ["t": "key", "code": "KeyC", "down": true],
                ["t": "key", "code": "KeyC", "down": false], ["t": "key", "code": "MetaLeft", "down": false],
            ], now: start, isSecret: { false })!
        XCTAssertEqual(
            result.actions,
            [
                .key(code: 0x37, down: true, mods: .command, isModifier: true),
                .key(code: 0x08, down: true, mods: .command, isModifier: false),
                .key(code: 0x08, down: false, mods: .command, isModifier: false),
                .key(code: 0x37, down: false, mods: [], isModifier: true),
            ])
    }

    func testTheOwnerPausesEverySessionForASecondAndLetsGoOfWhatItHolds() throws {
        var table = ControlSessions()
        let id = try session(&table)
        _ = table.input(id, events: [["t": "down", "x": 0.5, "y": 0.5], ["t": "key", "code": "ShiftLeft", "down": true]], now: start, isSecret: { false })
        let releases = table.ownerActed(at: start.addingTimeInterval(0.1))
        XCTAssertEqual(
            releases,
            [
                .button(x: 756, y: 491, button: .left, down: false, clicks: 1, mods: []),
                .key(code: 0x38, down: false, mods: [], isModifier: true),
            ])
        // the owner goes on: nothing more to let go of
        XCTAssertEqual(table.ownerActed(at: start.addingTimeInterval(0.2)), [])
        let paused = table.input(id, events: [["t": "move", "x": 0.2, "y": 0.2], ["t": "text", "text": "hi"]], now: start.addingTimeInterval(1.1), isSecret: { false })!
        XCTAssertTrue(paused.paused)
        XCTAssertEqual(paused.applied, 0)
        XCTAssertEqual(paused.actions, [])
        let after = table.input(id, events: [["t": "move", "x": 0.2, "y": 0.2]], now: start.addingTimeInterval(1.21), isSecret: { false })!
        XCTAssertFalse(after.paused)
        XCTAssertEqual(after.applied, 1)
    }

    func testAnUpAfterTheOwnersLetGoIsDroppedWhilePaused() throws {
        var table = ControlSessions()
        let id = try session(&table)
        _ = table.input(id, events: [["t": "down", "x": 0.5, "y": 0.5, "button": 2]], now: start, isSecret: { false })
        XCTAssertEqual(table.ownerActed(at: start.addingTimeInterval(0.1)).count, 1)
        let result = table.input(id, events: [["t": "up", "x": 0.5, "y": 0.5, "button": 2]], now: start.addingTimeInterval(0.2), isSecret: { false })!
        XCTAssertEqual(result.actions, [])
        XCTAssertTrue(result.paused)
    }

    func testAPasswordWithholdsKeysAndTextButNotTheMouse() throws {
        var table = ControlSessions()
        let id = try session(&table)
        var asked = 0
        let result = table.input(
            id,
            events: [
                ["t": "text", "text": "hunter2"], ["t": "key", "code": "Enter", "down": true], ["t": "key", "code": "Enter", "down": false],
                ["t": "move", "x": 0.5, "y": 0.5],
            ], now: start,
            isSecret: {
                asked += 1
                return true
            })!
        XCTAssertEqual(asked, 1, "asked once for the batch")
        XCTAssertEqual(result.withheld, 3)
        XCTAssertEqual(result.applied, 1)
        XCTAssertEqual(result.actions, [.move(x: 756, y: 491, dragging: nil)])
        XCTAssertEqual(result.dictionary["withheld"] as? Int, 3)
    }

    func testAKeyHeldBeforeThePasswordComesUpInIt() throws {
        var table = ControlSessions()
        let id = try session(&table)
        _ = table.input(id, events: [["t": "key", "code": "ShiftLeft", "down": true]], now: start, isSecret: { false })
        let result = table.input(id, events: [["t": "key", "code": "ShiftLeft", "down": false]], now: start, isSecret: { true })!
        XCTAssertEqual(result.withheld, 0)
        XCTAssertEqual(result.actions, [.key(code: 0x38, down: false, mods: [], isModifier: true)])
    }

    func testABadEventIsSkippedAndTheRestGo() throws {
        var table = ControlSessions()
        let id = try session(&table)
        let result = table.input(id, events: [["t": "key", "code": "Hyper", "down": true], ["t": "scroll", "dx": 3, "dy": -40]], now: start, isSecret: { false })!
        XCTAssertEqual(result.skipped, 1)
        XCTAssertEqual(result.problem, "no key \"Hyper\" on this Mac")
        XCTAssertEqual(result.actions, [.scroll(dx: 3, dy: -40)])
    }

    func testASessionWithNoInputEndsAfter30sAndLetsGo() throws {
        var table = ControlSessions()
        let id = try session(&table)
        _ = table.input(id, events: [["t": "key", "code": "KeyA", "down": true]], now: start.addingTimeInterval(5), isSecret: { false })
        XCTAssertEqual(table.idle(now: start.addingTimeInterval(34)), [])
        table.touch(id, now: start.addingTimeInterval(20))
        XCTAssertEqual(table.idle(now: start.addingTimeInterval(49)), [])
        XCTAssertEqual(table.idle(now: start.addingTimeInterval(50)), [id])
        let ended = table.end(id)
        XCTAssertEqual(ended?.releases, [.key(code: 0x00, down: false, mods: [], isModifier: false)])
        XCTAssertTrue(table.isEmpty)
        XCTAssertNil(table.input(id, events: [], now: start, isSecret: { false }))
        XCTAssertNil(table.end(id))
    }

    func testAtMostFourSessions() throws {
        var table = ControlSessions()
        for index in 0..<4 { _ = try table.start(who: "p\(index)", display: laptop, now: start) }
        XCTAssertThrowsError(try table.start(who: "p4", display: laptop, now: start))
    }

    func testTheDisplayIsReadAgainAtEachBatch() throws {
        var table = ControlSessions()
        let id = try session(&table)
        let wider = ControlDisplay(id: 1, x: 0, y: 0, width: 1800, height: 1169, pixelWidth: 3024, pixelHeight: 1964)
        let result = table.input(id, events: [["t": "move", "x": 0.5, "y": 0]], display: wider, now: start, isSecret: { false })!
        XCTAssertEqual(result.actions, [.move(x: 900, y: 0, dragging: nil)])
    }

    // MARK: - Clipboard

    func testAConcealedClipboardGoesToNoCaller() {
        let answer = ControlClipboard.answer(text: "hunter2", types: ["public.utf8-plain-text", "org.nspasteboard.ConcealedType"])
        XCTAssertTrue(answer["text"] is NSNull)
        XCTAssertNotNil(answer["withheld"])
        XCTAssertEqual(ControlClipboard.answer(text: "hello", types: ["public.utf8-plain-text"])["text"] as? String, "hello")
    }

    func testALargeClipboardIsCutAtACharacter() {
        let text = String(repeating: "é", count: 600_000)  // 1.2 MB of UTF-8
        let answer = ControlClipboard.answer(text: text, types: [])
        let cut = answer["text"] as! String
        XCTAssertEqual(answer["truncated"] as? Bool, true)
        XCTAssertLessThanOrEqual(cut.utf8.count, ControlClipboard.maxBytes)
        XCTAssertEqual(cut.utf8.count, 1_000_000)
        XCTAssertFalse(cut.contains("\u{FFFD}"))
        let odd = String(repeating: "é", count: 499_999) + "ab" + String(repeating: "é", count: 10)
        let oddCut = ControlClipboard.answer(text: odd, types: [])["text"] as! String
        XCTAssertFalse(oddCut.hasSuffix("\u{FFFD}"))
    }

    // MARK: - Latency, with a fake poster

    /// The app's part of the time from `control.input` arriving to its events posted: parse, map,
    /// coalesce, decide, and post to a poster that only keeps the time. The number goes to the log.
    func testTheTimeFromABatchToItsEventsPostedWithAFakePoster() throws {
        var table = ControlSessions()
        let id = try session(&table)
        // a typical batch of a page at 60 batches a second: some moves, a click, a key
        let json = #"[{"t":"move","x":0.41,"y":0.52},{"t":"move","x":0.42,"y":0.53},{"t":"move","x":0.43,"y":0.54},{"t":"down","x":0.43,"y":0.54,"button":0},{"t":"up","x":0.43,"y":0.54,"button":0},{"t":"key","code":"KeyA","down":true},{"t":"key","code":"KeyA","down":false},{"t":"text","text":"hello"}]"#
        var latency = ControlLatency()
        var firstPosted: UInt64 = 0
        var posted = 0
        for round in 0..<2_000 {
            let arrived = DispatchTime.now().uptimeNanoseconds
            // the app gets the parameters as JSON on its socket
            let events = (try JSONSerialization.jsonObject(with: Data(json.utf8)) as! [Any])
            let result = table.input(id, events: events, now: start.addingTimeInterval(Double(round) * 0.016), isSecret: { false })!
            for _ in result.actions {
                posted += 1  // the fake poster
                if firstPosted == 0 { firstPosted = DispatchTime.now().uptimeNanoseconds - arrived }
            }
            latency.add(nanoseconds: DispatchTime.now().uptimeNanoseconds - arrived, events: result.actions.count)
        }
        print("control latency with a fake poster: \(latency.line)")
        XCTAssertEqual(latency.batches, 2_000)
        XCTAssertGreaterThan(posted, 0)
        // the budget for the app's part: well under a millisecond on average
        XCTAssertLessThan(latency.totalNanoseconds / UInt64(latency.batches), 1_000_000)
    }
}
