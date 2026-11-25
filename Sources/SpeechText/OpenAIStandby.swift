import Foundation

/// THE STANDBY SOCKET of OpenAI's realtime transcription (README, "Dictation"): one socket, opened
/// and configured with the session of the next dictation, so that fn down needs no new one. A new
/// socket takes 0.74 to 1.02 s to be ready (p50 0.82 s, measured on the owner's Mac on 25 November
/// 2026); a standby is ready at once.
///
/// The bounds. The online recognizer opens a standby in the background when each of its listenings
/// ends (`prepare`), only with a credential (`OpenAIAccess`: a fresh token of the lent mind for each
/// socket it opens, else this Mac's key); the app drops it when the model is no longer online, the
/// key goes, the lent mind changes, or the Mac sleeps (`drop`). There is never more than one, held or opening. One that waits
/// 10 minutes unused is closed, and the next opens only after the next dictation: an idle Mac
/// holds no socket for long. One that the server or the network closes is dropped with a line in
/// the log and opened again, within those 10 minutes of the last dictation, at most once in
/// `renewSpacing` seconds (the owner's Mac, 25 Nov 2026: OpenAI reset idle standbys after 94 and
/// 101 s, and kept another 262 s). A listening takes it (`take`) when it is open, of the same session
/// (the word list's keywords, the credential's source) and answers a ping; else it opens a new
/// socket, as before.
///
/// Cost: OpenAI bills realtime transcription by the audio it gets (25 November 2026: $0.017 a
/// minute of sound), so an open socket with no audio costs nothing.
///
/// Everything runs off the main thread: a detached task opens it, URLSession's callbacks and one
/// timer close it. No polling.
public final class OpenAIStandby: @unchecked Sendable {
    /// The most seconds a standby waits unused.
    public static let unused = 600.0
    /// The fewest seconds between two openings after a standby went: a network that is down does not
    /// make a loop.
    static let renewSpacing = 15.0
    /// The most seconds a listening waits for the standby's pong.
    static let pingTimeout = 0.5

    /// The time, and a run after some seconds: a test sets its own.
    public struct Clock: Sendable {
        public var now: @Sendable () -> Date
        public var after: @Sendable (Double, @escaping @Sendable () -> Void) -> Void

        public init(now: @escaping @Sendable () -> Date, after: @escaping @Sendable (Double, @escaping @Sendable () -> Void) -> Void) {
            self.now = now
            self.after = after
        }

        /// The wall clock: a Mac that slept 10 minutes is 10 minutes on.
        public static let system = Clock(now: { Date() }, after: { seconds, run in DispatchQueue.global().asyncAfter(wallDeadline: .now() + seconds, execute: run) })
    }

    private struct Held {
        let id: Int
        let stream: OpenAIStream
        let setup: OpenAIStream.Setup
        let source: OpenAISource
        let opened: Date
    }

    private let clock: Clock
    private let log: @Sendable (String) -> Void
    private let lock = NSLock()
    private var held: Held?
    private var isOpening = false
    /// The id of the newest opening; an opening of an id at or below `dropped` is not kept.
    private var newest = 0
    private var dropped = 0
    /// The last dictation's session, and when it asked for a standby: a standby that goes is opened
    /// again until `unused` seconds after it.
    private var wanted: (setup: OpenAIStream.Setup, access: OpenAIAccess, at: Date)?
    private var lastRenewal: Date?

    public init(clock: Clock = .system, log: @escaping @Sendable (String) -> Void = { _ in }) {
        self.clock = clock
        self.log = log
    }

    /// Whether a standby is open and waits.
    var isHeld: Bool { lock.withLock { held != nil } }

    /// Opens a standby for `setup` in the background, unless one is held or opens, or there is no
    /// credential.
    public func prepare(_ setup: OpenAIStream.Setup, access: OpenAIAccess) {
        lock.withLock { wanted = (setup, access, clock.now()) }
        open(setup, access: access, until: clock.now().addingTimeInterval(Self.unused))
    }

    /// With this Mac's key alone.
    public func prepare(_ setup: OpenAIStream.Setup, key: @escaping @Sendable () -> String?) {
        prepare(setup, access: .ownKey(key))
    }

