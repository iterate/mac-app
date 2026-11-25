import Foundation

/// One command run to its end, with bounds: the endpoint's `run` (Powers.swift `Commands`).
///
/// - The child is the leader of a process group of its own, with the default action for every
///   signal and none blocked (the app ignores SIGPIPE; a child must not).
/// - stdin is written on a queue of its own, while stdout and stderr are read: a child that writes
///   before it reads does not stop. A child that does not read all of it ends the write (EPIPE),
///   with no signal to the app.
/// - stdout and stderr keep at most `mostBytes` each; the rest is read and dropped, so the child
///   never waits on a full pipe and memory stays bounded.
/// - At the deadline the group gets SIGTERM, and SIGKILL 2 s later; `timedOut` says that the
///   deadline came while it ran. Then the pipes are read for at most 2 s more.
/// - When the child exits, its pipes are read for at most `drainSeconds` more: a process it left in
///   the background that holds them (`sh -c "sleep 60 &"`) runs on, and is not waited for.
public enum CommandRun {
    public struct Result: Sendable, Equatable {
        /// The exit status, or the signal's number when a signal ended it.
        public var status: Int32
        public var timedOut: Bool
        public var stdout: Data
        public var stderr: Data
    }

    public struct DidNotStart: Error, CustomStringConvertible {
        public let description: String
    }

