import Foundation

/// WHERE THE APP KEEPS ITS FILES AND CHOICES, and what it may do to this Mac: resolved once, at
/// launch. Every path and every stored choice of the app comes from here.
///
/// The installed app has the default home: config.json and the folders of captures, inputs, word
/// lists, faces and the record in `~/Library/Application Support/iterate-mac-app`, the endpoint's
/// socket in `~/Library/Application Support/voice-meet-mac`, the log in
/// `~/Library/Logs/voice-meet-mac`, and the choices in `UserDefaults.standard`.
///
/// `--home <folder>` (or the environment's `ITERATE_MAC_HOME`) gives a copy a home of its own:
/// all of the above is in that folder, the choices too (`<home>/defaults.plist`). Such a copy
/// leaves the installed app alone: it registers no global key, touches no login item, never
/// updates itself, and starts no lend unless `--lend` is given. It alone opens the control socket
/// (`ControlSocket`), whose `approval.answer` stands in for Touch ID: the installed app, in the
/// default home, never opens one. Its menu-bar mark says it is a test copy. A copy that only draws
/// (`--render-*`) has a new, empty home in the temporary folder, removed at its exit. README,
/// "Testing with no hand".
struct AppEnvironment: @unchecked Sendable {
    /// config.json and the app's own folders.
    let folder: URL
    let endpointSocket: URL
    /// nil in the default home and in a drawing: only a test copy has a control socket.
    let controlSocket: URL?
    let logDirectory: URL
    let defaults: UserDefaults
    /// True for `--home`, `ITERATE_MAC_HOME` and `--render-*`.
    let hasOwnHome: Bool
    /// Whether the app keeps a lend (`iterate provide`).
    let lends: Bool
    /// A copy that only draws views to files.
    let isRendering: Bool
    /// The time of day in words, for the panel and the activity list. A drawing has a fixed one.
    let clock: @Sendable (Date) -> String

    static let current = resolve(arguments: CommandLine.arguments, environment: ProcessInfo.processInfo.environment)

    static func resolve(arguments: [String], environment: [String: String]) -> AppEnvironment {
        let isRendering = arguments.contains { $0.hasPrefix("--render-") }
        var home: URL?
        if isRendering {
            home = FileManager.default.temporaryDirectory.appendingPathComponent("iterate-render-\(ProcessInfo.processInfo.processIdentifier)")
        } else if let flag = arguments.firstIndex(of: "--home"), arguments.indices.contains(flag + 1) {
            home = URL(fileURLWithPath: arguments[flag + 1]).standardizedFileURL
        } else if let path = environment["ITERATE_MAC_HOME"], !path.isEmpty {
            home = URL(fileURLWithPath: path).standardizedFileURL
        }
        let clock = isRendering ? Self.fixedClock : Self.localClock
        guard let home else {
            let library = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library")
            let support = library.appendingPathComponent("Application Support/voice-meet-mac")
            return AppEnvironment(
                folder: library.appendingPathComponent("Application Support/iterate-mac-app"),
                endpointSocket: support.appendingPathComponent("endpoint.sock"),
                controlSocket: nil,
                logDirectory: library.appendingPathComponent("Logs/voice-meet-mac", isDirectory: true),
                defaults: .standard, hasOwnHome: false, lends: true, isRendering: false, clock: clock)
        }
        try? FileManager.default.createDirectory(at: home, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        // the bridges and cli.mjs that the app starts read the same home
        setenv("ITERATE_MAC_HOME", home.path, 1)
        return AppEnvironment(
            folder: home,
            endpointSocket: home.appendingPathComponent("endpoint.sock"),
            controlSocket: isRendering ? nil : home.appendingPathComponent("control.sock"),
            logDirectory: home.appendingPathComponent("logs", isDirectory: true),
            // a path as the suite's name: the choices are the file <home>/defaults.plist
            defaults: UserDefaults(suiteName: home.appendingPathComponent("defaults").path) ?? .standard,
            hasOwnHome: true, lends: !isRendering && arguments.contains("--lend"), isRendering: isRendering, clock: clock)
    }

    private static let localClock: @Sendable (Date) -> String = { date in date.formatted(date: .omitted, time: .standard) }

    /// The same words on every Mac: UTC and a fixed form.
    private static let fixedClock: @Sendable (Date) -> String = { date in
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "HH:mm:ss"
        return formatter.string(from: date)
    }
}
