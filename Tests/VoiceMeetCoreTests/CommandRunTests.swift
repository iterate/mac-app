import XCTest

@testable import VoiceMeetCore

final class CommandRunTests: XCTestCase {
    func testStdinGoesInAndTheOutputComesBack() async throws {
        let result = try await CommandRun.run("/bin/cat", [], stdin: Data("hello".utf8), timeout: 10)
        XCTAssertEqual(result, CommandRun.Result(status: 0, timedOut: false, stdout: Data("hello".utf8), stderr: Data()))
    }

    /// `cat /dev/zero` for ever: the deadline ends it, and it keeps the bound, not all it wrote.
    func testTheDeadlineEndsItAndTheOutputIsBounded() async throws {
        let started = Date()
        let result = try await CommandRun.run("/bin/cat", ["/dev/zero"], timeout: 1, mostBytes: 1_000_000)
        XCTAssertLessThan(Date().timeIntervalSince(started), 5)
        XCTAssertTrue(result.timedOut)
        XCTAssertEqual(result.stdout.count, 1_000_000)
    }

    /// A process it leaves in the background holds the pipes: the answer does not wait for it.
    func testABackgroundProcessThatHoldsThePipesIsNotWaitedFor() async throws {
        let started = Date()
        let result = try await CommandRun.run("/bin/sh", ["-c", "sleep 30 & echo started"], timeout: 60)
        XCTAssertLessThan(Date().timeIntervalSince(started), 4)
        XCTAssertFalse(result.timedOut)
        XCTAssertEqual(String(decoding: result.stdout, as: UTF8.self), "started\n")
    }

    /// At the deadline the whole group ends: a grandchild too.
    func testTheDeadlineEndsTheGroup() async throws {
        let started = Date()
        let result = try await CommandRun.run("/bin/sh", ["-c", "sleep 30; echo late"], timeout: 0.5)
        XCTAssertLessThan(Date().timeIntervalSince(started), 4)
        XCTAssertTrue(result.timedOut)
        XCTAssertEqual(result.status, SIGTERM)
        XCTAssertEqual(result.stdout, Data())
    }

    func testASignalIsNotATimeout() async throws {
        let result = try await CommandRun.run("/bin/sh", ["-c", "kill -SEGV $$"], timeout: 10)
        XCTAssertFalse(result.timedOut)
        XCTAssertEqual(result.status, SIGSEGV)
    }

    /// stdin that the command never reads: the write ends (EPIPE), and nothing else does.
    func testStdinThatIsNotReadEndsNothing() async throws {
        let result = try await CommandRun.run("/usr/bin/true", [], stdin: Data(count: 2_000_000), timeout: 10)
        XCTAssertEqual(result.status, 0)
    }

    /// The app ignores SIGPIPE; the command has the default: `yes | head` ends `yes` with no word.
    func testTheCommandHasTheDefaultSignals() async throws {
        signal(SIGPIPE, SIG_IGN)
        defer { signal(SIGPIPE, SIG_DFL) }
        let result = try await CommandRun.run("/bin/sh", ["-c", "yes | head -c 1"], timeout: 10)
        XCTAssertEqual(String(decoding: result.stdout, as: UTF8.self), "y")
        XCTAssertEqual(result.stderr, Data())
    }

    func testACommandThatIsNotThereDoesNotStart() async {
        do {
            _ = try await CommandRun.run("/no/such/command", [], timeout: 1)
            XCTFail("it started")
        } catch {}
    }
}
