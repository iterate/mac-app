#if canImport(AppKit)
import AppKit

/// WHAT THE CLIPBOARD HELD before a dictation's text went there for ⌘V, to put it back after.
///
/// - The text goes there as transient (`org.nspasteboard.TransientType`): a clipboard manager does
///   not keep it.
/// - What is kept is bounded: at most `mostBytes` in all, and no promise of a file, which would
///   make the app that copied it write the file now.
/// - It goes back only while the clipboard is still the text's (its change count): a copy of the
///   person's own meanwhile stays, even of the same text.
public struct ClipboardCopy: Sendable {
    public static let mostBytes = 16 * 1024 * 1024
    public static let transient = NSPasteboard.PasteboardType("org.nspasteboard.TransientType")
    /// Types that are a promise, not data: asking for their data makes another app do work.
    static let promises: Set<String> = [
        "com.apple.NSFilePromiseItemMetaData", "com.apple.pasteboard.promised-file-url",
        "com.apple.pasteboard.promised-file-content-type", "com.apple.pasteboard.promised-suggested-file-name",
        "NSPromiseContentsPboardType", "Apple files promise pasteboard type",
    ]

    private var items: [[(NSPasteboard.PasteboardType, Data)]] = []

    public init(of pasteboard: NSPasteboard) {
        var bytes = 0
        for item in pasteboard.pasteboardItems ?? [] {
            var kept: [(NSPasteboard.PasteboardType, Data)] = []
            for type in item.types where !Self.promises.contains(type.rawValue) && bytes < Self.mostBytes {
                guard let data = item.data(forType: type), bytes + data.count <= Self.mostBytes else { continue }
                bytes += data.count
                kept.append((type, data))
            }
            if !kept.isEmpty { items.append(kept) }
        }
    }

    public var isEmpty: Bool { items.isEmpty }

    /// Puts `text` on the clipboard, as transient. The answer is the clipboard's change count after it.
    @discardableResult
    public static func put(_ text: String, on pasteboard: NSPasteboard) -> Int {
        pasteboard.clearContents()
        let item = NSPasteboardItem()
        item.setString(text, forType: .string)
        item.setData(Data(), forType: transient)
        pasteboard.writeObjects([item])
        return pasteboard.changeCount
    }

    /// Puts back what was kept, while the clipboard's change count is still `change`. True when it did.
    @discardableResult
    public func restore(on pasteboard: NSPasteboard, ifStill change: Int) -> Bool {
        guard pasteboard.changeCount == change else { return false }
        pasteboard.clearContents()
        pasteboard.writeObjects(items.map { types in
            let item = NSPasteboardItem()
            for (type, data) in types { item.setData(data, forType: type) }
            return item
        })
        return true
    }
}
#endif
