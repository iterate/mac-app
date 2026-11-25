#if canImport(AppKit)
import AppKit
import VoiceMeetCore
import XCTest

/// Carbon 13: the clipboard after a dictation's ⌘V, on a pasteboard of the test's own.
final class ClipboardCopyTests: XCTestCase {
    private var pasteboard: NSPasteboard!

    override func setUp() {
        pasteboard = NSPasteboard(name: NSPasteboard.Name("com.iterate.test.\(UUID().uuidString)"))
    }

    override func tearDown() {
        pasteboard.releaseGlobally()
    }

    func testWhatWasThereComesBackAndTheTextIsTransient() {
        pasteboard.clearContents()
        pasteboard.setString("the person's", forType: .string)
        let kept = ClipboardCopy(of: pasteboard)
        let change = ClipboardCopy.put("dictated", on: pasteboard)
        XCTAssertEqual(pasteboard.string(forType: .string), "dictated")
        XCTAssertTrue(pasteboard.types?.contains(ClipboardCopy.transient) == true, "a clipboard manager does not keep it")
        XCTAssertTrue(kept.restore(on: pasteboard, ifStill: change))
        XCTAssertEqual(pasteboard.string(forType: .string), "the person's")
    }

    func testACopyOfThePersonMeanwhileStaysEvenOfTheSameText() {
        pasteboard.clearContents()
        pasteboard.setString("old", forType: .string)
        let kept = ClipboardCopy(of: pasteboard)
        let change = ClipboardCopy.put("dictated", on: pasteboard)
        // within the 0.6 s: the person copies a picture, then the same words
        pasteboard.clearContents()
        pasteboard.setData(Data([1, 2, 3]), forType: .png)
        XCTAssertFalse(kept.restore(on: pasteboard, ifStill: change))
        XCTAssertEqual(pasteboard.data(forType: .png), Data([1, 2, 3]))
        pasteboard.clearContents()
        pasteboard.setString("dictated", forType: .string)
        XCTAssertFalse(kept.restore(on: pasteboard, ifStill: change))
        XCTAssertNil(pasteboard.data(forType: .png))
        XCTAssertEqual(pasteboard.string(forType: .string), "dictated")
    }

    func testWhatIsKeptIsBounded() {
        pasteboard.clearContents()
        let item = NSPasteboardItem()
        let big = NSPasteboard.PasteboardType("com.iterate.test.big"), small = NSPasteboard.PasteboardType("com.iterate.test.small")
        item.setData(Data(count: ClipboardCopy.mostBytes + 1), forType: big)
        item.setData(Data([7]), forType: small)
        pasteboard.writeObjects([item])
        let kept = ClipboardCopy(of: pasteboard)
        let change = ClipboardCopy.put("dictated", on: pasteboard)
        XCTAssertTrue(kept.restore(on: pasteboard, ifStill: change))
        XCTAssertNil(pasteboard.data(forType: big), "too large to keep")
        XCTAssertEqual(pasteboard.data(forType: small), Data([7]))
    }
}
#endif
