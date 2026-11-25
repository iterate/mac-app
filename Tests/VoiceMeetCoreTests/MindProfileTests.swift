import XCTest

@testable import VoiceMeetCore

final class MindProfileTests: XCTestCase {
    func testANameIsOneSafeLine() {
        XCTAssertEqual(MindProfile.name("  Jane's\nmind  ", address: "example.com"), "Jane's mind")
        // a character that turns the text is a space: "evil\u{202E}moc.elpmaxe" cannot read as another address
        XCTAssertEqual(MindProfile.name("evil\u{202E}moc.elpmaxe", address: "example.com"), "evil moc.elpmaxe")
        XCTAssertNil(MindProfile.name("\u{2066}\u{2069}", address: "example.com"))
        XCTAssertNil(MindProfile.name("iterate.example.com", address: "example.com"))
        XCTAssertNil(MindProfile.name(42, address: "example.com"))
        XCTAssertEqual(MindProfile.name(String(repeating: "a", count: 200), address: "example.com")?.count, 80)
    }

    func testAnIconIsOnTheMindsOwnWebsite() {
        XCTAssertNotNil(MindProfile.iconURL("https://example.com/icon.png", address: "example.com"))
        XCTAssertNotNil(MindProfile.iconURL("https://cdn.example.com/icon.png", address: "example.com"))
        for bad in [
            "http://example.com/icon.png", "https://example.com.evil.net/icon.png", "https://evilexample.com/icon.png",
            "https://user:pw@example.com/icon.png", "https://example.com:8443/icon.png", "data:image/png;base64,AAAA",
        ] {
            XCTAssertNil(MindProfile.iconURL(bad, address: "example.com"), bad)
        }
        XCTAssertTrue(MindProfile.isHostname("iterate.example.com"))
        XCTAssertFalse(MindProfile.isHostname("example.com/../x"))
        XCTAssertFalse(MindProfile.isHostname("localhost"))
    }

    func testTheNamesOfTheForms() {
        XCTAssertNil(MindProfile.mindProblem("example.com"))
        XCTAssertNotNil(MindProfile.mindProblem("example"))
        XCTAssertNotNil(MindProfile.mindProblem("-x.com"))
        XCTAssertNil(MindProfile.deviceNameProblem("jane.mac"))
        XCTAssertNil(MindProfile.deviceNameProblem(""))
        XCTAssertEqual(MindProfile.deviceNameProblem("itx.jane"), "Leave out \"itx.\": it is always there.")
        for bad in ["1mac", "jane..mac", "jane.", "jane-mac", "jane mac"] { XCTAssertNotNil(MindProfile.deviceNameProblem(bad), bad) }
    }

