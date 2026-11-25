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
    /// A form, lower-case with one space for each run of separators, to its term.
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
            .map { (key: Self.key($0.form), term: $0.term) }
            .filter { !$0.key.isEmpty }
            // the longest first: "claude code" wins over "claude"
            .sorted { $0.key.count > $1.key.count }
        var terms: [String: String] = [:]
        // the longest form's term, when two forms are one key
        for row in forms where terms[row.key] == nil { terms[row.key] = row.term }
        self.terms = terms
        let words = forms.map { row in
            row.key.split(separator: " ").map { NSRegularExpression.escapedPattern(for: String($0)) }.joined(separator: Self.separators + "+")
        }
        pattern = words.isEmpty
            ? nil
            : try? NSRegularExpression(pattern: "(?<![\\p{L}\\p{N}])(?:\(words.joined(separator: "|")))(?![\\p{L}\\p{N}])", options: [.caseInsensitive])
    }

    /// The characters between the words of a form. Any run of them matches any other run: "b link"
    /// is "b-link", "B‑Link", "b - link" and "b_link" too. They are white space, the hyphen-minus,
    /// the hyphens and dashes U+2010 to U+2015, the minus sign U+2212 and the underscore. Not the
    /// full stop: "b. Link the box" ends a sentence, and "AGENTS.md" is a name with its dot.
    static let separators = "[\\s\\-\\u2010-\\u2015\\u2212_]"
    private static let separatorRun = try! NSRegularExpression(pattern: separators + "+")

    /// A form, lower-case, with one space for each run of separators and none at its ends.
    private static func key(_ form: String) -> String {
        let whole = form.lowercased()
        let spaced = separatorRun.stringByReplacingMatches(in: whole, range: NSRange(location: 0, length: (whole as NSString).length), withTemplate: " ")
        return spaced.trimmingCharacters(in: .whitespaces)
    }

    /// Each place in `text` where a wrong form, or the term in another case, stands: what was heard
    /// there and the term to write. In the order of the text, none inside another. Whole words only,
    /// and the longest form first. The term itself, in its own case, is no correction.
    public func corrections(in text: String) -> [WordCorrection] {
        guard let pattern else { return [] }
        let whole = text as NSString
        return pattern.matches(in: text, range: NSRange(location: 0, length: whole.length)).compactMap { match in
            let heard = whole.substring(with: match.range)
            guard let term = terms[Self.key(heard)], term != heard, let range = Range(match.range, in: text) else { return nil }
            return WordCorrection(range: range, heard: heard, term: term)
        }
    }

    /// A transcript with each wrong form, and each term in another case, written as the term
    /// (`corrections(in:)`). What follows a word stays: "b-link," is "Beelink,".
    public func repair(_ text: String) -> String {
        WordCorrection.apply(corrections(in: text), to: text)
    }
}

/// ONE REPAIR of the word list in a transcript: the heard words at `range` of the text that was
/// repaired, and the term that is written in their place.
public struct WordCorrection: Equatable, Sendable {
    public let range: Range<String.Index>
    public let heard: String
    public let term: String

    public init(range: Range<String.Index>, heard: String, term: String) {
        self.range = range
        self.heard = heard
        self.term = term
    }

    /// `text` with each correction's term in place of its heard words. The corrections are
    /// `corrections(in: text)`: in order, none inside another.
    public static func apply(_ corrections: [WordCorrection], to text: String) -> String {
        var written = ""
        var at = text.startIndex
        for correction in corrections {
            written += text[at..<correction.range.lowerBound]
            written += correction.term
            at = correction.range.upperBound
        }
        return written + text[at...]
    }
}

/// A TRANSCRIPT AS IT WAS HEARD, with the word list's corrections in it: the dictation pill shows
/// both, the heard words struck through and the term after them; what is written (`text`) has the
/// terms alone. Its ends carry no white space, as `Spoken.join`'s.
public struct HeardText: Equatable, Sendable {
    public static let empty = HeardText(heard: "", corrections: [])

    public let heard: String
    /// `words.corrections(in: heard)`.
    public let corrections: [WordCorrection]

    public init(_ heard: String, words: WordList) {
        let heard = heard.trimmingCharacters(in: .whitespacesAndNewlines)
        self.init(heard: heard, corrections: words.corrections(in: heard))
    }

    private init(heard: String, corrections: [WordCorrection]) {
        self.heard = heard
        self.corrections = corrections
    }

    /// The text that is written: the heard text with each correction's term.
    public var text: String { WordCorrection.apply(corrections, to: heard) }

    /// Two pieces as one, with one space between them when both have words (`Spoken.join`). Each
    /// piece keeps its own corrections: a form is never matched across the two.
    public static func join(_ first: HeardText, _ second: HeardText) -> HeardText {
        if first.heard.isEmpty { return second }
        if second.heard.isEmpty { return first }
        let heard = first.heard + " " + second.heard
        // the second piece's ranges move by the first piece and the space
        let corrections = first.corrections.map { $0.moved(from: first.heard, by: 0, into: heard) }
            + second.corrections.map { $0.moved(from: second.heard, by: first.heard.utf16.count + 1, into: heard) }
        return HeardText(heard: heard, corrections: corrections)
    }
}

extension WordCorrection {
    /// The same correction in `text`, which holds `old` at `offset` UTF-16 units from its start.
    fileprivate func moved(from old: String, by offset: Int, into text: String) -> WordCorrection {
        let place = { (index: String.Index) in
            text.utf16.index(text.startIndex, offsetBy: offset + old.utf16.distance(from: old.startIndex, to: index))
        }
        return WordCorrection(range: place(range.lowerBound)..<place(range.upperBound), heard: heard, term: term)
    }
}
