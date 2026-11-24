import XCTest

@testable import VoiceMeetCore

final class WordListTests: XCTestCase {
    private let list = WordList(markdown: """
        # Words

        One term per list item.

            - <term>: <wrong form>, <wrong form>

        ## People

        - iterate: itrade, hiterate
        - Templestein: temple stein, temple steen
        - Claude: clod, claud
        - Claude Code: clod code
        - itx: i t x, it x
        - AGENTS.md: agents dot md
        - Claude: clawed
        """)

    func testTheListItemsAreTheEntriesAndTheExampleIsNot() {
        XCTAssertEqual(list.entries.map(\.term), ["iterate", "Templestein", "Claude", "Claude Code", "itx", "AGENTS.md"])
        XCTAssertEqual(list.entries[2].wrong, ["clod", "claud", "clawed"])
        XCTAssertEqual(list.entries[4].wrong, ["i t x", "it x"])
    }

    func testAWrongFormBecomesItsTermAsAWholeWord() {
        XCTAssertEqual(list.repair("Ask Temple  Stein about itrade."), "Ask Templestein about iterate.")
        // inside a longer word nothing changes
        XCTAssertEqual(list.repair("The clodhopper reiterated it."), "The clodhopper reiterated it.")
    }

    func testATermInAnotherCaseIsWrittenAsTheTerm() {
        XCTAssertEqual(list.repair("Iterate uses ITX and agents.md"), "iterate uses itx and AGENTS.md")
    }

    func testTheLongestFormWins() {
        XCTAssertEqual(list.repair("clod code and clod"), "Claude Code and Claude")
    }

    func testAnEmptyListChangesNothing() {
        XCTAssertEqual(WordList.empty.repair("clod code"), "clod code")
        XCTAssertEqual(WordList(markdown: "no list here").entries, [])
    }
}

final class SpeechStretchTests: XCTestCase {
    private func sound(_ seconds: Double, level: Float) -> [Float] {
        (0..<Int(seconds * Double(SpeechStretch.rate))).map { $0 % 2 == 0 ? level : -level }
    }

    func testAStretchGoesOnWhileThePersonTalks() {
        var stretch = SpeechStretch()
        stretch.append(sound(5, level: 0.2))
        XCTAssertNil(stretch.end)
        XCTAssertEqual(stretch.seconds, 5, accuracy: 0.01)
    }

    func testAPauseEndsIt() {
        var stretch = SpeechStretch()
        stretch.append(sound(3, level: 0.2))
        stretch.append(sound(0.4, level: 0.001))
        XCTAssertNil(stretch.end)
        stretch.append(sound(0.4, level: 0.001))
        XCTAssertEqual(stretch.end, stretch.samples.count)
    }

    func testAShortStretchWaitsForMoreAndARoomWithNoSpeechHasNoPause() {
        var short = SpeechStretch()
        short.append(sound(0.5, level: 0.2))
        short.append(sound(1, level: 0.001))
        XCTAssertNil(short.end)
        var room = SpeechStretch()
        room.append(sound(6, level: 0.004))
        XCTAssertNil(room.end)
    }

    func testALongStretchIsCutAtItsQuietestMomentAndTheRestStartsTheNext() {
        var stretch = SpeechStretch()
        stretch.append(sound(12, level: 0.2))
        stretch.append(sound(0.1, level: 0.05))
        stretch.append(sound(2, level: 0.2))
        let end = stretch.end
        XCTAssertEqual(Double(end ?? 0) / Double(SpeechStretch.rate), 12, accuracy: 0.05)
        stretch.removeFirst(end ?? 0)
        XCTAssertEqual(stretch.seconds, 2.1, accuracy: 0.05)
        XCTAssertNil(stretch.end)
    }
}

final class SpokenTests: XCTestCase {
    func testTwoPiecesJoinWithOneSpace() {
        XCTAssertEqual(Spoken.join("Hello there. ", " And more"), "Hello there. And more")
        XCTAssertEqual(Spoken.join("", "And more"), "And more")
        XCTAssertEqual(Spoken.join("Hello", "  "), "Hello")
    }

    func testTheWordsAfterTheOnesThePersonTook() {
        XCTAssertEqual(Spoken.wordCount("open the  roadmap"), 3)
        XCTAssertEqual(Spoken.rest(of: "open the roadmap and tell Misha", afterWords: 3), "and tell Misha")
        XCTAssertEqual(Spoken.rest(of: "open the", afterWords: 3), "")
    }

    func testSpokenWordsGetASpaceWhereTwoWordsWouldTouch() {
        XCTAssertEqual(Spoken.fitted("and more", after: "d", before: nil), " and more")
        XCTAssertEqual(Spoken.fitted("and more", after: " ", before: "x"), "and more ")
        XCTAssertEqual(Spoken.fitted("and more", after: nil, before: "."), "and more")
        XCTAssertEqual(Spoken.fitted("", after: "d", before: "x"), "")
    }
}

final class DictationKeyTests: XCTestCase {
    private let start = Date(timeIntervalSince1970: 1_795_000_000)

    func testHoldTalkAndLetGo() {
        var key = DictationKey()
        XCTAssertEqual(key.pressed(at: start), .start)
        XCTAssertEqual(key.released(at: start.addingTimeInterval(2)), .finish)
        XCTAssertFalse(key.isOn)
    }

    func testATapGoesOnUntilTheNextPress() {
        var key = DictationKey()
        XCTAssertEqual(key.pressed(at: start), .start)
        XCTAssertEqual(key.released(at: start.addingTimeInterval(0.1)), .nothing)
        XCTAssertTrue(key.isOn)
        XCTAssertEqual(key.pressed(at: start.addingTimeInterval(20)), .finish)
        XCTAssertEqual(key.released(at: start.addingTimeInterval(20.1)), .nothing)
        XCTAssertFalse(key.isOn)
    }

    func testADictationThatEndedByItselfTakesNoRelease() {
        var key = DictationKey()
        _ = key.pressed(at: start)
        key.ended()
        XCTAssertEqual(key.released(at: start.addingTimeInterval(3)), .nothing)
        XCTAssertEqual(key.pressed(at: start.addingTimeInterval(4)), .start)
    }
}

final class SpokenTextTests: XCTestCase {
    func testSpokenWordsComeAfterWhatWasTyped() {
        var text = SpokenText(base: "For Misha:")
        text.heard("open the")
        XCTAssertEqual(text.text, "For Misha: open the")
        // the model hears more and changes its mind about the words
        text.heard("Open the roadmap.")
        XCTAssertEqual(text.text, "For Misha: Open the roadmap.")
    }

    func testAfterAChangeByHandOnlyLaterWordsComeIn() {
        var text = SpokenText(base: "")
        text.heard("open the road map")
        text.edited("Open the roadmap")
        XCTAssertEqual(text.text, "Open the roadmap")
        text.heard("open the road map and tell Misha")
        XCTAssertEqual(text.text, "Open the roadmap and tell Misha")
    }
}
