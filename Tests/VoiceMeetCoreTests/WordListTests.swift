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

    // MARK: - Separators

    /// The owner's list (25 November 2026): b-link must always be Beelink.
    private let beelink = WordList(markdown: "- Beelink: b-link, be link, bee link, b link\n- Claude Code: clod code\n")

    func testAnyRunOfSeparatorsMatchesAnyOther() {
        for heard in ["b-link", "b link", "B\u{2011}Link", "b - link", "b\u{2013}link", "b \u{2014} link", "b\u{2212}link", "b_link", "b\u{2010}link", "B  LINK", "b\tlink"] {
            XCTAssertEqual(beelink.repair("on the \(heard) box"), "on the Beelink box", heard)
        }
        XCTAssertEqual(beelink.repair("bee-link and bee_link and be\u{2015}link"), "Beelink and Beelink and Beelink")
        // a form with a hyphen catches the same words with a space
        let hyphen = WordList(markdown: "- Beelink: b-link\n")
        XCTAssertEqual(hyphen.repair("the b link box"), "the Beelink box")
        // a term with a space is written with its own space
        XCTAssertEqual(beelink.repair("clod-code and Claude-Code"), "Claude Code and Claude Code")
    }

    func testTheFullStopIsNoSeparator() {
        XCTAssertEqual(beelink.repair("I said b. Link the box."), "I said b. Link the box.")
        XCTAssertEqual(beelink.repair("b.link"), "b.link")
        // a form's own dot is matched as a dot
        XCTAssertEqual(list.repair("agents dot md and AGENTS-md"), "AGENTS.md and AGENTS-md")
    }

    func testPunctuationAfterTheWordStays() {
        XCTAssertEqual(beelink.repair("b-link, bee link. (b link) \"be link\"! b-link?"), "Beelink, Beelink. (Beelink) \"Beelink\"! Beelink?")
    }

    func testATermInAnotherCaseIsRepairedWithSeparators() {
        XCTAssertEqual(beelink.repair("BEELINK and beelink"), "Beelink and Beelink")
    }

    func testNoFalseHits() {
        // inside a longer word, a word that is not listed, a part of a form alone
        XCTAssertEqual(beelink.repair("blinking lights"), "blinking lights")
        XCTAssertEqual(beelink.repair("the lights blink"), "the lights blink")
        XCTAssertEqual(beelink.repair("the b is here, a link too"), "the b is here, a link too")
        XCTAssertEqual(beelink.repair("ab-link and b-links and b-link2"), "ab-link and b-links and b-link2")
        XCTAssertEqual(beelink.repair("b-"), "b-")
        XCTAssertEqual(beelink.repair("b- -link"), "Beelink", "a run of separators is one separator")
    }

    func testTheLongestFormWinsWithSeparators() {
        let list = WordList(markdown: "- Claude: clod\n- Claude Code: clod code\n")
        XCTAssertEqual(list.repair("clod-code then clod"), "Claude Code then Claude")
    }

    func testAFormOfSeparatorsAloneIsNoForm() {
        let list = WordList(markdown: "- Beelink: -, b-link, ‐ \n")
        XCTAssertEqual(list.repair("a - b and b-link"), "a - b and Beelink")
    }

    // MARK: - Corrections

    func testCorrectionsSayWhereWhatWasHeardAndTheTerm() {
        let text = "Ask b-link, Beelink and BEELINK."
        let corrections = beelink.corrections(in: text)
        XCTAssertEqual(corrections.map(\.heard), ["b-link", "BEELINK"], "the term in its own case is no correction")
        XCTAssertEqual(corrections.map(\.term), ["Beelink", "Beelink"])
        XCTAssertEqual(corrections.map { String(text[$0.range]) }, ["b-link", "BEELINK"])
        XCTAssertEqual(WordCorrection.apply(corrections, to: text), "Ask Beelink, Beelink and Beelink.")
        XCTAssertEqual(beelink.repair(text), WordCorrection.apply(corrections, to: text))
        XCTAssertEqual(beelink.corrections(in: "nothing here"), [])
        XCTAssertEqual(WordList.empty.corrections(in: "b-link"), [])
    }

    func testCorrectionsKeepTheirPlaceAfterAnEmoji() {
        let text = "👋🏽 é b link"
        let corrections = beelink.corrections(in: text)
        XCTAssertEqual(corrections.map { String(text[$0.range]) }, ["b link"])
        XCTAssertEqual(beelink.repair(text), "👋🏽 é Beelink")
    }

    func testHeardTextJoinsItsPiecesAndTheirCorrections() {
        let first = HeardText("  restart b-link ", words: beelink)
        let second = HeardText("then bee link 👋 b link", words: beelink)
        XCTAssertEqual(first.heard, "restart b-link")
        let both = HeardText.join(first, second)
        XCTAssertEqual(both.heard, "restart b-link then bee link 👋 b link")
        XCTAssertEqual(both.text, "restart Beelink then Beelink 👋 Beelink")
        XCTAssertEqual(both.corrections.map { String(both.heard[$0.range]) }, ["b-link", "bee link", "b link"])
        XCTAssertEqual(both.text, Spoken.join(first.text, second.text))
        XCTAssertEqual(HeardText.join(.empty, second), second)
        XCTAssertEqual(HeardText.join(first, HeardText(" ", words: beelink)), first)
    }

    func testAFormIsNotMatchedAcrossTwoPieces() {
        // two stretches of speech are repaired each alone, as the written text is
        let both = HeardText.join(HeardText("the b", words: beelink), HeardText("link box", words: beelink))
        XCTAssertEqual(both.text, "the b link box")
        XCTAssertEqual(both.corrections, [])
    }
}
