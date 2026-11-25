import AppKit
import VoiceMeetCore

/// The iterate mark for the menu bar, drawn from the logo's own vector paths
/// (`packages/ui/src/components/iterate-logo.svg`), so the package needs no image file for it.
enum IterateIcon {
    /// The two paths of the logo's "i", in the logo's coordinates (500 × 500, y down).
    private static let paths = [
        "M264.649 170.149H289.821L286.092 186.904L276.303 233.444L270.709 259.971L263.717 293.015L258.124 320.008L251.131 352.586L249.267 364.687V371.668L249.733 372.133H253.462L259.522 369.806L266.048 365.617L275.371 357.24L282.829 349.328L286.558 345.14L288.888 346.071L294.948 350.725L308 360.498L307.068 362.36L303.339 367.944L296.813 376.322L291.685 382.837L286.558 388.422L282.363 393.076L275.837 399.592L272.108 402.849L267.446 406.573L262.785 409.83L256.725 413.554L247.869 417.742L238.08 420.535L231.554 421H224.096L216.637 420.069L211.51 418.673L206.382 416.811L201.255 413.088L196.594 408.434L192.865 400.988L191.466 394.938L191 389.818V383.768L193.797 365.152L199.857 335.832L207.315 301.392L224.096 223.205L225.028 216.224V206.916L224.562 205.054L222.231 204.123L219.434 203.193L206.382 203.658L196.127 204.589H193.331V178.526L194.263 175.734L258.59 170.615L264.649 170.149Z",
        "M264.649 78H268.844L275.836 78.9308L282.362 80.7924L287.49 83.5848L292.151 87.7734L295.414 92.8928L297.278 96.616L299.143 105.924L299.609 113.836L299.143 118.49L298.677 122.213L296.812 128.729L293.549 134.779L290.286 138.502L286.091 141.76L282.362 143.621L278.167 145.018L274.438 145.948L267.912 146.414H260.92L254.394 145.483L249.267 144.087L244.139 141.294L239.944 138.037L236.681 133.383L233.884 127.332L232.486 121.282L232.02 117.559V108.716L232.952 101.735L234.816 95.6852L237.613 90.1004L240.41 86.3772L246.936 82.1886L252.529 79.8616L259.522 78.4654L264.649 78Z",
    ]

    /// The mark's height in the menu bar, in points. The bar is 24 points high; at 16 the mark had
    /// too little room above and below.
    private static let menuBarHeight: CGFloat = 13

    /// Every mark is this wide, so the menu bar does not shift when the mark changes.
    private static let menuBarWidth: CGFloat = 11

    /// A template image: the system draws it light or dark with the menu bar.
    static let plain = mark(height: menuBarHeight, color: nil)

    /// Each ink of the mark (`MenuBarMark.Ink`), with and without the gap where the record's dot
    /// sits. The lend at a glance, as Apple's own items show a state: plain while lent; dimmed while
    /// it connects; dimmed with a slash through it while it is not lent (as `wifi.slash` and
    /// `mic.slash` do), all template images, readable in a light and a dark bar. Red, orange and
    /// green are in colour.
    private static let marks: [String: NSImage] = {
        var marks: [String: NSImage] = [:]
        for ink in MenuBarMark.Ink.allCases {
            for gap in [false, true] {
                let image: NSImage
                switch ink {
                case .green: image = mark(height: menuBarHeight, color: .systemGreen, dotGap: gap)
                case .red: image = mark(height: menuBarHeight, color: .systemRed, dotGap: gap)
                case .orange: image = mark(height: menuBarHeight, color: .systemOrange, dotGap: gap)
                case .live: image = mark(height: menuBarHeight, color: nil, dotGap: gap)
                case .connecting: image = mark(height: menuBarHeight, color: nil, alpha: 0.4, dotGap: gap)
                case .down: image = mark(height: menuBarHeight, color: nil, alpha: 0.4, slash: true, dotGap: gap)
                }
                marks["\(ink.rawValue)\(gap)"] = image
            }
        }
        return marks
    }()

    /// The mark of a test copy (a home of its own, `AppEnvironment`): the mark in grey and an orange
    /// "test" after it, never taken for the installed app's. The mark sits at the image's left, as
    /// tall as the plain one, so the record's dot is where it is on the plain mark.
    @MainActor static func testImage(_ mark: MenuBarMark) -> NSImage {
        // made once for each look: the mark is set at each change of the app's state
        let key = "\(mark.ink.rawValue)\(mark.dot != .none)"
        if let made = testMarks[key] { return made }
        let made = makeTestImage(mark)
        testMarks[key] = made
        return made
    }

    @MainActor private static var testMarks: [String: NSImage] = [:]

