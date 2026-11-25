import AppKit
import Record
import SwiftUI
import VoiceMeetCore

/// THE RECORD OF THIS MAC, streamed into the mind it is lent to (`Sources/Record`): its screens,
/// cameras, microphones and speakers, each a switch of its own in the panel, all off until the
/// person turns one on. It records only while the Mac is lent to a mind, into that mind, and starts
/// again by itself when the app starts. A source whose permission macOS has not given stays off.
/// Screens and cameras pause while the Mac is locked or its displays sleep (the device's
/// presence); microphones and speakers go on.
///
/// The recorder writes 30-second files into a spool on this Mac, one for each mind and device name
/// (`~/Library/Application Support/iterate-mac-app/record/<mind>/itx.<name>/`, `Spool`); the job `record` of the
/// session's `MindBridge` (`bridge/record.mjs`) puts them into the mind's files under
/// `/devices/<name>/record/` and appends one `record/slot-stored` for each slot to
/// `/devices/<name>`, as the person (the CLI's own sign-in), for as long as the session lasts.
///
/// It records for one mind session (`MindSession`): `use` stops the old session's recorder and
/// upload at once. A reconnect keeps the session, and a spool keeps its slots for its mind and its
/// name: after a rename, the old name's slots wait until the Mac has that name again. The count of
/// waiting slots is the job's word (`{ uploaded, waiting }`, `{ failed, waiting }`), and one
/// look at the spool off the main thread when a session starts: no folder is listed on a timer.
@MainActor
final class DeviceRecord: ObservableObject {
    /// One switch of the panel: its source, its permission, its words.
    struct Switch: Identifiable {
        let source: RecordSource
        let title: String
        let symbol: String
        let permission: Permission
        var id: String { source.rawValue }
    }

    static let switches = [
        Switch(source: .screens, title: "Screens", symbol: "display", permission: .screenRecording),
        Switch(source: .cameras, title: "Camera", symbol: "video", permission: .camera),
        Switch(source: .mics, title: "Microphone", symbol: "mic", permission: .microphone),
        Switch(source: .speakers, title: "Speakers", symbol: "speaker.wave.2", permission: .screenRecording),
    ]

    /// The switches that are on, remembered across restarts.
    @Published private(set) var on: Set<RecordSource> = Set(
        RecordSource.allCases.filter { AppEnvironment.current.defaults.bool(forKey: "record.\($0.rawValue)") })
    /// The quiet line of state under the switches.
    @Published private(set) var line = "Off"
    /// A recorder runs (the dot on the mark); it may be paused.
    @Published private(set) var isRecording = false
    /// The recorder runs and is paused: the Mac is locked or its displays sleep (a ring on the mark).
    @Published private(set) var isPaused = false
    /// Why it is paused: the presence, "locked" or "asleep".
    private(set) var pausedBecause: String?
    /// The tracks the recorder writes now: "screen-1", "mic-1".
    private(set) var tracks: [String] = []

    /// The session it records for; none while the Mac is lent to no mind.
    private(set) var session: MindSession?
    /// The sources live wants now (`DeviceLive`): the recorder runs them too, and writes nothing
    /// of those the record does not want.
    var live: Set<RecordSource> = []
    /// Live's sink of the capture (`LivePeer`, made at the first watcher): every recorder hands it
    /// each frame and buffer, the one that runs from now.
    var sink: CaptureSink? {
        didSet { if let sink, let recorder { recorder.add(sink: sink) } }
    }
    /// The device's presence: "active", "idle", "locked", "asleep" (`DeviceEvents.presence`).
    var presence: () -> String? = { nil }
    /// Always listen is on (`Listening`): the transcript is recorded, as with the Microphone switch.
    var alwaysListens: () -> Bool = { false }
    /// The record's `mic-0` reads the app's microphone stream.
    private static let feed = StreamFeed()
    var onChange: () -> Void = {}

    private let log = AppLog("record")
    /// Recorders start and stop here, one after the other: a stop waits for the last files.
    private let lifecycle = DispatchQueue(label: "record.lifecycle")
    private var recorder: Recorder?
    private var running: Set<RecordSource> = []
    private var watching: Set<RecordSource> = []
    private var paused = false
    /// The session's bridge, whose job `record` uploads the spool.
    private var bridge: MindBridge?
    private var uploadFailure: String?
    private var waiting = 0
    private var timer: Timer?
    /// The session's work: a look at the spool of an old session lands nowhere.
    private var work = SessionWork()

