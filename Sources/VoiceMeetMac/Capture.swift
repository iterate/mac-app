import AVFoundation
import AppKit
import ApplicationServices
import Record
import ScreenCaptureKit
import SpeechText
import SwiftUI
import VoiceMeetCore

/// What the pill at the top of the display says.
@MainActor
final class CapturePill: ObservableObject {
    @Published var text = ""
    /// The mind the capture goes into, by its address: the pill shows its face.
    @Published var mind: String?
    @Published var startedAt: Date?
    /// The part of the bytes that went up, while the capture is sent.
    @Published var progress: Double?
}

/// A CAPTURE, made by the person: ⌥⇧S, then talk, click and draw (hold ⇧ and move the mouse: no
/// button), then ⌥⇧S again.
/// The gesture is Scrawl's, by Kit Langton (github.com/kitlangton/scrawl).
///
/// A capture is a folder with `capture.json` and the files it names. `capture.json` holds the
/// OBSERVATIONS, each with its time in milliseconds from the start: the screen (a movie), the voice,
/// the window in front (the app, its title, a browser's page, its accessibility tree), each click
/// and each ink mark with the accessibility element under it, and sharp pictures of the display at
/// those moments. The ink is on the screen, so the movie and the pictures show it.
///
/// The voice is put into words while the person talks: the microphone's sound goes to the one
/// transcriber (`Transcriber`, use `capture`: OpenAI when it can be reached, else the local model,
/// with the word list of the capture's mind), and each final segment, with its times from the
/// capture's start, goes to the uploader at each pause.
///
/// The job `capture` of the capture's mind's `MindBridge` (`bridge/capture.mjs`) runs beside the
/// capture from its start: it puts each picture into the mind as soon as it exists, and the rest at
/// the end, as files under `/captures/<id>/`, and answers the text that goes to the clipboard. The
/// capture holds that bridge until it is sent, so it ends on its own mind after a switch.
@available(macOS 15.0, *)
@MainActor
final class Capture: NSObject, SCStreamDelegate, SCStreamOutput, SCRecordingOutputDelegate {
    /// The voice, while the capture runs: the microphone's sound into the recognizer, with its time
    /// from the capture's start. Used on the voice's queue alone.
    private final class Voice: @unchecked Sendable {
        let queue = DispatchQueue(label: "com.iterate.capture.voice")
        var recognizer: SpeechListening?
        /// The capture's start on the host clock, which the stream's buffers are stamped with.
        var zero = CMTime.zero
        private let audio = SpeechAudio()
        /// The format of the last buffer: the stream's buffers all have one, made once.
        private var format: (description: CMFormatDescription, format: AVAudioFormat)?

        func take(_ sampleBuffer: CMSampleBuffer) {
            guard let recognizer, let description = sampleBuffer.formatDescription else { return }
            if format.map({ !CFEqual($0.description, description) }) ?? true {
                format = (description, AVAudioFormat(cmAudioFormatDescription: description))
            }
            guard let format = format?.format else { return }
            let seconds = (sampleBuffer.presentationTimeStamp - zero).seconds
            try? sampleBuffer.withAudioBufferList { list, _ in
                guard let sound = AVAudioPCMBuffer(pcmFormat: format, bufferListNoCopy: list.unsafePointer) else { return }
                let samples = audio.samples(of: sound)
                guard !samples.isEmpty else { return }
                // a stamp that is not of the capture's clock gives no time: the samples follow on
                recognizer.push(samples, at: seconds.isFinite && seconds >= 0 && seconds < Capture.maximumSeconds + 60 ? seconds : nil)
            }
        }
    }

    static let folder = AppEnvironment.current.folder.appendingPathComponent("captures")
    /// A capture ends by itself after this long.
    nonisolated static let maximumSeconds = 600.0

    /// Where the capture is: one at a time.
    private var phase = CapturePhase.idle
    /// It records now: from its first frame to the press that ends it.
    var isRunning: Bool { phase == .running }
    /// The last capture's outcome, for the panel.
    private(set) var lastLine: String?
    /// The last capture failed: the panel draws its line in orange.
    private(set) var lastFailed = false
    var onChange: () -> Void = {}
    /// The session of the mind this Mac is lent to now (`Lend.sessionChanged`).
    var session: MindSession?
    /// The guide to a permission of macOS (the app's delegate has it).
    var allow: (Permission) -> Void = { _ in }
    /// Writes a text where the cursor is (the dictation's ⌘V).
    var paste: (String) -> Void = { _ in }
    /// The one transcriber, and the word list of a mind.
    var transcriber: Transcriber?
    var words: (String?) -> WordList = { _ in .empty }

    private let log = AppLog("capture")
    private let pill = CapturePill()
    private var id = ""
    private var folder = Capture.folder
    private var zero = Date()
    private var screen: NSScreen?
    private var stream: SCStream?
    /// The movie of the stream that runs: its end, or the fallback's, is this capture's alone.
    private var recording: ObjectIdentifier?
    private var movieFallback: Task<Void, Never>?
    private var observations: [[String: Any]] = []
    private var displayID: CGDirectDisplayID = 0
    private var pictures = 0
    private var lastPictureAt = Date.distantPast
    /// The bridge of the capture's mind, while its job runs.
    private var bridge: MindBridge?
    /// The bridge each capture holds, by its id, until its job ends: an earlier capture may still
    /// be sent while a new one runs.
    private var holding: [String: MindBridge] = [:]
    private let voice = Voice()
    /// The recognizer of this capture's voice, and how many of its segments the uploader has.
    private var recognizer: SpeechListening?
    /// The model that the transcriber's rule picked at the start: the transcript's `by`.
    private var heardBy = SpeechModel.default.id
    private var segmentsSent = 0
    private var isVoiceDone = false
    /// The session at this capture's start: its manifest, its pill and its upload go with it until
    /// it ends, whatever the Mac is lent to then.
    private var pinned: MindSession?
    /// The clipboard's change count after this capture's text went there: a later text of the same
    /// capture takes its place only while the person copied nothing else.
    private var copiedAt: Int?
    private var moveMonitor: Any?
    private var marks = 0
    /// The numbered pictures an agent looks at: one for each mark and each click, cut out of the
    /// display's picture around it.
    private var panels: [[String: Any]] = []
    private var panelsAsked = 0
    /// Every picture that is still being taken: the end waits for them.
    private var pictureTasks: [Task<Void, Never>] = []
    /// What a numbered picture shows. `box` and `click` are points of the display from its top left.
    private struct Panel {
        let n: Int
        let did: String
        let from: Int
        let t: Int
        let box: CGRect
        var click: CGPoint?
        var on: [String: Any]?
    }
    /// ⇧ is still down from ⌥⇧S at the start: ink waits until ⇧ was let go once.
    private var isInkArmed = false
    private var trees = 0
    private var windowKey = ""
    private var overlay: NSPanel?
    private var pillPanel: NSPanel?
    private var ink: InkView?
    private var timer: Timer?
    private var clickMonitor: Any?
    private var flagsMonitor: Any?
    /// A launch of an app whose windows are never shown: the movie's filter leaves it out too.
    private var launches: NSObjectProtocol?
    private var finished: CheckedContinuation<Void, Never>?
    /// A read of the window in front is under way on the Accessibility queue: the next waits.
    private var isReadingWindow = false
    /// A dictation kept on became this capture (README, "Dictation becomes a capture"): fn ends
    /// it, and its text is written where the cursor is.
    private var byDictation = false
    /// The words the dictation heard before this capture, once they came: its first segment.
    private var before: String?
    private var pasted = false

