import Foundation

/// THE MIND'S WORD LIST: the names and terms that a speech model must get right (README,
/// "Dictation"). It is the mind's own file, `words.md` at the root of its config repo, which every
/// voice of that mind reads. Each list item is one term, written exactly as it must appear, and
/// after a colon the wrong forms that a transcript showed:
///
///     - Templestein: temple stein, temple steen
///     - itx
///
/// This is the mind's own parser (`words-parse.ts`), in Swift: the same list gives the same repair.
public struct WordList: Equatable, @unchecked Sendable {
    public struct Entry: Equatable, Sendable {
        public let term: String
        public let wrong: [String]

        public init(term: String, wrong: [String] = []) {
            self.term = term
            self.wrong = wrong
        }
    }

    public static let empty = WordList(entries: [])

    public let entries: [Entry]
    /// Every form of every entry, the longest first, as whole words with any case.
    private let pattern: NSRegularExpression?
    /// A form, lower-case with single spaces, to its term.
    private let terms: [String: String]

    public static func == (left: WordList, right: WordList) -> Bool {
        left.entries == right.entries
    }

    /// Every list item `- term` or `- term: wrong, wrong`. An indented line (the format's own
    /// example) and any other line is no entry. A term that comes twice has the wrong forms of both.
    public init(markdown: String) {
        var order: [String] = []
        var wrong: [String: [String]] = [:]
        for line in markdown.components(separatedBy: .newlines) {
            guard line.hasPrefix("- ") else { continue }
            let parts = line.dropFirst(2).components(separatedBy: ":")
            let term = parts[0].trimmingCharacters(in: .whitespaces)
            guard !term.isEmpty, term.count <= 60 else { continue }
            let forms = parts.dropFirst().joined(separator: ":").components(separatedBy: ",")
                .map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
            if wrong[term] == nil { order.append(term) }
            wrong[term, default: []] += forms
        }
        self.init(entries: order.map { Entry(term: $0, wrong: wrong[$0] ?? []) })
    }

    public init(entries: [Entry]) {
        self.entries = entries
        let forms = entries
            .flatMap { entry in ([entry.term] + entry.wrong).map { (form: $0, term: entry.term) } }
            .filter { !$0.form.trimmingCharacters(in: .whitespaces).isEmpty }
            .sorted { $0.form.count > $1.form.count }
        var terms: [String: String] = [:]
        for row in forms { terms[Self.key(row.form)] = row.term }
        self.terms = terms
        let words = forms.map { row in
            row.form.split(whereSeparator: \.isWhitespace).map { NSRegularExpression.escapedPattern(for: String($0)) }.joined(separator: "\\s+")
        }
        pattern = words.isEmpty
            ? nil
            : try? NSRegularExpression(pattern: "(?<![\\p{L}\\p{N}])(?:\(words.joined(separator: "|")))(?![\\p{L}\\p{N}])", options: [.caseInsensitive])
    }

    private static func key(_ form: String) -> String {
        form.lowercased().split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    /// A transcript with each wrong form, and each term in another case, written as the term.
    /// Whole words only, and the longest form first: "claude code" wins over "claude".
    public func repair(_ text: String) -> String {
        guard let pattern else { return text }
        let whole = text as NSString
        var repaired = text as NSString
        // from the end, so that the ranges before a change stay true
        for match in pattern.matches(in: text, range: NSRange(location: 0, length: whole.length)).reversed() {
            guard let term = terms[Self.key(whole.substring(with: match.range))] else { continue }
            repaired = repaired.replacingCharacters(in: match.range, with: term) as NSString
        }
        return repaired as String
    }
}