    func isOn(_ source: RecordSource) -> Bool { on.contains(source) }

    /// For a drawing (`Rendering`): switches and a state as given, with no recorder and nothing stored.
    func fixForDrawing(on: Set<RecordSource>, line: String, isRecording: Bool) {
        (self.on, self.line, self.isRecording) = (on, line, isRecording)
    }

    /// For `record.state()` on the endpoint (`AppModel` adds the window text).
    func state() -> [String: Any] {
        var answer: [String: Any] = [
            "sources": Dictionary(uniqueKeysWithValues: Self.switches.map { ($0.source.rawValue, on.contains($0.source)) }),
            "recording": isRecording, "paused": isPaused, "line": line, "tracks": tracks, "waitingSlots": waiting,
        ]
        if let uploadFailure, waiting > 0 { answer["uploadFailure"] = uploadFailure }
        if let session {
            answer["mind"] = session.mind
            answer["device"] = session.name
        }
        return answer
    }

    func set(_ source: RecordSource, _ value: Bool) {
        AppEnvironment.current.defaults.set(value, forKey: "record.\(source.rawValue)")
        if value { on.insert(source) } else { on.remove(source) }
        log.info("\(source.rawValue): \(value ? "on" : "off")")
        tick()
    }

    func start() {
        recordLog = { line in AppLog("record").info(line) }
        tick()
    }