    public static func run(
        _ executable: String, _ arguments: [String], stdin: Data = Data(), timeout: TimeInterval,
        mostBytes: Int = 8 * 1024 * 1024, drainSeconds: TimeInterval = 1
    ) async throws -> Result {
        var input: [Int32] = [0, 0], output: [Int32] = [0, 0], errors: [Int32] = [0, 0]
        guard pipe(&input) == 0, pipe(&output) == 0, pipe(&errors) == 0 else { throw DidNotStart(description: "no pipe: \(String(cString: strerror(errno)))") }
        // the parent's ends: never inherited, and a write to a reader that is gone is EPIPE, not SIGPIPE
        for descriptor in [input[1], output[0], errors[0]] { _ = fcntl(descriptor, F_SETFD, FD_CLOEXEC) }
        _ = fcntl(input[1], F_SETNOSIGPIPE, 1)

        var actions: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&actions)
        defer { posix_spawn_file_actions_destroy(&actions) }
        posix_spawn_file_actions_adddup2(&actions, input[0], 0)
        posix_spawn_file_actions_adddup2(&actions, output[1], 1)
        posix_spawn_file_actions_adddup2(&actions, errors[1], 2)
        var attributes: posix_spawnattr_t?
        posix_spawnattr_init(&attributes)
        defer { posix_spawnattr_destroy(&attributes) }
        var all = sigset_t(), none = sigset_t()
        sigfillset(&all)
        sigemptyset(&none)
        posix_spawnattr_setsigdefault(&attributes, &all)
        posix_spawnattr_setsigmask(&attributes, &none)
        posix_spawnattr_setpgroup(&attributes, 0)
        posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_SETPGROUP | POSIX_SPAWN_SETSIGDEF | POSIX_SPAWN_SETSIGMASK | POSIX_SPAWN_CLOEXEC_DEFAULT))

        let argv: [UnsafeMutablePointer<CChar>?] = ([executable] + arguments).map { strdup($0) } + [nil]
        defer { argv.forEach { free($0) } }
        var pid: pid_t = 0
        let spawned = posix_spawn(&pid, executable, &actions, &attributes, argv, environ)
        for descriptor in [input[0], output[1], errors[1]] { close(descriptor) }
        guard spawned == 0 else {
            for descriptor in [input[1], output[0], errors[0]] { close(descriptor) }
            throw DidNotStart(description: String(cString: strerror(spawned)))
        }

        let run = Running(pid: pid, mostBytes: mostBytes, drainSeconds: drainSeconds)
        return await withCheckedContinuation { continuation in
            run.finished = { continuation.resume(returning: $0) }
            run.start(stdin: stdin, input: input[1], output: output[0], errors: errors[0], timeout: timeout)
        }
    }

    /// One child while it runs: its exit, its two pipes, its deadline. Its state is under `lock`.
    private final class Running: @unchecked Sendable {
        let pid: pid_t
        let mostBytes: Int
        let drainSeconds: TimeInterval
        var finished: (Result) -> Void = { _ in }

        private let lock = NSLock()
        private let queue = DispatchQueue(label: "CommandRun.pipes")
        private var readers: [DispatchSourceRead] = []
        private var kept = [Data(), Data()]
        private var open = 2
        private var status: Int32?
        private var timedOut = false
        private var isDone = false

        init(pid: pid_t, mostBytes: Int, drainSeconds: TimeInterval) {
            self.pid = pid
            self.mostBytes = mostBytes
            self.drainSeconds = drainSeconds
        }

        func start(stdin: Data, input: Int32, output: Int32, errors: Int32, timeout: TimeInterval) {
            DispatchQueue.global().async {
                stdin.withUnsafeBytes { bytes in
                    var at = 0
                    while at < bytes.count {
                        let wrote = write(input, bytes.baseAddress! + at, bytes.count - at)
                        if wrote < 0, errno == EINTR { continue }
                        if wrote <= 0 { break }
                        at += wrote
                    }
                }
                close(input)
            }
            for (index, descriptor) in [output, errors].enumerated() {
                _ = fcntl(descriptor, F_SETFL, fcntl(descriptor, F_GETFL) | O_NONBLOCK)
                let source = DispatchSource.makeReadSource(fileDescriptor: descriptor, queue: queue)
                source.setEventHandler { [self] in drain(descriptor, into: index, source) }
                source.setCancelHandler { [self] in
                    close(descriptor)
                    lock.lock()
                    open -= 1
                    lock.unlock()
                    finishIfDone()
                }
                readers.append(source)
                source.resume()
            }
            // a thread of its own waits for the exit: it blocks no queue of the system's
            let pid = pid
            Thread {
                var raw: Int32 = 0
                while waitpid(pid, &raw, 0) < 0, errno == EINTR {}
                let status = (raw & 0x7F) == 0 ? (raw >> 8) & 0xFF : raw & 0x7F
                self.lock.lock()
                self.status = status
                self.lock.unlock()
                self.queue.asyncAfter(deadline: .now() + self.drainSeconds) { self.readers.forEach { $0.cancel() } }
                self.finishIfDone()
            }.start()
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout) { [self] in
                lock.lock()
                let isRunning = status == nil
                if isRunning { timedOut = true }
                lock.unlock()
                guard isRunning else { return }
                kill(-pid, SIGTERM)
                DispatchQueue.global().asyncAfter(deadline: .now() + 2) { [self] in
                    lock.lock()
                    let stillRuns = status == nil
                    lock.unlock()
                    if stillRuns { kill(-pid, SIGKILL) }
                    queue.asyncAfter(deadline: .now() + 2) { [self] in readers.forEach { $0.cancel() } }
                }
            }
        }

        /// What the pipe has now; the first `mostBytes` are kept. On the pipes' queue.
        private func drain(_ descriptor: Int32, into index: Int, _ source: DispatchSourceRead) {
            var buffer = [UInt8](repeating: 0, count: 65_536)
            while true {
                let count = read(descriptor, &buffer, buffer.count)
                if count > 0 {
                    let room = mostBytes - kept[index].count
                    if room > 0 { kept[index].append(contentsOf: buffer[0..<min(count, room)]) }
                    continue
                }
                if count < 0, errno == EINTR { continue }
                // 0 is the end; EAGAIN is all there is for now
                if count == 0 || errno != EAGAIN { source.cancel() }
                return
            }
        }

        private func finishIfDone() {
            lock.lock()
            guard !isDone, open == 0, let status else { return lock.unlock() }
            isDone = true
            let result = Result(status: status, timedOut: timedOut, stdout: kept[0], stderr: kept[1])
            lock.unlock()
            finished(result)
        }
    }
}
