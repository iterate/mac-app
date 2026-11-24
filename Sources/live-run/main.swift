import CoreGraphics
import Foundation
import LiveKitWebRTC
import Live
import Record
import VoiceMeetCore

// live-run: live from a terminal, for tests: the app's own Record and Live libraries and its
// bridge, with no switch and no question (every watcher gets every track asked for here).
//
//   live-run --device <name> --node <node> --bridge <bridge/mind.mjs> --iterate <iterate.js> --mind <address>
//            [--synthetic] [--screens] [--cameras] [--mics] [--record <spool>]
//            [--loopback-only] [--no-stun] [--seconds N]
//
// The bridge is the app's own process for a mind, with its job `live` alone.
// --record also records the same sources into a spool, as the app does with a watcher and the
// record on together. Real sources need the app's permissions: run it through the app's `run`
// method. stderr: one JSON line of statistics a second, and the libraries' log lines.
var arguments = Array(CommandLine.arguments.dropFirst())
func value(_ flag: String) -> String? {
    guard let i = arguments.firstIndex(of: flag), i + 1 < arguments.count else { return nil }
    return arguments[i + 1]
}
guard let device = value("--device"), let node = value("--node"), let bridgeScript = value("--bridge"), let iterate = value("--iterate"), let mind = value("--mind") else {
    FileHandle.standardError.write(Data("live-run --device <name> --node <node> --bridge <mind.mjs> --iterate <iterate.js> --mind <address> [--synthetic] [--screens] [--cameras] [--mics] [--record <spool>] [--loopback-only] [--no-stun] [--seconds N]\n".utf8))
    exit(2)
}
let started = Date()
let outLock = NSLock()
func say(_ line: [String: Any]) {
    guard let data = try? JSONSerialization.data(withJSONObject: line, options: [.sortedKeys, .withoutEscapingSlashes]) else { return }
    outLock.withLock { FileHandle.standardError.write(data + Data("\n".utf8)) }
}
recordLog = { say(["log": $0]) }

let sources = Set(RecordSource.allCases.filter { arguments.contains("--\($0.rawValue)") })
let spool = value("--record") ?? NSTemporaryDirectory() + "live-run-\(ProcessInfo.processInfo.processIdentifier)"
let recorder = Recorder(options: RecordOptions(spool: URL(fileURLWithPath: spool), device: device))
let peer = LivePeer(loopbackOnly: arguments.contains("--loopback-only"), stun: !arguments.contains("--no-stun"))
peer.log = { say(["log": $0]) }
recorder.add(sink: peer)
recorder.start()
if value("--record") != nil { recorder.set(sources) }

/// The tracks of the sources asked for: each display, the camera, the microphone, the test picture and beep.
func tracks() -> [String] {
    var displays = [CGDirectDisplayID](repeating: 0, count: 16)
    var count: UInt32 = 0
    CGGetOnlineDisplayList(16, &displays, &count)
    var tracks: [String] = []
    if sources.contains(.synthetic) { tracks += ["test-1", "test-2"] }
    if sources.contains(.screens) { tracks += displays.prefix(Int(count)).map { "screen-\($0)" } }
    if sources.contains(.cameras) { tracks.append("camera-0") }
    if sources.contains(.mics) { tracks.append("mic-0") }
    return tracks
}
peer.decide = { _, _, answer in answer(tracks(), "nothing to show") }
peer.changed = { watchers in recorder.watch(Set(watchers.tracks.compactMap(RecordSource.of(track:)))) }

peer.started = { watcher, who, tracks in
    say(["event": "live-watch-started", "watcher": watcher, "who": who, "tracks": tracks])
}
peer.ended = { watcher, who, seconds, why in
    say(["event": "live-watch-ended", "watcher": watcher, "who": who, "seconds": seconds, "why": why])
}
let bridgeEnded = DispatchSemaphore(value: 0)
// the bridge lives on the main actor: the main queue runs it, in `RunLoop.main.run()` below
let bridge = try MainActor.assumeIsolated { () throws -> JSONLineProcess in
    let bridge = JSONLineProcess(executable: node, arguments: [bridgeScript, mind, "--name", device, "--iterate", iterate])
    bridge.said = { line in if !peer.take(line) { say(["bridge": line]) } }
    bridge.logged = { say(["log": $0]) }
    bridge.exited = { status in
        say(["event": "bridge exited", "status": Int(status)])
        bridgeEnded.signal()
    }
    try bridge.start()
    bridge.send(["job": "live", "start": true])
    say(["event": "ready", "device": device, "bridge": Int(bridge.pid), "sources": sources.map(\.rawValue).sorted(), "record": value("--record") ?? "no"])
    return bridge
}
// the peer says these on its own queues: they go to the bridge in order, from the main queue
peer.send = { signal in
    let line = signal.json
    DispatchQueue.main.async { MainActor.assumeIsolated { bridge.send(["job": "live", "signal": line]) } }
}
peer.kept = { facts in
    DispatchQueue.main.async { MainActor.assumeIsolated { bridge.send(facts.merging(["job": "live"]) { $1 }) } }
}