    /// Fable 15: a small file that says it has 20,000 × 20,000 pixels is not decoded.
    func testAHugePictureIsNotDecoded() throws {
        let small = try XCTUnwrap(Self.png(width: 300, height: 200))
        let square = try XCTUnwrap(MindProfile.squareIcon(small, pixels: 128))
        let source = try XCTUnwrap(CGImageSourceCreateWithData(square as CFData, nil))
        let image = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
        XCTAssertEqual([image.width, image.height], [128, 128])

        // the same picture, with a header that says 20,000 × 20,000
        var huge = small
        huge.replaceSubrange(16..<24, with: Self.bigEndian(20_000) + Self.bigEndian(20_000))
        huge.replaceSubrange(29..<33, with: Self.bigEndian(Self.crc32(huge[12..<29])))
        XCTAssertNil(MindProfile.squareIcon(huge, pixels: 128))
        XCTAssertNil(MindProfile.squareIcon(Data("not a picture".utf8), pixels: 128))
        XCTAssertTrue(MindProfile.isSVG(Data(#"<?xml version="1.0"?><svg xmlns="http://www.w3.org/2000/svg"/>"#.utf8)))
    }

    /// Fable 15: an answer is read until it passes its bound, not to its end.
    func testAnAnswerIsReadToItsBoundOnly() async throws {
        let counter = Counter()
        let endless = AsyncStream<UInt8> { continuation in
            for _ in 0..<1_000_000 { continuation.yield(1) }
            continuation.finish()
        }.map { byte -> UInt8 in counter.add(); return byte }
        let read = try await MindProfile.bounded(endless, expected: -1, max: 16 * 1024)
        XCTAssertNil(read)
        XCTAssertEqual(counter.value, 16 * 1024 + 1)
        let said = try await MindProfile.bounded(AsyncStream<UInt8> { $0.finish() }, expected: 50_000_000, max: 16 * 1024)
        XCTAssertNil(said, "a Content-Length over the bound is not read at all")
        let whole = try await MindProfile.bounded(AsyncStream<UInt8> { c in c.yield(7); c.finish() }, expected: 1, max: 16)
        XCTAssertEqual(whole, Data([7]))
    }

    private final class Counter: @unchecked Sendable {
        private let lock = NSLock()
        private var count = 0
        func add() { lock.withLock { count += 1 } }
        var value: Int { lock.withLock { count } }
    }

    private static func png(width: Int, height: Int) -> Data? {
        guard let context = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        context.setFillColor(CGColor(red: 1, green: 0, blue: 0, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        guard let image = context.makeImage() else { return nil }
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, "public.png" as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, image, nil)
        return CGImageDestinationFinalize(destination) ? data as Data : nil
    }

    private static func bigEndian(_ value: UInt32) -> Data { withUnsafeBytes(of: value.bigEndian) { Data($0) } }

    private static func crc32(_ bytes: Data) -> UInt32 {
        var crc: UInt32 = 0xFFFF_FFFF
        for byte in bytes {
            crc ^= UInt32(byte)
            for _ in 0..<8 { crc = crc & 1 == 1 ? (crc >> 1) ^ 0xEDB8_8320 : crc >> 1 }
        }
        return ~crc
    }
}

final class SignInTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_764_000_000)

    private func sessions(_ entry: [String: Any], api: String = "https://iterate.example.com/api") -> Data {
        try! JSONSerialization.data(withJSONObject: [api: entry])
    }

    func testTheSignInOfAMind() {
        let later = "2025-11-24T17:00:00.123Z", earlier = "2025-11-24T10:00:00Z"
        guard case .until(let end) = SignIn.parse(sessions(["expiresAt": later]), mind: "example.com", now: now) else { return XCTFail("not signed in") }
        XCTAssertEqual(end.timeIntervalSince1970, 1_764_003_600.123, accuracy: 0.001)
        XCTAssertEqual(SignIn.parse(sessions(["expiresAt": "2025-11-24T17:00:00Z"]), mind: "example.com", now: now), .until(Date(timeIntervalSince1970: 1_764_003_600)))
        XCTAssertEqual(SignIn.parse(sessions(["expiresAt": earlier, "refreshToken": "r"]), mind: "example.com", now: now), .renews)
        XCTAssertEqual(SignIn.parse(sessions(["expiresAt": earlier, "refreshToken": ""]), mind: "example.com", now: now), .notSignedIn)
        XCTAssertEqual(SignIn.parse(sessions(["token": "t"]), mind: "example.com", now: now), .renews)
        XCTAssertEqual(SignIn.parse(nil, mind: "example.com", now: now), .notSignedIn)
        XCTAssertEqual(SignIn.parse(Data("{".utf8), mind: "example.com", now: now), .notSignedIn)
        // a mind of three labels is its own address
        XCTAssertEqual(SignIn.parse(sessions(["token": "t"], api: "https://a.b.example.com/api"), mind: "a.b.example.com", now: now), .renews)
        XCTAssertEqual(SignIn.address(of: "example.com"), "iterate.example.com")
        XCTAssertEqual(SignIn.left(until: now.addingTimeInterval(3 * 3600 + 12 * 60 + 30), now: now), "3 h 12 min left")
        XCTAssertEqual(SignIn.left(until: now.addingTimeInterval(12 * 60), now: now), "12 min left")
        XCTAssertEqual(SignIn.file(environment: ["XDG_CONFIG_HOME": "/x"], home: "/h").path, "/x/iterate/sessions.json")
        XCTAssertEqual(SignIn.file(environment: [:], home: "/h").path, "/h/.config/iterate/sessions.json")
    }
}
