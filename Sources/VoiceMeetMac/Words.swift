import Foundation
import VoiceMeetCore

/// THE WORD LISTS of the minds this Mac knows, for the app's speech model (README, "Dictation").
/// A list is the mind's own file `words.md`; `bridge/words-fetch.mjs` reads it as the person and
/// keeps a copy in the app's folder. The copy is read at each listening and fetched again when it
/// is older than ten minutes, so a term that was added in the mind is heard soon after.
@MainActor
final class Words {
    static let folder = AppEnvironment.current.folder.appendingPathComponent("words")

    /// The helpers of the config now: a list is fetched for any mind this Mac knows.
    var helpers: () -> MindSession.Helpers? = { nil }

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
        guard let helpers = helpers() else { return }
        askedAt[mind] = Date()
        let process = Process()
        let output = Pipe()
        process.executableURL = URL(fileURLWithPath: helpers.node)
        process.arguments = [helpers.wordsFetch, Self.file(of: mind).path, "--iterate", helpers.iterateBin, "--mind", mind]
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        process.terminationHandler = { [log] _ in
            let said = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            let line = (try? JSONSerialization.jsonObject(with: Data(said.utf8))) as? [String: Any]
            if let terms = line?["terms"] as? Int {
                log.info("\(mind): \(terms) terms")
            } else {
                log.error("\(mind): the word list was not read: \(line?["failed"] as? String ?? "no answer")")
            }
        }
        do {
            try process.run()
        } catch {
            log.error("\(mind): the fetch did not start: \(AppLog.describe(error))")
        }
    }
}
