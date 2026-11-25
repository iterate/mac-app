import Foundation

/// WHEN A KEY STAYS ON THE MAC: a key typed into a password goes to no mind, not even as a key
/// code. The north star is sign-in with no password at all; until then, the keyboard events
/// (`device/key-pressed`) leave out every key while one of these holds:
///
/// - macOS's secure input is on (`IsSecureEventInputEnabled`): a system password prompt, the
///   login window, Terminal's Secure Keyboard Entry, 1Password's own master password field.
/// - The app in front is a password manager or a system password prompt (`apps`).
/// - The focused element is a password field (Accessibility's `AXSecureTextField`), as in a
///   browser's sign-in form.
///
/// The keys after such a field, in the same app, go again as soon as the focus leaves it.
public enum SecretKeys {
    /// Password managers and the system's own password prompts, by bundle id (any case).
    public static let apps: Set<String> = [
        "com.1password.1password", "com.agilebits.onepassword7", "com.agilebits.onepassword-osx",
        "com.bitwarden.desktop", "com.lastpass.lastpass", "com.dashlane.dashlane", "com.apple.keychainaccess",
        "com.apple.passwords", "com.apple.securityagent", "com.apple.loginwindow",
        "com.apple.coreservices.uiagent", "com.apple.localauthentication.uiagent",
    ]

    /// The subrole of a password field.
    public static let secureSubrole = "AXSecureTextField"

    /// True: this key goes to no mind.
    public static func withholds(secureInput: Bool, app: String?, focusedSubrole: String?, focusedRole: String? = nil) -> Bool {
        if secureInput { return true }
        if let app, apps.contains(app.lowercased()) { return true }
        return isPasswordField(role: focusedRole, subrole: focusedSubrole)
    }

    /// Whether a focused element with this role and subrole is a password field.
    public static func isPasswordField(role: String?, subrole: String?) -> Bool {
        subrole == secureSubrole || role == secureSubrole
    }
}

/// THE FOCUSED ELEMENT'S PART OF THE RULE, kept between keys, so that a key costs no question to
/// the app in front (`FocusWatch` in the app). The front app tells when its focus moves (an
/// `AXObserver`); each such change is read once, and a key reads the verdict kept here. A verdict
/// holds for one app: another app in front, or a read that failed, leaves none, and the key then
/// asks the app itself, as each key did before.
public struct FocusVerdict: Equatable, Sendable {
    /// The app in front whose focus the verdict is of.
    public private(set) var pid: Int32?
    /// True: the focus is in a password field. Nil: not known; ask at the key.
    public private(set) var isPassword: Bool?
    /// When the verdict was read: a "not a password" verdict holds `maxAge` seconds, then a key
    /// asks again, in case the app moved its focus without telling. A "password" verdict holds
    /// until the focus moves: that error is the safe one.
    public private(set) var readAt: Date?
    public static let maxAge: TimeInterval = 1

    public init() {}

    /// Another app is in front (or none): no verdict until its focus is read.
    public mutating func front(_ pid: Int32?) {
        guard pid != self.pid else { return }
        self.pid = pid
        isPassword = nil
    }

    /// The focus of `pid` was read: `read` false when the app did not answer.
    public mutating func read(pid: Int32, role: String?, subrole: String?, read: Bool, at time: Date = Date()) {
        guard pid == self.pid else { return }
        isPassword = read ? SecretKeys.isPasswordField(role: role, subrole: subrole) : nil
        readAt = time
    }

    /// The verdict was lost (the app stopped telling): ask at each key again.
    public mutating func forget() { isPassword = nil }

    /// The kept verdict for a key typed while `pid` is in front; nil: ask the app.
    public func verdict(for pid: Int32?, at time: Date = Date()) -> Bool? {
        guard pid != nil, pid == self.pid, let isPassword else { return nil }
        if isPassword { return true }
        guard let readAt, time.timeIntervalSince(readAt) < Self.maxAge else { return nil }
        return false
    }
}
