import AppKit
import SpeechText
import VoiceMeetCore

/// THE HISTORY OF TRANSCRIPTS on this Mac (README, "Dictation"): every finished dictation and,
/// with Always listen, every finished stretch (`TranscriptHistory`). It is the file
/// `dictation-history.jsonl` in the app's home, at most 2,000 entries of the last 30 days. It
/// never goes to a mind: the record's transcript track already does, when the person shares it.
///
/// The file is read and written on a queue of its own: an entry is one line appended; a trim, a
/// replaced line or Clear writes the whole file again. A file that cannot be read starts empty,
/// with one line in the log, and its bytes are kept beside it as `dictation-history.broken.jsonl`.
///
/// Settings › Dictation, "Keep a history" (`dictation.history`, on unless set): off, an entry is
/// kept in memory alone, for "Paste the last transcript", and nothing is written.
@MainActor
final class History: ObservableObject {
    static let shared = History(file: AppEnvironment.current.folder.appendingPathComponent("dictation-history.jsonl"))

    @Published private(set) var history = TranscriptHistory()
    /// Settings › Dictation, "Keep a history".
    @Published var keeps: Bool {
        didSet {
            AppEnvironment.current.defaults.set(keeps, forKey: "dictation.history")
            log.info(keeps ? "kept: each transcript goes into the history" : "not kept: no transcript goes into the history from now")
        }
    }
    /// The file was read: before, the history is empty because it is not yet known.
    private(set) var isRead = false
    /// The newest entry while "Keep a history" is off: in memory only.
    private var unkept: TranscriptEntry?

    private let file: URL?
    private let queue = DispatchQueue(label: "history.file", qos: .utility)
    private let log = AppLog("history")
    /// Entries that came before the file was read: they go in after it.
    private var early: [TranscriptEntry] = []
    /// The lines in the file: past twice the entries, the file is written again.
    private var lines = 0

    init(file: URL?) {
        self.file = file
        keeps = AppEnvironment.current.defaults.object(forKey: "dictation.history") as? Bool ?? true
    }

    /// A drawing's, with no file.
    init(fixed entries: [TranscriptEntry]) {
        file = nil
        keeps = true
        history = TranscriptHistory(entries)
        isRead = true
    }

    /// Reads the file, once, on the queue.
    func read() {
        guard let file, !isRead else { return }
        let now = Date().timeIntervalSince1970
        queue.async { [log] in
            var result = (history: TranscriptHistory(), broken: 0, rewrite: false)
            var failure: String?
            if FileManager.default.fileExists(atPath: file.path) {
                do {
                    result = TranscriptHistory.read(try Data(contentsOf: file), now: now)
                } catch {
                    failure = AppLog.describe(error)
                    result.rewrite = true
                }
            }
            if result.broken > 0 || failure != nil {
                let broken = file.deletingPathExtension().appendingPathExtension("broken.jsonl")
                try? FileManager.default.removeItem(at: broken)
                try? FileManager.default.copyItem(at: file, to: broken)
                log.error(
                    failure.map { "the file could not be read (\($0)): the history starts empty; the old file is \(broken.lastPathComponent)" }
                        ?? "\(result.broken == 1 ? "1 line of the file was no entry: it is" : "\(result.broken) lines of the file were no entry: they are") skipped; the old file is \(broken.lastPathComponent)")
            }
            if result.rewrite { Self.write(result.history.file, to: file, log: log) }
            DispatchQueue.main.async {
                MainActor.assumeIsolated { self.didRead(result.history, lines: result.history.entries.count) }
            }
        }
    }

    private func didRead(_ read: TranscriptHistory, lines: Int) {
        history = read
        self.lines = lines
        isRead = true
        log.info("read: \(read.entries.count) entries")
        let early = self.early
        self.early = []
        for entry in early { add(entry) }
    }

    /// A new entry, or a newer form of one (the same id).
    func add(_ entry: TranscriptEntry) {
        guard keeps else {
            unkept = entry
            return
        }
        unkept = nil
        guard isRead || file == nil else { return early.append(entry) }
        let trimmed = history.add(entry, now: Date().timeIntervalSince1970)
        guard let file else { return }
        lines += 1
        if trimmed || lines > 2 * max(history.entries.count, 50) {
            lines = history.entries.count
            let data = history.file
            queue.async { [log] in Self.write(data, to: file, log: log) }
        } else {
            let line = entry.line
            queue.async { [log] in Self.append(line, to: file, log: log) }
        }
    }

    /// Settings › Dictation, "Clear History…", after the person said yes.
    func clear() {
        let count = history.entries.count
        history.clear()
        early = []
        unkept = nil
        lines = 0
        log.info("cleared: \(count) entries")
        guard let file else { return }
        queue.async { [log] in Self.write(Data(), to: file, log: log) }
    }

    /// What "Paste the last transcript" writes: the newest entry with words.
    var newest: TranscriptEntry? {
        guard let kept = history.newest else { return unkept.flatMap { $0.text.isEmpty ? nil : $0 } }
        guard let unkept, !unkept.text.isEmpty, unkept.at > kept.at else { return kept }
        return unkept
    }

    /// Waits for the queue: what was written is in the file (the tests, and the app's end).
    func flush() { queue.sync {} }

    nonisolated private static func write(_ data: Data, to file: URL, log: AppLog) {
        do {
            try data.write(to: file, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        } catch {
            log.error("the file was not written: \(AppLog.describe(error))")
        }
    }

    nonisolated private static func append(_ line: Data, to file: URL, log: AppLog) {
        guard FileManager.default.fileExists(atPath: file.path) else { return write(line, to: file, log: log) }
        do {
            let handle = try FileHandle(forWritingTo: file)
            defer { try? handle.close() }
            try handle.seekToEnd()
            try handle.write(contentsOf: line)
        } catch {
            log.error("the entry was not written: \(AppLog.describe(error))")
        }
    }

    /// For `ui.state`: counts, and the newest entry's text, which a test reads in its own copy.
    func controlState() -> [String: Any] {
        [
            "keeps": keeps, "read": isRead, "entries": history.entries.count,
            "newest": newest.map { ["text": $0.text, "kind": $0.kind.rawValue, "outcome": $0.outcome.rawValue, "app": $0.app ?? NSNull()] as [String: Any] }
                ?? NSNull(),
        ]
    }

    // MARK: - The apps' icons

    private var icons: [String: NSImage] = [:]

    /// The icon of the app with `bundle`, made once; nil in a drawing (the same on every Mac).
    func icon(_ bundle: String?) -> NSImage? {
        guard let bundle, !AppEnvironment.current.isRendering else { return nil }
        if let icon = icons[bundle] { return icon }
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundle) else { return nil }
        let icon = NSWorkspace.shared.icon(forFile: url.path)
        icons[bundle] = icon
        return icon
    }
}
