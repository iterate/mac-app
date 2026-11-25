import Foundation

/// WHERE THE INSTALLED APP CAME FROM, and so whether it updates itself. `npx @iterate-com/mac-app`
/// writes it to config.json: `spec` is what the setup ran from, and `copy` is set only when it ran
/// from a copy that `init` made (the copy has `.iterate-mac-app.json`). An app built from a copy
/// runs what was built: its owner changes the source and updates it with `update` in the copy.
public enum UpdateSource: Equatable, Sendable {
    /// npm's registry: once an hour the app asks for a newer version and runs its `update`.
    case registry(version: String)
    /// A pkg.pr.new link or a folder of the package: a trial, updated by hand.
    case trial(spec: String, version: String)
    /// An owner's copy, made by `init`: built from that folder, never updated by the app.
    case copy(folder: String)

    public static let package = "@iterate-com/mac-app"

    public static func of(spec: String, copy: String?, version: String) -> UpdateSource {
        if let copy, !copy.isEmpty { return .copy(folder: copy) }
        // `@iterate-com/mac-app@latest`, never `@iterate-com/mac-app-other`
        if spec == package || spec.hasPrefix("\(package)@") { return .registry(version: version) }
        return .trial(spec: spec, version: version)
    }

    public var updatesItself: Bool {
        if case .registry = self { return true }
        return false
    }

    /// The panel's line, with the home folder written as `~`.
    public func line(home: String) -> String {
        switch self {
        case .registry(let version): return "Version \(version) · updates by itself"
        case .trial(_, let version): return "Version \(version), a trial · updated by hand"
        case .copy(let folder):
            let shown = !home.isEmpty && folder.hasPrefix(home + "/") ? "~" + folder.dropFirst(home.count) : folder
            return "Built from \(shown)"
        }
    }
}

/// A version as npm writes it, `1.2.3` or `1.2.3-beta.4`, ordered as semver orders it: a
/// pre-release is before its release, and its parts are compared as numbers where both are.
public struct SemanticVersion: Comparable, Sendable {
    public let core: [Int]
    public let prerelease: [String]

    /// Nil for a text that is no version (`latest`, empty).
    public init?(_ text: String) {
        let withoutBuild = text.split(separator: "+", maxSplits: 1).first.map(String.init) ?? ""
        let parts = withoutBuild.split(separator: "-", maxSplits: 1).map(String.init)
        let numbers = (parts.first ?? "").split(separator: ".", omittingEmptySubsequences: false).map { Int($0) }
        guard numbers.count == 3, numbers.allSatisfy({ $0 != nil }) else { return nil }
        core = numbers.compactMap { $0 }
        prerelease = parts.count > 1 ? parts[1].split(separator: ".").map(String.init) : []
    }

    public static func < (a: SemanticVersion, b: SemanticVersion) -> Bool {
        if a.core != b.core { return a.core.lexicographicallyPrecedes(b.core) }
        // a release is after each of its pre-releases
        if a.prerelease.isEmpty || b.prerelease.isEmpty { return !a.prerelease.isEmpty && b.prerelease.isEmpty }
        for (x, y) in zip(a.prerelease, b.prerelease) where x != y {
            switch (Int(x), Int(y)) {
            case let (x?, y?): return x < y
            case (_?, nil): return true
            case (nil, _?): return false
            case (nil, nil): return x < y
            }
        }
        return a.prerelease.count < b.prerelease.count
    }

    /// True when npm's `latest` is a newer version than `current`; false when either is no version.
    public static func isNewer(_ latest: String, than current: String) -> Bool {
        guard let latest = SemanticVersion(latest), let current = SemanticVersion(current) else { return false }
        return current < latest
    }
}

/// General's version rows in Settings: where the app came from and the last ask of npm.
public struct UpdateStatus: Equatable, Sendable {
    public var title: String
    public var detail: String
    /// From npm: Update Now and the switch. A trial and a copy are updated by hand.
    public var updatesItself: Bool

    public init(title: String, detail: String, updatesItself: Bool = false) {
        (self.title, self.detail, self.updatesItself) = (title, detail, updatesItself)
    }

    /// The rows for `source` (nil: not set up). `check` is the last ask of npm, with its time of
    /// day as `clock` writes it; `hasOwnHome` a test copy's, which never updates.
    public static func of(
        _ source: UpdateSource?, home: String, hasOwnHome: Bool, updatesByItself: Bool, check: (at: String, latest: String?)?
    ) -> UpdateStatus {
        guard let source else { return UpdateStatus(title: "Not set up", detail: "Run npx @iterate-com/mac-app in a terminal.") }
        switch source {
        case .copy:
            return UpdateStatus(title: source.line(home: home), detail: "It runs what was built. Run node cli.mjs update in that folder to build it again.")
        case .trial(let spec, let version):
            return UpdateStatus(title: "\(version), a trial", detail: "Updated by hand: npx \(spec) update.")
        case .registry(let version):
            let detail: String
            if hasOwnHome {
                detail = "A home of its own never updates."
            } else if let check {
                if let latest = check.latest, SemanticVersion.isNewer(latest, than: version) {
                    detail = "Version \(latest) is out. Checked at \(check.at)."
                } else {
                    detail = check.latest == nil ? "npm did not answer at \(check.at)." : "Up to date. Checked at \(check.at)."
                }
            } else {
                detail = updatesByItself ? "Not checked yet: the first check is a minute after the start." : "It does not update by itself."
            }
            return UpdateStatus(title: "\(version), from npm", detail: detail, updatesItself: true)
        }
    }
}
