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
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path + ".new"))
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
}