    /// The next press of fn ends this capture: a dictation became it.
    var takesFn: Bool { byDictation && (phase == .starting || phase == .running) }

    /// Whether a dictation kept on can become a capture now.
    var canStartFromDictation: Bool { phase == .idle && Permission.screenRecording.isGranted }

    /// ⇧ in a dictation kept on: a capture starts at once.
    func startFromDictation() {
        guard canStartFromDictation else { return }
        byDictation = true
        before = nil
        pasted = false
        Task { @MainActor in await start() }
    }

    /// The dictation's words before this capture. False when no capture that a dictation became
    /// starts or runs: the dictation writes them itself.
    func saidBefore(_ text: String) -> Bool {
        guard takesFn || (byDictation && phase == .ending) else { return false }
        before = text
        if phase == .running || phase == .ending { sendBefore() }
        return true
    }

    /// The words before, as the capture's first segment: at its start, with no time of their own.
    private func sendBefore() {
        guard let before, !before.isEmpty else { return }
        upload(["segment": ["t": 0, "to": 0, "text": before, "words": [] as [Any], "before": true] as [String: Any]])
    }

    /// fn, in a capture that a dictation became: end and send.
    func endFromFn() {
        guard byDictation, phase == .running else { return }
        Task { @MainActor in await end(send: true) }
    }

    /// For `ui.state` on the control socket.
    func controlState() -> [String: Any] {
        [
            "running": isRunning, "phase": "\(phase)", "pillVisible": pillPanel?.isVisible ?? false, "pill": pill.text, "lastLine": lastLine ?? NSNull(),
            // the pill is in no picture and no movie of the screen
            "pillShared": pillPanel.map { $0.sharingType != .none } ?? false,
        ]
    }

    /// ⌥⇧S: start, or end and send.
    func toggle() {
        switch phase.toggle {
        case .start:
            byDictation = false
            Task { @MainActor in await start() }
        case .end: Task { @MainActor in await end(send: true) }
        case .nothing: log.info("capture: \(phase), the key waits")
        }
    }

    // MARK: - Start

