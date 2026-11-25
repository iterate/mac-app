import AppKit
import VoiceMeetCore

/// THE MIND'S FACE IN THE MENU BAR (`MenuBarIcon`): its icon in a circle 18 points across, in
/// colour, with the mark's states drawn into the same image. It is not a template image, so the
/// badges need no views over the button, as the mark's dot and Always listen's sign do.
///
/// - Tone: plain while lent, dimmed while it connects, dimmed with a slash while it is not lent.
/// - Ring: green, red or orange at the edge, with a thin gap inside it, so it reads on any face.
/// - The record: a red dot at the lower right, filled while it records, a ring while paused.
/// - Always listen: an orange dot at the upper left.
///
/// Each dot has a gap cut around it, as a badge on an app's icon has, so it reads on any face and
/// on a light or a dark bar. The slash's ink is the bar's label colour, resolved as it is drawn.
@MainActor
enum FaceIcon {
    /// The face's side in points: the bar is 24 high (22 on a Mac with no notch).
    static let side: CGFloat = 18
    private static let ringWidth: CGFloat = 1.8
    private static let ringGap: CGFloat = 0.8
    /// The dots' centres (y down) and radii, and the gap cut around each.
    static let recordCenter = NSPoint(x: 14.8, y: 14.8)
    static let recordRadius: CGFloat = 3.1
    static let listenCenter = NSPoint(x: 3.1, y: 3.1)
    static let listenRadius: CGFloat = 2.3
    private static let dotGap: CGFloat = 1
    /// The mark's own dimming.
    private static let dimmed: CGFloat = 0.4

    /// The drawings of the icon last asked for, one for each badge: a new icon drops them.
    private static var made: [String: NSImage] = [:]
    private static var madeFrom: NSImage?

    /// The face of `icon` with the badges of `face`, made once for each look.
    static func image(_ icon: NSImage, _ face: MenuBarFace) -> NSImage {
        if madeFrom !== icon {
            made = [:]
            madeFrom = icon
        }
        if let image = made[face.name] { return image }
        let image = draw(icon, face)
        made[face.name] = image
        return image
    }

    /// A new drawing, not kept: the drawings to a file make one for each appearance.
    static func draw(_ icon: NSImage, _ face: MenuBarFace) -> NSImage {
        let image = NSImage(size: NSSize(width: side, height: side), flipped: true) { rect in
            guard let context = NSGraphicsContext.current else { return false }
            context.imageInterpolation = .high
            let centre = NSPoint(x: rect.midX, y: rect.midY)

            // the face, in its circle
            context.saveGraphicsState()
            NSBezierPath(ovalIn: rect).addClip()
            icon.draw(
                in: rect, from: .zero, operation: .sourceOver, fraction: face.tone == .plain ? 1 : dimmed, respectFlipped: true, hints: nil)
            context.restoreGraphicsState()

            if face.ring != .none {
                // the face's edge cleared, the ring and the gap inside it, then the ring: no seam of
                // the face shows between them
                let band = ringWidth + ringGap
                cut(circle(centre, side / 2 - band / 2), width: band)
                let ring = circle(centre, side / 2 - ringWidth / 2)
                ring.lineWidth = ringWidth
                colour(face.ring).setStroke()
                ring.stroke()
            }

            if face.tone == .slashed {
                // from the top left to the bottom right, with a gap cut on each side of it
                let line = NSBezierPath()
                line.move(to: NSPoint(x: 2.5, y: 2.5))
                line.line(to: NSPoint(x: side - 2.5, y: side - 2.5))
                line.lineCapStyle = .round
                cut(line, width: 3.4)
                NSColor.labelColor.setStroke()
                line.lineWidth = 1.4
                line.stroke()
            }

            if face.listens {
                fill(circle(listenCenter, listenRadius + dotGap), with: nil)
                fill(circle(listenCenter, listenRadius), with: .systemOrange)
            }
            switch face.dot {
            case .none:
                break
            case .recording:
                fill(circle(recordCenter, recordRadius + dotGap), with: nil)
                fill(circle(recordCenter, recordRadius), with: IterateIcon.dotColor)
            case .paused:
                // a ring with the bar through it, as the mark's paused dot
                fill(circle(recordCenter, recordRadius + dotGap), with: nil)
                let width: CGFloat = 1.4
                let ring = circle(recordCenter, recordRadius - width / 2)
                ring.lineWidth = width
                IterateIcon.dotColor.setStroke()
                ring.stroke()
            }
            return true
        }
        image.isTemplate = false
        return image
    }

    private static func colour(_ ring: MenuBarFace.Ring) -> NSColor {
        switch ring {
        case .none: return .clear
        case .green: return .systemGreen
        case .red: return .systemRed
        case .orange: return .systemOrange
        }
    }

