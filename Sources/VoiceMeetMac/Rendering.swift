import AppKit
import SwiftUI
import VoiceMeetCore

/// THE DRAWINGS TO A FILE (the `--render-*` flags): views as PNG files, for a look with no click
/// and for the snapshot check (`harness/snapshots.mjs`).
///
/// A drawing is the same on every Mac: it reads no config.json, no stored choice and no network.
/// Its minds, their faces, the things of the Mac and the clock are fixed here, its home is a new
/// empty folder (`AppEnvironment`), and every file has 2 pixels to a point, whatever the screen.
@MainActor
enum Rendering {
    /// 24 Nov 2026, 14:02:11 UTC: the drawings' now.
    static let now = Date(timeIntervalSince1970: 1_795_528_931)

    /// The system's settings that change a drawing, held fixed in this process alone (the
    /// arguments' domain is never written to disk): scroll bars that show while scrolling, the blue
    /// accent, and English as in the United States. Before the first view.
    static func fixSystemSettings() {
        UserDefaults.standard.setVolatileDomain(
            ["AppleShowScrollBars": "WhenScrolling", "AppleAccentColor": 4, "AppleLanguages": ["en-US"], "AppleLocale": "en_US"],
            forName: UserDefaults.argumentDomain)
    }

    /// The minds of the drawings: the first is the active one, with an icon; the others show their letter.
    static let minds: [LendView.Mind] = [
        .init(mind: "iterate.example.com", name: "jane.mac"),
        .init(mind: "garden.example.org", name: "jane.mac"),
        .init(mind: "example.com", name: "jane.mac"),
    ]

    /// Where the drawn app came from.
    static let source = UpdateSource.of(spec: "@iterate-com/mac-app", copy: nil, version: "0.1.0").line(home: "/Users/jane")

    /// The things of a Mac with one display and one camera, each with the choice `sharing` gives
    /// it (Off when it gives none), stored in the drawing's own home.
    static func things(_ sharing: [String: Sharing] = [:]) -> [Shareable] {
        let things: [Shareable] = [
            Shareable(id: "screen.1", power: .screen, title: "Built-in Retina Display", does: "see the display \"Built-in Retina Display\"", symbol: "display"),
            Shareable(id: "camera.fixture", power: .camera, title: "FaceTime HD Camera", does: "see the camera \"FaceTime HD Camera\"", symbol: "video"),
            .microphone, .speaker, .banners, .accessibility, .commands, .pages,
        ]
        for thing in things { thing.sharing = sharing[thing.id] ?? .off }
        return things
    }

    /// The panel's state in one of `Panel.renderPhases`: the choices, the permissions, the notes,
    /// the last result, and what watches, records and runs.
    @MainActor
    struct Sample {
        var things: [Shareable]
        var missing: Set<Permission> = []
        var approvals: [String: Date] = [:]
        var uses: [String: Int] = [:]
        var lastResult: PanelState.LastResult?
        let phase: String

        init(phase: String) {
            self.phase = phase
            switch phase {
            case "busy":
                things = Rendering.things([
                    "screen.1": .shared, "camera.fixture": .ask, "microphone": .shared, "accessibility": .shared, "speaker": .shared,
                    "banners": .shared, "commands": .ask,
                ])
                approvals = ["camera.fixture": Rendering.now.addingTimeInterval(30 * 60)]
                uses = ["accessibility": 12]
                lastResult = .init(what: "Last capture", line: "0:15, in the mind and on the clipboard", failed: false)
            case "blocked":
                things = Rendering.things([
                    "screen.1": .shared, "accessibility": .shared, "speaker": .shared, "banners": .shared, "commands": .ask,
                ])
                missing = [.screenRecording, .accessibility]
                lastResult = .init(what: "Last dictation", line: "on the clipboard, press ⌘V. Accessibility is not allowed.", failed: true)
            default:
                things = Rendering.things([
                    "screen.1": .ask, "accessibility": .shared, "speaker": .shared, "banners": .shared, "commands": .ask,
                ])
                uses = ["accessibility": 3]
                lastResult = .init(what: "Last input", line: "sent to Iterate at 14:01", failed: false)
            }
        }

        /// What watches, records and runs, on the drawing's model.
        func fix(_ model: AppModel) {
            switch phase {
            case "busy":
                model.live.fixForDrawing([
                    DeviceLive.Watcher(id: "w1", who: "Misha", tracks: ["screen-0", "mic-0"], since: Rendering.now.addingTimeInterval(175))
                ])
                model.deviceEvents.fixForDrawing(sharesInput: true, keepsInput: true)
                model.record.fixForDrawing(on: [.screens, .cameras, .mics, .speakers], line: "Recording 4 tracks · 2 slots waiting", isRecording: true)
            case "blocked":
                model.deviceEvents.fixForDrawing(sharesInput: true, keepsInput: false)
                model.record.fixForDrawing(on: [.screens], line: "Off", isRecording: false)
            default:
                break
            }
        }
    }

