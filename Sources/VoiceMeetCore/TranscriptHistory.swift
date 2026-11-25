import Foundation

/// ONE ENTRY OF THE HISTORY OF TRANSCRIPTS (README, "Dictation"): a finished dictation, or a
/// finished stretch of Always listen. Its text is as it was written, with the word list's
/// corrections. It stays on this Mac: it is never an event to a mind.
public struct TranscriptEntry: Equatable, Sendable, Identifiable {
    public enum Kind: String, Sendable {
        /// fn or ⌥⇧D.
        case dictation
        /// A stretch of Always listen, heard with no key.
        case stretch
    }

    public enum Outcome: String, Sendable {
        /// Written where the cursor is (or put on the clipboard).
        case written
        /// The dictation ended and heard no words.
        case heardNothing = "heard-nothing"
        /// Esc threw it away: its text is kept here, to get it back.
        case cancelled
        /// The listening failed before the text was written.
        case failed
        /// A stretch of Always listen: heard, and written nowhere.
        case heard
    }

    /// Unique over every run of the app.
    public let id: String
    public var kind: Kind
    public var outcome: Outcome
    /// When it ended, in Unix seconds.
    public var at: Double
    public var text: String
    /// The app it went into: its name and bundle id. Nil for a stretch.
    public var app: String?
    public var bundle: String?
    /// The title of the window it went into. Never of an app that `ExcludeList` names.
    public var window: String?
    /// The model that heard it (`parakeet-v3`, `gpt-live-transcribe`).
    public var model: String?
    public var seconds: Double

    public init(
        id: String = UUID().uuidString, kind: Kind, outcome: Outcome, at: Double, text: String, app: String? = nil, bundle: String? = nil,
        window: String? = nil, model: String? = nil, seconds: Double = 0
    ) {
        self.id = id
        self.kind = kind
        self.outcome = outcome
        self.at = at
        self.text = text
        self.app = app
        self.bundle = bundle
        self.window = window
        self.model = model
        // tenths: as the file keeps it
        self.seconds = (seconds * 10).rounded() / 10
    }

    public var words: Int { Spoken.wordCount(text) }

    /// The entry as one line of the history's file: JSON with sorted keys, and a newline.
    public var line: Data {
        var object: [String: Any] = [
            "id": id, "kind": kind.rawValue, "outcome": outcome.rawValue, "at": at, "text": text, "words": words,
            "seconds": seconds,
        ]
        for (key, value) in [("app", app), ("bundle", bundle), ("window", window), ("model", model)] {
            if let value { object[key] = value }
        }
        let data = (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes])) ?? Data()
        return data + Data("\n".utf8)
    }

    /// An entry from one line of the file; nil for a line that is not one.
    public init?(line: Data) {
        guard let object = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any],
            let id = object["id"] as? String, !id.isEmpty,
            let kind = (object["kind"] as? String).flatMap(Kind.init(rawValue:)),
            let outcome = (object["outcome"] as? String).flatMap(Outcome.init(rawValue:)),
            let at = (object["at"] as? NSNumber)?.doubleValue, at.isFinite,
            let text = object["text"] as? String
        else { return nil }
        self.init(
            id: id, kind: kind, outcome: outcome, at: at, text: text, app: object["app"] as? String, bundle: object["bundle"] as? String,
            window: object["window"] as? String, model: object["model"] as? String, seconds: (object["seconds"] as? NSNumber)?.doubleValue ?? 0)
    }
}

/// THE HISTORY OF TRANSCRIPTS, as pure values: at most `most` entries of the last `days` days, the
/// oldest dropped first. Its file is JSON lines, one entry a line; a later line with the id of an
/// earlier one replaces it (a stretch's next segment, the window's title read after the entry).
public struct TranscriptHistory: Equatable, Sendable {
    public static let most = 2_000
    public static let days = 30.0

    /// Oldest first.
    public private(set) var entries: [TranscriptEntry] = []

    public init(_ entries: [TranscriptEntry] = []) {
        for entry in entries { put(entry) }
    }

    /// Adds `entry`, or replaces the one with its id, in time order. True when the oldest went:
    /// the file is then written again.
    @discardableResult
    public mutating func add(_ entry: TranscriptEntry, now: Double) -> Bool {
        put(entry)
        return trim(now: now)
    }

    private mutating func put(_ entry: TranscriptEntry) {
        if let index = entries.firstIndex(where: { $0.id == entry.id }) { entries.remove(at: index) }
        let index = entries.lastIndex { $0.at <= entry.at }.map { $0 + 1 } ?? 0
        entries.insert(entry, at: index)
    }

    /// Drops what is past `most` and older than `days`. True when something went.
    @discardableResult
    public mutating func trim(now: Double) -> Bool {
        let count = entries.count
        let oldest = now - Self.days * 86_400
        entries.removeAll { $0.at < oldest }
        if entries.count > Self.most { entries.removeFirst(entries.count - Self.most) }
        return entries.count != count
    }

    public mutating func clear() { entries = [] }

    /// What "Paste the last transcript" writes: the newest entry with words, a dictation's or a
    /// stretch's, whichever ended last.
    public var newest: TranscriptEntry? { entries.last { !$0.text.isEmpty } }

    /// Newest first; with a search, only the entries whose text has every word of it, in any case.
    public func shown(search: String = "") -> [TranscriptEntry] {
        let terms = search.split(whereSeparator: \.isWhitespace).map(String.init)
        let newestFirst = entries.reversed()
        guard !terms.isEmpty else { return Array(newestFirst) }
        return newestFirst.filter { entry in
            terms.allSatisfy { entry.text.range(of: $0, options: [.caseInsensitive, .diacriticInsensitive]) != nil }
        }
    }

    /// The whole history as its file.
    public var file: Data { entries.reduce(into: Data()) { $0.append($1.line) } }

    /// The history in a file's bytes. `broken`: lines that are no entry, which are skipped.
    /// `rewrite`: the file is not as `file` would write it (a broken or replaced line, an entry
    /// that went), so it is written again.
    public static func read(_ data: Data, now: Double) -> (history: TranscriptHistory, broken: Int, rewrite: Bool) {
        var history = TranscriptHistory()
        var broken = 0
        var lines = 0
        for line in data.split(separator: UInt8(ascii: "\n"), omittingEmptySubsequences: true) {
            lines += 1
            if let entry = TranscriptEntry(line: Data(line)) { history.put(entry) } else { broken += 1 }
        }
        let trimmed = history.trim(now: now)
        let endsBadly = !data.isEmpty && data.last != UInt8(ascii: "\n")
        return (history, broken, broken > 0 || trimmed || endsBadly || lines != history.entries.count)
    }
}
