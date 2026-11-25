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
            let configuration = LKRTCConfiguration()
            configuration.sdpSemantics = .unifiedPlan
            configuration.iceServers = Self.servers(iceServers)
            configuration.bundlePolicy = .maxBundle
            configuration.rtcpMuxPolicy = .require
            configuration.tcpCandidatePolicy = .disabled
            configuration.continualGatheringPolicy = .gatherOnce
            let publication = Publication(id: id, track: track, sender: self)
            guard let pc = self.factory.peerConnection(with: configuration, constraints: self.constraints, delegate: publication) else {
                return made(.failure(CallSenderError("no peer connection")))
            }
            publication.pc = pc
            self.publications[id] = publication
            let camera = track.hasPrefix("camera-")
            let setup = LKRTCRtpTransceiverInit()
            setup.direction = .sendOnly
            setup.streamIds = ["mac-\(id)"]
            setup.sendEncodings = camera ? Self.cameraLayers() : [Self.screenEncoding()]
            guard let transceiver = pc.addTransceiver(with: self.picture(track, camera: camera), init: setup) else {
                self.close(id)
                return made(.failure(CallSenderError("no sender for \(track)")))
            }
            publication.transceiver = transceiver
            // H.264 in hardware first: Constrained Baseline before High, so that every browser in the
            // call decodes it (Safari and Firefox take High too); the other codecs after
            let codecs = self.factory.rtpSenderCapabilities(forKind: "video").codecs
            let h264 = codecs.filter { $0.name.uppercased() == "H264" }
            let baseline = h264.filter { ($0.parameters["profile-level-id"] ?? "").hasPrefix("42e0") }
            let preferred = baseline + h264.filter { !baseline.contains($0) } + codecs.filter { $0.name.uppercased() != "H264" }
            try? transceiver.setCodecPreferences(preferred, error: ())
            if !camera {
                let parameters = transceiver.sender.parameters
                parameters.degradationPreference = NSNumber(value: LKRTCDegradationPreference.maintainResolution.rawValue)
                transceiver.sender.parameters = parameters
            }
            pc.offer(for: self.constraints) { offer, error in
                guard let offer else { return made(.failure(CallSenderError("no offer: \(String(describing: error))"))) }
                pc.setLocalDescription(offer) { error in
                    if let error { return made(.failure(CallSenderError("no offer: \(error.localizedDescription)"))) }
                    self.work.async {
                        publication.gathered = { [weak pc] in
                            guard let sdp = pc?.localDescription?.sdp else { return made(.failure(CallSenderError("no offer"))) }
                            made(.success((CallSDP.udpOnly(sdp), transceiver.mid)))
                        }
                        // as the kit: complete, or 300 ms after the first candidate that is not the
                        // host's, or 2 s at most
                        self.work.asyncAfter(deadline: .now() + 2) { publication.gatheringDone() }
                        if pc.iceGatheringState == .complete { publication.gatheringDone() }
                    }
                }
            }
        }
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
                if picture.users <= 0 { self.adapted[publication.track] = nil }
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
            return made.track
        }
    }

    fileprivate func publication(_ id: String, changed state: LKRTCPeerConnectionState) {
        work.async {
            guard let publication = self.publications[id] else { return }
            if state == .connected, !publication.wasConnected {
                publication.wasConnected = true
                self.lock.withLock { self.waitingFrame[publication.track, default: []].insert(id) }
                self.changed(id, true)
            }
            if state == .failed { self.changed(id, false) }
        }
    }

    // MARK: - CaptureSink: on the capture's queues

    /// The track a capture track feeds: the first camera that delivers is `camera-0`.
    private func sent(_ track: String) -> String {
        guard track.hasPrefix("camera-") else { return track }
        if feeds["camera-0"] == nil { feeds["camera-0"] = track }
        return feeds["camera-0"] == track ? "camera-0" : ""
    }

    public func video(_ track: String, _ frame: CVPixelBuffer, hostTime: CMTime) {
        let (picture, first, adapt) = lock.withLock { () -> ((source: LKRTCVideoSource, capturer: LKRTCVideoCapturer)?, Set<String>, (Int, Int)?) in
            let name = sent(track)
            guard let made = pictures[name] else { return (nil, [], nil) }
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
    let id: String
    let track: String
    weak var sender: CallSender?
    var pc: LKRTCPeerConnection!
    var transceiver: LKRTCRtpTransceiver?
    var wasConnected = false
    /// The offer waits for its candidates: called once, on the sender's queue.
    var gathered: (() -> Void)?
    private var soon = false

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
    func peerConnection(_ peerConnection: LKRTCPeerConnection, didChange newState: LKRTCPeerConnectionState) { sender?.publication(id, changed: newState) }
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
