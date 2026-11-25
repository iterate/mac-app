import Foundation
import VoiceMeetCore

/// THE WORD LISTS of the minds this Mac knows, for the app's speech model (README, "Dictation").
/// A list is what an itx expression answers, run as the person on that mind: the mind's own
/// expression (`minds[].wordsExpression` in config.json, its page in Settings), else this Mac's
/// default (`wordsExpression`, Settings › Dictation), else the built-in one, the mind's file
/// `words.md`. The job `words` of that mind's `MindBridge` (`bridge/words.mjs`) evaluates it and
/// keeps a copy in the app's folder, replaced only by a good answer: after a failure the last good
/// list stays in use. The copy is read at each listening and fetched again when it is older than
/// ten minutes, or at once when the expression changed, so a term that was added in the mind is
/// heard soon after.
@MainActor
final class Words: ObservableObject {
    static let folder = AppEnvironment.current.folder.appendingPathComponent("words")
    /// What runs when neither the mind nor this Mac set an expression (`DEFAULT_EXPRESSION` of the bridge).
    static let builtInExpression = #"itx.repos.get("/repos/config").readFile("words.md")"#

    /// What a mind's page in Settings shows of its list.
    struct Status: Equatable {
        /// The list in use (the copy on this Mac), and when it was fetched; nil before the first.
        var list: WordList?
        var fetchedAt: Date?
        /// The last fetch failed, with the bridge's reason.
        var failure: String?
        var isFetching = false
    }

    /// The bridge of a mind this Mac knows (by the config now): a list is fetched for any of them.
    var bridge: (_ mind: String) -> MindBridge? = { _ in nil }
    /// The expression a mind's list comes from: its own, else this Mac's default; nil is the built-in one.
    var expression: (_ mind: String) -> String? = { _ in nil }

    /// Each mind's list as Settings shows it. Filled when a fetch ends, and by `loadStatus`.
    @Published private(set) var status: [String: Status] = [:]

    private let log = AppLog("words")
    private var askedAt: [String: Date] = [:]
    /// The expression of each mind's last fetch: another one fetches at once.
    private var askedWith: [String: String] = [:]
    /// The minds whose fetch runs: one at a time for a mind, as its bridge has one handler of
    /// `words`. A fetch asked for meanwhile runs after it, with the newest expression.
    private var fetching: Set<String> = []
    private var fetchAfter: [String: String] = [:]

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

    /// Fetches the list in the background, at most once in ten minutes for a mind, and at once
    /// when its expression changed.
    func refresh(_ mind: String) {
        let expression = expression(mind) ?? Self.builtInExpression
        if askedWith[mind] == expression, let asked = askedAt[mind], Date().timeIntervalSince(asked) < 600 { return }
        fetch(mind, expression: expression)
    }

    /// Settings' Fetch Now: at once, whatever the time of the last one.
    func fetchNow(_ mind: String) {
        fetch(mind, expression: expression(mind) ?? Self.builtInExpression)
    }

    private func fetch(_ mind: String, expression: String) {
        guard !fetching.contains(mind) else {
            fetchAfter[mind] = expression
            return
        }
        guard let bridge = bridge(mind) else { return }
        fetching.insert(mind)
        askedAt[mind] = Date()
        askedWith[mind] = expression
        status[mind, default: Status()].isFetching = true
        bridge.on("words") { [weak self, weak bridge] line in
            guard let self, line["job"] != nil || line["exited"] != nil else { return }
            bridge?.release("words")
            self.fetching.remove(mind)
            defer { if let next = self.fetchAfter.removeValue(forKey: mind) { self.fetch(mind, expression: next) } }
            if let terms = line["terms"] as? Int {
                self.log.info("\(mind): \(terms) terms")
                self.loadStatus(mind, ended: .done)
            } else {
                let reason = line["failed"] as? String ?? "The mind's process ended."
                self.log.error("\(mind): the word list was not read: \(reason)")
                self.loadStatus(mind, ended: .failed(reason))
            }
        }
        bridge.hold("words")
        // the built-in expression is the bridge's own read of words.md, as it always was
        var words: [String: Any] = ["file": Self.file(of: mind).path]
        if expression != Self.builtInExpression { words["expression"] = expression }
        bridge.send("words", words)
    }

    /// Reads the copy of a mind's list and when it was written, away from the main thread, into
    /// `status`. A page of Settings calls it when it shows the mind; a fetch, when it ends.
    enum Ended { case done, failed(String) }

    func loadStatus(_ mind: String, ended: Ended? = nil) {
        let file = Self.file(of: mind)
        Task.detached(priority: .utility) {
            let text = try? String(contentsOf: file, encoding: .utf8)
            let date = (try? file.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
            let list = text.map(WordList.init(markdown:))
            await MainActor.run {
                var status = self.status[mind] ?? Status()
                status.list = list
                status.fetchedAt = date
                switch ended {
                case .done:
                    status.failure = nil
                    status.isFetching = false
                case .failed(let reason):
                    status.failure = reason
                    status.isFetching = false
                case nil:
                    break
                }
                if self.status[mind] != status { self.status[mind] = status }
            }
        }
    }

    /// The drawings' lists (`Rendering`): no file and no bridge.
    func fixForDrawing(_ mind: String, _ status: Status) {
        self.status[mind] = status
    }
}
