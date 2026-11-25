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

    /// The open descriptors of this process.
    private func openFiles() -> Int {
        (try? FileManager.default.contentsOfDirectory(atPath: "/dev/fd").count) ?? -1
    }

    /// A process whose callbacks hold it (as MindBridge's do) is freed at its exit, with its pipes.
    func testAnEndedProcessIsFreedWithItsPipes() throws {
        let before = openFiles()
        weak var last: JSONLineProcess?
        for _ in 0..<50 {
            // the app's run loop drains its pool at each turn; a test drains its own
            try autoreleasepool {
                let exited = expectation(description: "exited")
                let child = JSONLineProcess(executable: "/usr/bin/true", arguments: [])
                child.said = { _ in _ = child }
                child.exited = { _ in exited.fulfill() }
                try child.start()
                last = child
                wait(for: [exited], timeout: 10)
            }
        }
        // one turn of the main queue, for the last closures to go
        let turn = expectation(description: "turn")
        DispatchQueue.main.async { turn.fulfill() }
        wait(for: [turn], timeout: 5)
        XCTAssertNil(last, "no cycle keeps it")
        XCTAssertLessThanOrEqual(openFiles(), before + 2, "no pipe stays open")
    }

    func testAProcessThatDoesNotStartIsFreedToo() {
        weak var probe: JSONLineProcess?
        do {
            let child = JSONLineProcess(executable: "/no/such/node", arguments: [])
            child.exited = { _ in _ = child }
            XCTAssertThrowsError(try child.start())
            probe = child
        }
        XCTAssertNil(probe)
    }

    /// Lines to a child that is gone fail, and end nothing: no SIGPIPE.
    func testLinesToAChildThatIsGoneEndNothing() {
        let child = JSONLineProcess(executable: "/usr/bin/true", arguments: [])
        let exited = expectation(description: "exited")
        child.exited = { _ in exited.fulfill() }
        XCTAssertNoThrow(try child.start())
        // while it ends, and after
        for _ in 0..<1_000 { child.send(["text": String(repeating: "x", count: 1_000)]) }
        wait(for: [exited], timeout: 10)
        XCTAssertFalse(child.send(["after": true]))
    }

    /// A child that does not read: `send` never blocks the main thread, and the bytes that wait are bounded.
    func testAChildThatDoesNotReadBlocksNoSend() {
        let child = JSONLineProcess(executable: "/bin/sleep", arguments: ["30"])
        XCTAssertNoThrow(try child.start())
        let started = Date()
        let line: [String: Any] = ["text": String(repeating: "x", count: 1_000_000)]
        var dropped = 0
        for _ in 0..<40 where !child.send(line) { dropped += 1 }
        XCTAssertLessThan(Date().timeIntervalSince(started), 2, "the sends did not wait for the pipe")
        XCTAssertGreaterThan(dropped, 0, "past the bound, a line is dropped")
        child.terminate()
    }

    /// The lend's and the CLI's form: raw lines, an environment, no stdin. A line cut inside a
    /// character, and a link cut by two writes, come whole, before the exit.
    func testRawLinesComeWholeBeforeTheExit() {
        let script = #"printf '{"state":"caf\303'; sleep 0.2; printf '\251"}\n'; printf 'https://example.com/keys/en' >&2; sleep 0.2; printf 'rol?x=1\n' >&2; echo "$WHO"; exec 0<&-; exit 0"#
        let child = JSONLineProcess(executable: "/bin/sh", arguments: ["-c", script], environment: ["WHO": "the test", "PATH": "/usr/bin:/bin"], input: false)
        var printed: [String] = []
        var logged: [String] = []
        let exited = expectation(description: "exited")
        child.printed = { printed.append($0) }
        child.logged = { logged.append($0) }
        child.exited = { _ in
            XCTAssertEqual(printed, [#"{"state":"café"}"#, "the test"])
            XCTAssertEqual(logged, ["https://example.com/keys/enrol?x=1"])
            exited.fulfill()
        }
        XCTAssertNoThrow(try child.start())
        wait(for: [exited], timeout: 10)
    }

    func testABufferCutsManyLinesOfOneRead() {
        let lines = LineBuffer()
        let text = (0..<10_000).map { "line \($0)" }.joined(separator: "\n") + "\nrest"
        let whole = lines.add(Data(text.utf8))
        XCTAssertEqual(whole.count, 10_000)
        XCTAssertEqual(String(decoding: whole[9_999], as: UTF8.self), "line 9999")
        XCTAssertEqual(lines.end().map { String(decoding: $0, as: UTF8.self) }, ["rest"])
    }
}
