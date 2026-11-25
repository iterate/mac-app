import Foundation

/// WHAT OPENS A SOCKET AT OPENAI (README, "Dictation"): a token of 60 s that the lent mind mints
/// with its own key (`bridge/openai.mjs`: the key stays in the mind's vault), else this Mac's own
/// key in the login Keychain (`OpenAIKey`), else nothing.
///
/// A credential is got for each socket, just before it opens (a standby's too), and used at once:
/// none is kept. A token opens a socket within 60 s of its mint and does nothing after; the socket
/// it opened stays open.
public enum OpenAISource: Sendable, Equatable {
    /// A token of this mind, with the mind's key.
    case mindToken(String)
    /// The key of this Mac's Keychain.
    case ownKey

    /// For the speech log: `mind token` or `own key`. Never the token or the key.
    public var words: String {
        switch self {
        case .mindToken: "mind token"
        case .ownKey: "own key"
        }
    }
}

/// What the lent mind can do with OpenAI, as far as this session knows: found out with a mint at
/// each new connection, and by each dictation's mint.
public enum MindMint: Sendable, Equatable {
    /// Not asked yet, or the last ask had no answer (no connection, no time).
    case unknown
    /// It minted a token: the mind has `/secrets/openai`.
    case yes
    /// It said no: no `/secrets/openai`, or OpenAI refused its key.
    case no
}

public struct OpenAICredential: Sendable {
    /// The token or the key: only for the Authorization header.
    public let value: String
    public let source: OpenAISource

    public init(value: String, source: OpenAISource) {
        self.value = value
        self.source = source
    }
}

public struct OpenAIAccess: Sendable {
    /// Where the next socket's credential comes from, as far as is known now, with no mint: a
    /// standby of another source does not fit. Nil: none.
    public var source: @Sendable () async -> OpenAISource?
    /// One credential, for one socket that opens now.
    public var credential: @Sendable () async throws -> OpenAICredential

    public init(source: @escaping @Sendable () async -> OpenAISource?, credential: @escaping @Sendable () async throws -> OpenAICredential) {
        self.source = source
        self.credential = credential
    }

    /// The order. A lent mind that did not say no comes first; then this Mac's key.
    public static func order(mind: String?, mint: MindMint, hasKey: Bool) -> OpenAISource? {
        if let mind, mint != .no { return .mindToken(mind) }
        return hasKey ? .ownKey : nil
    }

    /// Only this Mac's key (`key` reads it off the main thread): a test, the speech bench.
    public static func ownKey(_ key: @escaping @Sendable () -> String?) -> OpenAIAccess {
        OpenAIAccess(
            source: { key() == nil ? nil : .ownKey },
            credential: {
                guard let value = key() else { throw OpenAIStream.Failure.noKey }
                return OpenAICredential(value: value, source: .ownKey)
            })
    }

    /// The mind first, then the key. `mind` is the lent mind and what it can do now; `mint` asks it
    /// for a token (bounded by its caller); `key` reads this Mac's key. A mint that fails falls back
    /// to the key when there is one (`log` says why); with none it throws, and the local model hears.
    public static func mindFirst(
        mind: @escaping @Sendable () async -> (name: String, mint: MindMint)?,
        mint: @escaping @Sendable () async throws -> String,
        key: @escaping @Sendable () -> String?,
        log: @escaping @Sendable (String) -> Void = { _ in }
    ) -> OpenAIAccess {
        OpenAIAccess(
            source: {
                // the key is read only when the mind does not come first: a read may ask the person
                if let mind = await mind(), mind.mint != .no { return .mindToken(mind.name) }
                return key() != nil ? .ownKey : nil
            },
            credential: {
                if let mind = await mind(), mind.mint != .no {
                    do {
                        return OpenAICredential(value: try await mint(), source: .mindToken(mind.name))
                    } catch {
                        guard key() != nil else { throw error }
                        log("no token from \(mind.name) (\(error.localizedDescription)): your own key")
                    }
                }
                guard let value = key() else { throw OpenAIStream.Failure.noKey }
                return OpenAICredential(value: value, source: .ownKey)
            })
    }
}
