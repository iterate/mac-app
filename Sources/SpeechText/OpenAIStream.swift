import CryptoKit
import Foundation
import Security
import os

/// ONE DICTATION AT OPENAI: the realtime transcription over a WebSocket (README, "Dictation"), in
/// the session shape that `harness/speech-bench/engines/openai.mjs` measured. A `transcription`
/// session of 24 kHz pcm16 with no turn detection; the sound as it comes; a commit at the end; the
/// item's `completed` text is the final. Each `delta` adds to the words so far, which `text` hears.
///
/// The socket is an `OpenAISocket`: the direct one with this Mac's key (`DirectSocket`), or the one
/// that the lent mind's bridge relays with the mind's key (`RelaySocket`). This stream is the same
/// on both. It is bounded: the socket and the session's setup must be ready within
/// `connectTimeout`, and the final must come within `finalTimeout` of the commit; else it throws,
/// and the caller (`StreamRecognizer`) lets the local model hear the sound. Everything runs on the
/// socket's callbacks, with no polling.
public final class OpenAIStream: SpeechStream, @unchecked Sendable {
    /// gpt-live-transcribe's price, by audio duration (its model page, 25 Nov 2026).
    public static let dollarsPerMinute = 0.017
    public struct Setup: Sendable, Equatable {
        public var url = URL(string: "wss://api.openai.com/v1/realtime?intent=transcription")!
        public var model = "gpt-live-transcribe"
        /// `low` had the lower WER and the faster final of the two delays (speech-bench).
        public var delay: String? = "low"
        /// The bench's prompt.
        public var prompt = "A software engineer dictating to a coding agent about the iterate platform."
        /// The word list's terms.
        public var keywords: [String] = []
        public var connectTimeout = 5.0
        public var finalTimeout = 5.0

        public init(keywords: [String] = []) {
            self.keywords = keywords
        }

        /// The `session.update` message.
        var sessionUpdate: [String: Any] {
            var transcription: [String: Any] = ["model": model, "prompt": prompt, "languages": ["en"]]
            if let delay { transcription["delay"] = delay }
            if !keywords.isEmpty { transcription["keywords"] = keywords }
            return [
                "type": "session.update",
                "session": [
                    "type": "transcription",
                    "audio": ["input": ["format": ["type": "audio/pcm", "rate": 24000], "transcription": transcription, "turn_detection": NSNull()]],
                ] as [String: Any],
            ]
        }
    }

    public enum Failure: Error, LocalizedError, Equatable {
        case noKey
        case timedOut(String)
        case failed(String)
        case cancelled

        public var errorDescription: String? {
            switch self {
            case .noKey: "no mind with an OpenAI key and no OpenAI key of this Mac"
            case .timedOut(let what): "no \(what) in time"
            case .failed(let reason): reason
            case .cancelled: "cancelled"
            }
        }
    }

    private let setup: Setup
    private let socket: OpenAISocket
    /// Under the lock: a standby (`OpenAIStandby`) hands them over when a dictation takes it.
    private var text: @Sendable (String) -> Void
    private var failed: @Sendable (String) -> Void

    private let lock = NSLock()
    private var said = ""
    private var item: String?
    private var finals: [String: String] = [:]
    /// What OpenAI billed for each item: `usage.seconds` of its `completed` event (the sound,
    /// rounded up to the second; 25 Nov 2026).
    private var billed: [String: Double] = [:]
    /// When the socket was made: a standby may wait minutes, which OpenAI does not bill.
    public let made = Date()
    /// The seconds from the start of the socket to OpenAI's `session.created`: the socket's own
    /// opening, through the mind or direct.
    public var createdAfter: Double? { lock.withLock { created } }
    private var created: Double?
    private var failure: Failure?
    private var isClosed = false
    private var isCommitted = false
    private var opened: CheckedContinuation<Void, Error>?
    private var isOpen = false
    private var final: CheckedContinuation<String, Error>?
    private var upsampler = Upsampler()
    /// Samples at 24 kHz sent so far.
    private var sent = 0

