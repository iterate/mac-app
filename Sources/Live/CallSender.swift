import CoreMedia
import Foundation
import LiveKitWebRTC
import Record
import VoiceMeetCore

/// THIS MAC'S PICTURES IN CALLS (README, "A call's camera or screen from this Mac"): a screen or
/// the camera, sent to a call's Cloudflare Realtime SFU as a page of the call sends its own. A
/// sink of the recorder's capture (`CaptureSink`), as live is: the same frames, no second capture.
///
/// One peer connection for each publication, send only, one video track, H.264 in hardware. The
/// call facet makes every SFU call: this class makes the offer (`offer`), the job `call` of the
/// mind's process hands it to the facet's `signal`, and the SFU's answer comes back (`answer`). The
/// SFU takes no trickled candidate: the offer waits for its candidates, as the kit's does.
///
/// - A screen goes at most 1920 × 1200 and 15 frames a second, 2.5 Mb/s at most, keeping its size
///   before its frames.
/// - A still screen gives no frames. So the last frame goes again when the connection connects
///   and when no frame came for `repeatAfter`: the encoder has a frame for each key frame that a
///   page asks for (a PLI), and a new page sees the picture at once.
/// - `prepare` makes a connection and its offer before the choice (when meet's device picker
///   opens): a choice then only adds the track. It reads no screen and no camera. A spare that is
///   not used ends after `spareLife`.
/// - The camera goes in three layers, `f`, `h`, `q` (1280, 640 and 320 wide), as the kit sends a
///   browser's camera, so every page takes the layer that fits its tile.
///
/// Track ids are the record's: `screen-<display>`, `camera-0` (the first camera that delivers), and
/// `test-1` for the synthetic picture. Everything runs on one queue; the callbacks are called there.
public final class CallSender: NSObject, CaptureSink, @unchecked Sendable {
    /// A publication's peer connection connected to the SFU, or failed: `connected` true or false.
    public var changed: (_ publication: String, _ connected: Bool) -> Void = { _, _ in }
    /// The first frame of a publication went to its encoder after the connection connected.
    public var firstFrame: (_ publication: String) -> Void = { _ in }
    public var log: (String) -> Void = { _ in }

    private let work = DispatchQueue(label: "call")
    private let factory: LKRTCPeerConnectionFactory
    private let constraints = LKRTCMediaConstraints(mandatoryConstraints: nil, optionalConstraints: nil)
    private var publications: [String: Publication] = [:]

    /// Touched from the capture queues: under `lock`.
    private let lock = NSLock()
    private var pictures: [String: (source: LKRTCVideoSource, capturer: LKRTCVideoCapturer, track: LKRTCVideoTrack, users: Int)] = [:]
    /// A screen's size the adapter was last set for, by track.
    private var adapted: [String: (Int, Int)] = [:]
    /// The publications waiting for their first frame since they connected, by track.
    private var waitingFrame: [String: Set<String>] = [:]
    private var feeds: [String: String] = [:]
    /// The newest frame of each sent track and when it went to the encoder, for the repeats.
    private var last: [String: (frame: CVPixelBuffer, at: Double)] = [:]
    private var repeater: DispatchSourceTimer?
    /// The connections made by `prepare`, by kind (`screen`, `camera`): on `work`.
    private var spares: [String: Publication] = [:]
    /// A still screen's last frame goes again after this many seconds with no frame.
    static let repeatAfter = 0.2
    /// A spare connection that no choice took ends after this many seconds.
    public static let spareLife = 60.0

    public override init() {
        factory = Self.silentFactory()
        super.init()
    }

    /// A factory with live's own audio device (`SoundDevice`), to which nobody pushes sound here:
    /// libwebrtc opens no microphone and no speaker.
    public static func silentFactory() -> LKRTCPeerConnectionFactory {
        _ = initializeOnce
        return LKRTCPeerConnectionFactory(encoderFactory: LKRTCDefaultVideoEncoderFactory(), decoderFactory: LKRTCDefaultVideoDecoderFactory(), audioDevice: SoundDevice())
    }

    private static let initializeOnce: Void = {
        LKRTCInitializeSSL()
        LKRTCSetMinDebugLogLevel(.error)
    }()

    /// The tracks sent now: the recorder runs their sources.
    public var tracks: Set<String> { lock.withLock { Set(pictures.keys) } }

