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
//            [--device <name>] [--seconds N] [--no-receive]
//
// It joins the call on <agent> twice through the bridge's job `call`, as the person the iterate
// CLI signed in: a receiver first (a page already in the call, as another person's page is), then
// the sender, which publishes the synthetic picture (`test-1`, 1280×720, its wall time as a strip
// of 48 bits) as a screen from `CallSender`. The receiver subscribes to it through the SFU as a
// page does, decodes the frames and reads the time strip back. stdout: one JSON line for each step
// with its milliseconds from the start, then one a second with the frames received and the
// picture's delay (the receiver's clock minus the strip's: the same Mac's clock).
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
recorder.add(sink: sender)
recorder.start()
recorder.watch([.synthetic])

/// THE RECEIVER: a page of the call that subscribes to the sender's track and reads each frame.
final class Receiver: NSObject, LKRTCPeerConnectionDelegate, LKRTCVideoRenderer {
    let factory = CallSender.silentFactory()
    var pc: LKRTCPeerConnection?
    let lock = NSLock()
    var frames = 0
    var firstAt: Int?
    var delays: [Double] = []
    var size = (0, 0)
    var gathered: (() -> Void)?
    /// The tracks drawn: libwebrtc's wrapper of a track takes its renderers away when it is freed.
    var drawn: [LKRTCVideoTrack] = []

    func draw(_ track: LKRTCVideoTrack?) {
        guard let track, !drawn.contains(where: { $0.trackId == track.trackId }) else { return }
        drawn.append(track)
        track.add(self)
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
                self.draw(transceiver.receiver.track as? LKRTCVideoTrack)
            }
            pc.answer(for: LKRTCMediaConstraints(mandatoryConstraints: nil, optionalConstraints: nil)) { answer, _ in
                guard let answer else { return say(["step": "receiver: no answer"]) }
                pc.setLocalDescription(answer) { _ in
                    self.gathered = { done(CallSDP.udpOnly(pc.localDescription?.sdp ?? answer.sdp)) }
                    DispatchQueue.global().asyncAfter(deadline: .now() + 1) { self.done() }
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
    func renderFrame(_ frame: LKRTCVideoFrame?) {
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
        lock.withLock {
            frames += 1
            size = (w, h)
            if firstAt == nil {
                firstAt = ms()
                say(["step": "receiver: first frame", "width": w, "height": h])
            }
            if let read { delays.append(now - Double(read)) }
        }
    }
    func setSize(_ size: CGSize) {}

    func peerConnection(_ peerConnection: LKRTCPeerConnection, didStartReceivingOn transceiver: LKRTCRtpTransceiver) {}
    func peerConnection(_ peerConnection: LKRTCPeerConnection, didAdd rtpReceiver: LKRTCRtpReceiver, streams mediaStreams: [LKRTCMediaStream]) {
        say(["step": "receiver: a track", "kind": rtpReceiver.track?.kind ?? "none"])
        draw(rtpReceiver.track as? LKRTCVideoTrack)
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
    func peerConnection(_ peerConnection: LKRTCPeerConnection, didGenerate candidate: LKRTCIceCandidate) {}
    func peerConnection(_ peerConnection: LKRTCPeerConnection, didRemove candidates: [LKRTCIceCandidate]) {}
    func peerConnection(_ peerConnection: LKRTCPeerConnection, didOpen dataChannel: LKRTCDataChannel) {}
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

/// The sender's publication: joined → offer → answer; then the receiver subscribes to its track.
func publish() {
    publishedAt = ms()
    say(["step": "publish: the choice"])
    MainActor.assumeIsolated { toCall(["publication": "tx", "join": ["context": context, "kind": "screen", "device": device]]) }
}

sender.changed = { _, connected in say(["step": connected ? "sender: connected to the SFU" : "sender: the connection failed"]) }
sender.firstFrame = { _ in say(["step": "sender: first frame to the encoder"]) }

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
            say(["step": "\(id): joined", "page": joined["page"] ?? "", "iceServers": ice.count])
            if id == "rx" {
                receiver.connect(ice)
                return publish()
            }
            senderPage = joined["page"] as? String ?? ""
            sender.offer("tx", track: "test-1", iceServers: ice) { result in
                switch result {
                case let .success(offer):
                    say(["step": "tx: offer made", "bytes": offer.sdp.utf8.count])
                    DispatchQueue.main.async {
                        MainActor.assumeIsolated { toCall(["publication": "tx", "offer": ["sdp": offer.sdp, "mid": offer.mid]]) }
                    }
                case let .failure(error): say(["step": "tx: no offer", "error": error.description])
                }
            }
            return
        }
        if let answer = line["answer"] as? [String: Any] {
            say(["step": "tx: the SFU answered"])
            sender.answer("tx", sdp: answer["sdp"] as? String ?? "") { error in if let error { say(["step": "tx: answer refused", "error": error.description]) } }
            // the track is in the call now: a page subscribes when the call's live state says so
            if receives { toCall(["publication": "rx", "signal": ["subscribe": ["\(senderPage):screen"], "layers": [:] as [String: String]]]) }
            return
        }
        if let signaled = line["signaled"] as? [String: Any], signaled["sdp"] == nil {
            return say(["step": "rx: renegotiated"])
        }
        if let signaled = line["signaled"] as? [String: Any], let offer = signaled["sdp"] as? String {
            say(["step": "rx: subscribed", "tracks": signaled["tracks"] ?? []])
            receiver.answer(offer) { sdp in
                DispatchQueue.main.async { MainActor.assumeIsolated { toCall(["publication": "rx", "signal": ["renegotiate": sdp]]) } }
            }
        }
    }
    if receives {
        toCall(["publication": "rx", "join": ["context": context, "listen": true, "device": "\(device)-receiver"]])
    } else {
        publish()
    }
}

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
        say(["sender": pick(report, "outbound-rtp", ["framesEncoded", "framesSent", "bytesSent", "encoderImplementation", "frameWidth", "frameHeight", "qualityLimitationReason"])])
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
            toCall(["publication": "rx", "leave": "call-run ends"])
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
            sender.close("tx")
            recorder.stop()
            MainActor.assumeIsolated { bridge.closeInput() }
        }
    }
}
ticker.resume()
RunLoop.main.run()