    private init(setup: Setup, socket: OpenAISocket, text: @escaping @Sendable (String) -> Void, failed: @escaping @Sendable (String) -> Void) {
        self.setup = setup
        self.socket = socket
        self.text = text
        self.failed = failed
    }

    /// Opens `socket` and configures the session. `text` hears the words so far at each delta;
    /// `failed` hears a failure that comes while the sound streams (not one that `open` or
    /// `finish` throws).
    public static func open(
        _ setup: Setup, socket: OpenAISocket, text: @escaping @Sendable (String) -> Void, failed: @escaping @Sendable (String) -> Void
    ) async throws -> OpenAIStream {
        let stream = OpenAIStream(setup: setup, socket: socket, text: text, failed: failed)
        try await stream.connect()
        return stream
    }

    /// With this Mac's key, on the direct socket to `setup.url`.
    public static func open(
        _ setup: Setup, key: String, text: @escaping @Sendable (String) -> Void, failed: @escaping @Sendable (String) -> Void
    ) async throws -> OpenAIStream {
        try await open(setup, socket: DirectSocket(url: setup.url, key: key), text: text, failed: failed)
    }

    /// A standby taken by a dictation: from now on `text` and `failed` are the dictation's. False
    /// when the socket failed or closed before: the caller opens a new one.
    func attach(text: @escaping @Sendable (String) -> Void, failed: @escaping @Sendable (String) -> Void) -> Bool {
        lock.withLock {
            guard failure == nil, !isClosed, isOpen else { return false }
            self.text = text
            self.failed = failed
            return true
        }
    }

    /// Whether the socket answers a ping within `within` seconds. A standby that waited may be
    /// dead with no sign (a sleep, another network), so a dictation asks before it takes it.
    func ping(within: Double) async -> Bool {
        guard lock.withLock({ failure == nil && !isClosed && isOpen }) else { return false }
        return await socket.ping(within: within)
    }

