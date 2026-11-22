import CoreMedia
import Foundation
import LiveKitWebRTC
import Record
import VoiceMeetCore

/// THIS MAC AS A WEBRTC PEER (README, "Live"): a watcher's page sees its screens, its camera and
/// hears its microphone, peer to peer, while the mind carries only the signalling. It is a sink of
/// the recorder's capture (`CaptureSink`): the same frames as the record, no copy. One peer
/// connection per watcher (at most `LiveWatchers.most`), send only; the device offers. The signalling's
/// rules are `LiveWatchers` (VoiceMeetCore); this class runs their effects.
///
/// Track ids are the record's: `screen-<display>`, `camera-0`, `mic-0`, and `test-1`, `test-2` for
/// the synthetic source. Live shows one camera and one sound: the first camera and the first
/// microphone that deliver are `camera-0` and `mic-0`.
///
/// Everything runs on one queue; the callbacks are called there.
public final class LivePeer: NSObject, CaptureSink, @unchecked Sendable {
    /// Which tracks a watcher gets: the app asks the owner's switches. Answer `(tracks, reason)`;
    /// no track ends the watch with `bye` and the reason.
    public var decide: (_ watcher: String, _ who: String, _ answer: @escaping ([String], String) -> Void) -> Void = { _, _, answer in answer([], "nothing to show") }
    /// A signal for one watcher: the bridge appends it to `/devices/<name>`.
    public var send: (LiveSignal) -> Void = { _ in }
    /// The two kept events of a watch, for the bridge: `{ started: { watcher, who, tracks } }` and
    /// `{ ended: { watcher, who, seconds, why } }`.
    public var kept: ([String: Any]) -> Void = { _ in }
    public var started: (_ watcher: String, _ who: String, _ tracks: [String]) -> Void = { _, _, _ in }
    public var ended: (_ watcher: String, _ who: String, _ seconds: Int, _ why: String) -> Void = { _, _, _, _ in }
    /// The watchers changed: the capture runs for their tracks; the panel lists them.
    public var changed: (_ watchers: LiveWatchers) -> Void = { _ in }
    public var log: (String) -> Void = { _ in }

    private let work = DispatchQueue(label: "live")
    private var watchers = LiveWatchers()
    private let factory: LKRTCPeerConnectionFactory
    private let soundDevice = SoundDevice()
    private let soundTrack: LKRTCAudioTrack
    private var connections: [String: Connection] = [:]
    private var iceServers: [LKRTCIceServer]
    private let stun: [LKRTCIceServer]
    private let loopbackOnly: Bool
    private let constraints = LKRTCMediaConstraints(mandatoryConstraints: nil, optionalConstraints: nil)

    /// Touched from the capture queues: under `lock`.
    private let lock = NSLock()
    private var pictures: [String: (source: LKRTCVideoSource, capturer: LKRTCVideoCapturer, track: LKRTCVideoTrack)] = [:]
    /// The sound track offered now (`mic-0` or `test-2`), and the capture tracks that feed
    /// `camera-0` and `mic-0`.
    private var hearing: String?
    private var feeds: [String: String] = [:]

    /// `loopbackOnly`: candidates on 127.0.0.1 alone, for a watcher on this Mac (no packet to the
    /// local network). `stun`: false for no STUN server until `setIceServers`.
    public init(loopbackOnly: Bool = false, stun: Bool = true) {
        _ = LivePeer.initializeOnce
        self.loopbackOnly = loopbackOnly
        factory = LKRTCPeerConnectionFactory(
            encoderFactory: LKRTCDefaultVideoEncoderFactory(), decoderFactory: LKRTCDefaultVideoDecoderFactory(), audioDevice: soundDevice)
        if loopbackOnly {
            let options = LKRTCPeerConnectionFactoryOptions()
            options.ignoreLoopbackNetworkAdapter = false
            options.ignoreWiFiNetworkAdapter = true
            options.ignoreEthernetNetworkAdapter = true
            options.ignoreVPNNetworkAdapter = true
            options.ignoreCellularNetworkAdapter = true
            factory.setOptions(options)
        }
        self.stun = stun ? [LKRTCIceServer(urlStrings: ["stun:stun.cloudflare.com:3478", "stun:stun.l.google.com:19302"])] : []
        iceServers = self.stun
        soundTrack = factory.audioTrack(with: factory.audioSource(with: nil), trackId: "sound")
        // The samples are the capture's own (Apple's voice processing, or a test tone): libwebrtc's
        // echo canceller, noise suppressor, gain control and high-pass filter stay off.
        _ = soundTrack.setAudioProcessingOptions(.raw())
        super.init()
    }