    private static func makeTestImage(_ mark: MenuBarMark) -> NSImage { testImage(of: image(mark)) }

    /// A test copy's image of `base`, a mark or a face (`FaceIcon`): a template image in grey, a
    /// face as it is, then the orange "test".
    static func testImage(of base: NSImage) -> NSImage {
        let words = NSAttributedString(string: "test", attributes: [.font: NSFont.systemFont(ofSize: 9, weight: .heavy), .foregroundColor: NSColor.systemOrange])
        let size = NSSize(width: base.size.width + 2 + ceil(words.size().width), height: base.size.height)
        return NSImage(size: size, flipped: false) { _ in
            let grey = NSImage(size: base.size, flipped: false) { rect in
                base.draw(in: rect)
                if base.isTemplate {
                    NSColor.systemGray.setFill()
                    rect.fill(using: .sourceAtop)
                }
                return true
            }
            grey.draw(in: NSRect(origin: .zero, size: base.size))
            words.draw(at: NSPoint(x: base.size.width + 2, y: (size.height - words.size().height) / 2))
            return true
        }
    }

    /// The mark's image for `mark`: its ink, with a gap cut where the dot sits when it has one.
    /// The dot itself is drawn by `RecordDotView` over the image, so that a template image stays
    /// one: the system draws it light or dark with the bar, and the dot stays red.
    static func image(_ mark: MenuBarMark) -> NSImage {
        marks["\(mark.ink.rawValue)\(mark.dot != .none)"] ?? plain
    }

    // MARK: - The record's dot

    /// The dot's centre in the mark's image (y down), and its sizes. It sits at the lower right,
    /// beside the foot of the "i", inside the mark's width.
    static let dotCenter = NSPoint(x: 9.2, y: 10.6)
    static let dotRadius: CGFloat = 2.3
    /// The gap cut out of the mark around the dot, so that the dot reads beside every ink.
    private static let dotGapRadius: CGFloat = 3.3
    /// The red of macOS's own recording marks.
    static let dotColor = NSColor.systemRed

    /// Draws the dot around `center`, in the current context: filled while it records, a ring while paused.
    static func drawDot(_ dot: RecordDot, at center: NSPoint, scale: CGFloat = 1) {
        let lineWidth = 1.3 * scale
        switch dot {
        case .none:
            return
        case .recording:
            let r = dotRadius * scale
            dotColor.setFill()
            NSBezierPath(ovalIn: NSRect(x: center.x - r, y: center.y - r, width: 2 * r, height: 2 * r)).fill()
        case .paused:
            let r = dotRadius * scale - lineWidth / 2
            let ring = NSBezierPath(ovalIn: NSRect(x: center.x - r, y: center.y - r, width: 2 * r, height: 2 * r))
            ring.lineWidth = lineWidth
            dotColor.setStroke()
            ring.stroke()
        }
    }

    static func mark(height: CGFloat, color: NSColor?, alpha: CGFloat = 1, slash: Bool = false, dotGap: Bool = false) -> NSImage {
        let glyph = glyph()
        let bounds = glyph.bounds
        let scale = height / bounds.height
        let width = max(menuBarWidth, ceil(bounds.width * scale))
        var transform = AffineTransform(translationByX: (width - bounds.width * scale) / 2, byY: 0)
        transform.scale(scale)
        transform.translate(x: -bounds.minX, y: -bounds.minY)
        glyph.transform(using: transform)
        // A flipped image has y down, as the logo has.
        let image = NSImage(size: NSSize(width: width, height: height), flipped: true) { _ in
            let ink = color ?? .black
            ink.withAlphaComponent(alpha).setFill()
            glyph.fill()
            if slash {
                // from the top left to the bottom right, with a gap cut on each side of it
                let line = NSBezierPath()
                line.move(to: NSPoint(x: 1, y: 1.5))
                line.line(to: NSPoint(x: width - 1, y: height - 1.5))
                line.lineCapStyle = .round
                NSGraphicsContext.current?.compositingOperation = .clear
                line.lineWidth = 3.2
                line.stroke()
                NSGraphicsContext.current?.compositingOperation = .sourceOver
                ink.setStroke()
                line.lineWidth = 1.3
                line.stroke()
            }
            if dotGap {
                let r = dotGapRadius
                NSGraphicsContext.current?.compositingOperation = .clear
                NSBezierPath(ovalIn: NSRect(x: dotCenter.x - r, y: dotCenter.y - r, width: 2 * r, height: 2 * r)).fill()
                NSGraphicsContext.current?.compositingOperation = .sourceOver
            }
            return true
        }
        image.isTemplate = color == nil
        return image
    }

