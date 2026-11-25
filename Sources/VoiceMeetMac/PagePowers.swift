import AppKit
import CoreImage
import VoiceMeetCore

// THIS MAC'S PAGES, served through the lend: `http(request)` in bridge/mac-endpoint.ts serves the
// files of `pages/` and asks the app for the data on this socket (README, "This Mac's pages").
//
// - `pages.state`: the data of `/state.json`, a use of Pages.
// - `pages.live.start {display?, maxWidth?}`: a live view of a display (`/live.mjpeg`): a use of
//   Pages and of that display, one question for the whole view when either is on Ask. At most
//   `PageStreams.most` at once; each ends after `PageStreams.seconds`.
// - `pages.live.frame {stream}`: the view's next JPEG, at most `PageStreams.perSecond` a second,
//   made off the main thread. A view whose display or Pages is now Off, whose round ended (another
//   mind, a refused key) or whose time is over ends here, with the reason.
// - `pages.live.stop {stream, why?}`: the reader went away. Always allowed.

/// The live views that run. Each one is an act in Activity from its start to its end.
@MainActor
final class PageStreams {
    /// At most this many views at once.
    static let most = 2
    /// A view ends after this long.
    static let seconds: TimeInterval = 600
    /// At most this many frames a second.
    static let perSecond = 4.0
    /// The widest frame, in pixels.
    static let maxWidth = 1280
    /// A view whose bridge asks no frame for this long is over (its process ended).
    static let idle: TimeInterval = 15

    struct Stream {
        let id: String
        let display: Shareable
        let act: String
        let round: ApprovalGrants.Round
        let started: Date
        let maxWidth: Int
        var lastFrame: Date?
        var frames = 0
        var busy = false
    }

    fileprivate(set) var streams: [String: Stream] = [:]
    fileprivate var watchdog: Task<Void, Never>?
}

/// Where the frames come from: the display (ScreenCaptureKit, password managers left out by
/// `Screen.filter`), or in a test copy `ITERATE_MAC_FRAME_FIXTURE`: an image file, or `synthetic`,
/// with a bar that moves at each frame. A fixture needs no Screen Recording.
enum PageFrames {
    static let fixture: String? = {
        let value = ProcessInfo.processInfo.environment["ITERATE_MAC_FRAME_FIXTURE"] ?? ""
        return value.isEmpty ? nil : value
    }()

    private static let fixtureImage: CIImage? = {
        guard let fixture else { return nil }
        if fixture != "synthetic", let image = CIImage(contentsOf: URL(fileURLWithPath: fixture)) { return image }
        // a display of 2560 × 1600 pixels: a gradient as a picture
        let gradient = CIFilter(name: "CILinearGradient", parameters: [
            "inputPoint0": CIVector(x: 0, y: 0), "inputPoint1": CIVector(x: 2560, y: 1600),
            "inputColor0": CIColor(red: 0.15, green: 0.35, blue: 0.75), "inputColor1": CIColor(red: 0.95, green: 0.6, blue: 0.3),
        ])?.outputImage
        return gradient?.cropped(to: CGRect(x: 0, y: 0, width: 2560, height: 1600))
    }()

    /// One frame as JPEG bytes, made on a task of its own, never on the main thread.
    static func frame(of display: CGDirectDisplayID, maxWidth: Int, number: Int) async throws -> (data: Data, width: Int, height: Int) {
        try await Task.detached(priority: .userInitiated) {
            let picture: CIImage
            if let base = fixtureImage {
                let width = base.extent.width
                let bar = CIImage(color: CIColor(red: 1, green: 1, blue: 1))
                    .cropped(to: CGRect(x: CGFloat(number * 97).truncatingRemainder(dividingBy: width), y: 0, width: width / 20, height: base.extent.height))
                picture = bar.composited(over: base).cropped(to: base.extent)
            } else {
                picture = CIImage(cgImage: try await Screen.image(of: display, maxWidth: maxWidth))
            }
            guard let jpeg = Snapshot.jpeg(of: picture, maxWidth: maxWidth) else {
                throw EndpointRefusal("The app could not make a picture of the display.")
            }
            return jpeg
        }.value
    }
}