    /// A look every 2 s, only while a switch that is on waits for a permission given in System
    /// Settings: nothing else is polled, and with every switch off, or all given, nothing runs.
    private func lookForPermissions(_ isWaiting: Bool) {
        guard isWaiting != (timer != nil) else { return }
        timer?.invalidate()
        timer = nil
        guard isWaiting else { return }
        let timer = Timer(timeInterval: 2, repeats: true) { [weak self] _ in MainActor.assumeIsolated { self?.tick() } }
        timer.tolerance = 0.5
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    /// The recorder sealed slot `t` of this session: the bridge's record job sends it now, not at
    /// its next look at the spool.
    private func sealed(_ t: Int64, stamp: SessionWork.Stamp) {
        guard work.lands(stamp) else { return }
        bridge?.send("record", ["slot": t])
    }

    /// At quit: the last files are written and sealed; the job sends them now or at the next start.
    func stop() {
        timer?.invalidate()
        timer = nil
        if let recorder { lifecycle.sync { recorder.stop() } }
        recorder = nil
    }

    static func spool(for session: MindSession) -> URL {
        Spool.folder(in: AppEnvironment.current.folder.appendingPathComponent("record"), mind: session.mind, device: session.name)
    }

    /// Another session and its bridge, or none: the old one's recorder and upload stop now (the
    /// recorder seals its last files into the old mind's spool, and the job ends the slot it is on),
    /// and the new one's upload starts. The next `tick` starts the recorder.
    func use(_ session: MindSession?, bridge: MindBridge?) {
        stopRecorder()
        self.bridge?.send("record", ["stop": true])
        uploadFailure = nil
        waiting = 0
        work.use(generation: session?.generation)
        self.session = session
        self.bridge = bridge
        guard let session, let bridge else { return }
        bridge.on("record") { [weak self, weak bridge] line in
            guard let self, let bridge, self.bridge === bridge else { return }
            self.said(line)
        }
        let spool = Self.spool(for: session), stamp = work.stamp
        // before the recorder starts (it starts on the same queue): an earlier version's spool of
        // this mind goes into the spools of its devices; then one look at what waits
        lifecycle.async { [weak self] in
            Spool.split(mindFolder: spool.deletingLastPathComponent())
            let waiting = Spool.waiting(in: spool)
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self, self.work.lands(stamp) else { return }
                    self.waiting = waiting
                    self.tick()
                }
            }
        }
        startUpload()
        log.info("session \(session.generation): uploads \(spool.path) to \(session.mind) at \(session.path)")
    }

    private func startUpload() {
        guard let session else { return }
        bridge?.send("record", ["start": true, "spool": Self.spool(for: session).path])
    }

    private func stopRecorder() {
        guard let old = recorder else { return }
        lifecycle.async { old.stop() }
        recorder = nil
        (running, watching) = ([], [])
    }

    /// At each switch, at once when the presence changes (`AppModel`), and every 2 s while a
    /// permission is waited for (`lookForPermissions`).
    func tick() {
        Perf.count("recordLooks")
        let session = session
        let permitted = { (sources: Set<RecordSource>) in
            session == nil ? [] : Set(sources.filter { source in Self.switches.first { $0.source == source }?.permission.isGranted ?? true })
        }
        // the record's switches, and live's watchers: the capture runs for both. The transcript
        // (README, "Listening") is recorded with the Microphone switch, and with Always listen.
        var wanted = permitted(on)
        let watched = permitted(live)
        if session != nil, wanted.contains(.mics) || alwaysListens() { wanted.insert(.transcript) }
        if wanted.union(watched).isEmpty { stopRecorder() }
        if let session, !wanted.union(watched).isEmpty {
            if recorder == nil {
                var options = RecordOptions(spool: Self.spool(for: session), device: session.name)
                options.microphone = Self.feed
                let recorder = Recorder(options: options)
                let stamp = work.stamp
                recorder.onSeal = { [weak self] t in
                    DispatchQueue.main.async { MainActor.assumeIsolated { self?.sealed(t, stamp: stamp) } }
                }
                if let sink { recorder.add(sink: sink) }
                lifecycle.async { recorder.start() }
                self.recorder = recorder
                paused = false
            }
            let recorder = recorder!
            if wanted != running {
                lifecycle.async { recorder.set(wanted) }
                running = wanted
            }
            if watched != watching {
                lifecycle.async { recorder.watch(watched) }
                watching = watched
            }
            if let state = presence() {
                let shouldPause = state == "locked" || state == "asleep"
                if shouldPause != paused {
                    paused = shouldPause
                    lifecycle.async { recorder.pause(shouldPause) }
                }
            }
        }
        lookForPermissions(session != nil && (wanted.subtracting([.transcript]) != on || watched != live))
        showState(waiting: session == nil ? 0 : waiting, isLent: session != nil)
    }

    private func showState(waiting: Int, isLent: Bool) {
        var parts: [String] = []
        if !isLent {
            parts.append(on.isEmpty ? "Off" : "Waits for the Mac to be lent to a mind")
        } else if let recorder, !running.subtracting([.transcript]).isEmpty {
            let tracks = recorder.trackIDs.count
            parts.append(paused ? "Paused: \(presence() ?? "locked")" : "Recording \(tracks) track\(tracks == 1 ? "" : "s")")
        } else if recorder != nil, running.contains(.transcript) {
            parts.append("Recording what Always listen hears, as text")
        } else {
            parts.append("Off")
        }
        if waiting > 0 { parts.append("\(waiting) slot\(waiting == 1 ? "" : "s") waiting") }
        if let uploadFailure, waiting > 0 { parts.append("upload failing: \(uploadFailure)") }
        let line = parts.joined(separator: " · ")
        // the transcript alone is no red dot: Always listen has its own sign on the mark
        let isRecording = recorder != nil && !running.subtracting([.transcript]).isEmpty
        let isPaused = isRecording && paused
        let tracks = isRecording ? recorder?.trackIDs ?? [] : []
        let pausedBecause = isPaused ? presence() ?? "locked" : nil
        // the mark shows these: it changes with them
        let markChanges = isRecording != self.isRecording || isPaused != self.isPaused || tracks.count != self.tracks.count || pausedBecause != self.pausedBecause
        (self.waiting, self.tracks, self.pausedBecause) = (waiting, tracks, pausedBecause)
        if line != self.line { self.line = line }
        if isRecording != self.isRecording { self.isRecording = isRecording }
        if isPaused != self.isPaused { self.isPaused = isPaused }
        if markChanges { onChange() }
    }

    /// A final segment of the transcription stream, as a line of the `transcript` track: kept only
    /// while that track records (the Microphone switch, or Always listen, while lent).
    func transcribed(_ line: Data) {
        guard let recorder, running.contains(.transcript) else { return }
        lifecycle.async { recorder.transcribed(line) }
    }

    // MARK: - The upload

    private func said(_ said: [String: Any]) {
        if said["uploaded"] != nil { uploadFailure = nil }
        // the job counts the slots that wait at each upload and each failure
        if let count = said["waiting"] as? Int, count != waiting {
            waiting = count
            showState(waiting: count, isLent: session != nil)
        }
        if let why = said["failed"] as? String, said["job"] != nil {
            if uploadFailure != why { log.error("upload: \(why)") }
            uploadFailure = String(why.prefix(80))
        }
        if let slot = said["dropped"], let why = said["why"] as? String { log.error("upload: slot \(slot) dropped: \(why)") }
        if let why = said["fallback"] as? String { log.info("upload: \(why)") }
        // a new process: the upload starts again
        if said["started"] != nil { startUpload() }
    }
}