    /// The drawings' picture of the display, 60 × 38 pixels: a menu bar and two windows.
    static let displayPicture: CGImage = {
        let width = 60, height = 38
        let context = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        // as the mocks draw it: a grey desktop, its menu bar, a light window and a darker one
        context.setFillColor(CGColor(gray: 0.27, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.setFillColor(CGColor(gray: 0.5, alpha: 1))
        context.fill(CGRect(x: 0, y: height - 6, width: width, height: 6))
        context.setFillColor(CGColor(gray: 0.62, alpha: 1))
        context.fill(CGRect(x: 6, y: 10, width: 26, height: 18))
        context.setFillColor(CGColor(gray: 0.48, alpha: 1))
        context.fill(CGRect(x: 38, y: 8, width: 18, height: 16))
        return context.makeImage()!
    }()

    /// The minds' faces: the first one's name and a drawn icon, the second one's name alone. No network.
    static func fixFaces() {
        MindFaces.shared.fix([
            MindFaces.Face(address: minds[0].mind, name: "Iterate", icon: icon()),
            MindFaces.Face(address: minds[1].mind, name: "The Garden", icon: nil),
            MindFaces.Face(address: minds[2].mind, name: nil, icon: nil),
        ])
    }

    /// A drawn icon: rings on a teal ground.
    private static func icon() -> NSImage {
        NSImage(size: NSSize(width: 128, height: 128), flipped: false) { rect in
            NSColor(calibratedRed: 0.05, green: 0.45, blue: 0.5, alpha: 1).setFill()
            rect.fill()
            NSColor.white.setStroke()
            for inset in [24.0, 44.0] {
                let ring = NSBezierPath(ovalIn: rect.insetBy(dx: inset, dy: inset))
                ring.lineWidth = 10
                ring.stroke()
            }
            return true
        }
    }

    /// A view as a PNG file, at 2 pixels to a point, in the light or the dark appearance.
    /// `window` makes the window it is laid out in, a borderless one when it is nil.
    static func png<Content: View>(
        of content: Content, dark: Bool, to file: URL,
        window makeWindow: ((NSRect) -> NSWindow)? = nil
    ) -> Bool {
        _ = NSApplication.shared
        let appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        let view = NSHostingView(rootView: content)
        view.appearance = appearance
        let frame = NSRect(origin: .zero, size: view.fittingSize)
        let window = makeWindow?(frame) ?? NSWindow(contentRect: frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.appearance = appearance
        window.contentView = view
        view.layoutSubtreeIfNeeded()
        // A text view learns its height after the first layout: size the window again to it.
        for _ in 0..<3 {
            RunLoop.main.run(until: Date().addingTimeInterval(0.05))
            window.setContentSize(view.fittingSize)
            view.layoutSubtreeIfNeeded()
        }
        let size = view.bounds.size
        // in sRGB, the space of the design's colours: a token's value is the file's value
        guard size.width > 0, size.height > 0,
            let picture = NSBitmapImageRep(
                bitmapDataPlanes: nil, pixelsWide: Int(size.width * 2), pixelsHigh: Int(size.height * 2), bitsPerSample: 8,
                samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .calibratedRGB, bytesPerRow: 0, bitsPerPixel: 0)?
                .retagging(with: .sRGB)
        else { return false }
        picture.size = size
        view.cacheDisplay(in: view.bounds, to: picture)
        try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        return picture.representation(using: .png, properties: [:]).map { (try? $0.write(to: file)) != nil } ?? false
    }

    /// Every view, light and dark, into `folder` (`--render-all <folder>`): the panel in each phase
    /// of the lend, the mind switcher, the activity, the forms, the input bar, the dictation pill,
    /// the banners, the menu-bar marks, the Settings window's pages, the Ask question and the Activity window.
    static func renderAll(to folder: URL) -> Bool {
        var drawn = true
        for phase in Panel.renderPhases {
            for (dark, tone) in [(false, "light"), (true, "dark")] {
                drawn = Panel.render(to: folder.appendingPathComponent("panel-\(phase)-\(tone).png"), phase: phase, dark: dark) && drawn
            }
        }
        drawn = MindSwitcher.render(to: folder) && drawn
        drawn = ActivityLog.render(to: folder) && drawn
        drawn = MindInput.render(to: folder) && drawn
        drawn = Dictation.render(to: folder) && drawn
        drawn = IterateIcon.render(to: folder) && drawn
        drawn = SettingsView.render(to: folder) && drawn
        drawn = ApprovalWindow.render(to: folder) && drawn
        drawn = ActivityWindowView.render(to: folder) && drawn
        for (dark, tone) in [(false, "light"), (true, "dark")] {
            let add = AddMindForm(profiles: ["example.com", "example.org"], name: "jane.mac", add: { _, _ in }, cancel: {})
            drawn = FormWindow.render(add, to: folder.appendingPathComponent("add-mind-\(tone).png"), dark: dark) && drawn
            let remove = RemoveMindForm(mind: "example.com", isActive: true, remove: {}, cancel: {})
            drawn = FormWindow.render(remove, to: folder.appendingPathComponent("remove-mind-\(tone).png"), dark: dark) && drawn
            for kind in ["ring", "request", "short", "three", "notice"] {
                drawn = BannerWindow.render(kind, to: folder.appendingPathComponent("banner-\(kind)-\(tone).png"), dark: dark) && drawn
            }
        }
        return drawn
    }
}
