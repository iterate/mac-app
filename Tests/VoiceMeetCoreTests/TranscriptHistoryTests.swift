import Foundation
import XCTest

@testable import VoiceMeetCore

final class TranscriptHistoryTests: XCTestCase {
    let now = 1_800_000_000.0

    func entry(_ text: String, at: Double, kind: TranscriptEntry.Kind = .dictation, outcome: TranscriptEntry.Outcome = .written, id: String? = nil)
        -> TranscriptEntry
    {
        TranscriptEntry(id: id ?? UUID().uuidString, kind: kind, outcome: outcome, at: at, text: text, app: "Notes", bundle: "com.apple.Notes", model: "parakeet-v3", seconds: 2.34)
    }

    func testAnEntryGoesInInTimeOrderAndItsLineReadsBack() {
        var history = TranscriptHistory()
        history.add(entry("second", at: now - 10), now: now)
        history.add(entry("first", at: now - 20), now: now)
        history.add(entry("third", at: now), now: now)
        XCTAssertEqual(history.entries.map(\.text), ["first", "second", "third"])
        XCTAssertEqual(history.shown().map(\.text), ["third", "second", "first"], "the view is newest first")
        let written = history.entries[0]
        let back = TranscriptEntry(line: written.line)
        XCTAssertEqual(back, written)
        let object = try? JSONSerialization.jsonObject(with: written.line) as? [String: Any]
        XCTAssertEqual(object?["words"] as? Int, 1)
        XCTAssertEqual(object?["seconds"] as? Double, 2.3)
        XCTAssertNil(object?["window"], "no title, no key")
    }

    func testAnEntryWithTheSameIdReplacesTheOne() {
        var history = TranscriptHistory()
        history.add(entry("Herdr runs", at: now - 5, kind: .stretch, outcome: .heard, id: "a"), now: now)
        history.add(entry("Herdr runs on the Beelink", at: now, kind: .stretch, outcome: .heard, id: "a"), now: now)
        XCTAssertEqual(history.entries.map(\.text), ["Herdr runs on the Beelink"])
    }

    func testTheOldestGoPastTheMostAndPastThirtyDays() {
        var history = TranscriptHistory()
        for index in 0..<TranscriptHistory.most {
            XCTAssertFalse(history.add(entry("\(index)", at: now - 1000 + Double(index) * 0.1), now: now))
        }
        XCTAssertTrue(history.add(entry("new", at: now), now: now), "one over the most: the oldest goes")
        XCTAssertEqual(history.entries.count, TranscriptHistory.most)
        XCTAssertEqual(history.entries.first?.text, "1")
        XCTAssertEqual(history.entries.last?.text, "new")

        var old = TranscriptHistory()
        old.add(entry("31 days", at: now - 31 * 86_400), now: now - 31 * 86_400)
        old.add(entry("29 days", at: now - 29 * 86_400), now: now - 29 * 86_400)
        XCTAssertEqual(old.entries.count, 2)
        XCTAssertTrue(old.trim(now: now))
        XCTAssertEqual(old.entries.map(\.text), ["29 days"])
        XCTAssertFalse(old.trim(now: now), "nothing more goes")
    }

    func testAFileReadsBackAndItsBrokenLinesAreSkipped() {
        let history = TranscriptHistory([entry("one", at: now - 2), entry("two", at: now - 1)])
        let clean = TranscriptHistory.read(history.file, now: now)
        XCTAssertEqual(clean.history, history)
        XCTAssertEqual(clean.broken, 0)
        XCTAssertFalse(clean.rewrite)

        var data = history.file
        data.append(Data("not json\n{\"id\":\"x\"}\n".utf8))
        data.append(Data("{\"id\":\"cut\",\"kind\":\"dicta".utf8))
        let broken = TranscriptHistory.read(data, now: now)
        XCTAssertEqual(broken.history.entries.map(\.text), ["one", "two"])
        XCTAssertEqual(broken.broken, 3)
        XCTAssertTrue(broken.rewrite)

        let garbage = TranscriptHistory.read(Data([0xFF, 0xFE, 0x00, 0x0A]), now: now)
        XCTAssertEqual(garbage.history.entries, [], "a file that cannot be read starts empty")
        XCTAssertTrue(garbage.rewrite)
        XCTAssertFalse(TranscriptHistory.read(Data(), now: now).rewrite)
    }

    func testAReplacedLineAndAnOldEntryMakeTheFileBeWrittenAgain() {
        let first = entry("Herdr", at: now - 5, id: "a")
        var second = first
        second.text = "Herdr runs"
        let read = TranscriptHistory.read(first.line + second.line + entry("old", at: now - 40 * 86_400).line, now: now)
        XCTAssertEqual(read.history.entries.map(\.text), ["Herdr runs"])
        XCTAssertTrue(read.rewrite)
        XCTAssertEqual(TranscriptHistory.read(read.history.file, now: now).rewrite, false)
    }

    func testClearLeavesNothing() {
        var history = TranscriptHistory([entry("one", at: now)])
        history.clear()
        XCTAssertNil(history.newest)
        XCTAssertEqual(history.file, Data())
    }

    func testTheNewestIsTheLastToEndOfADictationAndAStretchAndHasWords() {
        var history = TranscriptHistory()
        history.add(entry("the dictation", at: now - 30), now: now)
        history.add(entry("the stretch", at: now - 10, kind: .stretch, outcome: .heard), now: now)
        XCTAssertEqual(history.newest?.text, "the stretch")
        history.add(entry("a later dictation", at: now - 5), now: now)
        XCTAssertEqual(history.newest?.text, "a later dictation")
        history.add(entry("", at: now, outcome: .heardNothing), now: now)
        XCTAssertEqual(history.newest?.text, "a later dictation", "one that heard no words is not pasted")
        history.add(entry("thrown away with Esc", at: now + 1, outcome: .cancelled), now: now)
        XCTAssertEqual(history.newest?.text, "thrown away with Esc", "a cancelled text is exactly the one to get back")
    }

    func testTheSearchHasEveryWordInAnyCase() {
        let history = TranscriptHistory([
            entry("Herdr runs on the Beelink", at: now - 3), entry("the roadmap on Misha’s computer", at: now - 2), entry("Beelink and Doppler", at: now - 1),
        ])
        XCTAssertEqual(history.shown(search: "beelink").map(\.text), ["Beelink and Doppler", "Herdr runs on the Beelink"])
        XCTAssertEqual(history.shown(search: "  BEELINK herdr ").map(\.text), ["Herdr runs on the Beelink"])
        XCTAssertEqual(history.shown(search: "nothing").count, 0)
        XCTAssertEqual(history.shown(search: " ").count, 3)
    }
}
