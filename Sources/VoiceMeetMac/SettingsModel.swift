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
    @Published var update = UpdateRow()
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
    struct UpdateRow: Equatable {
        /// "0.1.0, from npm", or "Built from ~/src/mac-app".
        var title = ""
        var detail = ""
        /// From npm: Update Now and the switch. A trial and a copy are updated by hand.
        var updatesItself = false
    }
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

/// THE ITERATE CLI'S SIGN-IN to one mind, as it keeps it on this Mac: `sessions.json` in its folder
/// (`$XDG_CONFIG_HOME/iterate`, else `~/.config/iterate`), one entry for each mind's API
/// (`https://<address>/api`). An entry has `expiresAt`, the end of its token (4 hours after it was
/// given), and a `refreshToken`, with which the CLI renews it at its next use. The app reads the two
/// and nothing else: no token leaves the file, and no network is asked.
enum SignIn: Equatable {
    case unknown
    /// The token is good until then.
    case until(Date)
    /// The token ended; the CLI renews it at its next use.
    case renews
    case notSignedIn

    /// The address the CLI connects to for a mind of config.json: `example.com` is
    /// `iterate.example.com`, as the CLI's `addressOf` reads two labels.
    nonisolated static func address(of mind: String) -> String {
        mind.range(of: #"^[a-z0-9-]+\.[a-z0-9-]+$"#, options: .regularExpression) != nil ? "iterate.\(mind)" : mind
    }

    /// Reads the sign-in of `mind`, away from the main thread.
    nonisolated static func read(_ mind: String, now: Date = Date()) async -> SignIn {
        await Task.detached(priority: .utility) { () -> SignIn in
            let environment = ProcessInfo.processInfo.environment
            let folder = environment["XDG_CONFIG_HOME"].flatMap { $0.isEmpty ? nil : $0 } ?? (NSHomeDirectory() as NSString).appendingPathComponent(".config")
            let file = URL(fileURLWithPath: folder).appendingPathComponent("iterate/sessions.json")
            guard let data = try? Data(contentsOf: file), let sessions = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
                let session = sessions["https://\(address(of: mind))/api"] as? [String: Any]
            else { return .notSignedIn }
            let renewable = (session["refreshToken"] as? String).map { !$0.isEmpty } ?? false
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            let ends = (session["expiresAt"] as? String).flatMap { formatter.date(from: $0) ?? ISO8601DateFormatter().date(from: $0) }
            if let ends, ends > now { return .until(ends) }
            if ends == nil, session["token"] != nil { return .renews }
            return renewable ? .renews : .notSignedIn
        }.value
    }

    /// "3 h 12 min left", "12 min left".
    static func left(until: Date, now: Date) -> String {
        let minutes = max(0, Int(until.timeIntervalSince(now) / 60))
        return minutes >= 60 ? "\(minutes / 60) h \(String(format: "%02d", minutes % 60)) min left" : "\(minutes) min left"
    }
}
