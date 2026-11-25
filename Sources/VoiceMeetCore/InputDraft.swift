import Foundation

/// THE PERSON'S INPUT TO A MIND, while they write it and while it goes: a text and files
/// (README, "Input"). Pure: the app's bar (`MindInput`) shows it and does what it says.
///
/// An input is sent whole, by the job `input` of `bridge/mind.mjs`: the files into the mind's
/// files, then one event. While it goes the draft is `sending`; `done` gives a new, empty draft; a failure keeps
/// the text and the files with the reason. The next send of the same text and files is the same
/// `input.json`, byte for byte (its id and its time), so an input whose answer was lost is in the
/// mind once. A send after a change is another input: it has a new id.
public struct InputDraft: Equatable, Sendable {
    public struct Attachment: Equatable, Sendable, Identifiable {
        public let id: Int
        /// The file's name as the person sees it.
        public let name: String
        /// The file on this Mac.
        public let local: String
        public let bytes: Int
        public let contentType: String
    }

    public enum Phase: Equatable, Sendable {
        case editing
        /// The part of the bytes that went, 0 to 1.
        case sending(progress: Double)
        case failed(String)
    }

    /// What the sender's answer meant.
    public enum Outcome: Equatable, Sendable {
        case nothing
        case sent
        case failed(String)
    }

    public static let mostFiles = 20
    /// One file's bound: a signed upload is one request.
    public static let mostBytes = 500 * 1024 * 1024
    public static let mostCharacters = 100_000

    public private(set) var id: String
    public var text = ""
    public private(set) var attachments: [Attachment] = []
    public private(set) var phase: Phase = .editing
    /// Why the last file was not attached. The next change of the files clears it.
    public private(set) var refusal: String?
    private var nextAttachment = 1
    /// The last `input.json` that went, and what it was made of: a send of the same goes again as it was.
    private var sent: (made: Made, input: Data)?

    /// What an input is made of: the text as it goes and each file.
    private struct Made: Equatable {
        let text: String
        let files: [[String]]
    }

    public static func == (a: InputDraft, b: InputDraft) -> Bool {
        a.id == b.id && a.text == b.text && a.attachments == b.attachments && a.phase == b.phase && a.refusal == b.refusal
            && a.nextAttachment == b.nextAttachment && a.sent?.made == b.sent?.made && a.sent?.input == b.sent?.input
    }

    public init(id: String) {
        self.id = id
    }

    public var isSending: Bool {
        if case .sending = phase { return true }
        return false
    }

    public var isEmpty: Bool {
        text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && attachments.isEmpty
    }

    /// The reason the draft cannot go now, or nil.
    public var cannotSend: String? {
        if isSending { return "The input before this one is still going." }
        if isEmpty { return "Type something, or add a file." }
        if text.count > Self.mostCharacters { return "The text is longer than \(Self.mostCharacters) characters." }
        return nil
    }

    /// Adds a file. False, with `refusal`, when it is a folder, too large, one too many or there already.
    @discardableResult
    public mutating func attach(name: String, local: String, bytes: Int, contentType: String, isFolder: Bool = false) -> Bool {
        refusal = nil
        guard !isSending else { return false }
        if isFolder {
            refusal = "\(name) is a folder: add its files."
        } else if bytes > Self.mostBytes {
            refusal = "\(name) is larger than \(Self.mostBytes / (1024 * 1024)) MB."
        } else if attachments.contains(where: { $0.local == local }) {
            refusal = "\(name) is added already."
        } else if attachments.count >= Self.mostFiles {
            refusal = "An input takes at most \(Self.mostFiles) files."
        }
        guard refusal == nil else { return false }
        attachments.append(Attachment(id: nextAttachment, name: name, local: local, bytes: bytes, contentType: contentType))
        nextAttachment += 1
        if case .failed = phase { phase = .editing }
        return true
    }

    /// A file that could not be read, or an input with no mind to go to: the reason, for the bar.
    public mutating func refuse(_ reason: String) {
        refusal = reason
    }

    public mutating func remove(_ attachment: Int) {
        guard !isSending else { return }
        refusal = nil
        attachments.removeAll { $0.id == attachment }
    }

    /// An input's id: its time and four random hex digits, as a capture's.
    public static func newId(at time: Date = Date()) -> String {
        let stamp = ISO8601DateFormatter().string(from: time).replacingOccurrences(of: "-", with: "").replacingOccurrences(of: ":", with: "")
        return "\(stamp)-\(String(format: "%04x", UInt16.random(in: 0...UInt16.max)))"
    }

    /// Return was pressed. The answer is `input.json` for the sender, or nil with the reason in `phase`.
    /// The same text and files as the last send that failed: that `input.json` again. Else, after
    /// such a send, the input has a new id from `newId`.
    public mutating func submit(at: Date, newId: () -> String = { InputDraft.newId() }) -> Data? {
        guard !isSending else { return nil }
        if let reason = cannotSend {
            phase = .failed(reason)
            return nil
        }
        let made = Made(
            text: text.trimmingCharacters(in: .whitespacesAndNewlines),
            files: attachments.map { [$0.local, $0.name, $0.contentType, String($0.bytes)] })
        if let sent {
            if sent.made == made {
                refusal = nil
                phase = .sending(progress: 0)
                return sent.input
            }
            // the mind may have the earlier one: this is another input
            id = newId()
        }
        let input: [String: Any] = [
            "id": id,
            "text": made.text,
            "at": ISO8601DateFormatter().string(from: at),
            "files": attachments.map { ["local": $0.local, "name": $0.name, "contentType": $0.contentType] },
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: input, options: [.sortedKeys]) else {
            phase = .failed("The input could not be written.")
            return nil
        }
        sent = (made, data)
        refusal = nil
        phase = .sending(progress: 0)
        return data
    }

    /// One JSON line of the sender's stdout. After `sent` the draft is new and empty, with `next` as its id.
    public mutating func senderSaid(_ line: [String: Any], next: String) -> Outcome {
        guard isSending else { return .nothing }
        if let reason = line["failed"] as? String {
            phase = .failed(reason)
            return .failed(reason)
        }
        if line["done"] as? Bool == true {
            self = InputDraft(id: next)
            return .sent
        }
        if let progress = line["progress"] as? Double { phase = .sending(progress: min(max(progress, 0), 1)) }
        return .nothing
    }

    /// The sender's process ended. With no answer before, that is a failure.
    public mutating func senderEnded(status: Int32) -> Outcome {
        guard isSending else { return .nothing }
        let reason = "The sender ended with no answer (exit \(status))."
        phase = .failed(reason)
        return .failed(reason)
    }

    /// The sender could not start.
    public mutating func senderDidNotStart(_ reason: String) {
        guard isSending else { return }
        phase = .failed(reason)
    }

    /// A size in words: "812 bytes", "34 KB", "2.1 MB".
    public static func size(_ bytes: Int) -> String {
        if bytes < 1024 { return "\(bytes) bytes" }
        if bytes < 1024 * 1024 { return "\(bytes / 1024) KB" }
        return String(format: "%.1f MB", Double(bytes) / (1024 * 1024))
    }
}
