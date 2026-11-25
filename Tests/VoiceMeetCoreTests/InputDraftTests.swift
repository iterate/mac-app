import XCTest

@testable import VoiceMeetCore

final class InputDraftTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_795_000_000)

    private func json(_ data: Data?) -> [String: Any] {
        (data.flatMap { try? JSONSerialization.jsonObject(with: $0) } as? [String: Any]) ?? [:]
    }

    func testAnEmptyDraftDoesNotGoAndSaysWhy() {
        var draft = InputDraft(id: "a")
        draft.text = "  \n "
        XCTAssertNil(draft.submit(at: now))
        XCTAssertEqual(draft.phase, .failed("Type something, or add a file."))
    }

    func testATextGoesTrimmedWithItsIdAndTime() {
        var draft = InputDraft(id: "a")
        draft.text = "  open the roadmap\n"
        let input = json(draft.submit(at: now))
        XCTAssertEqual(input["id"] as? String, "a")
        XCTAssertEqual(input["text"] as? String, "open the roadmap")
        XCTAssertEqual(input["at"] as? String, "2026-11-18T11:06:40Z")
        XCTAssertEqual((input["files"] as? [Any])?.count, 0)
        XCTAssertEqual(draft.phase, .sending(progress: 0))
    }

    func testFilesAloneAreAnInput() {
        var draft = InputDraft(id: "a")
        XCTAssertTrue(draft.attach(name: "a.pdf", local: "/tmp/a.pdf", bytes: 10, contentType: "application/pdf"))
        let files = json(draft.submit(at: now))["files"] as? [[String: String]]
        XCTAssertEqual(files, [["local": "/tmp/a.pdf", "name": "a.pdf", "contentType": "application/pdf"]])
    }

    func testAFolderALargeFileASecondCopyAndTheTwentyFirstAreRefusedInWords() {
        var draft = InputDraft(id: "a")
        XCTAssertFalse(draft.attach(name: "src", local: "/src", bytes: 0, contentType: "", isFolder: true))
        XCTAssertEqual(draft.refusal, "src is a folder: add its files.")
        XCTAssertFalse(draft.attach(name: "movie.mov", local: "/movie.mov", bytes: InputDraft.mostBytes + 1, contentType: "video/quicktime"))
        XCTAssertEqual(draft.refusal, "movie.mov is larger than 500 MB.")
        for index in 0..<InputDraft.mostFiles {
            XCTAssertTrue(draft.attach(name: "\(index).txt", local: "/\(index).txt", bytes: 1, contentType: "text/plain"))
        }
        XCTAssertNil(draft.refusal)
        XCTAssertFalse(draft.attach(name: "3.txt", local: "/3.txt", bytes: 1, contentType: "text/plain"))
        XCTAssertEqual(draft.refusal, "3.txt is added already.")
        XCTAssertFalse(draft.attach(name: "more.txt", local: "/more.txt", bytes: 1, contentType: "text/plain"))
        XCTAssertEqual(draft.refusal, "An input takes at most 20 files.")
        draft.remove(1)
        XCTAssertNil(draft.refusal)
        XCTAssertEqual(draft.attachments.count, InputDraft.mostFiles - 1)
    }

    func testDoneGivesANewEmptyDraft() {
        var draft = InputDraft(id: "a")
        draft.text = "x"
        draft.attach(name: "a.pdf", local: "/a.pdf", bytes: 10, contentType: "application/pdf")
        _ = draft.submit(at: now)
        XCTAssertEqual(draft.senderSaid(["progress": 0.4], next: "b"), .nothing)
        XCTAssertEqual(draft.phase, .sending(progress: 0.4))
        XCTAssertEqual(draft.senderSaid(["done": true], next: "b"), .sent)
        XCTAssertEqual(draft, InputDraft(id: "b"))
        // the process ends after its answer: that changes nothing
        XCTAssertEqual(draft.senderEnded(status: 0), .nothing)
    }

    func testAFailureKeepsTheTextTheFilesAndTheId() {
        var draft = InputDraft(id: "a")
        draft.text = "x"
        draft.attach(name: "a.pdf", local: "/a.pdf", bytes: 10, contentType: "application/pdf")
        _ = draft.submit(at: now)
        XCTAssertEqual(draft.senderSaid(["failed": "Not signed in"], next: "b"), .failed("Not signed in"))
        XCTAssertEqual(draft.phase, .failed("Not signed in"))
        XCTAssertEqual(draft.id, "a")
        XCTAssertEqual(draft.text, "x")
        XCTAssertEqual(draft.attachments.count, 1)
        // the same input goes again
        XCTAssertEqual(json(draft.submit(at: now))["id"] as? String, "a")
    }

    /// Astra 9: the mind may have kept an input whose answer was lost. The same input goes again as
    /// it was, byte for byte; an input changed after it is another one, with a new id.
    func testARetryOfTheSameInputIsTheSameBytesAndAChangedOneHasANewId() {
        var draft = InputDraft(id: "a")
        draft.text = "x"
        draft.attach(name: "a.pdf", local: "/a.pdf", bytes: 10, contentType: "application/pdf")
        let first = draft.submit(at: now)
        _ = draft.senderSaid(["failed": "no answer"], next: "z")
        // a minute later, unchanged: the same id, the same time, the same files
        XCTAssertEqual(draft.submit(at: now.addingTimeInterval(60), newId: { "b" }), first)
        _ = draft.senderEnded(status: 1)
        // edited: another input
        draft.text = "x, and y"
        let edited = json(draft.submit(at: now.addingTimeInterval(120), newId: { "b" }))
        XCTAssertEqual(edited["id"] as? String, "b")
        XCTAssertEqual(edited["text"] as? String, "x, and y")
        XCTAssertEqual(draft.id, "b")
        _ = draft.senderSaid(["failed": "no answer"], next: "z")
        // a file less is a change too
        draft.remove(draft.attachments[0].id)
        XCTAssertEqual(json(draft.submit(at: now, newId: { "c" }))["id"] as? String, "c")
    }

    func testASenderThatEndsWithNoAnswerIsAFailure() {
        var draft = InputDraft(id: "a")
        draft.text = "x"
        _ = draft.submit(at: now)
        XCTAssertEqual(draft.senderEnded(status: 9), .failed("The sender ended with no answer (exit 9)."))
        XCTAssertEqual(draft.text, "x")
    }

    func testWhileItGoesNothingChangesAndNoSecondSendStarts() {
        var draft = InputDraft(id: "a")
        draft.text = "x"
        _ = draft.submit(at: now)
        XCTAssertNil(draft.submit(at: now))
        XCTAssertFalse(draft.attach(name: "a.pdf", local: "/a.pdf", bytes: 10, contentType: "application/pdf"))
        XCTAssertEqual(draft.phase, .sending(progress: 0))
    }

    func testSizesInWords() {
        XCTAssertEqual(InputDraft.size(812), "812 bytes")
        XCTAssertEqual(InputDraft.size(35_000), "34 KB")
        XCTAssertEqual(InputDraft.size(2_200_000), "2.1 MB")
    }
}