extension AppModel {
    /// Pages and its approvals, by the same gate as every use (`use`).
    func pages(_ method: String, _ parameters: [String: Any]) async throws -> [String: Any] {
        switch method {
        case "pages.state":
            try await use(.pages, what: "This Mac's page: its name, its lend, its record and its newest acts.")
            return pageState()
        case "pages.live.start":
            return try await startPageStream(parameters)
        case "pages.live.frame":
            return try await pageFrame(parameters["stream"] as? String ?? "")
        case "pages.live.stop":
            if let id = parameters["stream"] as? String { endPageStream(id, why: parameters["why"] as? String) }
            return ["streams": pageStreams.streams.count]
        default:
            throw EndpointRefusal("No method \"\(method)\".")
        }
    }

    /// What `/state.json` answers: what the app already knows, and nothing it must ask for.
    func pageState() -> [String: Any] {
        let record = recordState()
        let iso = ISO8601DateFormatter()
        return [
            "mac": session?.name ?? Host.current().localizedName ?? "this Mac",
            "computer": Host.current().localizedName ?? "",
            "mind": session?.mind ?? NSNull(),
            "lend": lendState(),
            "record": [
                "recording": record["recording"] ?? false, "paused": record["paused"] ?? false,
                "line": record["line"] ?? "", "tracks": record["tracks"] ?? [],
            ],
            "acts": acts.rows.prefix(8).map { row -> [String: Any] in
                var line: [String: Any] = [
                    "act": row.act, "thing": row.thing, "title": ActivityLine.title(of: row),
                    "startedAt": iso.string(from: row.startedAt), "running": row.isRunning, "inMind": row.isInMind,
                ]
                if let detail = row.detail { line["detail"] = detail }
                if let took = ActivityLine.took(row) { line["took"] = took }
                if let failure = row.failure { line["failure"] = failure }
                return line
            },
            "live": ["watchers": live.watchers.map(\.who), "pageViews": pageStreams.streams.count],
            "displays": Screen.displays.enumerated().map { index, display -> [String: Any] in
                let thing = Shareable.display(display)
                return ["display": index, "name": display.name, "sharing": thing.sharing.rawValue]
            },
            "at": iso.string(from: Date()),
        ]
    }

    private func startPageStream(_ parameters: [String: Any]) async throws -> [String: Any] {
        guard pageStreams.streams.count < PageStreams.most else {
            throw EndpointRefusal("At most \(PageStreams.most) live views of this Mac run at once: close one first.")
        }
        let display = try Screen.resolve(parameters["display"] as? Int ?? 0)
        let permitted = PageFrames.fixture != nil ? true : nil
        let round = approval.round
        let what = "A live view of the display \"\(display.title)\" in this Mac's page, at most \(Int(PageStreams.perSecond)) pictures a second, until the page closes or \(Int(PageStreams.seconds / 60)) minutes pass."
        try await use(.pages, what: what)
        try await use(display, what: what, permitted: permitted)
        try stillAllowed(.pages, in: round)
        // the question took time: another view may have started meanwhile
        guard pageStreams.streams.count < PageStreams.most else {
            throw EndpointRefusal("At most \(PageStreams.most) live views of this Mac run at once: close one first.")
        }
        let id = UUID().uuidString.lowercased()
        let act = acts.began(display, doing: "Showing the display “\(display.title)” live in a page", did: "Showed the display “\(display.title)” live in a page")
        let maxWidth = min(max(parameters["maxWidth"] as? Int ?? PageStreams.maxWidth, 64), PageStreams.maxWidth)
        pageStreams.streams[id] = PageStreams.Stream(id: id, display: display, act: act, round: round, started: Date(), maxWidth: maxWidth)
        watchPageStreams()
        return [
            "stream": id, "display": display.title, "perSecond": PageStreams.perSecond,
            "maxWidth": maxWidth, "seconds": PageStreams.seconds,
        ]
    }

