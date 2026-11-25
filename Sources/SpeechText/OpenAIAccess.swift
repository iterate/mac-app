import Foundation
import VoiceMeetCore

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
    /// reads this Mac's key. A socket of the mind that does not open falls back to the key only
    /// when the mind said no (`MindSockets` sets `.no` on a refusal); any other failure (a drop, a
    /// timeout) throws, and the local model hears. So a Mac lent to a mind that has OpenAI never
    /// reads the Keychain: a read of an item another program wrote makes macOS ask the person, again
    /// after each update of the app (Jonas, 25 Nov 2026: "why did you ask me for openai api key
    /// again now on keychain? i thought we use it from iterate mind").
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
                let lent = mind
                if let mind = await mind(), mind.state != .no {
                    do {
                        let stream = try await OpenAIStream.open(setup, socket: try await socket(), text: text, failed: failed)
                        return (stream, .mind(mind.name))
                    } catch {
                        // only the mind's no lets this Mac's key in; the key is read after that check
                        guard await lent()?.state == .no, key() != nil else { throw error }
                        log("no socket through \(mind.name) (\(error.localizedDescription)): your own key")
                    }
                }
                guard let value = key() else { throw OpenAIStream.Failure.noKey }
                return (try await OpenAIStream.open(setup, key: value, text: text, failed: failed), .ownKey)
            })
    }
}
