import CoreMedia
import Foundation
import LiveKitWebRTC
import Live
import Record
import VoiceMeetCore

// call-run: this Mac in a call, from a terminal, for tests and measurements (README, "A call's
// camera or screen from this Mac"). The app's own Record and Live libraries and its bridge, with
// the synthetic picture alone: no screen, no camera, no microphone, no switch and no question.
//
//   call-run --context <agent> --node <node> --bridge <bridge/mind.mjs> --iterate <iterate.js> --mind <address>
//            [--device <name>] [--seconds N] [--no-receive] [--no-prepare] [--choose-after MS] [--warm]
//            [--answer-at-once] [--still]
//
// It joins the call on <agent> twice through the bridge's job `call`, as the person the iterate
// CLI signed in: a receiver first (a page already in the call, as another person's page is), then
// the sender, which publishes the synthetic picture (`test-1`, 1280×720, its wall time as a strip
// of 48 bits) as a screen from `CallSender`. The receiver subscribes to it through the SFU as a
// page does, decodes the frames and reads the time strip back. stdout: one JSON line for each step
// with its milliseconds from the start, then one a second with the frames received and the
// picture's delay (the receiver's clock minus the strip's: the same Mac's clock).
//
// As meet's page does, the sender prepares a spare connection when "the picker opens" (after the
// receiver joined), and the choice comes `--choose-after` ms later (1500): the join and the offer
// then go at once. `--no-prepare`: no spare, and the join, the offer and the publish one after the
// other. `--warm`: the receiver first receives another picture of the Mac (a `camera`, as a page in
// a call already receives the member's camera or microphone), so the screen's subscribe uses a
// connection that is connected already. `--answer-at-once`: the receiver's answer goes without its
// candidates (the SFU is ICE lite: it learns the page's address from the page's own checks).
// `--still`: one frame at the start, then none, as a screen that does not change. The times are from the
// choice.
var arguments = Array(CommandLine.arguments.dropFirst())
func value(_ flag: String) -> String? {
    guard let i = arguments.firstIndex(of: flag), i + 1 < arguments.count else { return nil }
    return arguments[i + 1]
}
guard let context = value("--context"), let node = value("--node"), let bridgeScript = value("--bridge"), let iterate = value("--iterate"), let mind = value("--mind") else {
    FileHandle.standardError.write(Data("call-run --context <agent> --node <node> --bridge <mind.mjs> --iterate <iterate.js> --mind <address> [--device <name>] [--seconds N] [--no-receive]\n".utf8))
    exit(2)
}
let device = value("--device") ?? "call-run"
let prepares = !arguments.contains("--no-prepare")
let warm = arguments.contains("--warm")
let still = arguments.contains("--still")
let answersAtOnce = arguments.contains("--answer-at-once")
let chooseAfter = Double(value("--choose-after") ?? "1500") ?? 1500
let seconds = Double(value("--seconds") ?? "20") ?? 20
let receives = !arguments.contains("--no-receive")
let started = Date()
let outLock = NSLock()
func ms() -> Int { Int(Date().timeIntervalSince(started) * 1000) }
func say(_ line: [String: Any]) {
    var line = line
    line["ms"] = ms()
    guard let data = try? JSONSerialization.data(withJSONObject: line, options: [.sortedKeys, .withoutEscapingSlashes]) else { return }
    outLock.withLock { FileHandle.standardOutput.write(data + Data("\n".utf8)) }
}
recordLog = { FileHandle.standardError.write(Data("\($0)\n".utf8)) }

// THE SENDER: the recorder's synthetic picture, for live alone (nothing is written), into the sender
let spool = NSTemporaryDirectory() + "call-run-\(ProcessInfo.processInfo.processIdentifier)"
let recorder = Recorder(options: RecordOptions(spool: URL(fileURLWithPath: spool), device: device))
let sender = CallSender()
sender.log = { FileHandle.standardError.write(Data("\($0)\n".utf8)) }
/// `--still`: a screen that does not change. ScreenCaptureKit gives one whole frame when its
/// stream starts, and none while nothing changes: so the sender gets the first frame that it sends
/// (its track is there), then no more.
final class StillSink: CaptureSink {
    let to: CallSender
    private var gave = false
    init(_ to: CallSender) { self.to = to }
    func video(_ track: String, _ frame: CVPixelBuffer, hostTime: CMTime) {
        guard !gave, to.tracks.contains(track) else { return }
        gave = true
        to.video(track, frame, hostTime: hostTime)
    }
    func sound(_ track: String, _ sample: CMSampleBuffer, hostTime: CMTime) {}
    func ended(_ track: String) { to.ended(track) }
}
let stillSink = StillSink(sender)
recorder.add(sink: still ? stillSink : sender)
recorder.start()
recorder.watch([.synthetic])