    // MARK: - From the app and the job `call`

    /// A publication's peer connection and its offer: `track` (`screen-<id>`, `camera-0`,
    /// `test-1`) as the facet's `kind`, through `iceServers` (`[{ urls, username?, credential? }]`).
    /// `made` hears the offer with its candidates and the mid, or an error in words.
    public func offer(_ id: String, track: String, iceServers: [[String: Any]], made: @escaping (Result<(sdp: String, mid: String), CallSenderError>) -> Void) {
        work.async {
            let camera = track.hasPrefix("camera-")
            // a spare of this kind, made when the picker opened: it takes the track and its offer
            // goes as it is (the servers of the join come with `setIceServers`)
            if let spare = self.spares.removeValue(forKey: camera ? "camera" : "screen") {
                spare.id = id
                spare.track = track
                self.publications[id] = spare
                spare.transceiver?.sender.track = self.picture(track, camera: camera)
                self.log("\(id): the spare connection of \(Int((Date().timeIntervalSince1970 - spare.made) * 1000)) ms ago takes \(track)")
                return spare.whenOffered(made)
            }
            guard let publication = self.connect(id, track: track, camera: camera, iceServers: iceServers) else {
                return made(.failure(CallSenderError("no peer connection")))
            }
            publication.whenOffered(made)
        }
    }

    /// A connection and its offer for a later choice of `kind` (`screen` or `camera`), with no
    /// track: no frame is read. One of each kind; it ends after `spareLife` when no choice took it.
    public func prepare(_ kind: String, iceServers: [[String: Any]]) {
        work.async {
            guard ["screen", "camera"].contains(kind), self.spares[kind] == nil else { return }
            guard let spare = self.connect("spare-\(kind)", track: "", camera: kind == "camera", iceServers: iceServers) else { return }
            self.spares[kind] = spare
            self.work.asyncAfter(deadline: .now() + Self.spareLife) {
                guard self.spares[kind] === spare else { return }
                self.spares[kind] = nil
                spare.pc?.close()
            }
        }
    }

    /// The kinds with a spare connection now.
    public var prepared: [String] { work.sync { spares.keys.sorted() } }

    /// On `work`: a publication's peer connection with its sender and its offer, which waits for
    /// its candidates. `track` empty: a spare, with no track yet.
    private func connect(_ id: String, track: String, camera: Bool, iceServers: [[String: Any]]) -> Publication? {
        let configuration = LKRTCConfiguration()
        configuration.sdpSemantics = .unifiedPlan
        configuration.iceServers = Self.servers(iceServers)
        configuration.bundlePolicy = .maxBundle
        configuration.rtcpMuxPolicy = .require
        configuration.tcpCandidatePolicy = .disabled
        configuration.continualGatheringPolicy = .gatherOnce
        let publication = Publication(id: id, track: track, sender: self)
        guard let pc = factory.peerConnection(with: configuration, constraints: constraints, delegate: publication) else { return nil }
        publication.pc = pc
        if !track.isEmpty { publications[id] = publication }
        let setup = LKRTCRtpTransceiverInit()
        setup.direction = .sendOnly
        setup.streamIds = ["mac-\(id)"]
        setup.sendEncodings = camera ? Self.cameraLayers() : [Self.screenEncoding()]
        let made = track.isEmpty ? pc.addTransceiver(of: .video, init: setup) : pc.addTransceiver(with: picture(track, camera: camera), init: setup)
        guard let transceiver = made else {
            publication.offered(.failure(CallSenderError("no sender for \(track.isEmpty ? id : track)")))
            if track.isEmpty { pc.close() } else { close(id) }
            return track.isEmpty ? nil : publication
        }
        publication.transceiver = transceiver
        // H.264 in hardware first: Constrained Baseline before High, so that every browser in the
        // call decodes it (Safari and Firefox take High too); the other codecs after
        let codecs = factory.rtpSenderCapabilities(forKind: "video").codecs
        let h264 = codecs.filter { $0.name.uppercased() == "H264" }
        let baseline = h264.filter { ($0.parameters["profile-level-id"] ?? "").hasPrefix("42e0") }
        let preferred = baseline + h264.filter { !baseline.contains($0) } + codecs.filter { $0.name.uppercased() != "H264" }
        try? transceiver.setCodecPreferences(preferred, error: ())
        if !camera {
            let parameters = transceiver.sender.parameters
            parameters.degradationPreference = NSNumber(value: LKRTCDegradationPreference.maintainResolution.rawValue)
            transceiver.sender.parameters = parameters
        }
        pc.offer(for: constraints) { offer, error in
            guard let offer else { return self.onWork { publication.offered(.failure(CallSenderError("no offer: \(String(describing: error))"))) } }
            pc.setLocalDescription(offer) { error in
                self.work.async {
                    if let error { return publication.offered(.failure(CallSenderError("no offer: \(error.localizedDescription)"))) }
                    publication.gathered = { [weak pc] in
                        guard let sdp = pc?.localDescription?.sdp else { return publication.offered(.failure(CallSenderError("no offer"))) }
                        publication.offered(.success((CallSDP.udpOnly(sdp), transceiver.mid)))
                    }
                    // as the kit: complete, or 300 ms after the first candidate that is not the
                    // host's, or 2 s at most
                    self.work.asyncAfter(deadline: .now() + 2) { publication.gatheringDone() }
                    if pc.iceGatheringState == .complete { publication.gatheringDone() }
                }
            }
        }
        return publication
    }

