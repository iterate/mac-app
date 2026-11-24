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
/// The recorder writes 30-second files into a spool on this Mac
/// (`~/Library/Application Support/iterate-mac-app/record/<mind>/`); `bridge/record-upload.mjs`
/// puts them into the mind's files under `/devices/<name>/record/` and appends one
/// `record/slot-stored` for each slot to `/devices/<name>`, as the person (the CLI's own sign-in).
///
/// It records for one mind session (`MindSession`): `use` stops the old session's recorder and
/// uploader at once. A reconnect keeps the session, and a spool keeps its slots for its mind.
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
    /// Live's sink of the capture (`LivePeer`): every recorder hands it each frame and buffer.
    var sink: CaptureSink?
    /// The device's presence: "active", "idle", "locked", "asleep" (`DeviceEvents.presence`).
    var presence: () -> String? = { nil }
    var onChange: () -> Void = {}

    private let log = AppLog("record")
    /// Recorders start and stop here, one after the other: a stop waits for the last files.
    private let lifecycle = DispatchQueue(label: "record.lifecycle")
    private var recorder: Recorder?
    private var running: Set<RecordSource> = []
    private var watching: Set<RecordSource> = []
    private var paused = false
    private var uploader: Process?
    private var uploaderInput: FileHandle?
    private var uploaderEndedAt = Date.distantPast
    private var uploadFailure: String?
    private var waiting = 0
    private var pending = ""
    private var timer: Timer?

    func isOn(_ source: RecordSource) -> Bool { on.contains(source) }

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
        let timer = Timer(timeInterval: 2, repeats: true) { [weak self] _ in MainActor.assumeIsolated { self?.tick() } }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
        tick()
    }

    /// At quit: the last files are written and sealed; the uploader sends them now or at the next start.
    func stop() {
        timer?.invalidate()
        if let recorder { lifecycle.sync { recorder.stop() } }
        recorder = nil
        try? uploaderInput?.close()
    }

    static func spool(for mind: String) -> URL {
        AppEnvironment.current.folder.appendingPathComponent("record").appendingPathComponent(mind)
    }

    /// Another session, or none: the old one's recorder and uploader stop now (the recorder seals
    /// its last files into the old mind's spool). Nothing starts here: the next `tick` does.
    func use(_ session: MindSession?) {
        stopRecorder()
        endUploader()
        uploadFailure = nil
        self.session = session
    }

    private func stopRecorder() {
        guard let old = recorder else { return }
        lifecycle.async { old.stop() }
        recorder = nil
        (running, watching) = ([], [])
    }

    /// Every 2 s, at each switch, and at once when the presence changes (`AppModel`).
    func tick() {
        let session = session
        let permitted = { (sources: Set<RecordSource>) in
            session == nil ? [] : Set(sources.filter { source in Self.switches.first { $0.source == source }?.permission.isGranted ?? true })
        }
        // the record's switches, and live's watchers: the capture runs for both
        let wanted = permitted(on), watched = permitted(live)
        if wanted.union(watched).isEmpty { stopRecorder() }
        if let session, !wanted.union(watched).isEmpty {
            if recorder == nil {
                let recorder = Recorder(options: RecordOptions(spool: Self.spool(for: session.mind), device: session.name))
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
        let waiting = session.map { Self.waiting(in: Self.spool(for: $0.mind)) } ?? 0
        if let session, !running.isEmpty || waiting > 0 {
            if uploader == nil, Date().timeIntervalSince(uploaderEndedAt) > 10 { startUploader(session) }
        } else {
            endUploader()
        }
        showState(waiting: waiting, isLent: session != nil)
    }

    private func showState(waiting: Int, isLent: Bool) {
        var parts: [String] = []
        if !isLent {
            parts.append(on.isEmpty ? "Off" : "Waits for the Mac to be lent to a mind")
        } else if let recorder, !running.isEmpty {
            let tracks = recorder.trackIDs.count
            parts.append(paused ? "Paused: \(presence() ?? "locked")" : "Recording \(tracks) track\(tracks == 1 ? "" : "s")")
        } else {
            parts.append("Off")
        }
        if waiting > 0 { parts.append("\(waiting) slot\(waiting == 1 ? "" : "s") waiting") }
        if let uploadFailure, waiting > 0 { parts.append("upload failing: \(uploadFailure)") }
        let line = parts.joined(separator: " · ")
        let isRecording = recorder != nil && !running.isEmpty
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

    /// The slots in the spool that wait for the uploader.
    private static func waiting(in spool: URL) -> Int {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: spool.appendingPathComponent("slots").path)) ?? []
        return names.filter { $0.hasSuffix(".json") }.count
    }

    // MARK: - The uploader

    private func startUploader(_ session: MindSession) {
        let process = Process()
        let stdin = Pipe(), stdout = Pipe()
        process.executableURL = URL(fileURLWithPath: session.helpers.node)
        process.arguments = [
            session.helpers.recordUpload, Self.spool(for: session.mind).path, "--name", session.name, "--iterate", session.helpers.iterateBin,
            "--mind", session.mind,
        ]
        process.standardInput = stdin
        process.standardOutput = stdout
        process.standardError = FileHandle.nullDevice
        stdout.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let text = String(decoding: handle.availableData, as: UTF8.self)
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    // a line of an ended uploader, or of another session, changes nothing
                    guard let self, self.uploader === process else { return }
                    self.uploaderSaid(text)
                }
            }
        }
        process.terminationHandler = { [weak self] ended in
            stdout.fileHandleForReading.readabilityHandler = nil
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self, self.uploader === ended else { return }
                    self.log.info("uploader ended (status \(ended.terminationStatus))")
                    (self.uploader, self.uploaderInput, self.uploaderEndedAt) = (nil, nil, Date())
                }
            }
        }
        guard (try? process.run()) != nil else {
            uploadFailure = "the uploader did not start"
            uploaderEndedAt = Date()
            return
        }
        uploader = process
        uploaderInput = stdin.fileHandleForWriting
        log.info("session \(session.generation): uploader: \(Self.spool(for: session.mind).path) to \(session.mind) at \(session.path)")
    }

    /// Its stdin closes: it ends the slot it is on, then exits.
    private func endUploader() {
        guard uploader != nil else { return }
        try? uploaderInput?.close()
        // a new one waits: the old one may still be on its last slot
        (uploaderInput, uploader, uploaderEndedAt, pending) = (nil, nil, Date(), "")
    }

    private func uploaderSaid(_ text: String) {
        var lines = (pending + text).components(separatedBy: "\n")
        pending = lines.removeLast()
        for line in lines {
            guard let said = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any] else { continue }
            if said["uploaded"] != nil { uploadFailure = nil }
            if let why = said["failed"] as? String {
                if uploadFailure != why { log.error("upload: \(why)") }
                uploadFailure = String(why.prefix(80))
            }
            if let slot = said["dropped"], let why = said["why"] as? String { log.error("upload: slot \(slot) dropped: \(why)") }
        }
    }
}

