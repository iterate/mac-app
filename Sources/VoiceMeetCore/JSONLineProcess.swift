import Foundation

/// A child process that speaks in lines: the app's one way to run a script of the bridge
/// (`bridge/mind.mjs`, through `MindBridge`), the lend (`iterate provide`) and the CLI's commands
/// (`Lend`).
///
/// stdout is framed by bytes: a line ends at its `\n`, and only a whole line is decoded, so a
/// character whose bytes come in two reads stays whole. Each line that is a JSON object goes to
/// `said`, or each line as text to `printed` when that is set; each line of stderr goes to
/// `logged`. `exited` is told last, once the process has ended and both pipes are read to their
/// end: no line comes after it. Every callback is on the main actor, in the order the child wrote.
/// A started process keeps this object until `exited`; then the callbacks are let go, so a closure
/// that holds this object frees it.
///
/// `send` writes on a queue of its own, never on the caller's thread: a child that does not read
/// blocks no one. At most `mostUnwritten` bytes wait; a line past that is dropped and `send` says
/// false. A write to a child that is gone fails with EPIPE (the app ignores SIGPIPE) and is dropped.
@MainActor
public final class JSONLineProcess {
    public var said: ([String: Any]) -> Void = { _ in }
    /// When set, each line of stdout as text, in place of `said`.
    public var printed: ((String) -> Void)?
    public var logged: (String) -> Void = { _ in }
    public var exited: (Int32) -> Void = { _ in }

    public nonisolated static let mostUnwritten = 16 * 1024 * 1024

    private let process = Process()
    private let input: Pipe?
    private let writer = Writer()
    private var hasExited = false

    /// `environment` is the child's whole environment (nil: the app's). With `input` false the
    /// child's stdin is /dev/null.
    public init(executable: String, arguments: [String], environment: [String: String]? = nil, input: Bool = true) {
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        if let environment { process.environment = environment }
        self.input = input ? Pipe() : nil
        // a write to a child that is gone is EPIPE, never SIGPIPE: whatever the process ignores
        if let input = self.input { _ = fcntl(input.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1) }
    }

    public var pid: Int32 { process.processIdentifier }

    public func start() throws {
        let output = Pipe(), errors = Pipe()
        process.standardInput = input ?? FileHandle.nullDevice
        process.standardOutput = output
        process.standardError = errors
        // the end waits for three things: the end of stdout, of stderr, and of the process
        let ends = DispatchGroup()
        read(output, ends) { [weak self] line in
            guard let self else { return }
            if let printed = self.printed { return printed(String(decoding: line, as: UTF8.self)) }
            if let object = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any] {
                self.said(object)
            } else if !line.isEmpty {
                self.logged("not a JSON line: \(String(decoding: line.prefix(200), as: UTF8.self))")
            }
        }
        read(errors, ends) { [weak self] line in
            if !line.isEmpty { self?.logged(String(decoding: line, as: UTF8.self)) }
        }
        ends.enter()
        process.terminationHandler = { _ in ends.leave() }
        do {
            try process.run()
        } catch {
            output.fileHandleForReading.readabilityHandler = nil
            errors.fileHandleForReading.readabilityHandler = nil
            letGo()
            throw error
        }
        writer.handle = input?.fileHandleForWriting
        let process = process
        // a process that runs keeps this object until its end: its owner need not
        ends.notify(queue: .main) {
            MainActor.assumeIsolated {
                let exited = self.exited
                self.letGo()
                exited(process.terminationStatus)
            }
        }
    }

    /// One line to the child's stdin; false when it was dropped (no stdin, more than
    /// `mostUnwritten` bytes wait, or the child is gone).
    @discardableResult
    public func send(_ object: [String: Any]) -> Bool {
        guard !hasExited, let data = try? JSONSerialization.data(withJSONObject: object, options: [.withoutEscapingSlashes]) else { return false }
        return writer.write(data + Data([0x0A]))
    }

    /// The child's stdin ends, after what waits to be written: a bridge script then ends its work and exits.
    public func closeInput() {
        writer.close()
    }

    /// SIGTERM to the child, if it runs.
    public func terminate() {
        if process.isRunning { process.terminate() }
    }

    /// The callbacks go, and with them what they hold (a cycle through this object, often).
    private func letGo() {
        hasExited = true
        said = { _ in }
        printed = nil
        logged = { _ in }
        exited = { _ in }
        writer.close()
    }

    /// Reads `pipe` on its own queue and hands each whole line to `line` on the main queue.
    private func read(_ pipe: Pipe, _ ends: DispatchGroup, _ line: @escaping @MainActor (Data) -> Void) {
        ends.enter()
        let lines = LineBuffer()
        pipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            let whole = data.isEmpty ? lines.end() : lines.add(data)
            if !whole.isEmpty { DispatchQueue.main.async { MainActor.assumeIsolated { whole.forEach(line) } } }
            guard data.isEmpty else { return }
            handle.readabilityHandler = nil
            // after the lines above: `notify` runs on the main queue behind them
            ends.leave()
        }
    }

    /// The writes to stdin, in order, on a serial queue; the count of bytes that wait bounds them.
    private final class Writer: @unchecked Sendable {
        private let queue = DispatchQueue(label: "JSONLineProcess.stdin")
        private let lock = NSLock()
        private var unwritten = 0
        private var isClosed = false
        /// Set once, before the first write.
        var handle: FileHandle?

        func write(_ data: Data) -> Bool {
            lock.lock()
            guard !isClosed, handle != nil, unwritten + data.count <= JSONLineProcess.mostUnwritten else {
                lock.unlock()
                return false
            }
            unwritten += data.count
            lock.unlock()
            queue.async { [self] in
                // EPIPE when the child is gone: the line goes nowhere, as the child does
                try? handle?.write(contentsOf: data)
                lock.lock()
                unwritten -= data.count
                lock.unlock()
            }
            return true
        }

        func close() {
            lock.lock()
            let wasClosed = isClosed
            isClosed = true
            lock.unlock()
            guard !wasClosed else { return }
            queue.async { [self] in try? handle?.close() }
        }
    }
}

/// The bytes of a stream cut into lines at `\n`. Used on one pipe's queue alone.
public final class LineBuffer: @unchecked Sendable {
    private var pending = Data()

    public init() {}

    /// The lines that `data` ends; the rest waits for the next.
    public func add(_ data: Data) -> [Data] {
        pending.append(data)
        var lines: [Data] = []
        var start = pending.startIndex
        while let end = pending[start...].firstIndex(of: 0x0A) {
            lines.append(Data(pending[start..<end]))
            start = pending.index(after: end)
        }
        // the rest is copied once, not once for each line
        if start != pending.startIndex { pending = Data(pending[start...]) }
        return lines
    }

    /// The stream ended: what is left is the last line.
    public func end() -> [Data] {
        defer { pending = Data() }
        return pending.isEmpty ? [] : [pending]
    }
}