    /// The SFU's answer to a publication's offer.
    public func answer(_ id: String, sdp: String, done: @escaping (CallSenderError?) -> Void = { _ in }) {
        work.async {
            guard let publication = self.publications[id] else { return done(CallSenderError("no such publication")) }
            publication.pc.setRemoteDescription(LKRTCSessionDescription(type: .answer, sdp: CallSDP.udpOnly(sdp))) { error in
                done(error.map { CallSenderError("the SFU's answer was refused: \($0.localizedDescription)") })
            }
        }
    }

    /// Fresh TURN credentials for a publication's connection.
    public func setIceServers(_ id: String, _ servers: [[String: Any]]) {
        work.async {
            guard let pc = self.publications[id]?.pc else { return }
            let configuration = pc.configuration
            configuration.iceServers = Self.servers(servers)
            _ = pc.setConfiguration(configuration)
        }
    }

    /// The publication ends here: its connection closes; its picture goes when no other sends it.
    public func close(_ id: String) {
        work.async {
            guard let publication = self.publications.removeValue(forKey: id) else { return }
            publication.pc?.close()
            self.lock.withLock {
                self.waitingFrame[publication.track]?.remove(id)
                guard var picture = self.pictures[publication.track] else { return }
                picture.users -= 1
                self.pictures[publication.track] = picture.users > 0 ? picture : nil
                if picture.users <= 0 {
                    self.adapted[publication.track] = nil
                    self.last[publication.track] = nil
                }
                if self.pictures.isEmpty {
                    self.repeater?.cancel()
                    self.repeater = nil
                }
            }
        }
    }

    /// The peer connection of a publication, for its statistics (`call-run`).
    public func connection(_ id: String) -> LKRTCPeerConnection? { work.sync { publications[id]?.pc } }

    // MARK: - Inside

    private static func servers(_ servers: [[String: Any]]) -> [LKRTCIceServer] {
        let made = servers.compactMap { server -> LKRTCIceServer? in
            let urls = ((server["urls"] as? [String]) ?? (server["urls"] as? String).map { [$0] } ?? [])
                // a URL on port 53 is dropped, as the kit drops it
                .filter { !$0.contains(":53?") && !$0.hasSuffix(":53") }
            return urls.isEmpty ? nil : LKRTCIceServer(urlStrings: urls, username: server["username"] as? String, credential: server["credential"] as? String)
        }
        return made.isEmpty ? [LKRTCIceServer(urlStrings: ["stun:stun.cloudflare.com:3478"])] : made
    }

    /// The camera's layers, as the kit's `cameraLayers` for a 1280 wide camera: full, half, quarter.
    static func cameraLayers() -> [LKRTCRtpEncodingParameters] {
        [("f", 1.0, 900_000), ("h", 2.0, 400_000), ("q", 4.0, 150_000)].map { rid, scale, bitrate in
            let layer = LKRTCRtpEncodingParameters()
            layer.rid = rid
            layer.scaleResolutionDownBy = NSNumber(value: scale)
            layer.maxBitrateBps = NSNumber(value: bitrate)
            layer.isActive = true
            return layer
        }
    }