/// The panel's "Record into the mind": five switches in one row (the four sources, and the window
/// text), red while on, orange while on and held off by a permission macOS has not given; at the
/// title's right whether it records; under the row the record's line and what is missing.
struct RecordSection: View {
    @ObservedObject var record: DeviceRecord
    @ObservedObject var window: DeviceWindow
    /// The permissions of macOS that are not given.
    let missing: Set<Permission>
    let allow: (Permission) -> Void

    var body: some View {
        let held = DeviceRecord.switches.filter { record.isOn($0.source) && missing.contains($0.permission) }
        let windowHeld = window.readsWindowText && missing.contains(.accessibility)
        VStack(alignment: .leading, spacing: 7) {
            SectionTitle(title: "Record into the mind") { state }
            HStack(spacing: Theme.Metric.recordChipGap) {
                ForEach(DeviceRecord.switches) { item in
                    chip(item.title, symbol: item.symbol, id: "record.\(item.source.rawValue)", isOn: record.isOn(item.source),
                         isHeld: held.contains { $0.source == item.source }) { record.set(item.source, $0) }
                }
                chip("Window text", symbol: "text.alignleft", id: "record.windowText", isOn: window.readsWindowText, isHeld: windowHeld) {
                    window.readsWindowText = $0
                }
                .help("On a new app or window, a click, a pause after typing, the end of a scroll; at most every 2 s. Never of a password manager.")
            }
            if let line {
                Text(line).font(.system(size: 11)).lineSpacing(1.5).foregroundStyle(Theme.t3).lineLimit(2).textSelection(.enabled)
                    .padding(.horizontal, 2)
            }
            ForEach(held) { item in
                MissingPermission(words: "\(item.title) is off: macOS has not allowed \(item.permission.title)") { allow(item.permission) }
            }
            if windowHeld {
                MissingPermission(words: "Window text is off: macOS has not allowed Accessibility") { allow(.accessibility) }
            }
        }
    }

    /// "Off", or a red dot and "Recording", or a red ring and "Paused".
    @ViewBuilder
    private var state: some View {
        if record.isRecording {
            HStack(spacing: 5) {
                if record.isPaused {
                    Circle().strokeBorder(Theme.live, lineWidth: 1.5).frame(width: 7, height: 7)
                } else {
                    Circle().fill(Theme.live).frame(width: 7, height: 7)
                }
                Text(record.isPaused ? "Paused" : "Recording")
            }
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(Theme.liveText)
        } else {
            Text("Off").font(.system(size: 12)).foregroundStyle(Theme.t3)
        }
    }

    /// The record's line, when it says more than the title: "4 tracks · 2 slots waiting".
    private var line: String? {
        var line = record.line
        if line == "Off" { return nil }
        if line.hasPrefix("Recording ") { line = String(line.dropFirst("Recording ".count)) }
        return line
    }

    private func chip(_ title: String, symbol: String, id: String, isOn: Bool, isHeld: Bool, set: @escaping (Bool) -> Void) -> some View {
        Button {
            set(!isOn)
        } label: {
            // the mock: a 15 pt icon 3 over the name on one line (line height 1.3), the two centred
            // in the 46 pt tile. The name is a point under the mock's 11, so SF takes Inter's width
            // and keeps 6 pt of air at each side; a name still too long tightens, then shrinks to 90 %
            VStack(spacing: Theme.Metric.recordChipIconGap) {
                // a symbol at 11 pt fills the square as the mock's line drawings do (about 13 pt)
                Image(systemName: symbol)
                    .symbolRenderingMode(.monochrome)
                    .font(.system(size: 11, weight: .regular))
                    .frame(width: Theme.Metric.recordChipIcon, height: Theme.Metric.recordChipIcon)
                Text(title)
                    .font(.system(size: Theme.Size.recordChipLabel))
                    .lineLimit(1)
                    .allowsTightening(true)
                    .minimumScaleFactor(0.9)
                    .frame(height: (Theme.Size.caption * 1.3).rounded())
                    .padding(.horizontal, Theme.Metric.recordChipInset)
            }
            .frame(maxWidth: .infinity)
        }
        .buttonStyle(TileStyle(tint: isHeld ? .held : isOn ? .on : nil))
        .accessibilityIdentifier(id)
        .accessibilityLabel(title)
        .accessibilityValue(isOn ? "on" : "off")
        .accessibilityAddTraits(isOn ? .isSelected : [])
    }
}
