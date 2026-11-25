import AppKit
import SwiftUI
import VoiceMeetCore

/// WHAT SETTINGS SHOWS that is not in its sub-models (`Choices`, `SpeechChoice`, `Words`): the
/// page, the minds and the lend, the saved values of config.json, the version, each mind's sign-in.
/// The app fills it when the window opens and at each change while it shows
/// (`AppDelegate.refreshSettings`), so no view reads a file, the defaults or a device while it draws.
@MainActor
final class SettingsState: ObservableObject {
    enum Page: Hashable {
        case general, dictation
        case mind(String)

        /// The page's name for `ui.state`: `general`, `dictation`, `mind:<address>`.
        var name: String {
            switch self {
            case .general: "general"
            case .dictation: "dictation"
            case .mind(let mind): "mind:\(mind)"
            }
        }
    }

    @Published var page = Page.general
    /// The minds, the active one, its phase (the panel's `LendView`).
    @Published var lend = LendView()
    /// config.json's `login`.
    @Published var login = false
    /// config.json's `wordsExpression`: this Mac's default; nil is the built-in one.
    @Published var defaultExpression: String?
    /// Each mind's own expression (`minds[].wordsExpression`), by its address.
    @Published var expressions: [String: String] = [:]
    @Published var update = UpdateRow(title: "", detail: "")
    /// Each mind's sign-in of the iterate CLI, read when its page shows.
    @Published var signIns: [String: SignIn] = [:]
    /// What keeps fn dictation from working (`Dictation.fnLines`).
    @Published var fnLines: [String] = []
    /// A key that macOS refused, in words, by the key's id (`HotKey.Combo.id`).
    @Published var keyProblems: [UInt32: String] = [:]
    /// The Activity page's tick, "Show each act on the screen" (`ActivityLog.showsPill`).
    @Published var showsPill = true
    /// The drawings' clock; nil is the real one.
    var fixedNow: Date?

    /// The version's rows of General.
    /// General's version rows (`UpdateStatus`).
    typealias UpdateRow = UpdateStatus
}

/// What the person does in Settings.
struct SettingsActions {
    var setLogin: (Bool) -> Void = { _ in }
    var setShowsPill: (Bool) -> Void = { _ in }
    /// A key was recorded (or removed, nil) for capture or the input: the answer is why macOS refused it.
    var setKey: (_ id: UInt32, _ combo: HotKey.Combo?) -> String? = { _, _ in nil }
    /// A recorder listens: the key it replaces does nothing meanwhile.
    var recording: (_ id: UInt32, _ isRecording: Bool) -> Void = { _, _ in }
    var updateNow: () -> Void = {}
    var copyPrompt: () -> Void = {}
    var openKeyboardSettings: () -> Void = {}
    var allowAccessibility: () -> Void = {}
    /// This Mac's default expression; nil is the built-in one.
    var setDefaultExpression: (String?) -> Void = { _ in }
    /// A mind's own expression; nil is the default.
    var setExpression: (_ mind: String, _ expression: String?) -> Void = { _, _ in }
    var fetchNow: (String) -> Void = { _ in }
    /// A mind's page shows: its sign-in and its list are read again.
    var showMind: (String) -> Void = { _ in }
    /// A new name in a mind, after the person said yes: a new key (`Lend.add`).
    var rename: (_ mind: String, _ name: String) -> Void = { _, _ in }
    /// The person chose another page: what it shows is read again.
    var pageChanged: () -> Void = {}
    var lend = LendActions()
}

// The iterate CLI's sign-in to one mind: `SignIn` (VoiceMeetCore).

