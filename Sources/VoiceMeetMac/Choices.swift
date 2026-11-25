import AppKit
import Carbon.HIToolbox

/// THE PERSON'S CHOICES FOR THIS MAC that Settings changes (design/HANDOFF.md 4.2), beside the
/// sharing ones (`sharing.<thing>`, `Permissions.swift`) and `activity.pill` (`ActivityLog`). Each
/// is read from the defaults once, at the start, and written at each change: no view and no key
/// press reads the defaults.
///
/// | Key | What |
/// | --- | --- |
/// | `approval.minutes` | How long "Approve for N Minutes" lasts (`Approval`); 30 unless set. |
/// | `key.capture`, `key.input` | The keys of capture and the input (`HotKey`), or "none". |
/// | `dictation.key` | "fn": a hold of fn dictates; "none": fn does nothing (⌥⇧D still works). |
/// | `dictation.doubleTap` | Two taps of fn keep the dictation on. |
/// | `dictation.pill` | The dictation pill shows the words; off, the level bars and the time alone. |
/// | `dictation.sounds` | A gentle sound when a dictation starts, is written and is thrown away (`DictationSound`). |
/// | `dictation.write` | "cursor": the text is written where the cursor is; "clipboard": it is put on the clipboard only. |
/// | `update.byItself` | The app updates itself once an hour (only when it is from npm). |
@MainActor
final class Choices: ObservableObject {
    static let shared = Choices()

    /// What "An approval can last" offers.
    static let approvalChoices = [5, 15, 30, 60, 120]

    enum Write: String, CaseIterable {
        case cursor, clipboard

        var title: String { self == .cursor ? "Where the cursor is" : "On the clipboard only" }
    }

    private let defaults = AppEnvironment.current.defaults

    @Published var approvalMinutes: Int { didSet { defaults.set(approvalMinutes, forKey: "approval.minutes") } }
    @Published var captureKey: HotKey.Combo? { didSet { defaults.set(captureKey?.stored ?? "none", forKey: "key.capture") } }
    @Published var inputKey: HotKey.Combo? { didSet { defaults.set(inputKey?.stored ?? "none", forKey: "key.input") } }
    @Published var dictationOnFn: Bool { didSet { defaults.set(dictationOnFn ? "fn" : "none", forKey: "dictation.key") } }
    @Published var doubleTap: Bool { didSet { defaults.set(doubleTap, forKey: "dictation.doubleTap") } }
    @Published var pillShowsWords: Bool { didSet { defaults.set(pillShowsWords, forKey: "dictation.pill") } }
    @Published var sounds: Bool { didSet { defaults.set(sounds, forKey: "dictation.sounds") } }
    @Published var write: Write { didSet { defaults.set(write.rawValue, forKey: "dictation.write") } }
    @Published var updatesByItself: Bool { didSet { defaults.set(updatesByItself, forKey: "update.byItself") } }

    private init() {
        let minutes = defaults.integer(forKey: "approval.minutes")
        approvalMinutes = minutes > 0 ? min(minutes, 24 * 60) : 30
        captureKey = HotKey.Combo.read(defaults.string(forKey: "key.capture"), as: .capture)
        inputKey = HotKey.Combo.read(defaults.string(forKey: "key.input"), as: .input)
        dictationOnFn = defaults.string(forKey: "dictation.key") != "none"
        doubleTap = defaults.object(forKey: "dictation.doubleTap") as? Bool ?? true
        pillShowsWords = defaults.object(forKey: "dictation.pill") as? Bool ?? true
        sounds = defaults.object(forKey: "dictation.sounds") as? Bool ?? true
        write = Write(rawValue: defaults.string(forKey: "dictation.write") ?? "") ?? .cursor
        updatesByItself = defaults.object(forKey: "update.byItself") as? Bool ?? true
    }

    /// The words of an approval's length, as its button says them: "30 Minutes", "1 Hour".
    static func approvalWords(_ minutes: Int) -> String {
        if minutes % 60 == 0 { return minutes == 60 ? "1 Hour" : "\(minutes / 60) Hours" }
        return "\(minutes) Minutes"
    }
}

extension HotKey.Combo {
    /// How the defaults keep a key: "<key code> <Carbon modifiers>".
    var stored: String { "\(key) \(modifiers)" }

    /// The stored key, the default one when none is stored, and nil for "none".
    static func read(_ stored: String?, as fallback: HotKey.Combo) -> HotKey.Combo? {
        guard let stored else { return fallback }
        if stored == "none" { return nil }
        let parts = stored.split(separator: " ").compactMap { Int($0) }
        guard parts.count == 2 else { return fallback }
        return HotKey.Combo(id: fallback.id, key: parts[0], modifiers: parts[1])
    }

    /// A key that the person pressed, for a recorder: nil for a key that needs ⌘, ⌥ or ⌃ and has none.
    static func from(_ event: NSEvent, id: UInt32) -> HotKey.Combo? {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        var modifiers = 0
        if flags.contains(.command) { modifiers |= cmdKey }
        if flags.contains(.option) { modifiers |= optionKey }
        if flags.contains(.control) { modifiers |= controlKey }
        if flags.contains(.shift) { modifiers |= shiftKey }
        guard modifiers & (cmdKey | optionKey | controlKey) != 0 else { return nil }
        return HotKey.Combo(id: id, key: Int(event.keyCode), modifiers: modifiers)
    }
}