    /// Opens one, kept until `until` at the latest, with a credential got for it now.
    private func open(_ setup: OpenAIStream.Setup, access: OpenAIAccess, until: Date) {
        let id: Int? = lock.withLock {
            guard held == nil, !isOpening else { return nil }
            isOpening = true
            newest += 1
            return newest
        }
        guard let id else { return }
        Task.detached(priority: .utility) { [self] in
            // no credential (no mind, no key) opens none, with no line
            guard await access.source() != nil else { return lock.withLock { isOpening = false } }
            let started = clock.now()
            do {
                let credential = try await access.credential()
                let stream = try await OpenAIStream.open(
                    setup, key: credential.value, text: { _ in }, failed: { [weak self] reason in self?.lost(id, reason) })
                let isKept: Bool = lock.withLock {
                    isOpening = false
                    guard id > dropped else { return false }
                    held = Held(id: id, stream: stream, setup: setup, source: credential.source, opened: clock.now())
                    return true
                }
                guard isKept else { return stream.cancel() }
                log("a standby socket is ready after \(milliseconds(since: started)) ms, with \(setup.keywords.count) keywords (\(credential.source.words))")
                clock.after(max(0, until.timeIntervalSince(clock.now()))) { [weak self] in self?.expire(id) }
            } catch {
                lock.withLock { isOpening = false }
                log("no standby socket: \(error.localizedDescription)")
            }
        }
    }

    /// The standby, for a listening of `setup` whose credential comes from `source`: open, of the
    /// same session, unused for less than `unused` seconds, and it answers a ping. Else nil, and a
    /// standby that does not fit is closed. Either way no standby is held after it.
    func take(_ setup: OpenAIStream.Setup, source: OpenAISource?) async -> (stream: OpenAIStream, source: OpenAISource)? {
        let (taken, isOpening): (Held?, Bool) = lock.withLock {
            defer { held = nil }
            return (held, self.isOpening)
        }
        guard let taken else {
            if isOpening { log("the standby socket still opens: a new one") }
            return nil
        }
        let why: String? =
            if clock.now().timeIntervalSince(taken.opened) >= Self.unused { "waited \(Int(Self.unused / 60)) min unused" }
            else if taken.setup.keywords != setup.keywords { "has other keywords" }
            else if taken.source != source { "is of another credential (\(taken.source.words))" }
            else if taken.setup != setup { "has another session" }
            else if await !taken.stream.ping(within: Self.pingTimeout) { "did not answer a ping" }
            else { nil }
        guard let why else { return (taken.stream, taken.source) }
        taken.stream.cancel()
        log("the standby socket \(why): closed, and a new one")
        return nil
    }

    /// Closes the standby, and one that opens now is not kept.
    public func drop(_ why: String) {
        let taken: Held? = lock.withLock {
            dropped = newest
            wanted = nil
            defer { held = nil }
            return held
        }
        guard let taken else { return }
        taken.stream.cancel()
        log("the standby socket is closed: \(why)")
    }

    /// The server or the network closed it.
    private func lost(_ id: Int, _ reason: String) {
        let isHeld: Bool = lock.withLock {
            guard held?.id == id else { return false }
            held = nil
            return true
        }
        guard isHeld else { return }
        let renew: (OpenAIStream.Setup, OpenAIAccess, Date, Double)? = lock.withLock {
            guard let wanted else { return nil }
            let until = wanted.at.addingTimeInterval(Self.unused)
            guard clock.now() < until else { return nil }
            let wait = lastRenewal.map { max(0, Self.renewSpacing - clock.now().timeIntervalSince($0)) } ?? 0
            lastRenewal = clock.now().addingTimeInterval(wait)
            return (wanted.setup, wanted.access, until, wait)
        }
        guard let (setup, access, until, wait) = renew else { return log("the standby socket went (\(reason)): dropped") }
        log("the standby socket went (\(reason)): a new one in \(Int(wait)) s")
        clock.after(wait) { [weak self] in
            // a drop meanwhile (the model, the key, sleep) wants none
            guard let self, self.lock.withLock({ self.wanted != nil }) else { return }
            // a fresh credential: a token of the last opening is no longer good
            self.open(setup, access: access, until: until)
        }
    }

    /// The timer of `unused` seconds. Internal for a test.
    func expire(_ id: Int) {
        let taken: Held? = lock.withLock {
            guard let held, held.id == id else { return nil }
            self.held = nil
            return held
        }
        guard let taken else { return }
        taken.stream.cancel()
        log("the standby socket waited \(Int(Self.unused / 60)) min unused: closed; the next opens after the next dictation")
    }

    private func milliseconds(since date: Date) -> Int { Int((clock.now().timeIntervalSince(date) * 1000).rounded()) }
}