    private static func circle(_ centre: NSPoint, _ radius: CGFloat) -> NSBezierPath {
        NSBezierPath(ovalIn: NSRect(x: centre.x - radius, y: centre.y - radius, width: 2 * radius, height: 2 * radius))
    }

    /// Fills `path` with `colour`, or clears it when `colour` is nil.
    private static func fill(_ path: NSBezierPath, with colour: NSColor?) {
        guard let colour else {
            NSGraphicsContext.current?.compositingOperation = .clear
            path.fill()
            NSGraphicsContext.current?.compositingOperation = .sourceOver
            return
        }
        colour.setFill()
        path.fill()
    }

    /// Clears a stroke of `path`, `width` wide.
    private static func cut(_ path: NSBezierPath, width: CGFloat) {
        NSGraphicsContext.current?.compositingOperation = .clear
        path.lineWidth = width
        path.stroke()
        NSGraphicsContext.current?.compositingOperation = .sourceOver
    }

    // MARK: - The drawings to a file

    /// The face in every state, on a light and a dark menu bar (`--render-all`, `--render-icons`):
    /// `faces-light.png` and `faces-dark.png`, 8 times its size, a row for each tone and ring (plain,
    /// dimmed, slashed, red, orange, green) and a column for each dot (none, recording, paused,
    /// Always listen, recording and Always listen). And `menubar-light.png`, `menubar-dark.png`: a
    /// strip of the bar at its own size, 2 pixels to a point, with the mark, then the face plain,
    /// recording, red and slashed, and the mark of a mind with no icon.
    static func render(to folder: URL, icon: NSImage, bars: [(look: String, appearance: NSAppearance, background: NSColor, ink: NSColor)]) -> Bool {
        let zoom: CGFloat = 8
        let cell = NSSize(width: 32 * zoom, height: 24 * zoom)
        let rows: [(MenuBarFace.Tone, MenuBarFace.Ring)] = [
            (.plain, .none), (.dimmed, .none), (.slashed, .none), (.plain, .red), (.plain, .orange), (.plain, .green),
        ]
        let columns: [(RecordDot, Bool)] = [(.none, false), (.recording, false), (.paused, false), (.none, true), (.recording, true)]
        for bar in bars {
            var drawn = true
            bar.appearance.performAsCurrentDrawingAppearance {
                let sheet = NSSize(width: cell.width * CGFloat(columns.count), height: cell.height * CGFloat(rows.count))
                drawn = IterateIcon.write(size: sheet, scale: 1, to: folder.appendingPathComponent("faces-\(bar.look).png")) {
                    bar.background.setFill()
                    NSRect(origin: .zero, size: sheet).fill()
                    for (row, (tone, ring)) in rows.enumerated() {
                        for (column, (dot, listens)) in columns.enumerated() {
                            let face = MenuBarFace(tone: tone, ring: ring, dot: dot, listens: listens)
                            let size = side * zoom
                            let x = CGFloat(column) * cell.width + (cell.width - size) / 2
                            let y = sheet.height - CGFloat(row + 1) * cell.height + (cell.height - size) / 2
                            draw(icon, face).draw(in: NSRect(x: x, y: y, width: size, height: size))
                        }
                    }
                }
                guard drawn else { return }
                // the bar at its own size: each item 8 points from the next, as the system spaces them
                let strip: [NSImage] = [
                    IterateIcon.image(MenuBarMark(ink: .live, dot: .none)),
                    draw(icon, MenuBarFace(tone: .plain, ring: .none, dot: .none, listens: false)),
                    draw(icon, MenuBarFace(tone: .plain, ring: .none, dot: .recording, listens: true)),
                    draw(icon, MenuBarFace(tone: .plain, ring: .red, dot: .none, listens: false)),
                    draw(icon, MenuBarFace(tone: .dimmed, ring: .none, dot: .none, listens: false)),
                    draw(icon, MenuBarFace(tone: .slashed, ring: .none, dot: .paused, listens: false)),
                ]
                let gap: CGFloat = 8
                let size = NSSize(width: strip.reduce(gap) { $0 + $1.size.width + gap }, height: 24)
                drawn = IterateIcon.write(size: size, scale: 2, to: folder.appendingPathComponent("menubar-\(bar.look).png")) {
                    bar.background.setFill()
                    NSRect(origin: .zero, size: size).fill()
                    var x = gap
                    for image in strip {
                        let place = NSRect(x: x, y: (size.height - image.size.height) / 2, width: image.size.width, height: image.size.height)
                        IterateIcon.tinted(image, ink: bar.ink).draw(in: place)
                        x += image.size.width + gap
                    }
                }
            }
            guard drawn else { return false }
        }
        return true
    }
}
