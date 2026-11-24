import Foundation

/// A child process that speaks JSON lines: the app's one way to run a script of the bridge
/// (`bridge/mind.mjs`, through `MindBridge`).
///
/// stdout is framed by bytes: a line ends at its `\n`, and only a whole line is decoded, so a
/// character whose bytes come in two reads stays whole. Each line that is a JSON object goes to
/// `said`; each line of stderr goes to `logged`. `exited` is told last, once the process has ended
/// and both pipes are read to their end: no line comes after it. Every callback is on the main
/// actor, in the order the child wrote.
@MainActor
public final class JSONLineProcess {
    public var said: ([String: Any]) -> Void = { _ in }
    public var logged: (String) -> Void = { _ in }
    public var exited: (Int32) -> Void = { _ in }

    private let process = Process()
    private let input = Pipe()

    public init(executable: String, arguments: [String]) {
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
    }

    public var pid: Int32 { process.processIdentifier }

    public func start() throws {
        let output = Pipe(), errors = Pipe()
        process.standardInput = input
        process.standardOutput = output
        process.standardError = errors
        // the end waits for three things: the end of stdout, of stderr, and of the process
        let ends = DispatchGroup()
        read(output, ends) { [weak self] line in
            if let object = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any] {
                self?.said(object)
            } else if !line.isEmpty {
                self?.logged("not a JSON line: \(String(decoding: line.prefix(200), as: UTF8.self))")
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
            throw error
        }
        let process = process
        ends.notify(queue: .main) { [weak self] in
            MainActor.assumeIsolated { self?.exited(process.terminationStatus) }
        }
    }

    /// One line to the child's stdin.
    public func send(_ object: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: object, options: [.withoutEscapingSlashes]) else { return }
        try? input.fileHandleForWriting.write(contentsOf: data + Data([0x0A]))
    }

    /// The child's stdin ends: a bridge script then ends its work and exits.
    public func closeInput() {
        try? input.fileHandleForWriting.close()
    }

    /// Reads `pipe` on its own queue and hands each whole line to `line` on the main queue.
    private func read(_ pipe: Pipe, _ ends: DispatchGroup, _ line: @escaping @MainActor (Data) -> Void) {
        ends.enter()
        let lines = LineBuffer()
        pipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            let whole = data.isEmpty ? lines.end() : lines.add(data)
            for each in whole { DispatchQueue.main.async { MainActor.assumeIsolated { line(each) } } }
            guard data.isEmpty else { return }
            handle.readabilityHandler = nil
            // after the lines above: `notify` runs on the main queue behind them
            ends.leave()
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
        while let end = pending.firstIndex(of: 0x0A) {
            lines.append(Data(pending[pending.startIndex..<end]))
            pending = Data(pending[pending.index(after: end)...])
        }
        return lines
    }

    /// The stream ended: what is left is the last line.
    public func end() -> [Data] {
        defer { pending = Data() }
        return pending.isEmpty ? [] : [pending]
    }
}
