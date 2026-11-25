import AppKit
import CoreMedia
import Foundation

/// What a recorder may record. Each one is a switch of its own.
public enum RecordSource: String, CaseIterable, Sendable {
    case screens, cameras, mics, speakers
    /// The final segments of the transcription stream (`Recorder.transcribed`): no capture.
    case transcript
    /// A source that needs no permission: a moving picture `test-1` and a beep each second `test-2`.
    case synthetic

    /// The beginning of the ids of its tracks.
    var prefix: String {
        switch self {
        case .screens: return "screen-"
        case .cameras: return "camera-"
        case .mics: return "mic-"
        case .speakers: return "speaker-"
        case .transcript: return "transcript"
        case .synthetic: return "test-"
        }
    }

    /// The source of a track id: `screen-1` is `screens`.
    public static func of(track: String) -> RecordSource? { allCases.first { track.hasPrefix($0.prefix) } }
}

public struct RecordOptions: Sendable {
    /// The spool of one mind: a file's path here is its path in the mind's files.
    public var spool: URL
    /// The device's name in the mind: `/devices/<device>`.
    public var device: String
    public var fps = 10
    public var quality = 0.45
    public var keyframeSeconds = 10.0
    public var pictureWidth = 640
    public var cameraHeight = 720
    public var cameraFps = 15
    public var maxWidth: Int?
    public var exclude = ExcludeList()
    /// The app's microphone stream: `mic-0` reads it, and no microphone opens for the record. Nil:
    /// each microphone opens on its own (`DeviceCapture`).
    public var microphone: MicrophoneFeed?

    public init(spool: URL, device: String) {
        self.spool = spool
        self.device = device
    }
}

/// Records the sources that are switched on into the spool: one file per track per 30-second slot,
/// a picture per video file, and for each slot ONE file `slots/<t>.json`, the payload of the event
/// `record/slot-stored`, once every track of the slot has closed. The uploader
/// (the job `record` of `bridge/mind.mjs`) takes it from there.
///
/// Who owns what: `lock` guards `sources`, `tracks` and `paused`. `slots` (a queue) owns the open
/// slots and the slots' files. A track writes its media file and its picture first, on its own
/// queue (another track's start does not wait for them), and only while it is open in that slot;
/// then, on `slots`, the slot's `.open` file (its entries so far, so that a crash keeps what was
/// written), and at the seal its rename to `.json`. A slot that is sealed takes nothing more, not
/// a late track's file either, also after a restart (`sealed`).
public final class Recorder: @unchecked Sendable {
    public let options: RecordOptions
    let clock = HostClock.shared
    private let lock = NSLock()
    private var sources: [RecordSource: Source] = [:]
    private var tracks: [Track] = []
    private var paused = false
    /// What the record wants and what live wants (`watch`): the sources run for both.
    private var recorded: Set<RecordSource> = []
    private var watched: Set<RecordSource> = []
    /// Who gets each frame and sound buffer: the record's own tracks first, then live.
    private lazy var sinks: [CaptureSink] = [RecordSink(recorder: self)]
    private let control = DispatchQueue(label: "record.control")
    private let slots = DispatchQueue(label: "record.slots")
    private var entries: [Int64: [String: [String: Any]]] = [:]
    private var open: [Int64: Set<String>] = [:]
    private var sealed: Int64 = -1
    private let tickQueue = DispatchQueue(label: "record.tick")
    private var timer: DispatchSourceTimer?
    private var observers: [(NotificationCenter, NSObjectProtocol)] = []
    private var activity: NSObjectProtocol?

    /// A slot was sealed: its event file is final (`slots/<t>.json`). Called on the recorder's own
    /// queue; set it before `start`. The app tells the bridge's record job, which wakes for it.
    public var onSeal: (@Sendable (Int64) -> Void)?

    public init(options: RecordOptions) {
        self.options = options
    }

    var isPaused: Bool { lock.withLock { paused } }
    /// A track writes files only while the record wants its source; one made for live alone is
    /// not added, so it gets no frame and writes nothing.
    func add(_ track: Track) {
        lock.withLock { if recorded.contains(where: { track.id.hasPrefix($0.prefix) }) { tracks.append(track) } }
    }
    func track(_ id: String) -> Track? { lock.withLock { tracks.first { $0.id == id } } }

    /// The ids of the tracks that record now.
    public var trackIDs: [String] { lock.withLock { tracks.map(\.id) } }