// MARK: statistics, one line a second: CPU of this process, and per watcher and track what is sent

func cpuSeconds() -> Double {
    var usage = rusage()
    getrusage(RUSAGE_SELF, &usage)
    let t = { (v: timeval) in Double(v.tv_sec) + Double(v.tv_usec) / 1e6 }
    return t(usage.ru_utime) + t(usage.ru_stime)
}
var cpuBefore = (seconds: cpuSeconds(), at: Date())
var sentBefore: [String: (bytes: Double, frames: Double)] = [:]
let statsQueue = DispatchQueue(label: "stats")
let timer = DispatchSource.makeTimerSource(queue: statsQueue)
timer.schedule(deadline: .now() + 1, repeating: 1)
timer.setEventHandler {
    let now = Date(), cpu = cpuSeconds()
    let percent = (cpu - cpuBefore.seconds) / now.timeIntervalSince(cpuBefore.at) * 100
    let seconds = max(0.001, now.timeIntervalSince(cpuBefore.at))
    cpuBefore = (cpu, now)
    var rows: [String: Any] = [:]
    for watch in peer.state.watches {
        guard let pc = peer.connection(watch.id) else { continue }
        let done = DispatchSemaphore(value: 0)
        pc.statistics { report in
            let all = report.statistics
            let number = { (s: LKRTCStatistics, k: String) -> Double in (s.values[k] as? NSNumber)?.doubleValue ?? 0 }
            var tracks: [String: Any] = [:]
            for out in all.values where out.type == "outbound-rtp" {
                let track = (out.values["mediaSourceId"] as? String).flatMap { all[$0]?.values["trackIdentifier"] as? String } ?? "?"
                let key = "\(watch.id)/\(track)", bytes = number(out, "bytesSent"), frames = number(out, "framesSent")
                let before = sentBefore[key] ?? (0, 0)
                sentBefore[key] = (bytes, frames)
                var row: [String: Any] = ["kbps": Int((bytes - before.bytes) * 8 / 1000 / seconds)]
                if out.values["kind"] as? String == "video" {
                    row["fps"] = ((frames - before.frames) / seconds * 10).rounded() / 10
                    row["size"] = "\(Int(number(out, "frameWidth")))x\(Int(number(out, "frameHeight")))"
                    row["encoder"] = out.values["encoderImplementation"] as? String ?? "?"
                    row["limit"] = out.values["qualityLimitationReason"] as? String ?? "?"
                }
                tracks[track] = row
            }
            rows[String(watch.id.prefix(8))] = ["phase": "\(watch.phase)", "tracks": tracks]
            done.signal()
        }
        _ = done.wait(timeout: .now() + 0.5)
    }
    say(["stats": ["t": Int(now.timeIntervalSince(started)), "cpu": Int(percent.rounded()), "recording": recorder.trackIDs, "watchers": rows]])
}
timer.resume()

// MARK: run until --seconds, SIGINT or SIGTERM; each watcher hears bye first

func finish(_ why: String) {
    DispatchQueue.global().async {
        timer.cancel()
        peer.endAll(why: "the device stopped")
        // the byes go out, then the bridge's stdin closes and it ends
        DispatchQueue.main.async { MainActor.assumeIsolated { bridge.closeInput() } }
        _ = bridgeEnded.wait(timeout: .now() + 10)
        recorder.stop()
        say(["event": "stopped", "why": why, "seconds": Int(Date().timeIntervalSince(started))])
        exit(0)
    }
}
signal(SIGINT, SIG_IGN)
signal(SIGTERM, SIG_IGN)
let signalSources = [SIGINT, SIGTERM].map { number -> DispatchSourceSignal in
    let source = DispatchSource.makeSignalSource(signal: number, queue: .main)
    source.setEventHandler { finish("signal \(number)") }
    source.resume()
    return source
}
if let seconds = value("--seconds").flatMap(Double.init) {
    DispatchQueue.main.asyncAfter(deadline: .now() + seconds) { finish("time") }
}
withExtendedLifetime(signalSources) { RunLoop.main.run() }