/// THE RECEIVER: a page of the call that subscribes to the sender's track and reads each frame.
final class Receiver: NSObject, LKRTCPeerConnectionDelegate {
    let factory = CallSender.silentFactory()
    var pc: LKRTCPeerConnection?
    let lock = NSLock()
    var frames = 0
    var firstAt: Int?
    /// The mid whose first frame is measured (the choice's screen), and the mids seen.
    var measured: String?
    var firstOf: [String: Int] = [:]
    /// The first frame of another mid (`--warm`'s camera): the run goes on.
    var warmed: (() -> Void)?
    var delays: [Double] = []
    var size = (0, 0)
    var gathered: (() -> Void)?
    /// A candidate that is not the host's came: the answer goes 300 ms later.
    var soon = false
    /// The tracks drawn: libwebrtc's wrapper of a track takes its renderers away when it is freed.
    var drawn: [(track: LKRTCVideoTrack, tile: Tile)] = []

    func draw(_ track: LKRTCVideoTrack?, mid: String) {
        guard let track, !drawn.contains(where: { $0.track.trackId == track.trackId }) else { return }
        let tile = Tile(mid: mid, receiver: self)
        drawn.append((track, tile))
        track.add(tile)
    }

    func connect(_ iceServers: [[String: Any]]) {
        let configuration = LKRTCConfiguration()
        configuration.sdpSemantics = .unifiedPlan
        configuration.iceServers = iceServers.compactMap { server in
            let urls = (server["urls"] as? [String]) ?? (server["urls"] as? String).map { [$0] } ?? []
            return urls.isEmpty ? nil : LKRTCIceServer(urlStrings: urls, username: server["username"] as? String, credential: server["credential"] as? String)
        }
        configuration.bundlePolicy = .maxBundle
        configuration.tcpCandidatePolicy = .disabled
        pc = factory.peerConnection(with: configuration, constraints: LKRTCMediaConstraints(mandatoryConstraints: nil, optionalConstraints: nil), delegate: self)
    }

    /// The SFU's offer answered; `done` hears the answer with its candidates.
    func answer(_ offer: String, done: @escaping (String) -> Void) {
        guard let pc else { return }
        pc.setRemoteDescription(LKRTCSessionDescription(type: .offer, sdp: CallSDP.udpOnly(offer))) { error in
            if let error { return say(["step": "receiver: the SFU's offer was refused", "error": error.localizedDescription]) }
            // each video receiver the offer made draws into this receiver
            for transceiver in pc.transceivers {
                say(["step": "receiver: a transceiver", "kind": transceiver.receiver.track?.kind ?? "none"])
                self.draw(transceiver.receiver.track as? LKRTCVideoTrack, mid: transceiver.mid)
            }
            pc.answer(for: LKRTCMediaConstraints(mandatoryConstraints: nil, optionalConstraints: nil)) { answer, _ in
                guard let answer else { return say(["step": "receiver: no answer"]) }
                pc.setLocalDescription(answer) { _ in
                    // as the kit's `gathered`: complete, 300 ms after the first candidate that is
                    // not the host's, or 2 s at most
                    self.lock.withLock { self.gathered = { done(CallSDP.udpOnly(pc.localDescription?.sdp ?? answer.sdp)) } }
                    if answersAtOnce || pc.iceGatheringState == .complete || self.lock.withLock({ self.soon }) { return self.done() }
                    DispatchQueue.global().asyncAfter(deadline: .now() + 2) { self.done() }
                }
            }
        }
    }

    private func done() {
        lock.lock()
        let go = gathered
        gathered = nil
        lock.unlock()
        go?()
    }