    private func start() async {
        guard phase == .idle else { return }
        guard Permission.screenRecording.isGranted else { return allow(.screenRecording) }
        // from here a press does nothing until the capture runs, or did not start
        phase = .starting
        defer {
            if phase == .starting {
                phase = .idle
                byDictation = false
            }
        }
        let status = AVCaptureDevice.authorizationStatus(for: .audio)
        var microphone = CapturePhase.microphone(hasOwnHome: AppEnvironment.current.hasOwnHome, isAuthorized: status == .authorized, isUndetermined: status == .notDetermined)
        if microphone == .ask { microphone = await AVCaptureDevice.requestAccess(for: .audio) ? .on : .off }
        let hears = microphone == .on
        // the display under the pointer
        let pointer = NSEvent.mouseLocation
        guard let screen = NSScreen.screens.first(where: { $0.frame.contains(pointer) }) ?? NSScreen.main,
            let displayID = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID
        else { return }
        let stamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: "-", with: "").replacingOccurrences(of: ":", with: "")
        id = "\(stamp)-\(String(format: "%04x", UInt16.random(in: 0...UInt16.max)))"
        pinned = session
        folder = Self.folder.appendingPathComponent(id)
        // A capture stays on this Mac for an agent here to read, for 7 days.
        for old in (try? FileManager.default.contentsOfDirectory(at: Self.folder, includingPropertiesForKeys: [.contentModificationDateKey])) ?? [] {
            if let changed = try? old.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate, changed < Date().addingTimeInterval(-7 * 86_400) {
                try? FileManager.default.removeItem(at: old)
            }
        }
        // the ink's window first: the movie shows it, and of this app's windows it alone
        showOverlay(on: screen)
        do {
            try FileManager.default.createDirectory(at: folder.appendingPathComponent("pictures"), withIntermediateDirectories: true)
            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
            guard let display = content.displays.first(where: { $0.displayID == displayID }) else {
                hideOverlay()
                return fail("That display is not connected.")
            }
            let filter = Screen.filter(of: display, in: content, onlyOwn: ownWindows)
            let configuration = SCStreamConfiguration()
            // a small movie: the pictures are the sharp part
            let scale = min(CGFloat(filter.pointPixelScale), 1600 / filter.contentRect.width)
            configuration.width = Int(filter.contentRect.width * scale)
            configuration.height = Int(filter.contentRect.height * scale)
            configuration.minimumFrameInterval = CMTime(value: 1, timescale: 10)
            configuration.showsCursor = true
            configuration.captureMicrophone = hears
            let stream = SCStream(filter: filter, configuration: configuration, delegate: self)
            let recording = SCRecordingOutputConfiguration()
            recording.outputURL = folder.appendingPathComponent("screen.mp4")
            recording.outputFileType = .mp4
            recording.videoCodecType = .hevc
            let output = SCRecordingOutput(configuration: recording, delegate: self)
            try stream.addRecordingOutput(output)
            if configuration.captureMicrophone { try stream.addStreamOutput(self, type: .microphone, sampleHandlerQueue: voice.queue) }
            try await stream.startCapture()
            self.stream = stream
            self.recording = ObjectIdentifier(output)
        } catch {
            hideOverlay()
            return fail("The recording did not start: \(AppLog.describe(error))")
        }
        self.screen = screen
        self.displayID = displayID
        zero = Date()
        startVoice(isOn: hears)
        observations = []
        pictures = 0
        lastPictureAt = .distantPast
        startUploader()
        marks = 0
        panels = []
        panelsAsked = 0
        pictureTasks = []
        trees = 0
        windowKey = ""
        isReadingWindow = false
        phase = .running
        isInkArmed = false
        say(byDictation ? "⇧ and move draws · fn sends" : "⇧ and move draws · ⌥⇧S sends", startedAt: zero)
        if byDictation { sendBefore() }
        observeWindow()
        picture("start", after: 0.3)
        clickMonitor = NSEvent.addGlobalMonitorForEvents(matching: .leftMouseDown) { [weak self] _ in
            MainActor.assumeIsolated { self?.clicked() }
        }
        // Ink needs no button: while ⇧ alone is down, the pointer's way is a stroke.
        moveMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.mouseMoved, .leftMouseDragged]) { [weak self] event in
            let flags = event.modifierFlags.intersection([.shift, .option, .command, .control])
            MainActor.assumeIsolated { self?.moved(isInk: flags == .shift, isShiftUp: !flags.contains(.shift)) }
        }
        // a stroke ends when ⇧ is let go (macOS tells a global monitor so with Accessibility; the
        // tick looks once a second too)
        flagsMonitor = NSEvent.addGlobalMonitorForEvents(matching: .flagsChanged) { [weak self] event in
            let isShiftUp = !event.modifierFlags.contains(.shift)
            MainActor.assumeIsolated { if isShiftUp { self?.shiftUp() } }
        }
        launches = NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didLaunchApplicationNotification, object: nil, queue: .main) { [weak self] note in
            let bundle = (note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication)?.bundleIdentifier
            MainActor.assumeIsolated { if ExcludeList().excludes(bundle) { self?.refilter() } }
        }
        timer?.invalidate()
        let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in MainActor.assumeIsolated { self?.tick() } }
        timer.tolerance = 0.2
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
        log.info("capture \(id) starts on \"\(screen.localizedName)\", \(configuration(of: screen)), voice \(hears ? "on" : AppEnvironment.current.hasOwnHome ? "off: a home of its own" : "off: no Microphone permission")")
        onChange()
    }

    /// This app's windows that the movie and the pictures show: the ink's alone.
    private var ownWindows: Set<CGWindowID> {
        Set([overlay].compactMap { $0.map { CGWindowID($0.windowNumber) } })
    }

    /// An app whose windows are never shown was opened: the movie leaves it out from now.
    private func refilter() {
        guard isRunning, let stream else { return }
        let displayID = displayID, own = ownWindows
        Task { @MainActor in
            guard let content = try? await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true),
                let display = content.displays.first(where: { $0.displayID == displayID })
            else { return }
            try? await stream.updateContentFilter(Screen.filter(of: display, in: content, onlyOwn: own))
        }
    }

    private func configuration(of screen: NSScreen) -> String {
        "\(Int(screen.frame.width)) × \(Int(screen.frame.height)) points at \(screen.backingScaleFactor)x"
    }

    // MARK: - While it runs

    /// Milliseconds since the start.
    private var now: Int { max(0, Int(Date().timeIntervalSince(zero) * 1000)) }

    private func observe(_ kind: String, at t: Int? = nil, _ fields: [String: Any?]) {
        var observation: [String: Any] = ["t": t ?? now, "kind": kind]
        for (key, value) in fields { if let value { observation[key] = value } }
        observations.append(observation)
    }

    /// Once a second: ⇧ let go with no event seen, the window in front, the longest capture's end.
    private func tick() {
        guard isRunning else { return }
        if !NSEvent.modifierFlags.contains(.shift) { shiftUp() }
        observeWindow()
        if Date().timeIntervalSince(zero) > Self.maximumSeconds { toggle() }
    }

    /// ⇧ is up: a stroke ends, and the next ⇧ draws.
    private func shiftUp() {
        guard isRunning else { return }
        isInkArmed = true
        endStroke()
    }

    /// A new observation when the app in front, its window's title or its page changes. The app
    /// is asked on the Accessibility queue, one read at a time; a read that ends after its
    /// capture changes nothing.
    private func observeWindow() {
        guard isRunning, !isReadingWindow, let app = Accessibility.App.front, app.pid != ProcessInfo.processInfo.processIdentifier else { return }
        isReadingWindow = true
        let capture = id, trusted = AXIsProcessTrusted(), seen = windowKey, treesSoFar = trees, folder = folder, t = now
        Task { @MainActor in
            let read = try? await Accessibility.read { () -> (key: String, title: String?, url: String?, tree: String?) in
                let (title, url) = trusted ? Accessibility.window(of: app) : (nil, nil)
                let key = [app.bundle, title, url].map { $0 ?? "" }.joined(separator: "\n")
                guard key != seen else { return (key, title, url, nil) }
                // the window as text, for the first few windows: a tree is large
                guard trusted, treesSoFar < 6, let window = try? Accessibility.tree(of: app, maxDepth: 12, maxNodes: 1_500),
                    let data = try? JSONSerialization.data(withJSONObject: window, options: [.sortedKeys])
                else { return (key, title, url, nil) }
                let tree = "accessibility/\(treesSoFar).json"
                try? FileManager.default.createDirectory(at: folder.appendingPathComponent("accessibility"), withIntermediateDirectories: true)
                return (key, title, url, (try? data.write(to: folder.appendingPathComponent(tree))) == nil ? nil : tree)
            }
            guard capture == id else { return }
            isReadingWindow = false
            guard isRunning, let read, read.key != windowKey else { return }
            windowKey = read.key
            if read.tree != nil { trees += 1 }
            observe("window", at: t, ["application": app.name, "bundleIdentifier": app.bundle, "title": read.title, "url": read.url, "accessibilityTree": read.tree])
            if now > 1_000 { picture("window", after: 0.5) }
        }
    }

    /// The pointer moved. With ⇧ down it draws; a stroke ends when ⇧ is let go.
    private func moved(isInk: Bool, isShiftUp: Bool) {
        guard isRunning else { return }
        if isShiftUp { isInkArmed = true }
        let point = NSEvent.mouseLocation
        guard isInk, isInkArmed, let screen, screen.frame.contains(point) else { return endStroke() }
        ink?.add(x: point.x - screen.frame.minX, y: screen.frame.maxY - point.y, t: now)
    }

    /// A mark from a script on this Mac: the same stroke as one by hand.
    func mark(_ points: [[Double]]) {
        guard isRunning else { return }
        endStroke()
        for point in points where point.count == 2 { ink?.add(x: point[0], y: point[1], t: now) }
        endStroke()
    }

    private func endStroke() {
        if let stroke = ink?.end() { inked(stroke) }
    }

    /// A sharp picture of the display, now or a moment later, straight to the uploader. At most
    /// 12 for a capture: a mark always gets one, a click or a window only among the first 8 and
    /// not within a second of another.
    private func picture(_ reason: String, after seconds: Double = 0, isMark: Bool = false, shows: ((Int) -> Panel)? = nil) {
        guard pictures < (isMark || reason == "end" ? 12 : 8), isMark || Date().timeIntervalSince(lastPictureAt) > 1 else { return }
        pictures += 1
        lastPictureAt = Date()
        let file = "pictures/\(String(format: "%02d", pictures)).jpg"
        let capture = id
        var panel: Panel?
        if let shows {
            panelsAsked += 1
            panel = shows(panelsAsked)
        }
        pictureTasks.append(
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                await self.takePicture(file, reason, of: capture, panel: panel)
            })
    }

    /// The picture is taken by ScreenCaptureKit, and made a JPEG and written off the main actor.
    private func takePicture(_ file: String, _ reason: String, of capture: String, panel: Panel? = nil) async {
        let t = now
        guard phase == .running || phase == .ending, capture == id,
            let image = try? await Screen.image(of: displayID, maxWidth: 2_000, onlyOwn: ownWindows)
        else { return }
        let url = folder.appendingPathComponent(file)
        let written = await Task.detached(priority: .userInitiated) { () -> (width: Int, height: Int)? in
            guard let picture = Snapshot.jpeg(of: CIImage(cgImage: image), maxWidth: 2_000), (try? picture.data.write(to: url)) != nil else { return nil }
            return (picture.width, picture.height)
        }.value
        guard capture == id, let written else { return }
        observe("picture", at: t, ["file": file, "reason": reason, "pixelWidth": written.width, "pixelHeight": written.height])
        upload(["put": file])
        if let panel, let screen { await cut(panel, from: image, picture: file, display: screen.frame.size) }
    }

    /// One numbered picture: the part of the display around a mark or a click, with its number in
    /// the corner. The box is twice the mark's size and at least 640 × 400 points, so that what is
    /// near the mark can be read. Drawn and written off the main actor.
    private func cut(_ panel: Panel, from image: CGImage, picture: String, display: CGSize) async {
        let capture = id
        let file = "\(panel.n).jpg"
        let url = folder.appendingPathComponent(file)
        let (n, box, click) = (panel.n, panel.box, panel.click)
        let isWritten = await Task.detached(priority: .userInitiated) { Self.drawCut(n, box: box, click: click, from: image, display: display, to: url) }.value
        guard isWritten, capture == id else { return }
        var entry: [String: Any] = ["n": panel.n, "did": panel.did, "from": panel.from, "t": panel.t, "file": file, "picture": picture]
        // What was under it, when the app in front names it in a few words (a terminal answers its whole text).
        if let on = panel.on, let words = (on["title"] ?? on["description"]) as? String, !words.isEmpty, words.count <= 60 {
            entry["on"] = "“\(words)”"
        }
        panels.append(entry)
        upload(["put": file])
    }

    private nonisolated static func drawCut(_ n: Int, box: CGRect, click: CGPoint?, from image: CGImage, display: CGSize, to url: URL) -> Bool {
        let scale = CGFloat(image.width) / display.width
        let size = CGSize(width: min(display.width, max(640, box.width * 2)), height: min(display.height, max(400, box.height * 2)))
        let origin = CGPoint(
            x: max(0, min(display.width - size.width, box.midX - size.width / 2)),
            y: max(0, min(display.height - size.height, box.midY - size.height / 2)))
        // a CGImage counts from its top left, as the box does
        guard let part = image.cropping(to: CGRect(x: origin.x * scale, y: origin.y * scale, width: size.width * scale, height: size.height * scale).integral),
            let context = CGContext(
                data: nil, width: part.width, height: part.height, bitsPerComponent: 8, bytesPerRow: 0,
                space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)
        else { return false }
        let height = CGFloat(part.height)
        context.draw(part, in: CGRect(x: 0, y: 0, width: part.width, height: part.height))
        if let click {
            // a click leaves no ink: a ring says where it was
            context.setStrokeColor(CGColor(red: 1, green: 0.1, blue: 0.1, alpha: 1))
            context.setLineWidth(5)
            context.strokeEllipse(in: CGRect(x: (click.x - origin.x) * scale - 16, y: height - (click.y - origin.y) * scale - 16, width: 32, height: 32))
        }
        let badge = CGRect(x: 0, y: height - 56, width: 64, height: 56)
        context.setFillColor(CGColor(gray: 0, alpha: 1))
        context.fill(badge)
        let font = CTFontCreateUIFontForLanguage(.emphasizedSystem, 40, nil)
        let number = CTLineCreateWithAttributedString(
            NSAttributedString(string: String(n), attributes: [.font: font as Any, .foregroundColor: CGColor(gray: 1, alpha: 1)]))
        let bounds = CTLineGetBoundsWithOptions(number, .useGlyphPathBounds)
        context.textPosition = CGPoint(x: badge.midX - bounds.midX, y: badge.midY - bounds.midY)
        CTLineDraw(number, context)
        guard let numbered = context.makeImage(), let jpeg = Snapshot.jpeg(of: CIImage(cgImage: numbered), maxWidth: 2_000) else { return false }
        return (try? jpeg.data.write(to: url)) != nil
    }

    /// All the numbered pictures on one: an agent reads it first. Two in a row, each 780 pixels
    /// wide. Drawn and written off the main actor.
    private func writeSheet() async {
        let files = panels.sorted { ($0["n"] as? Int ?? 0) < ($1["n"] as? Int ?? 0) }.compactMap { $0["file"] as? String }.map(folder.appendingPathComponent)
        let sheet = folder.appendingPathComponent("sheet.jpg")
        let isWritten = await Task.detached(priority: .userInitiated) { Self.drawSheet(of: files, to: sheet) }.value
        if isWritten { upload(["put": "sheet.jpg"]) }
    }

    private nonisolated static func drawSheet(of files: [URL], to url: URL) -> Bool {
        let cells = files.compactMap { file -> CGImage? in
            guard let source = CGImageSourceCreateWithURL(file as CFURL, nil) else { return nil }
            return CGImageSourceCreateImageAtIndex(source, 0, nil)
        }
        guard cells.count > 1 else { return false }
        let cellWidth: CGFloat = 780, gap: CGFloat = 6
        let heights = cells.map { CGFloat($0.height) * cellWidth / CGFloat($0.width) }
        let rows = stride(from: 0, to: cells.count, by: 2).map { heights[$0..<min($0 + 2, cells.count)].max() ?? 0 }
        let size = CGSize(width: cellWidth * 2 + gap * 3, height: rows.reduce(gap) { $0 + $1 + gap })
        guard
            let context = CGContext(
                data: nil, width: Int(size.width), height: Int(size.height), bitsPerComponent: 8, bytesPerRow: 0,
                space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)
        else { return false }
        context.setFillColor(CGColor(gray: 0.13, alpha: 1))
        context.fill(CGRect(origin: .zero, size: size))
        context.interpolationQuality = .high
        var top = gap
        for (index, cell) in cells.enumerated() {
            let column = CGFloat(index % 2)
            context.draw(cell, in: CGRect(x: gap + column * (cellWidth + gap), y: size.height - top - heights[index], width: cellWidth, height: heights[index]))
            if index % 2 == 1 { top += rows[index / 2] + gap }
        }
        guard let sheet = context.makeImage(), let jpeg = Snapshot.jpeg(of: CIImage(cgImage: sheet), maxWidth: 2_000) else { return false }
        return (try? jpeg.data.write(to: url)) != nil
    }

    /// A click in another app (a global monitor sees no click in this app's own windows).
    private func clicked() {
        guard isRunning, let screen, screen.frame.contains(NSEvent.mouseLocation) else { return }
        let point = NSEvent.mouseLocation
        let place = CGPoint(x: point.x - screen.frame.minX, y: screen.frame.maxY - point.y)
        let t = now
        // the end waits for this: the click's element, then its picture
        pictureTasks.append(
            Task { @MainActor in
                let on = await self.element(at: point)
                self.observe("click", at: t, ["x": Int(place.x), "y": Int(place.y), "on": on])
                self.picture("click", after: 0.4) { Panel(n: $0, did: "clicked", from: t, t: t, box: CGRect(origin: place, size: .zero), click: place, on: on) }
            })
    }

    private func inked(_ stroke: InkView.Stroke) {
        guard let screen, let first = stroke.points.first, let last = stroke.points.last else { return }
        marks += 1
        let mark = marks
        let xs = stroke.points.map(\.x), ys = stroke.points.map(\.y)
        // the middle of the mark, as a point of the whole desktop with its origin at the bottom left
        let middle = CGPoint(x: screen.frame.minX + (xs.min()! + xs.max()!) / 2, y: screen.frame.maxY - (ys.min()! + ys.max()!) / 2)
        let box = CGRect(x: xs.min()!, y: ys.min()!, width: xs.max()! - xs.min()!, height: ys.max()! - ys.min()!)
        let points = stroke.points.map { [Int($0.x), Int($0.y), $0.t] }
        // the end waits for this: the mark's element, then its picture
        pictureTasks.append(
            Task { @MainActor in
                let on = await self.element(at: middle)
                self.observe("ink", at: first.t, ["to": last.t, "mark": mark, "points": points, "on": on])
                self.picture("mark \(mark)", after: 0.15, isMark: true) { Panel(n: $0, did: "drew", from: first.t, t: last.t, box: box, on: nil) }
            })
    }

    /// The accessibility element of the app in front at a point of the desktop: its role, title
    /// and value. Asked on the Accessibility queue; nil for an app whose windows are never read.
    private func element(at point: CGPoint) async -> [String: Any]? {
        guard AXIsProcessTrusted(), let app = Accessibility.App.front, let primary = NSScreen.screens.first else { return nil }
        // Accessibility counts from the top left of the first display
        let place = CGPoint(x: point.x, y: primary.frame.maxY - point.y)
        return try? await Accessibility.read { Accessibility.Handed(value: Accessibility.element(of: app, at: place)) }.value
    }

    // MARK: - End

    private func end(send: Bool) async {
        guard phase == .running else { return }
        // from here a press does nothing until the last line went to the job
        phase = .ending
        defer { phase = .idle }
        let voiceEnds = endVoice(send: send)
        endStroke()
        // every mark and click has its picture before the ink goes (a click's own picture is
        // asked after its element: the list grows while it is waited for)
        while !pictureTasks.isEmpty {
            let tasks = pictureTasks
            pictureTasks = []
            for task in tasks { await task.value }
        }
        let durationMs = now
        if send {
            // The last picture, with the ink still on the screen. It is the one numbered picture
            // of a capture with no mark and no click: the whole display.
            pictures += 1
            let whole = panels.isEmpty ? screen.map { Panel(n: 1, did: "the screen at the end", from: 0, t: durationMs, box: CGRect(origin: .zero, size: $0.frame.size)) } : nil
            await takePicture("pictures/\(String(format: "%02d", pictures)).jpg", "end", of: id, panel: whole)
            await writeSheet()
            // The text is on the clipboard now: nothing below is waited for.
            if (try? writeManifest(durationMs: durationMs)) != nil { upload(["copy": true]) }
        }
        timer?.invalidate()
        timer = nil
        for monitor in [clickMonitor, moveMonitor, flagsMonitor] { if let monitor { NSEvent.removeMonitor(monitor) } }
        clickMonitor = nil
        moveMonitor = nil
        flagsMonitor = nil
        if let launches { NSWorkspace.shared.notificationCenter.removeObserver(launches) }
        launches = nil
        hideOverlay()
        onChange()
        if let stream {
            // the movie is whole once its recording output says so; a stream that fails says it
            // too, and after 5 s the end goes on without it. Each is this stream's alone.
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                finished = continuation
                let recording = recording
                movieFallback = Task { @MainActor in
                    try? await stream.stopCapture()
                    guard (try? await Task.sleep(nanoseconds: 5_000_000_000)) != nil else { return }
                    if let recording { self.movieIsWhole(recording) }
                }
            }
        }
        stream = nil
        recording = nil
        guard send else {
            upload(["discard": true])
            bridge = nil
            try? FileManager.default.removeItem(at: folder)
            log.info("capture \(id): discarded by the person")
            return say("Discarded", for: 2)
        }
        say(copiedAt == nil ? "Sending…" : "Copied: paste it to an agent", progress: 0)
        guard await writeBundle(durationMs: durationMs) else {
            // the files stay on this Mac, and the job ends
            upload(["discard": true])
            bridge = nil
            return fail("The capture was not written. It is in \(folder.path)", keep: true)
        }
        guard bridge != nil else {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(folder.path, forType: .string)
            return fail("No mind is set up. The capture is in \(folder.path)", keep: true)
        }
        // the last words before the end: `heard` goes before `finish`
        await voiceEnds?.value
        upload(["finish": true])
    }

    /// The movie's own end, or its stream's failure, or the fallback: of the recording `of` alone.
    private func movieIsWhole(_ of: ObjectIdentifier) {
        guard of == recording else { return }
        movieFallback?.cancel()
        movieFallback = nil
        finished?.resume()
        finished = nil
    }

    nonisolated func recordingOutputDidFinishRecording(_ recordingOutput: SCRecordingOutput) {
        let output = ObjectIdentifier(recordingOutput)
        Task { @MainActor in self.movieIsWhole(output) }
    }

    nonisolated func recordingOutput(_ recordingOutput: SCRecordingOutput, didFailWithError error: Error) {
        let words = AppLog.describe(error)
        let output = ObjectIdentifier(recordingOutput)
        Task { @MainActor in
            guard output == self.recording else { return }
            self.log.error("capture \(self.id): the recording failed: \(words)")
            self.movieIsWhole(output)
        }
    }

    /// The stream ended by itself (the display went away, macOS stopped it): the capture ends with what it has.
    nonisolated func stream(_ stream: SCStream, didStopWithError error: Error) {
        let words = AppLog.describe(error)
        let ended = ObjectIdentifier(stream)
        Task { @MainActor in
            guard let current = self.stream, ObjectIdentifier(current) == ended else { return }
            self.log.error("capture \(self.id): the stream stopped: \(words)")
            if self.isRunning { await self.end(send: true) }
        }
    }

    /// Cuts the voice out of the movie, and writes `capture.json` again with both. A part that
    /// fails (a movie that does not read, a voice that is not cut) is left out and logged: the
    /// pictures and the movie stay, and the rest goes. False when `capture.json` itself was not
    /// written.
    private func writeBundle(durationMs: Int) async -> Bool {
        let movie = AVURLAsset(url: folder.appendingPathComponent("screen.mp4"))
        var movieMs: Int?
        do {
            movieMs = Int(try await movie.load(.duration).seconds * 1000)
        } catch {
            log.error("capture \(id): screen.mp4 does not read: \(AppLog.describe(error))")
        }
        if let movieMs {
            observe("screen", at: 0, ["to": movieMs, "file": "screen.mp4"])
            let voice = folder.appendingPathComponent("voice.m4a")
            do {
                if !(try await movie.loadTracks(withMediaType: .audio)).isEmpty, let export = AVAssetExportSession(asset: movie, presetName: AVAssetExportPresetAppleM4A) {
                    try await export.export(to: voice, as: .m4a)
                    observe("voice", at: 0, ["to": movieMs, "file": "voice.m4a"])
                }
            } catch {
                try? FileManager.default.removeItem(at: voice)
                log.error("capture \(id): voice.m4a was not cut out of the movie: \(AppLog.describe(error))")
            }
        }
        do {
            try writeManifest(durationMs: movieMs ?? durationMs)
        } catch {
            log.error("capture \(id): capture.json was not written: \(AppLog.describe(error))")
            return false
        }
        log.info("capture \(id): \((movieMs ?? durationMs) / 1000) s, \(observations.count) observations, \(pictures) pictures, \(marks) marks")
        return true
    }

    /// `capture.json`: every observation with its time, and the numbered pictures. Written twice:
    /// at the end for the text, and again when the movie is whole.
    private func writeManifest(durationMs: Int) throws {
        let frame = screen?.frame ?? .zero
        let displayName: String = screen?.localizedName ?? ""
        let displayScale: CGFloat = screen?.backingScaleFactor ?? 1
        let iso = ISO8601DateFormatter()
        let manifest: [String: Any] = [
            "schema": 1,
            "capture": id,
            "startedAt": iso.string(from: zero),
            "endedAt": iso.string(from: zero.addingTimeInterval(Double(durationMs) / 1000)),
            "durationMs": durationMs,
            // the voice is heard on this Mac while the person talks
            "microphone": Permission.microphone.isGranted,
            "panels": panels.sorted { ($0["n"] as? Int ?? 0) < ($1["n"] as? Int ?? 0) },
            "by": [
                "adapter": ["name": "mac-app", "version": Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? ""],
                "device": pinned?.name ?? Host.current().localizedName ?? "",
                "method": "person",
            ],
            // points of the desktop; an ink point and a click count from this display's top left
            "display": [
                "name": displayName, "scale": displayScale,
                "frame": ["x": Int(frame.minX), "y": Int(frame.minY), "w": Int(frame.width), "h": Int(frame.height)],
            ],
            "observations": observations.sorted { ($0["t"] as? Int ?? 0) < ($1["t"] as? Int ?? 0) },
        ]
        try JSONSerialization.data(withJSONObject: manifest, options: [.prettyPrinted, .sortedKeys]).write(to: folder.appendingPathComponent("capture.json"))
    }

    /// The job starts with the capture: on its mind's connection it gets the upload links while the
    /// person talks.
    private func startUploader() {
        copiedAt = nil
        guard let pinned else { return bridge = nil }
        let bridge = MindBridge.of(pinned)
        let capture = id
        holding[capture] = bridge
        self.bridge = bridge
        bridge.on("capture") { [weak self, weak bridge] line in
            guard let self, let bridge else { return }
            self.uploaderSaid(line, from: bridge)
        }
        bridge.hold("capture \(capture)")
        upload(["folder": folder.path, "heardBy": heardBy])
    }

    /// One step of this capture's job.
    private func upload(_ fields: [String: Any]) {
        var line = fields
        line["capture"] = id
        bridge?.send("capture", line)
    }

    /// A capture's job ended, or its process did: its bridge is let go.
    private func letGo(_ capture: String) {
        holding.removeValue(forKey: capture)?.release("capture \(capture)")
    }

    /// The listening of the capture's voice, from its start: the transcriber's, with the word list
    /// of the capture's mind. Each final segment goes to the uploader at once.
    private func startVoice(isOn: Bool) {
        segmentsSent = 0
        isVoiceDone = false
        recognizer = nil
        let host = CMClockGetTime(CMClockGetHostTimeClock())
        guard isOn, let transcriber else { return voice.queue.async { [voice] in voice.recognizer = nil } }
        let capture = id
        let (recognizer, model) = transcriber.listening(.capture, words: words(pinned?.mind)) { [weak self] event in
            DispatchQueue.main.async { MainActor.assumeIsolated { if self?.id == capture { self?.heard(event) } } }
        }
        heardBy = model.id
        self.recognizer = recognizer
        recognizer.start()
        voice.queue.async { [voice] in
            voice.zero = host
            voice.recognizer = recognizer
        }
        log.info("capture \(id): the voice is heard by \(model.id) (\(transcriber.current.route.why.words))")
    }

    private func heard(_ event: SpeechRecognizer.Event) {
        switch event {
        case .segment(let segment):
            guard !isVoiceDone else { return }
            upload(["segment": segment.transcriptEntry])
            segmentsSent += 1
        case .partial(let said):
            // what was just heard, while the capture runs: the sign that the microphone hears the person
            if isRunning, !said.text.isEmpty { say("…" + said.text.suffix(44), startedAt: zero) }
        case .note(let note):
            log.info("capture \(id): voice: \(note)")
        case .failed(let reason):
            log.error("capture \(id): voice: \(reason)")
        case .loading, .ready:
            break
        }
    }

    /// The most seconds the end waits for the last words: a model that still comes over the network.
    static let voiceWait = 120.0

    /// The voice ends with the capture. Sent: the answer is the task of its last segments and then
    /// `heard` (with no voice, `heard` alone), each with this capture's id; the end awaits it
    /// before `finish`, so the bridge has every word before the movie. Discarded: nil.
    private func endVoice(send: Bool) -> Task<Void, Never>? {
        voice.queue.async { [voice] in voice.recognizer = nil }
        let recognizer = self.recognizer
        self.recognizer = nil
        guard send else {
            recognizer?.cancel()
            return nil
        }
        let capture = id
        return Task { @MainActor in
            if let recognizer {
                let segments = await recognizer.finish(within: Self.voiceWait)
                if segments == nil { self.log.error("capture \(capture): the last words did not come within \(Int(Self.voiceWait)) s") }
                // the end holds the capture until this ends: the id is still this one's
                guard self.id == capture else { return }
                self.isVoiceDone = true
                for segment in (segments ?? []).dropFirst(self.segmentsSent) { self.upload(["segment": segment.transcriptEntry]) }
            }
            guard self.id == capture else { return }
            // a dictation's last words before the capture: at most 5 s more
            for _ in 0..<100 where self.byDictation && self.before == nil {
                try? await Task.sleep(nanoseconds: 50_000_000)
            }
            guard self.id == capture else { return }
            self.upload(["heard": true])
        }
    }

    /// The microphone's sound, on the voice's queue: to the recognizer.
    nonisolated func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        if type == .microphone { voice.take(sampleBuffer) }
    }

    /// `copy` is the text for the clipboard: with the mind's paths, or this Mac's with `failed`.
    private func uploaderSaid(_ line: [String: Any], from bridge: MindBridge) {
        if line["exited"] != nil {
            // every capture on that process ends; the one that runs now says so
            for (capture, held) in holding where held === bridge { letGo(capture) }
            guard self.bridge === bridge else { return }
            self.bridge = nil
            return fail("Not sent: the uploader ended. The capture is in \(folder.path)", keep: true)
        }
        guard let capture = line["capture"] as? String else { return }
        if line["done"] != nil || line["failed"] != nil || line["discarded"] != nil { letGo(capture) }
        // a line of an earlier capture changes nothing here
        guard capture == id, self.bridge === bridge else { return }
        let mind = pinned?.mind ?? "the mind"
        if let progress = line["progress"] as? Double, pill.progress != nil { pill.progress = progress }
        if let text = line["copy"] as? String, copiedAt == nil || copiedAt == NSPasteboard.general.changeCount {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
            copiedAt = NSPasteboard.general.changeCount
            if line["failed"] == nil {
                log.info("capture \(id): \(text.count) characters copied")
                say("Copied: paste it to an agent", progress: pill.progress)
                // a capture that a dictation became: its text where the cursor is, once
                if byDictation, !pasted {
                    pasted = true
                    paste(text)
                }
            }
        }
        if let reason = line["failed"] as? String {
            self.bridge = nil
            fail("Not sent to \(mind): \(reason.prefix(200)). The capture is in \(folder.path)", keep: true)
        } else if line["done"] != nil {
            self.bridge = nil
            log.info("capture \(id): sent to \(mind) as /captures/\(id)/")
            // The folder stays: an agent on this Mac reads the pictures from it.
            lastLine = "Sent to \(mind) at \(Lend.clock(Date())), and copied"
            lastFailed = false
            say("Copied: paste it to an agent", for: 3)
            onChange()
        }
    }

    private func fail(_ reason: String, keep: Bool = false) {
        log.error("capture \(id): \(reason)")
        if !keep { try? FileManager.default.removeItem(at: folder) }
        lastLine = reason
        lastFailed = true
        say(reason, for: 8)
        onChange()
    }

    // MARK: - The overlay and the pill

    private func panel(_ frame: NSRect, level: Int) -> NSPanel {
        let panel = NSPanel(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.level = NSWindow.Level(rawValue: level)
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        return panel
    }

    /// A clear window over the whole display, for the ink. Every click goes through it.
    private func showOverlay(on screen: NSScreen) {
        let overlay = panel(screen.frame, level: NSWindow.Level.statusBar.rawValue)
        overlay.ignoresMouseEvents = true
        let ink = InkView(frame: NSRect(origin: .zero, size: screen.frame.size))
        overlay.contentView = ink
        OffScreen.orderFront(overlay) { overlay.orderFrontRegardless() }
        self.overlay = overlay
        self.ink = ink
    }

    private func hideOverlay() {
        overlay?.orderOut(nil)
        overlay = nil
        ink = nil
    }

    /// The pill at the top of the display: what the capture does now. With `seconds`, it goes away after them.
    private func say(_ text: String, startedAt: Date? = nil, progress: Double? = nil, for seconds: Double? = nil) {
        pill.text = text
        pill.mind = pinned?.mind
        pill.startedAt = startedAt
        pill.progress = progress
        let screen = self.screen ?? NSScreen.main
        let width = CapturePillView.width(of: pill)
        let frame = NSRect(
            x: (screen?.frame.midX ?? 400) - width / 2, y: (screen?.visibleFrame.maxY ?? 800) - 48, width: width, height: CapturePillView.height)
        let panel = pillPanel ?? self.panel(frame, level: NSWindow.Level.statusBar.rawValue + 1)
        if pillPanel == nil {
            // in no picture and no movie of the screen: the ink is, the pill is not
            panel.sharingType = .none
            panel.contentView = NSHostingView(
                rootView: CapturePillView(
                    pill: pill,
                    send: { [weak self] in self?.toggle() },
                    discard: { [weak self] in Task { @MainActor in await self?.end(send: false) } }))
            pillPanel = panel
        }
        panel.setFrame(frame, display: true)
        OffScreen.orderFront(panel) { panel.orderFrontRegardless() }
        guard let seconds else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds) { [weak self] in
            // a newer line stays
            if self?.pill.text == text { self?.pillPanel?.orderOut(nil) }
        }
    }
}

