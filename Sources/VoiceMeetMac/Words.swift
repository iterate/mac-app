import Foundation
import VoiceMeetCore

/// THE WORD LISTS of the minds this Mac knows, for the app's speech model (README, "Dictation").
/// A list is the mind's own file `words.md`; the job `words` of that mind's `MindBridge`
/// (`bridge/words.mjs`) reads it as the person and keeps a copy in the app's folder. The copy is read at each listening and fetched again when it
/// is older than ten minutes, so a term that was added in the mind is heard soon after.
@MainActor
final class Words {
    static let folder = AppEnvironment.current.folder.appendingPathComponent("words")

    /// The bridge of a mind this Mac knows (by the config now): a list is fetched for any of them.
    var bridge: (_ mind: String) -> MindBridge? = { _ in nil }

    private let log = AppLog("words")
    private var askedAt: [String: Date] = [:]

    private static func file(of mind: String) -> URL {
        folder.appendingPathComponent("\(mind).md")
    }

    /// The list of a mind as this Mac has it now: empty before the first fetch.
    func list(of mind: String?) -> WordList {
        guard let mind else { return .empty }
        refresh(mind)
        guard let text = try? String(contentsOf: Self.file(of: mind), encoding: .utf8) else { return .empty }
        return WordList(markdown: text)
    }

    /// Fetches the list in the background, at most once in ten minutes for a mind.
    func refresh(_ mind: String) {
        if let asked = askedAt[mind], Date().timeIntervalSince(asked) < 600 { return }
        guard let bridge = bridge(mind) else { return }
        askedAt[mind] = Date()
        bridge.on("words") { [weak self, weak bridge] line in
            guard let self, line["job"] != nil || line["exited"] != nil else { return }
            bridge?.release("words")
            if let terms = line["terms"] as? Int {
                self.log.info("\(mind): \(terms) terms")
            } else {
                self.log.error("\(mind): the word list was not read: \(line["failed"] as? String ?? "the process ended")")
            }
        }
        bridge.hold("words")
        bridge.send("words", ["file": Self.file(of: mind).path])
    }
}