    // a frame: its time strip read back from the luma, at the top or the bottom row of blocks
    func frame(_ frame: LKRTCVideoFrame?, mid: String) {
        guard let frame else { return }
        let now = Date().timeIntervalSince1970 * 1000
        let i420 = frame.buffer.toI420()
        let w = Int(i420.width), h = Int(i420.height)
        let scale = Double(w) / 1280
        var read: Int64?
        for row in [Int(20 * scale), h - Int(20 * scale)] where row >= 0 && row < h {
            var ms: Int64 = 0
            for bit in 0..<48 {
                let x = Int((32 + Double(bit) * 24 + 12) * scale)
                let luma = i420.dataY[row * Int(i420.strideY) + min(x, w - 1)]
                ms = ms << 1 | (luma > 128 ? 1 : 0)
            }
            if abs(Double(ms) - now) < 60_000 { read = ms }
        }
        var warmedNow: (() -> Void)?
        lock.withLock {
            if firstOf[mid] == nil {
                firstOf[mid] = ms()
                if mid != measured {
                    say(["step": "receiver: first frame of another picture", "mid": mid])
                    warmedNow = warmed
                    warmed = nil
                }
            }
            guard mid == measured else { return }
            frames += 1
            size = (w, h)
            if firstAt == nil {
                firstAt = ms()
                say(["step": "receiver: first frame", "width": w, "height": h, "mid": mid])
            }
            if let read { delays.append(now - Double(read)) }
        }
        warmedNow?()
    }

    func peerConnection(_ peerConnection: LKRTCPeerConnection, didStartReceivingOn transceiver: LKRTCRtpTransceiver) {}
    func peerConnection(_ peerConnection: LKRTCPeerConnection, didAdd rtpReceiver: LKRTCRtpReceiver, streams mediaStreams: [LKRTCMediaStream]) {
        say(["step": "receiver: a track", "kind": rtpReceiver.track?.kind ?? "none"])
        draw(rtpReceiver.track as? LKRTCVideoTrack, mid: peerConnection.transceivers.first { $0.receiver.receiverId == rtpReceiver.receiverId }?.mid ?? "")
    }
    func peerConnection(_ peerConnection: LKRTCPeerConnection, didChange newState: LKRTCPeerConnectionState) {
        say(["step": "receiver: connection \(newState.rawValue)"])
    }
    func peerConnection(_ peerConnection: LKRTCPeerConnection, didChange newState: LKRTCIceGatheringState) {
        if newState == .complete { done() }
    }
    func peerConnection(_ peerConnection: LKRTCPeerConnection, didChange stateChanged: LKRTCSignalingState) {}
    func peerConnection(_ peerConnection: LKRTCPeerConnection, didAdd stream: LKRTCMediaStream) {}
    func peerConnection(_ peerConnection: LKRTCPeerConnection, didRemove stream: LKRTCMediaStream) {}
    func peerConnectionShouldNegotiate(_ peerConnection: LKRTCPeerConnection) {}
    func peerConnection(_ peerConnection: LKRTCPeerConnection, didChange newState: LKRTCIceConnectionState) {}
    func peerConnection(_ peerConnection: LKRTCPeerConnection, didGenerate candidate: LKRTCIceCandidate) {
        guard !candidate.sdp.contains(" typ host") else { return }
        let first = lock.withLock { () -> Bool in
            defer { soon = true }
            return !soon
        }
        if first { DispatchQueue.global().asyncAfter(deadline: .now() + 0.3) { self.done() } }
    }
    func peerConnection(_ peerConnection: LKRTCPeerConnection, didRemove candidates: [LKRTCIceCandidate]) {}
    func peerConnection(_ peerConnection: LKRTCPeerConnection, didOpen dataChannel: LKRTCDataChannel) {}
}
/// One received track's renderer: its frames go to the receiver with their mid.
final class Tile: NSObject, LKRTCVideoRenderer {
    let mid: String
    weak var receiver: Receiver?
    init(mid: String, receiver: Receiver) {
        self.mid = mid
        self.receiver = receiver
    }
    func renderFrame(_ frame: LKRTCVideoFrame?) { receiver?.frame(frame, mid: mid) }
    func setSize(_ size: CGSize) {}
}
let receiver = Receiver()

// THE BRIDGE: the app's own process for a mind; its job `call` alone
var publishedAt = 0
var senderPage = ""
let bridge = try MainActor.assumeIsolated { () throws -> JSONLineProcess in
    let bridge = JSONLineProcess(executable: node, arguments: [bridgeScript, mind, "--name", device, "--iterate", iterate])
    bridge.logged = { FileHandle.standardError.write(Data("bridge: \($0)\n".utf8)) }
    bridge.exited = { status in
        say(["step": "bridge exited", "status": Int(status)])
        exit(status == 0 ? 0 : 1)
    }
    try bridge.start()
    return bridge
}

