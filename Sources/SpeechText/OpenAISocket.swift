import Foundation

/// ONE SOCKET OF OPENAI'S REALTIME TRANSCRIPTION, as `OpenAIStream` uses it: text frames out, text
/// frames in, a ping, a close (README, "Dictation"). Two ways carry it:
/// - `DirectSocket`: a `URLSessionWebSocketTask` to OpenAI, with this Mac's own key;
/// - `RelaySocket`: the job `openai` of the lent mind's bridge (`bridge/openai.mjs`), which opens
///   the socket through the mind with the mind's key and relays its frames over JSON lines.
///
/// `start` opens it. `heard` hears each text frame; `ended` hears, once, why it ended when it was
/// not this side's `close` (the far side closed it, it failed, or it never opened). A frame sent
/// before the socket is open waits for it, in order.
public protocol OpenAISocket: AnyObject, Sendable {
    func start(heard: @escaping @Sendable (String) -> Void, ended: @escaping @Sendable (String) -> Void)
    func send(_ text: String)
    /// Whether the socket answers within `within` seconds.
    func ping(within: Double) async -> Bool
    /// The end, from this side: `normal` at the end of a dictation, else a failure's. Nothing is
    /// heard after it.
    func close(normal: Bool)
}

/// THE DIRECT SOCKET: URLSession's WebSocket to OpenAI, with the key in the Authorization header.
/// Its callbacks run on URLSession's queue: `receive` is a chain of them, with no polling.
public final class DirectSocket: OpenAISocket, @unchecked Sendable {
    /// A shared session with no delegate: each socket is one task of it.
    private static let urlSession = URLSession(configuration: .ephemeral)

    private let task: URLSessionWebSocketTask
    private let lock = NSLock()
    private var ended: (@Sendable (String) -> Void)?

    public init(url: URL, key: String) {
        var request = URLRequest(url: url)
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        task = Self.urlSession.webSocketTask(with: request)
    }

    public func start(heard: @escaping @Sendable (String) -> Void, ended: @escaping @Sendable (String) -> Void) {
        lock.withLock { self.ended = ended }
        task.resume()
        receive(heard)
    }

    public func send(_ text: String) {
        task.send(.string(text)) { [weak self] error in
            if let error { self?.end("the socket did not send: \(error.localizedDescription)") }
        }
    }

    public func ping(within: Double) async -> Bool {
        let once = Once()
        return await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
            once.set(continuation)
            task.sendPing { error in once.resume(error == nil) }
            DispatchQueue.global().asyncAfter(deadline: .now() + within) { once.resume(false) }
        }
    }

    public func close(normal: Bool) {
        lock.withLock { ended = nil }
        task.cancel(with: normal ? .normalClosure : .goingAway, reason: nil)
    }

    private func receive(_ heard: @escaping @Sendable (String) -> Void) {
        task.receive { [weak self] result in
            guard let self else { return }
            switch result {
            case .success(.string(let string)): heard(string)
            case .success(.data(let data)): heard(String(decoding: data, as: UTF8.self))
            case .success: break
            case .failure(let error): return end("the connection ended: \(error.localizedDescription)")
            }
            receive(heard)
        }
    }

    private func end(_ why: String) {
        let ended: (@Sendable (String) -> Void)? = lock.withLock {
            defer { self.ended = nil }
            return self.ended
        }
        ended?(why)
    }
}

/// THE RELAY SOCKET: one socket that the lent mind's bridge opens through the mind (the job
/// `openai`, `bridge/openai.mjs`). Each line it sends is `{ socket: id, … }`, given to `send`
/// (the app adds the job and writes it to the bridge's stdin, in order); each line of the bridge
/// for this id comes to `take`. The lines: out `open`, `frame`, `ping`, `close`; in `opened`,
/// `frame`, `pong`, `closed {code, reason}`, `failed {refused?}`.
///
/// Its ping asks the bridge, which answers when the socket is open there: a pong says the hop to
/// the bridge is up and the bridge holds the socket; a drop of the bridge's link to the mind fails
/// the socket by itself (`failed`), and so does an exit of the bridge (`fail`).
public final class RelaySocket: OpenAISocket, @unchecked Sendable {
    public let id: String
    private let send: @Sendable ([String: Any]) -> Void
    private let lock = NSLock()
    private var heard: (@Sendable (String) -> Void)?
    private var ended: (@Sendable (String) -> Void)?
    private var isEnded = false
    private var pings: [Int: Once] = [:]
    private var nextPing = 0