    static func screenEncoding() -> LKRTCRtpEncodingParameters {
        let encoding = LKRTCRtpEncodingParameters()
        encoding.maxBitrateBps = NSNumber(value: 2_500_000)
        encoding.maxFramerate = NSNumber(value: 15)
        encoding.isActive = true
        return encoding
    }

    /// On `work`: the video track of a capture track, shared by every publication of it.
    private func picture(_ id: String, camera: Bool) -> LKRTCVideoTrack {
        lock.withLock {
            if var made = pictures[id] {
                made.users += 1
                pictures[id] = made
                return made.track
            }
            let source = factory.videoSource(forScreenCast: !camera)
            let made = (source: source, capturer: LKRTCVideoCapturer(delegate: source), track: factory.videoTrack(with: source, trackId: "mac-\(id)"), users: 1)
            pictures[id] = made
            if repeater == nil {
                let timer = DispatchSource.makeTimerSource(queue: DispatchQueue(label: "call.repeat"))
                timer.schedule(deadline: .now() + 0.1, repeating: 0.1, leeway: .milliseconds(20))
                timer.setEventHandler { [weak self] in self?.repeatStill() }
                timer.resume()
                repeater = timer
            }
            return made.track
        }
    }

    fileprivate func publication(_ publication: Publication, changed state: LKRTCPeerConnectionState) {
        work.async {
            let id = publication.id
            guard self.publications[id] === publication else { return }
            if state == .connected, !publication.wasConnected {
                publication.wasConnected = true
                self.lock.withLock { self.waitingFrame[publication.track, default: []].insert(id) }
                self.changed(id, true)
                // the encoder starts with a key frame: the newest frame now, not at the screen's
                // next change
                self.again(publication.track)
            }
            if state == .failed { self.changed(id, false) }
        }
    }

    /// Every 0.1 s: the last frame of each track again when none came for `repeatAfter`.
    private func repeatStill() {
        let now = ProcessInfo.processInfo.systemUptime
        let still = lock.withLock { last.filter { now - $0.value.at >= Self.repeatAfter }.map(\.key) }
        for track in still { again(track) }
    }

    /// The newest frame of `track` to its encoder again, at the time now.
    private func again(_ track: String) {
        guard let frame = lock.withLock({ last[track]?.frame }) else { return }
        feed(track, frame, hostTime: CMClockGetTime(CMClockGetHostTimeClock()))
    }

    // MARK: - CaptureSink: on the capture's queues

    /// The track a capture track feeds: the first camera that delivers is `camera-0`.
    private func sent(_ track: String) -> String {
        guard track.hasPrefix("camera-") else { return track }
        if feeds["camera-0"] == nil { feeds["camera-0"] = track }
        return feeds["camera-0"] == track ? "camera-0" : ""
    }

    public func video(_ track: String, _ frame: CVPixelBuffer, hostTime: CMTime) {
        guard let name = lock.withLock({ () -> String? in
            let name = sent(track)
            return pictures[name] == nil ? nil : name
        }) else { return }
        feed(name, frame, hostTime: hostTime)
    }

    /// A frame of the sent track `name` to its encoder: from the capture, or the last one again.
    private func feed(_ name: String, _ frame: CVPixelBuffer, hostTime: CMTime) {
        let (picture, first, adapt) = lock.withLock { () -> ((source: LKRTCVideoSource, capturer: LKRTCVideoCapturer)?, Set<String>, (Int, Int)?) in
            guard let made = pictures[name] else { return (nil, [], nil) }
            last[name] = (frame, ProcessInfo.processInfo.systemUptime)
            let first = waitingFrame.removeValue(forKey: name) ?? []
            // a screen: at most 1920 × 1200 and 15 frames a second, in its own aspect (the adapter
            // crops to the aspect it is given), set again when the display's size changes
            let size = (CVPixelBufferGetWidth(frame), CVPixelBufferGetHeight(frame))
            guard !name.hasPrefix("camera-"), adapted[name].map({ $0 != size }) ?? true else { return ((made.source, made.capturer), first, nil) }
            adapted[name] = size
            return ((made.source, made.capturer), first, size)
        }
        guard let picture else { return }
        if let (w, h) = adapt {
            let fit = CallFit.screen(width: w, height: h)
            picture.source.adaptOutputFormat(toWidth: Int32(fit.width), height: Int32(fit.height), fps: 15)
        }
        // libwebrtc's clock is the host clock too
        let nanos = CMTimeConvertScale(hostTime, timescale: 1_000_000_000, method: .roundHalfAwayFromZero).value
        picture.source.capturer(picture.capturer, didCapture: LKRTCVideoFrame(buffer: LKRTCCVPixelBuffer(pixelBuffer: frame), rotation: ._0, timeStampNs: nanos))
        for id in first { work.async { self.firstFrame(id) } }
    }