    public func start() {
        // Slot ends are timed work: App Nap would delay the timer of a process in the background.
        activity = ProcessInfo.processInfo.beginActivity(options: .userInitiatedAllowingIdleSystemSleep, reason: "recording")
        slots.sync { recover() }
        for (center, name, reason) in [
            (NotificationCenter.default, Notification.Name.NSSystemClockDidChange, "clock set"),
            // Host time stood still while the Mac slept.
            (NSWorkspace.shared.notificationCenter, NSWorkspace.didWakeNotification, "wake"),
        ] {
            observers.append((center, center.addObserver(forName: name, object: nil, queue: nil) { [weak self] _ in self?.clockChanged(reason) }))
        }
        // Once a second, with leeway, so that the system can join it with other wakeups: a slot's end
        // is written with its own time whatever the tick's delay (a video track begins the next
        // slot at the boundary, an audio track closes its file 2 s after it). A resume does not wait
        // for the tick.
        let timer = DispatchSource.makeTimerSource(queue: tickQueue)
        timer.schedule(deadline: .now() + 1, repeating: 1, leeway: .milliseconds(250))
        var ticks = 0
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            for track in self.lock.withLock({ self.tracks }) { track.tick() }
            ticks += 1
            self.sealStale()
            // A clock set that came with no notification, or a slow drift of the host clock.
            if ticks % 10 == 0, abs(self.clock.drift()) > 250 { self.clockChanged("drift") }
        }
        timer.resume()
        self.timer = timer
        log("record: device \(options.device), spool \(options.spool.path), slots sealed up to \(sealed)")
    }

    /// The sources the record wants: each records into the spool. A source that live alone wants
    /// runs, and writes nothing.
    public func set(_ wanted: Set<RecordSource>) { control.async { self.apply(record: wanted, live: nil) } }

    /// The sources live wants (`Sources/Live`): they run while somebody watches. A screen then
    /// captures `CaptureRate.live` frames a second; the record keeps its own `fps` of them by time.
    public func watch(_ wanted: Set<RecordSource>) { control.async { self.apply(record: nil, live: wanted) } }

    /// Another receiver of every frame and sound buffer (live). It gets them on the capture's queue.
    public func add(sink: CaptureSink) { lock.withLock { sinks.append(sink) } }
    public func remove(sink: CaptureSink) { lock.withLock { sinks.removeAll { $0 === sink } } }

    /// On `control`: starts and stops the sources by `CapturePlan`. A source that stops takes its
    /// tracks with it: each writes what it has, and its slot is sealed when its other tracks close.
    private func apply(record: Set<RecordSource>?, live: Set<RecordSource>?) {
        let (running, recordBefore, liveBefore) = lock.withLock { (Set(sources.keys), recorded, watched) }
        let plan = CapturePlan.changes(running: running, record: (recordBefore, record ?? recordBefore), live: (liveBefore, live ?? liveBefore))
        lock.withLock { (recorded, watched) = (record ?? recordBefore, live ?? liveBefore) }
        for change in plan {
            switch change {
            case .stop(let kind), .restart(let kind):
                guard let source = lock.withLock({ sources.removeValue(forKey: kind) }) else { continue }
                source.stop()
                endTracks(kind)
                log("record: \(kind.rawValue) off")
                if case .restart = change { start(kind) }
            case .start(let kind):
                start(kind)
            case .stopRecording(let kind):
                endTracks(kind)
                log("record: \(kind.rawValue) off (live goes on)")
            case .rate(let kind):
                lock.withLock { sources[kind] }?.rate(captureFps(kind))
            }
        }
    }

    private func start(_ kind: RecordSource) {
        let source: Source
        switch kind {
        case .screens: source = Screens(recorder: self)
        case .cameras: source = DeviceCapture(recorder: self, media: .video)
        case .mics: source = options.microphone.map { FeedMic(recorder: self, feed: $0) } ?? DeviceCapture(recorder: self, media: .audio)
        case .speakers: source = Speakers(recorder: self)
        case .transcript: source = TranscriptSource(recorder: self)
        case .synthetic: source = Synthetic(recorder: self)
        }
        lock.withLock { sources[kind] = source }
        source.start()
        let (records, watches) = lock.withLock { (recorded.contains(kind), watched.contains(kind)) }
        let fast = watches && (kind == .screens || kind == .synthetic)
        log("record: \(kind.rawValue) on\(records ? "" : " for live alone")\(fast ? ", watched at \(captureFps(kind)) fps" : "")")
    }

    /// The tracks of a source stop: each writes what it has.
    private func endTracks(_ kind: RecordSource) {
        let stopping = lock.withLock { () -> [Track] in
            defer { tracks.removeAll { $0.id.hasPrefix(kind.prefix) } }
            return tracks.filter { $0.id.hasPrefix(kind.prefix) }
        }
        for track in stopping { track.stop() }
    }

    /// The frames a second a screen or the synthetic picture captures now.
    func captureFps(_ kind: RecordSource) -> Int {
        CaptureRate.capture(record: options.fps, watched: lock.withLock { watched.contains(kind) })
    }

    /// Hands a frame to every sink (from a source, on its capture queue).
    func video(_ track: String, _ frame: CVPixelBuffer, hostTime: CMTime) {
        for sink in lock.withLock({ sinks }) { sink.video(track, frame, hostTime: hostTime) }
    }

    func sound(_ track: String, _ sample: CMSampleBuffer, hostTime: CMTime) {
        for sink in lock.withLock({ sinks }) { sink.sound(track, sample, hostTime: hostTime) }
    }

    func ended(_ track: String) {
        for sink in lock.withLock({ sinks }) { sink.ended(track) }
    }

    /// A final segment of the transcription stream, as one line of the `transcript` track. False
    /// when the record has no such track now.
    @discardableResult
    public func transcribed(_ line: Data) -> Bool {
        guard let track = track(TranscriptTrack.name) as? TranscriptTrack else { return false }
        track.append(line)
        return true
    }

    /// The Mac is locked or its displays sleep: screens and cameras pause and start again by
    /// themselves; a camera's capture stops, so its light is off. Microphones and speakers go on.
    public func pause(_ on: Bool) {
        let (changed, video, sources) = lock.withLock { () -> (Bool, [VideoTrack], [Source]) in
            defer { paused = on }
            return (paused != on, tracks.compactMap { $0 as? VideoTrack }.filter(\.pausable), Array(self.sources.values))
        }
        guard changed else { return }
        log(on ? "record: paused" : "record: resumed")
        for track in video { on ? track.pause() : track.resume() }
        for source in sources { on ? source.paused() : source.resumed() }
    }

    /// Stops every source and track, writes what is left and seals every slot.
    public func stop() {
        control.async { self.apply(record: [], live: []) }
        control.sync {}
        timer?.cancel()
        tickQueue.sync {}
        slots.sync {
            open = [:]
            for slot in entries.keys.sorted() { seal(slot) }
        }
        for (center, observer) in observers { center.removeObserver(observer) }
        if let activity { ProcessInfo.processInfo.endActivity(activity) }
        log("record: stopped")
    }

    /// A new anchor for the timeline. Audio follows it by itself (`Resync`). Forward, slots are
    /// skipped. Backward, the tracks write nothing until the timeline passes what they wrote last.
    /// A jump of more than 1 s also ends each video track's last frame at the jump.
    func clockChanged(_ reason: String) {
        let before = nowMs()
        let step = clock.reanchor()
        log(String(format: "record: clock %@, timeline moved %+.0f ms", reason, step))
        guard abs(step) > 1000 else { return }
        for video in lock.withLock({ tracks.compactMap { $0 as? VideoTrack } }) { video.clockJumped(at: before) }
    }

    // MARK: the slots and the spool (called by the tracks)

    /// Whether `track` may begin its file of `slot`: not in a slot that is sealed, nor twice in one
    /// slot (a source switched off and on again). Such a track begins with the next slot.
    func opening(track: String, slot: Int64) -> Bool {
        slots.sync {
            guard slot > sealed, entries[slot]?[track] == nil else {
                log("\(track): slot \(slot) is written already; this track begins with the next one")
                return false
            }
            open[slot, default: []].insert(track)
            return true
        }
    }

    /// The file of `track` for `slot` is whole: into the spool with its picture, then its entry.
    /// A file that cannot be written gets no entry.
    /// Only while `track` is open in `slot`: after the slot was sealed without it (`sealStale`),
    /// its file is dropped, and the slot's event stays as it was sealed.
    func finished(track: String, slot: Int64, parts: [Data], size: Int, entry: [String: Any], picture: Data?, ext: String = "mp4") {
        let isOpen = { self.open[slot]?.contains(track) == true }
        guard slots.sync(execute: isOpen) else { return log("\(track): slot \(slot) was sealed without it; its file is dropped") }
        let file = Slot.path(device: options.device, track: track, slot: slot, ext: ext)
        let picturePath = Slot.path(device: options.device, track: track, slot: slot, ext: "jpg")
        let wrote = write(file, parts)
        var entry = entry
        if wrote {
            entry["file"] = file
            entry["bytes"] = size
            if let picture, write(picturePath, [picture]) { entry["picture"] = picturePath }
        }
        slots.sync {
            guard isOpen() else {
                // sealed while the file was written: nothing names it
                for path in [file, picturePath] { try? FileManager.default.removeItem(at: url(path)) }
                return log("\(track): slot \(slot) was sealed while its file was written; the file is dropped")
            }
            open[slot]?.remove(track)
            if wrote {
                entries[slot, default: [:]][track] = entry
                _ = write("slots/\(slot).open", [Slot.event(t: slot, tracks: entries[slot]!)])
            }
            if open[slot]?.isEmpty != false { seal(slot) }
        }
    }

    /// On `slots`: the slot's event file is final. Its `.open` file becomes `.json`.
    private func seal(_ slot: Int64) {
        open[slot] = nil
        // also with nothing written: no track begins this slot after its seal
        sealed = max(sealed, slot)
        guard let tracks = entries.removeValue(forKey: slot) else { return }
        // no sync: a restart also takes the newest slot's name in `slots/` (`recover`)
        _ = write("sealed", [Data("\(sealed)".utf8)], sync: false)
        let from = url("slots/\(slot).open"), to = url("slots/\(slot).json")
        if rename(from.path, to.path) != 0 {
            log("record: slot \(slot): the event file could not be renamed (\(errno)); writing it again")
            guard write("slots/\(slot).json", [Slot.event(t: slot, tracks: tracks)]) else { return }
            try? FileManager.default.removeItem(at: from)
        }
        onSeal?(slot)
    }

    /// About once a second: a slot that ended more than 10 s ago with a track still
    /// "open" (a track that began it and never wrote it) is sealed with what it has.
    func sealStale(now: Double = nowMs()) {
        let limit = Int64(now) - Slot.ms - 10_000
        slots.sync { for slot in open.keys.sorted() where slot < limit { seal(slot) } }
    }

    /// On `slots`, at start: what an earlier run left. Its open slots are sealed as they are (its
    /// open files were in memory and are gone), half-written files are deleted, and `sealed` is the
    /// newest slot it sealed.
    private func recover() {
        sealed = Int64((try? String(contentsOf: url("sealed"), encoding: .utf8)) ?? "") ?? -1
        let walker = FileManager.default.enumerator(at: options.spool, includingPropertiesForKeys: nil)
        var parts = 0
        while let file = walker?.nextObject() as? URL {
            if file.pathExtension == "part" {
                try? FileManager.default.removeItem(at: file)
                parts += 1
            } else if file.deletingLastPathComponent().lastPathComponent == "slots", let t = Int64(file.deletingPathExtension().lastPathComponent) {
                sealed = max(sealed, t)
                if file.pathExtension == "open" { rename(file.path, url("slots/\(t).json").path) }
            }
        }
        if parts > 0 { log("record: deleted \(parts) half-written files of an earlier run") }
    }

    func url(_ path: String) -> URL { options.spool.appendingPathComponent(path.hasPrefix("/") ? String(path.dropFirst()) : path) }

    /// Writes a file whole: its parts in order to `<name>.part`, then a rename. False when it could
    /// not: then nothing may refer to it. It tries twice, because the uploader removes the folders
    /// it empties, and one can go between our making it and our writing into it.
    func write(_ path: String, _ parts: [Data], sync: Bool = true) -> Bool {
        let file = url(path), part = file.appendingPathExtension("part")
        func attempt() throws {
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            guard FileManager.default.createFile(atPath: part.path, contents: nil) else { throw CocoaError(.fileWriteUnknown) }
            let handle = try FileHandle(forWritingTo: part)
            defer { try? handle.close() }
            for data in parts { try handle.write(contentsOf: data) }
            if sync { try handle.synchronize() }
            guard rename(part.path, file.path) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        }
        do {
            do { try attempt() } catch { try attempt() }
            return true
        } catch {
            try? FileManager.default.removeItem(at: part)
            log("record: cannot write \(path): \(error.localizedDescription)")
            return false
        }
    }

    /// A stable number for a capture device, so that its track id is the same after a restart.
    /// Kept in `devices.json` of the spool. Callers ask for built-in devices first, then by unique
    /// id: a first start numbers them so.
    func number(_ kind: String, device uid: String) -> Int {
        slots.sync {
            let file = url("devices.json")
            var map = (try? Data(contentsOf: file)).flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Int] } ?? [:]
            if let n = map["\(kind)/\(uid)"] { return n }
            let taken = Set(map.filter { $0.key.hasPrefix("\(kind)/") }.values)
            let n = (0...).first { !taken.contains($0) }!
            map["\(kind)/\(uid)"] = n
            if let data = try? JSONSerialization.data(withJSONObject: map, options: .sortedKeys) { _ = write("devices.json", [data]) }
            return n
        }
    }
}

/// One kind of source behind one switch.
protocol Source: AnyObject {
    func start()
    /// Stops the capture; the recorder then stops the source's tracks.
    func stop()
    /// The Mac is locked or its displays sleep (after the tracks paused).
    func paused()
    /// After an unlock or a wake: open again what could not open (a locked Mac lists no display).
    func resumed()
    /// A watcher came or the last one left: a screen captures this many frames a second now.
    func rate(_ fps: Int)
}

extension Source {
    func paused() {}
    func resumed() {}
    func rate(_ fps: Int) {}
}