/// A line of the job `call`.
@MainActor func toCall(_ fields: [String: Any]) {
    var line = fields
    line["job"] = "call"
    _ = bridge.send(line)
}

/// A publication's offer to the job, once made.
func sendOffer(_ id: String, ice: [[String: Any]]) {
    sender.offer(id, track: "test-1", iceServers: ice) { result in
        switch result {
        case let .success(offer):
            say(["step": "\(id): offer made", "bytes": offer.sdp.utf8.count])
            DispatchQueue.main.async {
                MainActor.assumeIsolated { toCall(["publication": id, "offer": ["sdp": offer.sdp, "mid": offer.mid]]) }
            }
        case let .failure(error): say(["step": "\(id): no offer", "error": error.description])
        }
    }
}

/// The pages of the publications: `tx` the measured screen, `warm` the camera before it.
var pages: [String: String] = [:]

/// "The picker opens": a spare connection for a screen, with no TURN server (as the app's first
/// call after it starts); the choice `chooseAfter` ms later.
func pickerOpens() {
    if prepares {
        say(["step": "picker opens: prepare"])
        sender.prepare("screen", iceServers: [])
    }
    DispatchQueue.main.asyncAfter(deadline: .now() + chooseAfter / 1000) { publish() }
}

/// The choice: with a spare, the join and the offer at once (as `DeviceCall`); else one after the other.
func publish() {
    publishedAt = ms()
    say(["step": "publish: the choice"])
    MainActor.assumeIsolated { toCall(["publication": "tx", "join": ["context": context, "kind": "screen", "device": device]]) }
    if prepares { sendOffer("tx", ice: []) }
}

sender.changed = { id, connected in say(["step": connected ? "sender: connected to the SFU" : "sender: the connection failed", "publication": id]) }
sender.firstFrame = { id in say(["step": "sender: first frame to the encoder", "publication": id]) }

MainActor.assumeIsolated {
    bridge.said = { line in
        guard (line["job"] as? String) == "call" else {
            if line["connected"] != nil || line["failed"] != nil { say(["bridge": line]) }
            return
        }
        let id = line["publication"] as? String ?? ""
        if let failed = line["failed"] { return say(["step": "\(id): failed", "error": failed]) }
        if let gone = line["gone"] { return say(["step": "\(id): gone", "why": gone]) }
        if let joined = line["joined"] as? [String: Any] {
            let ice = joined["iceServers"] as? [[String: Any]] ?? []
            say(["step": "\(id): joined", "page": joined["page"] ?? "", "iceServers": ice.count, "bridgeMs": joined["ms"] ?? NSNull()])
            pages[id] = joined["page"] as? String ?? ""
            if id == "rx" {
                receiver.connect(ice)
                if !warm { return pickerOpens() }
                receiver.warmed = { DispatchQueue.main.async { pickerOpens() } }
                return toCall(["publication": "warm", "join": ["context": context, "kind": "camera", "device": "\(device)-warm"]])
            }
            if id == "warm" || !prepares { sendOffer(id, ice: ice) }
            return
        }
        if let answer = line["answer"] as? [String: Any] {
            say(["step": "\(id): the SFU answered", "bridgeMs": answer["ms"] ?? NSNull(), "early": answer["early"] ?? NSNull()])
            sender.answer(id, sdp: answer["sdp"] as? String ?? "") { error in if let error { say(["step": "\(id): answer refused", "error": error.description]) } }
            // the track is in the call now: a page subscribes when the call's live state says so
            let kind = id == "warm" ? "camera" : "screen"
            if receives { toCall(["publication": "rx", "signal": ["subscribe": ["\(pages[id] ?? ""):\(kind)"], "layers": [:] as [String: String]]]) }
            return
        }
        if let signaled = line["signaled"] as? [String: Any], signaled["sdp"] == nil {
            return say(["step": "rx: renegotiated", "bridgeMs": line["ms"] ?? NSNull()])
        }
        if let signaled = line["signaled"] as? [String: Any], let offer = signaled["sdp"] as? String {
            let tracks = signaled["tracks"] as? [[String: Any]] ?? []
            say(["step": "rx: subscribed", "tracks": tracks, "bridgeMs": line["ms"] ?? NSNull(), "iceLite": offer.contains("a=ice-lite")])
            for track in tracks where (track["track"] as? String)?.hasSuffix(":screen") == true {
                receiver.lock.withLock { receiver.measured = track["mid"] as? String }
            }
            receiver.answer(offer) { sdp in
                say(["step": "rx: answer made"])
                DispatchQueue.main.async { MainActor.assumeIsolated { toCall(["publication": "rx", "signal": ["renegotiate": sdp]]) } }
            }
        }
    }
    if receives {
        toCall(["publication": "rx", "join": ["context": context, "listen": true, "device": "\(device)-receiver"]])
    } else {
        pickerOpens()
    }
}