    public func sound(_ track: String, _ sample: CMSampleBuffer, hostTime: CMTime) {}

    public func ended(_ track: String) {
        lock.withLock { feeds = feeds.filter { $0.value != track } }
    }
}

public struct CallSenderError: Error, CustomStringConvertible {
    public let description: String
    init(_ description: String) { self.description = description }
}

/// One publication's peer connection and its delegate.
private final class Publication: NSObject, LKRTCPeerConnectionDelegate {
    /// On the sender's queue: a spare takes the publication's id and track when a choice takes it.
    var id: String
    var track: String
    weak var sender: CallSender?
    var pc: LKRTCPeerConnection!
    var transceiver: LKRTCRtpTransceiver?
    var wasConnected = false
    /// When it was made (Unix seconds), for the log.
    let made = Date().timeIntervalSince1970
    /// The offer waits for its candidates: called once, on the sender's queue.
    var gathered: (() -> Void)?
    private var soon = false
    /// The offer with its candidates once made, and who waits for it: on the sender's queue.
    private var offer: Result<(sdp: String, mid: String), CallSenderError>?
    private var waiting: [(Result<(sdp: String, mid: String), CallSenderError>) -> Void] = []

    init(id: String, track: String, sender: CallSender) {
        self.id = id
        self.track = track
        self.sender = sender
    }

    func gatheringDone() {
        let done = gathered
        gathered = nil
        done?()
    }

    func offered(_ result: Result<(sdp: String, mid: String), CallSenderError>) {
        guard offer == nil else { return }
        offer = result
        let all = waiting
        waiting = []
        for one in all { one(result) }
    }

    func whenOffered(_ made: @escaping (Result<(sdp: String, mid: String), CallSenderError>) -> Void) {
        if let offer { return made(offer) }
        waiting.append(made)
    }

    func peerConnection(_ peerConnection: LKRTCPeerConnection, didChange newState: LKRTCIceGatheringState) {
        if newState == .complete { sender?.onWork { self.gatheringDone() } }
    }
    func peerConnection(_ peerConnection: LKRTCPeerConnection, didGenerate candidate: LKRTCIceCandidate) {
        guard !candidate.sdp.contains(" typ host") else { return }
        sender?.onWork {
            guard !self.soon else { return }
            self.soon = true
            self.sender?.onWork(after: 0.3) { self.gatheringDone() }
        }
    }
    func peerConnection(_ peerConnection: LKRTCPeerConnection, didChange newState: LKRTCPeerConnectionState) { sender?.publication(self, changed: newState) }
    func peerConnection(_ peerConnection: LKRTCPeerConnection, didChange stateChanged: LKRTCSignalingState) {}
    func peerConnection(_ peerConnection: LKRTCPeerConnection, didAdd stream: LKRTCMediaStream) {}
    func peerConnection(_ peerConnection: LKRTCPeerConnection, didRemove stream: LKRTCMediaStream) {}
    func peerConnectionShouldNegotiate(_ peerConnection: LKRTCPeerConnection) {}
    func peerConnection(_ peerConnection: LKRTCPeerConnection, didChange newState: LKRTCIceConnectionState) {}
    func peerConnection(_ peerConnection: LKRTCPeerConnection, didRemove candidates: [LKRTCIceCandidate]) {}
    func peerConnection(_ peerConnection: LKRTCPeerConnection, didOpen dataChannel: LKRTCDataChannel) {}
}

extension CallSender {
    fileprivate func onWork(after seconds: Double = 0, _ block: @escaping () -> Void) {
        work.asyncAfter(deadline: .now() + seconds, execute: block)
    }
}
