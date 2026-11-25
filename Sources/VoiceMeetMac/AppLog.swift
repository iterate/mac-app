import Foundation
import OSLog

/// The app's log. Every line goes to two places:
///
/// - the system's unified log, subsystem `com.iterate.voice-meet-mac`;
/// - the text file `~/Library/Logs/voice-meet-mac/app.log` (`<home>/logs/app.log` for a copy with a
///   home of its own, `AppEnvironment`), which a person or an agent can follow with `tail -F`.
///
/// The lines hold states, events, formats, sizes, counts, device names and errors. They hold no
/// picture, no sound and no window title.
struct AppLog: Sendable {
    static let subsystem = "com.iterate.voice-meet-mac"
    static var directory: URL { AppEnvironment.current.logDirectory }
    static var fileURL: URL { directory.appendingPathComponent("app.log") }

    private let category: String
    private let logger: Logger

    init(_ category: String) {
        self.category = category
        logger = Logger(subsystem: Self.subsystem, category: category)
    }

    func info(_ message: String) {
        logger.info("\(message, privacy: .public)")
        LogFile.shared.write(level: "I", category: category, message: message)
    }

    func error(_ message: String) {
        logger.error("\(message, privacy: .public)")
        LogFile.shared.write(level: "E", category: category, message: message)
    }

    /// The domain and the code say more than the localized text ("The operation couldn't be completed").
    static func describe(_ error: Error) -> String {
        let nsError = error as NSError
        var text = "\(nsError.domain) \(nsError.code): \(nsError.localizedDescription)"
        if let underlying = nsError.userInfo[NSUnderlyingErrorKey] as? NSError {
            text += " (underlying \(underlying.domain) \(underlying.code))"
        }
        return text
    }
}

/// The one writer of `app.log`. A lock makes it safe from every thread; each line is written at
/// once, so a crash loses nothing that was logged. The file has a bound: past `maxBytes` (at the
/// start, or while the app runs) it becomes `app.previous.log`, in place of the one before, and a
/// new `app.log` begins. So the two hold the last 20 to 40 MB.
private final class LogFile: @unchecked Sendable {
    static let shared = LogFile()
    static let maxBytes: UInt64 = 20 * 1024 * 1024

    private let lock = NSLock()
    private var handle: FileHandle?
    private var written: UInt64 = 0
    private let timestamps = Date.ISO8601FormatStyle(includingFractionalSeconds: true)

    private init() {
        try? FileManager.default.createDirectory(at: AppLog.directory, withIntermediateDirectories: true)
        let size = (try? FileManager.default.attributesOfItem(atPath: AppLog.fileURL.path)[.size] as? NSNumber)?.uint64Value ?? 0
        if size > Self.maxBytes { Self.setAside() }
        open()
    }

    func write(level: String, category: String, message: String) {
        let line = Data("\(Date().formatted(timestamps)) \(level) [\(category)] \(message)\n".utf8)
        lock.lock()
        defer { lock.unlock() }
        if written + UInt64(line.count) > Self.maxBytes {
            try? handle?.close()
            Self.setAside()
            open()
        }
        try? handle?.write(contentsOf: line)
        written += UInt64(line.count)
    }

    /// app.log becomes app.previous.log, in place of the one before.
    private static func setAside() {
        let previous = AppLog.directory.appendingPathComponent("app.previous.log")
        _ = Darwin.rename(AppLog.fileURL.path, previous.path)
    }

    private func open() {
        let manager = FileManager.default
        if !manager.fileExists(atPath: AppLog.fileURL.path) {
            manager.createFile(atPath: AppLog.fileURL.path, contents: nil)
        }
        handle = try? FileHandle(forWritingTo: AppLog.fileURL)
        written = (try? handle?.seekToEnd()) ?? 0
    }
}