    /// Each lend mark on a light and a dark menu bar, as the system tints a template image, 8 times
    /// its size, one PNG each in `folder` (`--render-icons <folder>`), for a look with no Mac bar.
    /// And `marks-light.png`, `marks-dark.png`: each ink (a row: plain, dimmed, slashed, red,
    /// orange, green) with each record's dot (a column: none, recording, paused).
    /// With them, the mind's face in every state (`FaceIcon.render`).
    @MainActor static func render(to folder: URL) -> Bool {
        let zoom: CGFloat = 8
        let cell = NSSize(width: 40 * zoom, height: 24 * zoom)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let inks: [MenuBarMark.Ink] = [.live, .connecting, .down, .red, .orange, .green]
        for (look, background, ink) in [("light", NSColor(white: 0.93, alpha: 1), NSColor.black), ("dark", NSColor(white: 0.16, alpha: 1), NSColor.white)] {
            for glance in LendGlance.allCases {
                let mark = MenuBarMark.of(bannerShows: false, inUse: false, microphoneOrCameraOn: false, glance: glance, isRecording: false, isPaused: false)
                guard
                    write(size: cell, to: folder.appendingPathComponent("mark-\(glance.rawValue)-\(look).png"), draw: {
                        background.setFill()
                        NSRect(origin: .zero, size: cell).fill()
                        draw(mark, in: NSRect(origin: .zero, size: cell), zoom: zoom, ink: ink)
                    })
                else { return false }
            }
            let sheet = NSSize(width: cell.width * CGFloat(RecordDot.allCases.count), height: cell.height * CGFloat(inks.count))
            guard
                write(size: sheet, to: folder.appendingPathComponent("marks-\(look).png"), draw: {
                    background.setFill()
                    NSRect(origin: .zero, size: sheet).fill()
                    for (row, markInk) in inks.enumerated() {
                        for (column, dot) in RecordDot.allCases.enumerated() {
                            let place = NSRect(x: CGFloat(column) * cell.width, y: sheet.height - CGFloat(row + 1) * cell.height, width: cell.width, height: cell.height)
                            draw(MenuBarMark(ink: markInk, dot: dot), in: place, zoom: zoom, ink: ink)
                        }
                    }
                })
            else { return false }
            // a test copy's mark, as the bar shows it (`testImage`)
            let test = makeTestImage(MenuBarMark(ink: .live, dot: .none))
            let testCell = NSSize(width: (test.size.width + 16) * zoom, height: cell.height)
            guard
                write(size: testCell, to: folder.appendingPathComponent("mark-test-\(look).png"), draw: {
                    background.setFill()
                    NSRect(origin: .zero, size: testCell).fill()
                    let size = NSSize(width: test.size.width * zoom, height: test.size.height * zoom)
                    test.draw(in: NSRect(x: (testCell.width - size.width) / 2, y: (testCell.height - size.height) / 2, width: size.width, height: size.height))
                })
            else { return false }
        }
        // the face of the drawings' first mind (`Rendering.fixFaces`)
        Rendering.fixFaces()
        guard let icon = MindFaces.shared.face(of: Rendering.minds[0].mind).icon else { return false }
        return FaceIcon.render(
            to: folder, icon: icon,
            bars: [
                ("light", NSAppearance(named: .aqua)!, NSColor(white: 0.93, alpha: 1), .black),
                ("dark", NSAppearance(named: .darkAqua)!, NSColor(white: 0.16, alpha: 1), .white),
            ])
    }

    /// One mark, centred in `cell`, `zoom` times its size: a template image in the bar's `ink`, a
    /// coloured one as it is, then the dot, as `RecordDotView` draws it over the button.
    private static func draw(_ mark: MenuBarMark, in cell: NSRect, zoom: CGFloat, ink: NSColor) {
        let image = image(mark)
        let size = NSSize(width: image.size.width * zoom, height: image.size.height * zoom)
        let place = NSRect(x: cell.midX - size.width / 2, y: cell.midY - size.height / 2, width: size.width, height: size.height)
        tinted(image, ink: ink).draw(in: place)
        // the image's y runs down; the bitmap's runs up
        drawDot(mark.dot, at: NSPoint(x: place.minX + dotCenter.x * zoom, y: place.maxY - dotCenter.y * zoom), scale: zoom)
    }

    /// `image` as the bar draws it: a template image in the bar's `ink`, a coloured one as it is.
    static func tinted(_ image: NSImage, ink: NSColor) -> NSImage {
        guard image.isTemplate else { return image }
        return NSImage(size: image.size, flipped: false) { rect in
            image.draw(in: rect)
            ink.setFill()
            rect.fill(using: .sourceAtop)
            return true
        }
    }