    /// Once per process, before the first factory: every video packet asks the watcher to show it
    /// at once (the RTP playout-delay extension, min 0, max 0). Measured: 15 to 40 ms from drawn
    /// to shown, against about 180 ms with the browser's own playout.
    private static let initializeOnce: Void = {
        // deprecated, and the one the measurements were made with
        LKRTCInitFieldTrialDictionary(["WebRTC-ForceSendPlayoutDelay": "min_ms:0,max_ms:0"])
        LKRTCInitializeSSL()
        LKRTCSetMinDebugLogLevel(.error)
    }()

    // MARK: - From the bridge and the app

    /// One `device/live-signal` to the device: `{ from, want | description | candidate | bye }`.
    /// `who` is the event's source as a short name.
    public func heard(_ signal: [String: Any], who: String) {
        work.async {
            guard let from = signal["from"] as? String, !from.isEmpty else { return }
            let now = Date()
            if signal["want"] as? Bool == true {
                self.run(self.watchers.want(from: from, who: who, now: now))
            } else if signal["bye"] != nil {
                // the page says why it left ("you turned Live off", "the page was hidden", an error)
                let reason = (signal["reason"] as? String).map { String($0.prefix(200)) }
                self.run(self.watchers.end(from, why: reason.map { "the watcher left: \($0)" } ?? "the watcher left", tell: false, now: now))
            } else if let d = signal["description"] as? [String: Any], d["type"] as? String == "answer", let sdp = d["sdp"] as? String {
                self.run(self.watchers.answer(from: from, sdp: sdp))
            } else if let c = signal["candidate"] as? [String: Any], let line = c["candidate"] as? String, !line.isEmpty,
                // loopback alone: a watcher's `.local` name is not resolved (that asks the local network)
                !(self.loopbackOnly && line.contains(".local"))
            {
                let candidate = LiveCandidate(candidate: line, sdpMid: c["sdpMid"] as? String, sdpMLineIndex: (c["sdpMLineIndex"] as? Int) ?? 0)
                self.run(self.watchers.candidate(from: from, candidate))
            }
        }
    }

    /// The addresses a connection may use (STUN, TURN): `[{ urls, username?, credential? }]`, for
    /// every peer connection made after. None: STUN alone.
    public func setIceServers(_ servers: [[String: Any]]) {
        work.async {
            let made = servers.compactMap { server -> LKRTCIceServer? in
                let urls = (server["urls"] as? [String]) ?? (server["urls"] as? String).map { [$0] } ?? []
                return urls.isEmpty ? nil : LKRTCIceServer(urlStrings: urls, username: server["username"] as? String, credential: server["credential"] as? String)
            }
            self.iceServers = made.isEmpty ? self.stun : made
            self.log("live: \(self.iceServers.count) ICE servers: \(self.iceServers.flatMap(\.urlStrings).map { $0.components(separatedBy: "?")[0] }.joined(separator: ", "))")
        }
    }

    /// The owner's button, or the Mac is no longer lent: the watcher hears `bye` with `why`.
    public func end(_ watcher: String, why: String) {
        work.async { self.run(self.watchers.end(watcher, why: why, tell: true, now: Date())) }
    }

    public func endAll(why: String) {
        work.sync { run(watchers.endAll(why: why, now: Date())) }
    }

    /// The watchers now.
    public var state: LiveWatchers { work.sync { watchers } }

    /// The peer connection of a watcher, for its statistics (`live-run`).
    public func connection(_ watcher: String) -> LKRTCPeerConnection? { work.sync { connections[watcher]?.pc } }

    // MARK: - The effects of the signalling