/// The panel's group "Record": a switch for each source, the window text, and one line of state.
struct RecordSection: View {
    @ObservedObject var record: DeviceRecord
    @ObservedObject var window: DeviceWindow
    let allow: (Permission) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            Text("RECORD").font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
            ForEach(DeviceRecord.switches) { item in
                row(item.title, id: "record.\(item.source.rawValue)", symbol: item.symbol, permission: item.permission, isOn: Binding(
                    get: { record.isOn(item.source) }, set: { record.set(item.source, $0) }))
            }
            VStack(alignment: .leading, spacing: 4) {
                Toggle("Window text: the text of the window in front", isOn: $window.readsWindowText)
                    .toggleStyle(.checkbox)
                    .accessibilityIdentifier("record.windowText")
                    .help("On a new app or window, a click, a pause after typing, the end of a scroll; at most every 2 s. Never of a password manager.")
                Text("The app in front and its window's title go to the mind always, while the Mac is lent.")
                    .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            .font(.caption)
            .padding(.leading, 30)
            if window.readsWindowText, !Permission.accessibility.isGranted { missing(.accessibility) }
            Text(record.line).font(.caption).foregroundStyle(.secondary).lineLimit(2).textSelection(.enabled)
        }
    }

    private func row(_ title: String, id: String, symbol: String, permission: Permission, isOn: Binding<Bool>) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 10) {
                Image(systemName: symbol).font(.system(size: 14)).frame(width: 20)
                    .foregroundStyle(isOn.wrappedValue && permission.isGranted ? Color.accentColor : Color.secondary)
                Text(title)
                Spacer(minLength: 8)
                Toggle("", isOn: isOn).toggleStyle(.switch).controlSize(.small).labelsHidden().accessibilityIdentifier(id)
            }
            if isOn.wrappedValue, !permission.isGranted { missing(permission) }
        }
    }

    /// A source with no permission says so in its row and stays off.
    private func missing(_ permission: Permission) -> some View {
        HStack(spacing: 8) {
            Label("Off: macOS has not allowed \(permission.title)", systemImage: "exclamationmark.triangle.fill")
                .font(.caption).foregroundStyle(.orange)
            Spacer()
            Button("Allow…") { allow(permission) }.controlSize(.small)
        }
        .padding(.leading, 30)
    }
}