    /// A PNG of `size` points, `scale` pixels to a point, drawn by `draw` in points.
    static func write(size: NSSize, scale: CGFloat = 1, to file: URL, draw: () -> Void) -> Bool {
        guard let bitmap = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: Int(size.width * scale), pixelsHigh: Int(size.height * scale), bitsPerSample: 8,
            samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)
        else { return false }
        bitmap.size = size
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
        draw()
        NSGraphicsContext.restoreGraphicsState()
        guard let png = bitmap.representation(using: .png, properties: [:]) else { return false }
        return (try? png.write(to: file)) != nil
    }

    static func glyph() -> NSBezierPath {
        let glyph = NSBezierPath()
        for path in paths {
            glyph.append(read(path))
        }
        return glyph
    }

    /// Reads a path that has only the absolute commands M, L, H, V and Z, as the logo's paths have.
    private static func read(_ data: String) -> NSBezierPath {
        let path = NSBezierPath()
        let scanner = Scanner(string: data)
        var command: Character = "M"
        var point = NSPoint.zero
        while !scanner.isAtEnd {
            if let letter = scanner.scanCharacters(from: .letters)?.last {
                command = letter
            }
            switch command {
            case "M", "L":
                guard let x = scanner.scanDouble(), let y = scanner.scanDouble() else { return path }
                point = NSPoint(x: x, y: y)
                if command == "M" {
                    path.move(to: point)
                    command = "L"
                } else {
                    path.line(to: point)
                }
            case "H":
                guard let x = scanner.scanDouble() else { return path }
                point.x = x
                path.line(to: point)
            case "V":
                guard let y = scanner.scanDouble() else { return path }
                point.y = y
                path.line(to: point)
            default:
                path.close()
                return path
            }
        }
        return path
    }
}

/// The record's dot over the mark in the menu bar (`IterateIcon.drawDot`). A view of its own on
/// the status button, so that the mark's template image stays a template.
final class RecordDotView: NSView {
    var dot: RecordDot = .none {
        didSet { if dot != oldValue { needsDisplay = true } }
    }

    override var isFlipped: Bool { true }

    /// Clicks go to the button under it.
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func draw(_ dirtyRect: NSRect) {
        IterateIcon.drawDot(dot, at: NSPoint(x: bounds.midX, y: bounds.midY))
    }

    /// Puts the view on `button`, its centre where the dot sits in the mark's image (which the
    /// button centres).
    static func attach(to button: NSStatusBarButton, imageSize: NSSize) -> RecordDotView {
        let view = RecordDotView()
        view.translatesAutoresizingMaskIntoConstraints = false
        button.addSubview(view)
        let side = IterateIcon.dotRadius * 2 + 2
        NSLayoutConstraint.activate([
            view.widthAnchor.constraint(equalToConstant: side),
            view.heightAnchor.constraint(equalToConstant: side),
            view.centerXAnchor.constraint(equalTo: button.centerXAnchor, constant: IterateIcon.dotCenter.x - imageSize.width / 2),
            view.centerYAnchor.constraint(equalTo: button.centerYAnchor, constant: IterateIcon.dotCenter.y - imageSize.height / 2),
        ])
        return view
    }
}

/// THE SIGN OF ALWAYS LISTEN on the mark (README, "Listening"): a small orange dot at the mark's
/// upper left, where the 𝑖 leaves the image empty, while the microphone is open with no key. Orange
/// is macOS's own colour of a microphone in use. The mark itself does not change; the sign is a
/// view over it, as the record's dot is.
final class ListenSignView: NSView {
    /// The sign's centre in the mark's image (y down), and its radius.
    static let center = NSPoint(x: 1.6, y: 2.2)
    static let radius: CGFloat = 1.6

    var isOn = false {
        didSet { if isOn != oldValue { isHidden = !isOn } }
    }

    override var isFlipped: Bool { true }

    /// Clicks go to the button under it.
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func draw(_ dirtyRect: NSRect) {
        let r = Self.radius
        NSColor.systemOrange.setFill()
        NSBezierPath(ovalIn: NSRect(x: bounds.midX - r, y: bounds.midY - r, width: 2 * r, height: 2 * r)).fill()
    }

    static func attach(to button: NSStatusBarButton, imageSize: NSSize) -> ListenSignView {
        let view = ListenSignView()
        view.isHidden = true
        view.translatesAutoresizingMaskIntoConstraints = false
        button.addSubview(view)
        let side = radius * 2 + 2
        NSLayoutConstraint.activate([
            view.widthAnchor.constraint(equalToConstant: side),
            view.heightAnchor.constraint(equalToConstant: side),
            view.centerXAnchor.constraint(equalTo: button.centerXAnchor, constant: center.x - imageSize.width / 2),
            view.centerYAnchor.constraint(equalTo: button.centerYAnchor, constant: center.y - imageSize.height / 2),
        ])
        return view
    }
}
