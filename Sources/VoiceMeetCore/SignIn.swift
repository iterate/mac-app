import Foundation

/// THE ITERATE CLI'S SIGN-IN to one mind, as it keeps it on this Mac: `sessions.json` in its folder
/// (`$XDG_CONFIG_HOME/iterate`, else `~/.config/iterate`), one entry for each mind's API
/// (`https://<address>/api`). An entry has `expiresAt`, the end of its token (4 hours after it was
/// given), and a `refreshToken`, with which the CLI renews it at its next use. The app reads the two
/// and nothing else: no token leaves the file, and no network is asked.
public enum SignIn: Equatable, Sendable {
    case unknown
    /// The token is good until then.
    case until(Date)
    /// The token ended; the CLI renews it at its next use.
    case renews
    case notSignedIn

    /// The address the CLI connects to for a mind of config.json: `example.com` is
    /// `iterate.example.com`, as the CLI's `addressOf` reads two labels.
    public static func address(of mind: String) -> String {
        mind.range(of: #"^[a-z0-9-]+\.[a-z0-9-]+$"#, options: .regularExpression) != nil ? "iterate.\(mind)" : mind
    }

    /// The CLI's file of sign-ins, for this environment.
    public static func file(environment: [String: String] = ProcessInfo.processInfo.environment, home: String = NSHomeDirectory()) -> URL {
        let folder = environment["XDG_CONFIG_HOME"].flatMap { $0.isEmpty ? nil : $0 } ?? (home as NSString).appendingPathComponent(".config")
        return URL(fileURLWithPath: folder).appendingPathComponent("iterate/sessions.json")
    }

    /// Reads the sign-in of `mind`, away from the main thread.
    public static func read(_ mind: String, now: Date = Date()) async -> SignIn {
        await Task.detached(priority: .utility) { () -> SignIn in
            parse(try? Data(contentsOf: file()), mind: mind, now: now)
        }.value
    }

    /// The sign-in of `mind` in the bytes of sessions.json (nil: no file).
    public static func parse(_ data: Data?, mind: String, now: Date) -> SignIn {
        guard let data, let sessions = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
            let session = sessions["https://\(address(of: mind))/api"] as? [String: Any]
        else { return .notSignedIn }
        let renewable = (session["refreshToken"] as? String).map { !$0.isEmpty } ?? false
        let ends = (session["expiresAt"] as? String).flatMap { text in (try? withFraction.parse(text)) ?? (try? withoutFraction.parse(text)) }
        if let ends, ends > now { return .until(ends) }
        if ends == nil, session["token"] != nil { return .renews }
        return renewable ? .renews : .notSignedIn
    }

    private static let withFraction = Date.ISO8601FormatStyle(includingFractionalSeconds: true)
    private static let withoutFraction = Date.ISO8601FormatStyle()

    /// "3 h 12 min left", "12 min left".
    public static func left(until: Date, now: Date) -> String {
        let minutes = max(0, Int(until.timeIntervalSince(now) / 60))
        return minutes >= 60 ? "\(minutes / 60) h \(String(format: "%02d", minutes % 60)) min left" : "\(minutes) min left"
    }
}