    /// `send` writes one line to the bridge, from any thread.
    public init(id: String, send: @escaping @Sendable ([String: Any]) -> Void) {
        self.id = id
        self.send = send
    }

    public func start(heard: @escaping @Sendable (String) -> Void, ended: @escaping @Sendable (String) -> Void) {
        let isEnded: Bool = lock.withLock {
            self.heard = heard
            self.ended = ended
            return self.isEnded
        }
        // a socket that failed before its start (the bridge exited) says so at once
        if isEnded { return fail("the mind's bridge ended") }
        send(["socket": id, "open": true])
    }

    public func send(_ text: String) {
        guard !lock.withLock({ isEnded }) else { return }
        send(["socket": id, "frame": text])
    }

    public func ping(within: Double) async -> Bool {
        let once = Once()
        let number: Int? = lock.withLock {
            guard !isEnded else { return nil }
            nextPing += 1
            pings[nextPing] = once
            return nextPing
        }
        guard let number else { return false }
        return await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
            once.set(continuation)
            send(["socket": id, "ping": number])
            DispatchQueue.global().asyncAfter(deadline: .now() + within) { [weak self] in
                once.resume(false)
                self?.lock.withLock { _ = self?.pings.removeValue(forKey: number) }
            }
        }
    }

    public func close(normal: Bool) {
        let wasEnded: Bool = lock.withLock {
            defer { endLocked() }
            return isEnded
        }
        if !wasEnded { send(["socket": id, "close": true, "code": normal ? 1000 : 1001]) }
    }

    /// A line of the bridge for this socket. It answers whether the socket ended with it.
    @discardableResult
    public func take(_ line: [String: Any]) -> Bool {
        if let frame = line["frame"] as? String {
            let heard = lock.withLock { isEnded ? nil : self.heard }
            heard?(frame)
            return false
        }
        if let number = line["pong"] as? Int {
            let once = lock.withLock { pings.removeValue(forKey: number) }
            once?.resume(true)
            return false
        }
        if line["closed"] as? Bool == true {
            let code = line["code"] as? Int ?? 1005
            let reason = (line["reason"] as? String).flatMap { $0.isEmpty ? nil : $0 }
            fail("the socket closed (\(code)\(reason.map { ": \($0)" } ?? ""))")
            return true
        }
        if let failed = line["failed"] as? String {
            fail(failed)
            return true
        }
        return false
    }

    /// The socket ended on the bridge's side, or the bridge did: `ended` hears `why`, once.
    /// `closing` asks the bridge to close its end too (the app gives the socket up: another mind).
    public func fail(_ why: String, closing: Bool = false) {
        let (ended, wasEnded): ((@Sendable (String) -> Void)?, Bool) = lock.withLock {
            let wasEnded = isEnded
            guard !isEnded || self.ended != nil else { return (nil, wasEnded) }
            defer { endLocked() }
            return (self.ended, wasEnded)
        }
        if closing, !wasEnded { send(["socket": id, "close": true, "code": 1001]) }
        ended?(why)
    }

    /// Under the lock: nothing is heard after it, and every ping that waits is answered no.
    private func endLocked() {
        isEnded = true
        heard = nil
        ended = nil
        let waiting = pings.values
        pings = [:]
        for once in waiting { once.resume(false) }
    }
}

/// A continuation answered once: by the first of a ping's pong and its time out.
final class Once: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Bool, Never>?
    private var answer: Bool?

    func set(_ continuation: CheckedContinuation<Bool, Never>) {
        let given: Bool? = lock.withLock {
            if answer == nil { self.continuation = continuation }
            return answer
        }
        if let given { continuation.resume(returning: given) }
    }

    func resume(_ value: Bool) {
        let continuation: CheckedContinuation<Bool, Never>? = lock.withLock {
            guard answer == nil else { return nil }
            answer = value
            defer { self.continuation = nil }
            return self.continuation
        }
        continuation?.resume(returning: value)
    }
}
