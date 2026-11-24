import XCTest

@testable import VoiceMeetCore

@MainActor
final class JSONLineProcessTests: XCTestCase {
    /// A child that writes "é" (bytes C3 A9) in two writes, a line on stderr, then its last line.
    func testLinesAreWholeAndTheExitComesAfterTheLast() {
        let script = #"printf '{"text":"caf\303'; sleep 0.2; printf '\251"}\n'; echo 'a line for the log' >&2; printf '{"last":true}\n'; exit 3"#
        let child = JSONLineProcess(executable: "/bin/sh", arguments: ["-c", script])
        var said: [[String: Any]] = []
        var logged: [String] = []
        var saidAtExit = -1
        let exited = expectation(description: "exited")
        child.said = { said.append($0) }
        child.logged = { logged.append($0) }
        child.exited = { status in
            XCTAssertEqual(status, 3)
            saidAtExit = said.count
            exited.fulfill()
        }
        XCTAssertNoThrow(try child.start())
        wait(for: [exited], timeout: 10)
        XCTAssertEqual(said.first?["text"] as? String, "café", "the character split across two writes is whole")
        XCTAssertEqual(said.last?["last"] as? Bool, true)
        XCTAssertEqual(saidAtExit, 2, "the exit comes after the last line")
        XCTAssertEqual(logged, ["a line for the log"])
    }

    func testALineSentReachesTheChildAndAClosedInputEndsIt() {
        let child = JSONLineProcess(executable: "/bin/sh", arguments: ["-c", "while read line; do echo \"$line\"; done"])
        var said: [[String: Any]] = []
        let exited = expectation(description: "exited")
        child.said = { said.append($0) }
        child.exited = { _ in exited.fulfill() }
        XCTAssertNoThrow(try child.start())
        child.send(["job": "words", "file": "/a/b"])
        child.closeInput()
        wait(for: [exited], timeout: 10)
        XCTAssertEqual(said.count, 1)
        XCTAssertEqual(said.first?["file"] as? String, "/a/b")
    }

    func testABufferCutsLinesAtTheirByteAndKeepsTheRest() {
        let lines = LineBuffer()
        XCTAssertEqual(lines.add(Data([0x61, 0xC3])), [])
        XCTAssertEqual(lines.add(Data([0xA9, 0x0A, 0x62])).map { String(decoding: $0, as: UTF8.self) }, ["aé"])
        XCTAssertEqual(lines.end().map { String(decoding: $0, as: UTF8.self) }, ["b"])
    }
}
