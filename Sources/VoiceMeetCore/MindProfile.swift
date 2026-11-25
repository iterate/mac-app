import Foundation

#if canImport(ImageIO)
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
#endif

/// WHAT A MIND'S PROFILE MAY SAY, and the names a person types for a mind and for this Mac: the
/// rules of `MindFaces` (the app) and of the forms, kept here so that a test reads them. The
/// profile is the owner's own words, unsigned: its name is one line of bounded length, and its icon
/// an `https:` address on the mind's own website, drawn as a small picture only.
public enum MindProfile {
    /// A hostname of letters, digits, hyphens and dots: the only kind of address read or kept.
    public static func isHostname(_ address: String) -> Bool {
        address.count <= 253 && address.contains(".")
            && address.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == ".") }
    }

    /// The characters that turn the direction of a text: none of them is drawn in a name.
    private static let unsafe = CharacterSet.controlCharacters.union(
        CharacterSet(charactersIn: "\u{200E}\u{200F}\u{202A}\u{202B}\u{202C}\u{202D}\u{202E}\u{2066}\u{2067}\u{2068}\u{2069}"))

    /// The name, one line of at most 80 characters, with no control character and no character
    /// that turns the direction of the text. nil when it is empty or only the address.
    public static func name(_ value: Any?, address: String) -> String? {
        guard let value = value as? String else { return nil }
        let words = value.unicodeScalars.map { unsafe.contains($0) ? " " : String($0) }.joined()
            .split(whereSeparator: \.isWhitespace).joined(separator: " ")
        let name = String(words.prefix(80)).trimmingCharacters(in: .whitespaces)
        return name.isEmpty || [address, "iterate.\(address)"].contains(name.lowercased()) ? nil : name
    }

    /// The icon's address, when it is an `https:` address on the mind's website or a host under it.
    public static func iconURL(_ value: Any?, address: String) -> URL? {
        guard let value = value as? String, value.count <= 2048, let url = URL(string: value),
            url.scheme == "https", url.user == nil, url.password == nil, url.port == nil,
            let host = url.host?.lowercased(), host == address || host.hasSuffix(".\(address)")
        else { return nil }
        return url
    }

    /// The rule of cli.mjs for a mind's address: a host name. nil when it is one (or empty).
    public static func mindProblem(_ mind: String) -> String? {
        if mind.isEmpty { return nil }
        let host = #"^[a-z0-9]([a-z0-9-]*[a-z0-9])?(\.[a-z0-9]([a-z0-9-]*[a-z0-9])?)+$"#
        return mind.range(of: host, options: .regularExpression) == nil ? "A mind's address is a host name, such as example.com." : nil
    }

    /// The name rule of `iterate provide` for this Mac's name in a mind (`jane.mac`, without
    /// `itx.`). nil when it is one (or empty).
    public static func deviceNameProblem(_ name: String) -> String? {
        if name.isEmpty { return nil }
        if name.hasPrefix("itx.") { return "Leave out \"itx.\": it is always there." }
        let rule = #"^[a-zA-Z][a-zA-Z0-9]*(\.[a-zA-Z][a-zA-Z0-9]*)*$"#
        return name.range(of: rule, options: .regularExpression) == nil
            ? "Letters and digits, starting with a letter; dots between parts, such as jane.mac."
            : nil
    }

    /// A picture whose pixels are more than this is not drawn: an icon of 256 KB can say it has
    /// 20,000 × 20,000 pixels, and its decode would take 1.6 GB.
    public static let iconMaxPixels = 2048 * 2048

    #if canImport(ImageIO)
    /// A PNG, JPEG, GIF, HEIC or WebP icon drawn on a square of `pixels` (filled, as `object-fit:
    /// cover`), as PNG bytes. nil for a picture larger than `iconMaxPixels`, or one that does not
    /// read; nil also for an SVG, which the caller draws itself (it has no pixels to bound). Its
    /// size is read from the header first, and the decode is a thumbnail's: for any thread.
    public static func squareIcon(_ data: Data, pixels: Int) -> Data? {
        guard let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
            CGImageSourceGetCount(source) > 0,
            let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
            let width = (properties[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue,
            let height = (properties[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue,
            width > 0, height > 0
        else { return nil }
        let area = width.multipliedReportingOverflow(by: height)
        guard !area.overflow, area.partialValue <= iconMaxPixels else { return nil }
        // the shorter side at `pixels` at least, so that the square is filled
        let longest = Int((Double(max(width, height)) / Double(min(width, height)) * Double(pixels)).rounded(.up))
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: min(max(longest, pixels), max(width, height)), kCGImageSourceShouldCacheImmediately: false,
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary),
            let context = CGContext(
                data: nil, width: pixels, height: pixels, bitsPerComponent: 8, bytesPerRow: 0,
                space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        let scale = Double(pixels) / Double(min(image.width, image.height))
        let size = CGSize(width: Double(image.width) * scale, height: Double(image.height) * scale)
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: (Double(pixels) - size.width) / 2, y: (Double(pixels) - size.height) / 2, width: size.width, height: size.height))
        guard let square = context.makeImage() else { return nil }
        let bytes = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(bytes, UTType.png.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, square, nil)
        return CGImageDestinationFinalize(destination) ? bytes as Data : nil
    }
    #endif

    /// Whether `data` is an SVG: XML whose root is `<svg`.
    public static func isSVG(_ data: Data) -> Bool {
        guard let head = String(data: data.prefix(1024), encoding: .utf8) else { return false }
        return head.range(of: "<svg", options: .caseInsensitive) != nil
    }

    /// The body of an answer, read as it arrives and given up past `max` bytes: a server that
    /// streams 50 MB is read for `max` and one chunk more, not to its end. `expected` is the
    /// answer's Content-Length, when it said one (-1 when not).
    public static func bounded<Bytes: AsyncSequence>(_ bytes: Bytes, expected: Int64, max: Int) async throws -> Data? where Bytes.Element == UInt8 {
        if expected > Int64(max) { return nil }
        var data = Data()
        data.reserveCapacity(expected > 0 ? Int(expected) : 4096)
        for try await byte in bytes {
            data.append(byte)
            if data.count > max { return nil }
        }
        return data
    }
}
