import Foundation

/// WHAT OPENS A SOCKET AT OPENAI (README, "Dictation"): the lent mind, whose bridge opens the socket
/// through the mind with the mind's own key (`RelaySocket`, `bridge/openai.mjs`: the key stays in
/// the mind's vault), else this Mac's own key in the login Keychain (`OpenAIKey`, `DirectSocket`),
/// else nothing. A socket of the mind that does not open falls back to this Mac's key, when there
/// is one; with none, the caller's local model hears.
public enum OpenAISource: Sendable, Equatable {
    /// Through this mind, with its key.
    case mind(String)
    /// The key of this Mac's Keychain.
    case ownKey

    /// For the speech log: `mind` or `own key`. Never a key.
    public var words: String {
        switch self {
        case .mind: "mind"
        case .ownKey: "own key"
        }
    }
}

/// Whether the lent mind opens OpenAI's sockets, as far as this session knows: found out with a
/// socket opened and closed at each new connection of its bridge, and by each dictation's socket.
public enum MindOpenAI: Sendable, Equatable {
    /// Not asked yet, or the last ask had no answer (no connection, no time).
    case unknown
    /// A socket opened: the mind has `/secrets/openai`, and OpenAI takes it.
    case yes
    /// It said no: no `/secrets/openai`, or OpenAI refused its key.
    case no
}

public struct OpenAIAccess: Sendable {
    public typealias Open = @Sendable (
        _ setup: OpenAIStream.Setup, _ text: @escaping @Sendable (String) -> Void, _ failed: @escaping @Sendable (String) -> Void
    ) async throws -> (stream: OpenAIStream, source: OpenAISource)

    /// Where the next socket comes from, as far as is known now, with no socket opened: a standby
    /// of another source does not fit. Nil: none.
    public var source: @Sendable () async -> OpenAISource?
    /// One stream on a socket that opens now, and where it came from.
    public var open: Open

    public init(source: @escaping @Sendable () async -> OpenAISource?, open: @escaping Open) {
        self.source = source
        self.open = open
    }

    /// The order. A lent mind that did not say no comes first; then this Mac's key.
    public static func order(mind: String?, state: MindOpenAI, hasKey: Bool) -> OpenAISource? {
        if let mind, state != .no { return .mind(mind) }
        return hasKey ? .ownKey : nil
    }

    /// Only this Mac's key (`key` reads it off the main thread): a test, the speech bench.
    public static func ownKey(_ key: @escaping @Sendable () -> String?) -> OpenAIAccess {
        OpenAIAccess(
            source: { key() == nil ? nil : .ownKey },
            open: { setup, text, failed in
                guard let value = key() else { throw OpenAIStream.Failure.noKey }
                return (try await OpenAIStream.open(setup, key: value, text: text, failed: failed), .ownKey)
            })
    }

    /// The mind first, then the key. `mind` is the lent mind and what it can do now; `socket`
    /// makes a socket of its bridge (the stream opens it, within its `connectTimeout`); `key`
    /// reads this Mac's key. A socket of the mind that does not open falls back to the key when
    /// there is one (`log` says why); with none it throws, and the local model hears.
    public static func mindFirst(
        mind: @escaping @Sendable () async -> (name: String, state: MindOpenAI)?,
        socket: @escaping @Sendable () async throws -> OpenAISocket,
        key: @escaping @Sendable () -> String?,
        log: @escaping @Sendable (String) -> Void = { _ in }
    ) -> OpenAIAccess {
        OpenAIAccess(
            source: {
                // the key is read only when the mind does not come first: a read may ask the person
                if let mind = await mind(), mind.state != .no { return .mind(mind.name) }
                return key() != nil ? .ownKey : nil
            },
            open: { setup, text, failed in
                if let mind = await mind(), mind.state != .no {
                    do {
                        let stream = try await OpenAIStream.open(setup, socket: try await socket(), text: text, failed: failed)
                        return (stream, .mind(mind.name))
                    } catch {
                        guard key() != nil else { throw error }
                        log("no socket through \(mind.name) (\(error.localizedDescription)): your own key")
                    }
                }
                guard let value = key() else { throw OpenAIStream.Failure.noKey }
                return (try await OpenAIStream.open(setup, key: value, text: text, failed: failed), .ownKey)
            })
    }
}