    private func run(_ effects: [LiveEffect]) {
        for effect in effects {
            switch effect {
            case let .decide(id, who):
                decide(id, who) { tracks, reason in
                    self.work.async {
                        self.run(self.watchers.decided(id, tracks: tracks, reason: reason))
                        self.watchersChanged()
                    }
                }
            case let .makeOffer(id, tracks):
                offer(id, tracks)
            case let .send(signal):
                send(signal)
            case let .setAnswer(id, sdp):
                guard let connection = connections[id] else { continue }
                connection.remoteSet = false
                // A screen is larger than the level a browser answers by default (LiveAnswer).
                connection.pc.setRemoteDescription(LKRTCSessionDescription(type: .answer, sdp: LiveAnswer.raisingH264Level(sdp))) { error in
                    self.work.async {
                        if let error { self.log("live: \(id.prefix(8)): the answer was refused: \(error.localizedDescription)") }
                        connection.remoteSet = true
                        for candidate in connection.early { connection.pc.add(candidate) { _ in } }
                        connection.early = []
                    }
                }
            case let .addCandidate(id, c):
                guard let connection = connections[id] else { continue }
                let candidate = LKRTCIceCandidate(sdp: c.candidate, sdpMLineIndex: Int32(c.sdpMLineIndex), sdpMid: c.sdpMid)
                if connection.remoteSet { connection.pc.add(candidate) { _ in } } else { connection.early.append(candidate) }
            case let .close(id):
                connections.removeValue(forKey: id)?.pc.close()
                watchersChanged()
            case let .started(id, who, tracks):
                log("live: \(who) watches (\(id.prefix(8))): \(tracks.joined(separator: ", "))")
                kept(["started": ["watcher": id, "who": who, "tracks": tracks]])
                started(id, who, tracks)
                watchersChanged()
            case let .ended(id, who, seconds, why):
                log("live: \(who) watched \(seconds) s (\(id.prefix(8))): \(why)")
                kept(["ended": ["watcher": id, "who": who, "seconds": seconds, "why": why]])
                ended(id, who, seconds, why)
            }
        }
    }

    /// On `work`: the pictures and the sound follow the watchers' tracks; the app hears of it.
    private func watchersChanged() {
        let tracks = watchers.tracks
        lock.withLock {
            pictures = pictures.filter { tracks.contains($0.key) }
            hearing = tracks.first { $0 == "mic-0" || $0 == "test-2" }
        }
        changed(watchers)
    }

    /// On `work`: the watcher's peer connection: each of its tracks, send only, and the offer.
    private func offer(_ id: String, _ tracks: [String]) {
        let configuration = LKRTCConfiguration()
        configuration.sdpSemantics = .unifiedPlan
        configuration.iceServers = iceServers
        configuration.tcpCandidatePolicy = .disabled
        configuration.bundlePolicy = .maxBundle
        configuration.rtcpMuxPolicy = .require
        configuration.continualGatheringPolicy = .gatherOnce
        let connection = Connection(id: id, peer: self)
        guard let pc = factory.peerConnection(with: configuration, constraints: constraints, delegate: connection) else {
            return run(watchers.end(id, why: "no peer connection", tell: true, now: Date()))
        }
        connection.pc = pc
        connections[id] = connection
        // H.264 in hardware: High before Constrained Baseline, the other codecs after.
        let codecs = factory.rtpSenderCapabilities(forKind: "video").codecs
        let h264 = codecs.filter { $0.name.uppercased() == "H264" }
        let high = h264.filter { ($0.parameters["profile-level-id"] ?? "").hasPrefix("64") }
        let preferred = high + h264.filter { !high.contains($0) } + codecs.filter { $0.name.uppercased() != "H264" }
        var sent: [(LKRTCRtpTransceiver, String)] = []
        for track in tracks {
            let setup = LKRTCRtpTransceiverInit()
            setup.direction = .sendOnly
            if track == "mic-0" || track == "test-2" {
                // The sound in a stream of its own: the watcher does not hold it back for lip sync
                // (measured: lip sync held it about 140 ms, with the picture shown at once).
                setup.streamIds = ["device-sound"]
                if let transceiver = pc.addTransceiver(with: soundTrack, init: setup) { sent.append((transceiver, track)) }
                continue
            }
            setup.streamIds = ["device"]
            guard let transceiver = pc.addTransceiver(with: picture(track), init: setup) else { continue }
            try? transceiver.setCodecPreferences(preferred, error: ())
            // A screen of text keeps its size and gives up frames first.
            let parameters = transceiver.sender.parameters
            parameters.degradationPreference = NSNumber(value: LKRTCDegradationPreference.maintainResolution.rawValue)
            transceiver.sender.parameters = parameters
            sent.append((transceiver, track))
        }
        pc.offer(for: constraints) { offer, error in
            guard let offer else {
                return self.work.async { self.run(self.watchers.end(id, why: "no offer: \(String(describing: error))", tell: true, now: Date())) }
            }
            pc.setLocalDescription(offer) { error in
                self.work.async {
                    if let error { return self.run(self.watchers.end(id, why: "no offer: \(error.localizedDescription)", tell: true, now: Date())) }
                    var mids: [String: String] = [:]
                    for (transceiver, track) in sent where !transceiver.mid.isEmpty { mids[transceiver.mid] = track }
                    self.run(self.watchers.offerMade(id, sdp: offer.sdp, mids: mids))
                }
            }
        }
    }