// every 50 ms after the choice: the key frames, PLIs and frames of both ends, said when they change
var seen: [String: Any] = [:]
let watcher = DispatchSource.makeTimerSource(queue: .main)
watcher.schedule(deadline: .now() + 0.05, repeating: 0.05)
watcher.setEventHandler {
    guard publishedAt > 0, ms() - publishedAt < 6000 else { return }
    let note = { (side: String, report: LKRTCStatisticsReport?, type: String, keys: [String]) in
        var out: [String: Any] = [:]
        for stat in report?.statistics.values ?? [:].values where stat.type == type && (stat.values["kind"] as? String) == "video" {
            for key in keys { if let value = stat.values[key] { out[key] = value } }
        }
        DispatchQueue.main.async {
            let text = out.keys.sorted().map { "\($0)=\(out[$0]!)" }.joined(separator: " ")
            guard !out.isEmpty, (seen[side] as? String) != text else { return }
            seen[side] = text
            say(["counts": side, "values": out])
        }
    }
    sender.connection("tx")?.statistics { note("tx", $0, "outbound-rtp", ["keyFramesEncoded", "pliCount", "firCount", "framesSent"].filter { $0 != "framesSent" }) }
    receiver.pc?.statistics { note("rx", $0, "inbound-rtp", ["keyFramesDecoded", "pliCount", "firCount", "framesReceived"].filter { $0 != "framesReceived" }) }
}
watcher.resume()

// one line a second: the frames, the picture's delay; the end after `seconds`
var lastFrames = 0
let ticker = DispatchSource.makeTimerSource(queue: .main)
ticker.schedule(deadline: .now() + 1, repeating: 1)
ticker.setEventHandler {
    let (frames, delays, size, first) = receiver.lock.withLock { (receiver.frames, receiver.delays, receiver.size, receiver.firstAt) }
    receiver.lock.withLock { receiver.delays = [] }
    let sorted = delays.sorted()
    // the encoder's and the decoder's own counts: where the frames stop, when they do
    let pick = { (report: LKRTCStatisticsReport?, type: String, keys: [String]) -> [String: Any] in
        var out: [String: Any] = [:]
        for stat in report?.statistics.values ?? [:].values where stat.type == type && (stat.values["kind"] as? String) == "video" {
            for key in keys { if let value = stat.values[key] { out[key] = value } }
        }
        return out
    }
    sender.connection("tx")?.statistics { report in
        say(["sender": pick(report, "outbound-rtp", ["framesEncoded", "framesSent", "bytesSent", "encoderImplementation", "frameWidth", "frameHeight", "qualityLimitationReason", "keyFramesEncoded", "pliCount", "firCount"])])
    }
    receiver.pc?.statistics { report in
        say(["receiver": pick(report, "inbound-rtp", ["framesReceived", "framesDecoded", "packetsReceived", "bytesReceived", "decoderImplementation", "frameWidth", "nackCount", "pliCount", "keyFramesDecoded"])])
    }
    say([
        "fps": frames - lastFrames, "frames": frames, "size": "\(size.0)x\(size.1)",
        "delayMs": sorted.isEmpty ? NSNull() : ["p50": Int(sorted[sorted.count / 2]), "max": Int(sorted.last!)] as Any,
        "firstFrameAfterChoiceMs": first.map { $0 - publishedAt } as Any,
    ])
    lastFrames = frames
    if Date().timeIntervalSince(started) > seconds {
        ticker.cancel()
        MainActor.assumeIsolated {
            toCall(["publication": "tx", "leave": "call-run ends"])
            if warm { toCall(["publication": "warm", "leave": "call-run ends"]) }
            toCall(["publication": "rx", "leave": "call-run ends"])
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
            sender.close("tx")
            sender.close("warm")
            recorder.stop()
            MainActor.assumeIsolated { bridge.closeInput() }
        }
    }
}
ticker.resume()
RunLoop.main.run()