struct CapturePillView: View {
    @ObservedObject var pill: CapturePill
    let send: () -> Void
    let discard: () -> Void
    /// A drawing's clock: the time since the start at that moment, with no timer.
    var now: Date?

    static let height: CGFloat = 36

    /// Room for the dot, the clock and the two buttons while it records, the face, the bar, the words.
    static func width(of pill: CapturePill) -> CGFloat {
        let controls: CGFloat = pill.startedAt == nil ? 60 : 250
        let face: CGFloat = pill.mind == nil ? 0 : 26
        let bar: CGFloat = pill.progress == nil ? 0 : 110
        return min(controls + face + bar + CGFloat(pill.text.count * 8), 760)
    }

    var body: some View {
        HStack(spacing: 10) {
            if let mind = pill.mind { MindAvatar(mind: mind, size: 22) }
            if let startedAt = pill.startedAt {
                Circle().fill(Theme.live).frame(width: 9, height: 9)
                Group {
                    if let now {
                        let seconds = max(0, Int(now.timeIntervalSince(startedAt)))
                        Text(String(format: "%d:%02d", seconds / 60, seconds % 60))
                    } else {
                        Text(startedAt, style: .timer)
                    }
                }
                .font(.system(size: 13, weight: .semibold))
                .monospacedDigit()
            }
            Text(pill.text).lineLimit(1).truncationMode(.middle)
            if let progress = pill.progress {
                ProgressView(value: min(max(progress, 0), 1)).progressViewStyle(.linear).controlSize(.small).tint(Theme.t2).frame(width: 90)
            }
            if pill.startedAt != nil {
                Spacer(minLength: 0)
                Button("Discard", action: discard).buttonStyle(FillButtonStyle()).accessibilityIdentifier("capture.discard")
                Button("Send", action: send).buttonStyle(FillButtonStyle(prominent: true)).accessibilityIdentifier("capture.send")
            }
        }
        .font(.system(size: 13))
        .foregroundStyle(Theme.t1)
        .padding(.leading, pill.mind == nil ? 14 : 7)
        .padding(.trailing, pill.startedAt == nil ? 14 : 5)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.surface, in: Capsule())
        .overlay(Capsule().strokeBorder(Theme.edge, lineWidth: 1))
    }
}