    /// Why a view may no longer go on, or nil.
    private func pageStreamEnd(_ stream: PageStreams.Stream) -> String? {
        if Date().timeIntervalSince(stream.started) >= PageStreams.seconds { return "it ran for \(Int(PageStreams.seconds / 60)) minutes" }
        guard approval.holds(stream.round), isAuthorized else { return "the Mac is no longer lent to this mind, or the mind refused its key" }
        let permitted = PageFrames.fixture != nil ? true : stream.display.isPermitted
        for (thing, isPermitted) in [(Shareable.pages, true), (stream.display, permitted)] {
            switch UseGate.decide(sharing: thing.sharing.rawValue, permitted: isPermitted, approved: true) {
            case .off: return "the owner turned \(thing.title) off"
            case .notPermitted: return "macOS took back \(thing.power.permission?.title ?? "a permission")"
            case .ask, .go: break
            }
        }
        return nil
    }

    private func pageFrame(_ id: String) async throws -> [String: Any] {
        guard var stream = pageStreams.streams[id] else { throw EndpointRefusal("No live view \(id): it ended.") }
        if let why = pageStreamEnd(stream) {
            endPageStream(id, why: why)
            throw EndpointRefusal("The live view ended: \(why).")
        }
        guard !stream.busy else { throw EndpointRefusal("One frame at a time: the last one is still being made.") }
        // the pace: at most `perSecond` frames, however fast they are asked for
        if let last = stream.lastFrame {
            let wait = 1 / PageStreams.perSecond - Date().timeIntervalSince(last)
            if wait > 0 {
                pageStreams.streams[id]?.busy = true
                try? await Task.sleep(nanoseconds: UInt64(wait * 1_000_000_000))
                pageStreams.streams[id]?.busy = false
            }
        }
        stream.lastFrame = Date()
        stream.frames += 1
        pageStreams.streams[id]?.lastFrame = stream.lastFrame
        pageStreams.streams[id]?.frames = stream.frames
        pageStreams.streams[id]?.busy = true
        defer { pageStreams.streams[id]?.busy = false }
        let frame = try await PageFrames.frame(of: Screen.id(of: stream.display), maxWidth: stream.maxWidth, number: stream.frames)
        return [
            "jpegBase64": frame.data.base64EncodedString(), "pixelWidth": frame.width, "pixelHeight": frame.height,
            "frame": stream.frames,
        ]
    }

    func endPageStream(_ id: String, why: String?) {
        guard let stream = pageStreams.streams.removeValue(forKey: id) else { return }
        let seconds = Int(Date().timeIntervalSince(stream.started).rounded())
        AppLog("pages").info("live view \(id.prefix(8)) ended after \(seconds) s and \(stream.frames) frames: \(why ?? "the reader went away")")
        let failure = why.flatMap { $0 == "the reader went away" ? nil : Self.oneLine($0, limit: 90) }
        acts.ended(stream.act, failure: failure)
        if pageStreams.streams.isEmpty {
            pageStreams.watchdog?.cancel()
            pageStreams.watchdog = nil
        }
    }

    func endPageStreams(why: String) {
        for id in Array(pageStreams.streams.keys) { endPageStream(id, why: why) }
    }

    /// Every second while a view runs: a view whose reader is gone (no frame asked for `idle`
    /// seconds), whose time is over or whose choice is now Off ends, with no frame asked.
    private func watchPageStreams() {
        guard pageStreams.watchdog == nil else { return }
        pageStreams.watchdog = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                guard let self else { return }
                for stream in Array(self.pageStreams.streams.values) where !stream.busy {
                    let quiet = Date().timeIntervalSince(stream.lastFrame ?? stream.started)
                    if let why = self.pageStreamEnd(stream) ?? (quiet > PageStreams.idle ? "no frame was asked for \(Int(PageStreams.idle)) s" : nil) {
                        self.endPageStream(stream.id, why: why)
                    }
                }
            }
        }
    }
}
