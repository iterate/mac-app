import XCTest

@testable import VoiceMeetCore

final class UpdateSourceTests: XCTestCase {
    func testTheRegistryUpdatesItself() {
        let source = UpdateSource.of(spec: "@iterate-com/mac-app@latest", copy: nil, version: "0.2.0")
        XCTAssertEqual(source, .registry(version: "0.2.0"))
        XCTAssertTrue(source.updatesItself)
        XCTAssertEqual(source.line(home: "/Users/jane"), "Version 0.2.0 · updates by itself")
    }

    func testATrialIsUpdatedByHand() {
        for spec in ["https://pkg.pr.new/@iterate-com/mac-app@1234", "/Users/jane/src/packages/mac-app", "@iterate-com/mac-app-other@1"] {
            let source = UpdateSource.of(spec: spec, copy: nil, version: "0.2.0")
            XCTAssertEqual(source, .trial(spec: spec, version: "0.2.0"), spec)
            XCTAssertFalse(source.updatesItself)
        }
    }

    func testACopyNeverUpdatesItselfWhateverTheSpec() {
        let source = UpdateSource.of(spec: "@iterate-com/mac-app@latest", copy: "/Users/jane/src/iterate-mac-app", version: "0.2.0")
        XCTAssertEqual(source, .copy(folder: "/Users/jane/src/iterate-mac-app"))
        XCTAssertFalse(source.updatesItself)
        XCTAssertEqual(source.line(home: "/Users/jane"), "Built from ~/src/iterate-mac-app")
        // a folder outside the home folder, and a home folder that is only a prefix of the name
        XCTAssertEqual(UpdateSource.copy(folder: "/opt/mac").line(home: "/Users/jane"), "Built from /opt/mac")
        XCTAssertEqual(UpdateSource.copy(folder: "/Users/janet/app").line(home: "/Users/jane"), "Built from /Users/janet/app")
        // an empty `copy` is no copy
        XCTAssertEqual(UpdateSource.of(spec: "/x", copy: "", version: "1"), .trial(spec: "/x", version: "1"))
    }
}

final class SemanticVersionTests: XCTestCase {
    /// Carbon 6: an older `latest` (a rollback on npm, a cached answer) is no update.
    func testOnlyANewerVersionIsAnUpdate() {
        let newer: [(String, String)] = [
            ("0.2.0", "0.1.9"), ("0.10.0", "0.9.0"), ("1.0.0", "1.0.0-beta.2"), ("1.0.0-beta.10", "1.0.0-beta.2"),
            ("1.0.0-beta", "1.0.0-alpha.1"), ("1.0.0-alpha.1", "1.0.0-alpha"), ("2.0.0", "1.99.99"),
        ]
        for (latest, current) in newer {
            XCTAssertTrue(SemanticVersion.isNewer(latest, than: current), "\(latest) > \(current)")
            XCTAssertFalse(SemanticVersion.isNewer(current, than: latest), "\(current) < \(latest)")
        }
        for (latest, current) in [("0.1.0", "0.1.0"), ("0.1.0+build.2", "0.1.0"), ("latest", "0.1.0"), ("0.1", "0.1.0"), ("", "0.1.0")] {
            XCTAssertFalse(SemanticVersion.isNewer(latest, than: current), "\(latest) vs \(current)")
        }
    }

    func testTheVersionRows() {
        let registry = UpdateSource.registry(version: "0.2.0")
        let row = { (latest: String?) in
            UpdateStatus.of(registry, home: "/Users/jane", hasOwnHome: false, updatesByItself: true, check: ("14:01", latest)).detail
        }
        XCTAssertEqual(row("0.3.0"), "Version 0.3.0 is out. Checked at 14:01.")
        XCTAssertEqual(row("0.1.0"), "Up to date. Checked at 14:01.")
        XCTAssertEqual(row(nil), "npm did not answer at 14:01.")
        XCTAssertEqual(UpdateStatus.of(nil, home: "", hasOwnHome: false, updatesByItself: true, check: nil).title, "Not set up")
        XCTAssertEqual(
            UpdateStatus.of(registry, home: "", hasOwnHome: true, updatesByItself: true, check: nil),
            UpdateStatus(title: "0.2.0, from npm", detail: "A home of its own never updates.", updatesItself: true))
        XCTAssertEqual(
            UpdateStatus.of(.copy(folder: "/Users/jane/src/mac-app"), home: "/Users/jane", hasOwnHome: false, updatesByItself: true, check: nil).title,
            "Built from ~/src/mac-app")
    }
}