    private func connect() async throws {
        socket.start(
            heard: { [weak self] text in self?.handle(Data(text.utf8)) },
            ended: { [weak self] why in self?.fail(.failed(why)) })
        send(setup.sessionUpdate)
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            lock.withLock {
                if let failure { return continuation.resume(throwing: failure) }
                // the session may be ready before this line: a relay answers on another thread
                if isOpen { return continuation.resume() }
                opened = continuation
            }
            DispatchQueue.global().asyncAfter(deadline: .now() + setup.connectTimeout) { [weak self] in
                self?.fail(.timedOut("session after \(Int(self?.setup.connectTimeout ?? 0)) s"), only: .open)
            }
        }
    }

    /// The next 16 kHz samples. Nothing is sent after the commit or a failure.
    public func push(_ samples: [Float]) {
        let pcm: [Int16]? = lock.withLock {
            guard !isClosed, !isCommitted, failure == nil else { return nil }
            let pcm = upsampler.next(samples)
            sent += pcm.count
            return pcm
        }
        guard let pcm, !pcm.isEmpty else { return }
        // at most half a second a message: a socket that opened late sends what was kept in pieces
        for start in stride(from: 0, to: pcm.count, by: 12_000) {
            let piece = pcm[start..<min(start + 12_000, pcm.count)]
            let bytes = piece.withUnsafeBufferPointer { Data(buffer: $0) }
            send(["type": "input_audio_buffer.append", "audio": bytes.base64EncodedString()])
        }
    }

    /// Commits the sound and waits for its text. Less than 0.1 s of sound (OpenAI refuses a
    /// smaller commit) is no text.
    public func finish() async throws -> String {
        let tooShort: Bool = try lock.withLock {
            if let failure { throw failure }
            isCommitted = true
            return sent < 2_400
        }
        if tooShort {
            close()
            return ""
        }
        send(["type": "input_audio_buffer.commit"])
        defer { close() }
        return try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<String, Error>) in
            lock.withLock {
                if let failure { return continuation.resume(throwing: failure) }
                final = continuation
            }
            answerFinal()
            DispatchQueue.global().asyncAfter(deadline: .now() + setup.finalTimeout) { [weak self] in
                self?.fail(.timedOut("final after \(Int(self?.setup.finalTimeout ?? 0)) s"), only: .final)
            }
        }
    }

    public func cancel() {
        fail(.cancelled)
        close()
    }

    private func close() {
        let wasClosed = lock.withLock {
            defer { isClosed = true }
            return isClosed
        }
        if !wasClosed { socket.close(normal: true) }
    }

    private func send(_ message: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: message), let string = String(data: data, encoding: .utf8) else { return }
        socket.send(string)
    }

    private func handle(_ data: Data) {
        guard let event = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any], let type = event["type"] as? String else { return }
        let message = ((event["error"] as? [String: Any])?["message"] as? String) ?? type
        switch type {
        case "session.created":
            let after = Date().timeIntervalSince(made)
            lock.withLock { if created == nil { created = after } }
        case "session.updated":
            let continuation: CheckedContinuation<Void, Error>? = lock.withLock {
                defer { opened = nil }
                isOpen = true
                return opened
            }
            continuation?.resume()
        case "input_audio_buffer.committed":
            lock.withLock { item = event["item_id"] as? String }
            answerFinal()
        case "conversation.item.input_audio_transcription.delta":
            guard let delta = event["delta"] as? String else { return }
            let (words, text): (String, @Sendable (String) -> Void) = lock.withLock {
                said += delta
                return (said, self.text)
            }
            if !words.trimmingCharacters(in: .whitespaces).isEmpty { text(words) }
        case "conversation.item.input_audio_transcription.completed":
            guard let id = event["item_id"] as? String else { return }
            let usage = event["usage"] as? [String: Any]
            lock.withLock {
                finals[id] = event["transcript"] as? String ?? ""
                if usage?["type"] as? String == "duration", let seconds = usage?["seconds"] as? Double { billed[id] = seconds }
            }
            answerFinal()
        case "conversation.item.input_audio_transcription.failed", "error":
            fail(.failed("OpenAI: \(message)"))
        default:
            break
        }
    }

    /// The seconds OpenAI billed for the committed sound, once its final came; nil when it said none.
    public var billedSeconds: Double? { lock.withLock { item.flatMap { billed[$0] } } }

    /// The final, when it is here and asked for.
    private func answerFinal() {
        let answer: (CheckedContinuation<String, Error>, String)? = lock.withLock {
            guard let final, let item, let text = finals[item] else { return nil }
            self.final = nil
            return (final, text)
        }
        if let (continuation, text) = answer { continuation.resume(returning: text) }
    }

    private enum Wait { case open, final }

    /// The first failure: it answers whoever waits (`open`, `finish`); with no one waiting, while
    /// the sound streams, `failed` hears it. A failure after the close is none. `only` is a time
    /// out's: it fails that wait, if it still goes, and nothing else.
    private func fail(_ reason: Failure, only: Wait? = nil) {
        typealias Waiting = (opened: CheckedContinuation<Void, Error>?, final: CheckedContinuation<String, Error>?, streaming: Bool, failed: @Sendable (String) -> Void)
        let waiting: Waiting? = lock.withLock {
            guard failure == nil else { return nil }
            switch only {
            case .open?: guard opened != nil else { return nil }
            case .final?: guard final != nil else { return nil }
            case nil: guard !isClosed || final != nil || opened != nil else { return nil }
            }
            failure = reason
            defer {
                opened = nil
                final = nil
            }
            return (opened, final, isOpen && !isCommitted, failed)
        }
        guard let waiting else { return }
        waiting.opened?.resume(throwing: reason)
        waiting.final?.resume(throwing: reason)
        if waiting.opened == nil, waiting.final == nil, waiting.streaming, reason != .cancelled { waiting.failed(reason.localizedDescription) }
        socket.close(normal: false)
    }
}