    /// On `work`: the video track of a capture track, shared by every watcher.
    private func picture(_ id: String) -> LKRTCVideoTrack {
        lock.withLock {
            if let made = pictures[id] { return made.track }
            // a camera is a person's picture; a screen or the test picture is a screencast
            let source = factory.videoSource(forScreenCast: !id.hasPrefix("camera-"))
            let made = (source: source, capturer: LKRTCVideoCapturer(delegate: source), track: factory.videoTrack(with: source, trackId: id))
            pictures[id] = made
            return made.track
        }
    }

    fileprivate func connection(_ id: String, changed state: LKRTCPeerConnectionState) {
        work.async {
            guard self.connections[id] != nil else { return }
            if state == .connected { self.run(self.watchers.connected(id, now: Date())) }
            if state == .failed { self.run(self.watchers.end(id, why: "connection failed", tell: true, now: Date())) }
        }
    }

    fileprivate func connection(_ id: String, made candidate: LKRTCIceCandidate) {
        let c = LiveCandidate(candidate: candidate.sdp, sdpMid: candidate.sdpMid, sdpMLineIndex: Int(candidate.sdpMLineIndex))
        work.async { self.run(self.watchers.deviceCandidate(id, c)) }
    }

    // MARK: - CaptureSink: on the capture's queues

    /// The live track a capture track feeds: the first camera and the first microphone that
    /// deliver are `camera-0` and `mic-0`; the others are themselves.
    private func live(_ track: String) -> String {
        for (prefix, name) in [("camera-", "camera-0"), ("mic-", "mic-0")] where track.hasPrefix(prefix) {
            if feeds[name] == nil { feeds[name] = track }
            return feeds[name] == track ? name : ""
        }
        return track
    }

    public func video(_ track: String, _ frame: CVPixelBuffer, hostTime: CMTime) {
        guard let picture = lock.withLock({ pictures[live(track)] }) else { return }
        // libwebrtc's clock is the host clock too
        let nanos = CMTimeConvertScale(hostTime, timescale: 1_000_000_000, method: .roundHalfAwayFromZero).value
        picture.source.capturer(picture.capturer, didCapture: LKRTCVideoFrame(buffer: LKRTCCVPixelBuffer(pixelBuffer: frame), rotation: ._0, timeStampNs: nanos))
    }

    public func sound(_ track: String, _ sample: CMSampleBuffer, hostTime: CMTime) {
        guard lock.withLock({ hearing != nil && live(track) == hearing }) else { return }
        soundDevice.put(sample)
    }

    public func ended(_ track: String) {
        lock.withLock { feeds = feeds.filter { $0.value != track } }
    }
}

/// One watcher's peer connection and its delegate.
private final class Connection: NSObject, LKRTCPeerConnectionDelegate {
    let id: String
    weak var peer: LivePeer?
    var pc: LKRTCPeerConnection!
    /// Candidates of the watcher that wait for the answer to be set.
    var early: [LKRTCIceCandidate] = []
    var remoteSet = false

    init(id: String, peer: LivePeer) {
        self.id = id
        self.peer = peer
    }

    func peerConnection(_ peerConnection: LKRTCPeerConnection, didGenerate candidate: LKRTCIceCandidate) { peer?.connection(id, made: candidate) }
    func peerConnection(_ peerConnection: LKRTCPeerConnection, didChange newState: LKRTCPeerConnectionState) { peer?.connection(id, changed: newState) }
    func peerConnection(_ peerConnection: LKRTCPeerConnection, didChange stateChanged: LKRTCSignalingState) {}
    func peerConnection(_ peerConnection: LKRTCPeerConnection, didAdd stream: LKRTCMediaStream) {}
    func peerConnection(_ peerConnection: LKRTCPeerConnection, didRemove stream: LKRTCMediaStream) {}
    func peerConnectionShouldNegotiate(_ peerConnection: LKRTCPeerConnection) {}
    func peerConnection(_ peerConnection: LKRTCPeerConnection, didChange newState: LKRTCIceConnectionState) {}
    func peerConnection(_ peerConnection: LKRTCPeerConnection, didChange newState: LKRTCIceGatheringState) {}
    func peerConnection(_ peerConnection: LKRTCPeerConnection, didRemove candidates: [LKRTCIceCandidate]) {}
    func peerConnection(_ peerConnection: LKRTCPeerConnection, didOpen dataChannel: LKRTCDataChannel) {}
}