/// The ink: red strokes along the pointer's way. A stroke goes away 4 seconds after its end.
private final class InkView: NSView {
    /// Points of the display from its top left, each with its time in milliseconds.
    struct Stroke {
        var points: [(x: CGFloat, y: CGFloat, t: Int)]
        var isEnded = false
    }

    private var strokes: [Stroke] = []

    func add(x: CGFloat, y: CGFloat, t: Int) {
        if strokes.last?.isEnded ?? true { strokes.append(Stroke(points: [])) }
        strokes[strokes.count - 1].points.append((x, y, t))
        needsDisplay = true
    }

    /// Ends the stroke that runs, and answers it. A few points are no mark (⇧ for a capital letter): nil.
    func end() -> Stroke? {
        guard let stroke = strokes.last, !stroke.isEnded else { return nil }
        guard stroke.points.count >= 5 else {
            strokes.removeLast()
            needsDisplay = true
            return nil
        }
        strokes[strokes.count - 1].isEnded = true
        let endedAt = stroke.points.last?.t ?? 0
        DispatchQueue.main.asyncAfter(deadline: .now() + 4) { [weak self] in
            self?.strokes.removeAll { $0.isEnded && ($0.points.last?.t ?? 0) <= endedAt }
            self?.needsDisplay = true
        }
        return stroke
    }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.systemRed.setStroke()
        for stroke in strokes {
            let path = NSBezierPath()
            path.lineWidth = 4
            path.lineCapStyle = .round
            path.lineJoinStyle = .round
            for (index, point) in stroke.points.enumerated() {
                let place = NSPoint(x: point.x, y: bounds.height - point.y)
                if index == 0 { path.move(to: place) } else { path.line(to: place) }
            }
            path.stroke()
        }
    }
}

extension CapturePillView {
    /// The pill while a capture records, 15 s after its start, with the last words heard, light and
    /// dark: `capture-pill-<tone>.png` in `folder` (`--render-capture <folder>`).
    @MainActor
    static func render(to folder: URL) -> Bool {
        _ = NSApplication.shared
        Rendering.fixFaces()
        let pill = CapturePill()
        pill.text = "…and this is slow"
        pill.mind = Rendering.minds[0].mind
        pill.startedAt = Rendering.now.addingTimeInterval(-15)
        var drawn = true
        for (dark, tone) in [(false, "light"), (true, "dark")] {
            // around it, the see-through panel's margin
            let view = CapturePillView(pill: pill, send: {}, discard: {}, now: Rendering.now)
                .frame(width: width(of: pill), height: height)
                .padding(12)
            drawn = Rendering.png(of: view, dark: dark, to: folder.appendingPathComponent("capture-pill-\(tone).png")) && drawn
        }
        return drawn
    }
}