/// 16 kHz to 24 kHz pcm16, linear, across pushes: an output sample at 24 kHz index `j` is the
/// input at 16 kHz position `2j / 3`.
struct Upsampler {
    /// The last input sample of the push before, and the count of inputs and outputs so far.
    private var last: Float = 0
    private var consumed = 0
    private var produced = 0

    mutating func next(_ input: [Float]) -> [Int16] {
        guard !input.isEmpty else { return [] }
        let total = consumed + input.count
        func sample(_ index: Int) -> Float { index < consumed ? last : input[index - consumed] }
        var output: [Int16] = []
        output.reserveCapacity(input.count * 3 / 2 + 2)
        while true {
            let index = produced * 2 / 3
            let fraction = Float(produced * 2 % 3) / 3
            if fraction == 0 ? index > total - 1 : index + 1 > total - 1 { break }
            let value = fraction == 0 ? sample(index) : sample(index) * (1 - fraction) + sample(index + 1) * fraction
            output.append(Int16(max(-1, min(1, value)) * Float(Int16.max)))
            produced += 1
        }
        consumed = total
        last = input[input.count - 1]
        return output
    }
}

/// THE OPENAI KEY of this Mac, in the login Keychain: a generic password of the service `service`
/// and the account `api-key` (README, "Dictation"). It is never in a file, a log, `ui.state` or a
/// process's arguments. `cli.mjs --openai-key-from-env` writes the same item.
public struct OpenAIKey: Sendable {
    public static let account = "api-key"
    public static let baseService = "com.iterate.mac-app.openai"

    /// The service of a home: `com.iterate.mac-app.openai` for the default home, and for a copy
    /// with a home of its own that name with `.` and the first 12 hex digits of the SHA-256 of the
    /// home's path, so that a test never reads or writes the owner's item. `cli.mjs` has the same
    /// rule (`openAIService`).
    public static func service(home: String?) -> String {
        guard let home else { return baseService }
        let hash = SHA256.hash(data: Data(home.utf8)).map { String(format: "%02x", $0) }.joined()
        return "\(baseService).\(hash.prefix(12))"
    }

    public let service: String

    public init(service: String) {
        self.service = service
    }

    private var query: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: Self.account]
    }

    /// Whether the item is there. It reads no secret, so macOS asks nothing.
    public var isSet: Bool {
        var query = query
        query[kSecReturnAttributes as String] = true
        return SecItemCopyMatching(query as CFDictionary, nil) == errSecSuccess
    }

    /// The keys read in this process, by service. macOS may ask the person at each read of an item
    /// another program wrote (`cli.mjs`), so the Keychain is read once a process; `store` and
    /// `remove` keep this in step.
    private static let known = OSAllocatedUnfairLock<[String: String]>(initialState: [:])

    /// The key, or nil: from the Keychain at the first call of this process, then from memory.
    public func read() -> String? {
        if let key = Self.known.withLock({ $0[service] }) { return key }
        guard let key = readKeychain() else { return nil }
        Self.known.withLock { $0[service] = key }
        return key
    }

    private func readKeychain() -> String? {
        var query = query
        query[kSecReturnData as String] = true
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess, let data = result as? Data else { return nil }
        let key = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        return key.isEmpty ? nil : key
    }

    /// Writes the key in place of the one before. False when the Keychain refused it.
    @discardableResult
    public func store(_ key: String) -> Bool {
        let key = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { return false }
        SecItemDelete(query as CFDictionary)
        var item = query
        item[kSecValueData as String] = Data(key.utf8)
        item[kSecAttrLabel as String] = "iterate Mac app: OpenAI API key"
        let isStored = SecItemAdd(item as CFDictionary, nil) == errSecSuccess
        Self.known.withLock { $0[service] = isStored ? key : nil }
        return isStored
    }

    @discardableResult
    public func remove() -> Bool {
        let status = SecItemDelete(query as CFDictionary)
        Self.known.withLock { $0[service] = nil }
        return status == errSecSuccess || status == errSecItemNotFound
    }
}
