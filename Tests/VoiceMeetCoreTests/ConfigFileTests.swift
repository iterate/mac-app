import XCTest

@testable import VoiceMeetCore

final class ConfigFileTests: XCTestCase {
    private func state() throws -> [String: Any] {
        let text = #"{"login":true,"spec":"@iterate-com/mac-app","version":"0.1.0","minds":[{"mind":"a.com","name":"j.mac","keyFile":"/k/a.com.key"},{"mind":"b.com","name":"j.mac","keyFile":"/k/b.com.key"}],"active":"a.com"}"#
        return try XCTUnwrap(JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
    }

    func testUseMakesAKnownMindActive() throws {
        XCTAssertEqual(try ConfigFile.using("B.com", in: state())["active"] as? String, "b.com")
        XCTAssertThrowsError(try ConfigFile.using("c.com", in: state())) { error in
            XCTAssertEqual("\(error)", #"No mind "c.com" on this Mac. Its minds: a.com, b.com."#)
        }
    }

    func testRemoveTakesTheMindAndItsActivityAndNamesItsKey() throws {
        let (removed, key) = try ConfigFile.removing("a.com", from: state())
        XCTAssertEqual(key, "/k/a.com.key")
        XCTAssertEqual((removed["minds"] as? [[String: Any]])?.compactMap { $0["mind"] as? String }, ["b.com"])
        XCTAssertTrue(removed["active"] is NSNull)
        XCTAssertEqual(try ConfigFile.removing("b.com", from: state()).state["active"] as? String, "a.com")
    }

    /// The format of `JSON.stringify(state, null, 2)`, with the keys sorted.
    func testTheFileIsWrittenAsTheCLIWritesIt() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("config-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appendingPathComponent("config.json")
        try ConfigFile.write(ConfigFile.removing("a.com", from: state()).state, to: file)
        XCTAssertEqual(
            try String(contentsOf: file, encoding: .utf8),
            """
            {
              "active": null,
              "login": true,
              "minds": [
                {
                  "keyFile": "/k/b.com.key",
                  "mind": "b.com",
                  "name": "j.mac"
                }
              ],
              "spec": "@iterate-com/mac-app",
              "version": "0.1.0"
            }

            """)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: folder.path), ["config.json"], "no temporary file is left")
        XCTAssertEqual(ConfigFile.stringify(["n": 2, "e": [String](), "o": [String: Any]()]), "{\n  \"e\": [],\n  \"n\": 2,\n  \"o\": {}\n}")
    }

    func testTheProfilesAreTheMindsOfTheCLIsFile() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("xdg-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder.appendingPathComponent("iterate"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        try Data(#"{"configs":{"x":{"mind":"a.com"},"y":{"mind":"a.com"},"z":{}}}"#.utf8).write(to: folder.appendingPathComponent("iterate/minds.json"))
        XCTAssertEqual(ConfigFile.profileMinds(environment: ["XDG_CONFIG_HOME": folder.path]), ["a.com"])
        XCTAssertEqual(ConfigFile.profileMinds(environment: [:], home: "/nowhere"), [])
    }

    /// `update` reads the file again under the CLI's lock; a held lock waits, a lock of a process
    /// that is gone is taken over.
    func testAnUpdateReadsAgainUnderTheLock() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("config-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appendingPathComponent("config.json")
        // another process changed it since the app read it
        var other = try state()
        other["login"] = false
        try ConfigFile.write(other, to: file)
        try ConfigFile.update(file) { try ConfigFile.using("b.com", in: $0) }
        let read = try ConfigFile.read(file)
        XCTAssertEqual(read["active"] as? String, "b.com")
        XCTAssertEqual(read["login"] as? Bool, false, "the other change stays")

        let lock = file.appendingPathExtension("lock")
        // held by a process that runs (this one)
        try Data(String(getpid()).utf8).write(to: lock)
        XCTAssertThrowsError(try ConfigFile.update(file, waitSeconds: 0.1) { $0 })
        // held by one that is gone
        let gone = Process()
        gone.executableURL = URL(fileURLWithPath: "/usr/bin/true")
        try gone.run()
        gone.waitUntilExit()
        try Data(String(gone.processIdentifier).utf8).write(to: lock)
        XCTAssertNoThrow(try ConfigFile.update(file, waitSeconds: 0.1) { $0 })
        XCTAssertFalse(FileManager.default.fileExists(atPath: lock.path), "the lock went with the update")
    }
}
