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
        return focusedSubrole == secureSubrole || focusedRole == secureSubrole
    }
}
