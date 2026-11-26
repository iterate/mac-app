import Foundation
import LiveKitWebRTC
import VoiceMeetCore

/// A DRIVER'S DIRECT PATH (README, "Drive"): one WebRTC data channel from the page that drives a
/// control session to this Mac, so that a batch of input does not go through the mind. The mind
/// carries only the one signal: `control.connect({ session, offer, iceServers? })` answers
/// `{ answer }`. Both sides gather their candidates before they say their description (no trickle).
///
/// - The page makes the channel `control` (ordered, reliable) and offers. The Mac answers.
/// - Each message from the page is `{ id, events }`, as `control.input` without the session; the
///   answer goes back on the channel as `{ id, applied, paused, … }`, or `{ id, error }`.
/// - The channel belongs to its session: `control.end`, the session's end and the app's end close
///   it. A session has one channel; a new connect replaces the old one.
/// - It carries no media: the factory has an audio device of our own that sends nothing
///   (`SoundDevice`), so libwebrtc opens no microphone and no speaker.
///
/// Everything runs on one queue; `take` is called there, and its answer may come from any queue.
public final class ControlChannels: NSObject, @unchecked Sendable {
    /// One batch of a session's channel: the app applies it as `control.input` and answers.
    public var take: (_ session: String, _ events: [Any], _ answer: @escaping ([String: Any]) -> Void) -> Void = { _, _, answer in
        answer(["error": "nobody takes input"])
    }
    public var log: (String) -> Void = { _ in }

    /// The most time for this Mac's own candidates before it answers.
    public static let gatherSeconds = 1.5
    /// The most channels at once: one for each control session (`ControlSessions`).
    public static let most = 4

    private let work = DispatchQueue(label: "control-channel")
    private lazy var factory: LKRTCPeerConnectionFactory = {
        _ = LivePeer.initializeOnce
        return LKRTCPeerConnectionFactory(encoderFactory: nil, decoderFactory: nil, audioDevice: SoundDevice())
    }()
    private let constraints = LKRTCMediaConstraints(mandatoryConstraints: nil, optionalConstraints: nil)
    private var links: [String: Link] = [:]

    public override init() { super.init() }

    /// `control.connect`: the page's offer for `session`; `done` gets the answer's SDP, with this
    /// Mac's candidates in it, or a failure in words.
    public func connect(session: String, offer: String, iceServers: [[String: Any]], done: @escaping (Result<String, ControlChannelProblem>) -> Void) {
        work.async {
            self.links.removeValue(forKey: session)?.close()
            guard self.links.count < Self.most else { return done(.failure(.init("at most \(Self.most) direct channels at once"))) }
            let configuration = LKRTCConfiguration()
            configuration.sdpSemantics = .unifiedPlan
            configuration.iceServers = Self.servers(iceServers)
            configuration.tcpCandidatePolicy = .disabled
            configuration.bundlePolicy = .maxBundle
            configuration.rtcpMuxPolicy = .require
            configuration.continualGatheringPolicy = .gatherOnce
            let link = Link(session: session, owner: self)
            guard let pc = self.factory.peerConnection(with: configuration, constraints: self.constraints, delegate: link) else {
                return done(.failure(.init("no peer connection")))
            }
            link.pc = pc
            self.links[session] = link
            let fail = { (words: String) in
                self.work.async {
                    if self.links[session] === link { self.links.removeValue(forKey: session)?.close() }
                    done(.failure(.init(words)))
                }
            }
            pc.setRemoteDescription(LKRTCSessionDescription(type: .offer, sdp: offer)) { error in
                if let error { return fail("the offer was refused: \(error.localizedDescription)") }
                pc.answer(for: self.constraints) { answer, error in
                    guard let answer else { return fail("no answer: \(String(describing: error))") }
                    pc.setLocalDescription(answer) { error in
                        if let error { return fail("no answer: \(error.localizedDescription)") }
                        // the answer goes with this Mac's candidates: when gathering completes,
                        // or after `gatherSeconds` with what it has
                        link.gathered = { self.work.async { link.answered(done) } }
                        self.work.asyncAfter(deadline: .now() + Self.gatherSeconds) { link.answered(done) }
                        if pc.iceGatheringState == .complete { link.gathered?() }
                    }
                }
            }
        }
    }

    /// The session ended: its channel closes.
    public func close(session: String) {
        work.async { self.links.removeValue(forKey: session)?.close() }
    }

    public func closeAll() {
        work.sync {
            for link in links.values { link.close() }
            links = [:]
        }
    }

    /// The sessions with a channel open now, for `control.state`.
    public var open: [String] { work.sync { links.values.filter { $0.channel?.readyState == .open }.map(\.session) } }

    private static func servers(_ servers: [[String: Any]]) -> [LKRTCIceServer] {
        let made = servers.compactMap { server -> LKRTCIceServer? in
            let urls = (server["urls"] as? [String]) ?? (server["urls"] as? String).map { [$0] } ?? []
            return urls.isEmpty ? nil : LKRTCIceServer(urlStrings: urls, username: server["username"] as? String, credential: server["credential"] as? String)
        }
        return made.isEmpty ? [LKRTCIceServer(urlStrings: ["stun:stun.cloudflare.com:3478"])] : made
    }

    /// On `work`: a message of a session's channel.
    fileprivate func message(_ link: Link, _ data: Data) {
        guard links[link.session] === link else { return }
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
        let id = object["id"] ?? NSNull()
        guard let events = object["events"] as? [Any] else { return link.send(["id": id, "error": "a message is { id, events }"]) }
        take(link.session, events) { answer in
            var answer = answer
            answer["id"] = id
            link.send(answer)
        }
    }

    fileprivate func changed(_ link: Link, _ state: LKRTCPeerConnectionState) {
        work.async {
            guard self.links[link.session] === link else { return }
            if state == .connected { self.log("control: \(link.session.prefix(8)): the direct channel connected") }
            if state == .failed || state == .closed {
                self.log("control: \(link.session.prefix(8)): the direct channel \(state == .failed ? "failed" : "closed")")
                self.links.removeValue(forKey: link.session)?.close()
            }
        }
    }
}

/// Why `control.connect` gave no answer, in words.
public struct ControlChannelProblem: Error, CustomStringConvertible {
    public let description: String
    init(_ words: String) { description = words }
}

/// One session's peer connection, its channel, and their delegate.
private final class Link: NSObject, LKRTCPeerConnectionDelegate, LKRTCDataChannelDelegate {
    let session: String
    weak var owner: ControlChannels?
    var pc: LKRTCPeerConnection!
    var channel: LKRTCDataChannel?
    var gathered: (() -> Void)?
    private var isAnswered = false

    init(session: String, owner: ControlChannels) {
        self.session = session
        self.owner = owner
    }

    /// Once: the local description as it is now, candidates and all.
    func answered(_ done: (Result<String, ControlChannelProblem>) -> Void) {
        guard !isAnswered else { return }
        isAnswered = true
        guard let sdp = pc.localDescription?.sdp else { return done(.failure(.init("no answer"))) }
        done(.success(sdp))
    }

    func send(_ answer: [String: Any]) {
        guard let channel, channel.readyState == .open, let data = try? JSONSerialization.data(withJSONObject: answer) else { return }
        channel.sendData(LKRTCDataBuffer(data: data, isBinary: false))
    }

    func close() {
        channel?.close()
        pc?.close()
    }

    func peerConnection(_ peerConnection: LKRTCPeerConnection, didOpen dataChannel: LKRTCDataChannel) {
        dataChannel.delegate = self
        channel = dataChannel
    }
    func dataChannel(_ dataChannel: LKRTCDataChannel, didReceiveMessageWith buffer: LKRTCDataBuffer) {
        guard let owner else { return }
        let data = buffer.data
        owner.workAsync { owner.message(self, data) }
    }
    func dataChannelDidChangeState(_ dataChannel: LKRTCDataChannel) {}
    func peerConnection(_ peerConnection: LKRTCPeerConnection, didChange newState: LKRTCIceGatheringState) {
        if newState == .complete { gathered?() }
    }
    func peerConnection(_ peerConnection: LKRTCPeerConnection, didChange newState: LKRTCPeerConnectionState) {
        owner?.changed(self, newState)
    }
    func peerConnection(_ peerConnection: LKRTCPeerConnection, didGenerate candidate: LKRTCIceCandidate) {}
    func peerConnection(_ peerConnection: LKRTCPeerConnection, didChange stateChanged: LKRTCSignalingState) {}
    func peerConnection(_ peerConnection: LKRTCPeerConnection, didAdd stream: LKRTCMediaStream) {}
    func peerConnection(_ peerConnection: LKRTCPeerConnection, didRemove stream: LKRTCMediaStream) {}
    func peerConnectionShouldNegotiate(_ peerConnection: LKRTCPeerConnection) {}
    func peerConnection(_ peerConnection: LKRTCPeerConnection, didChange newState: LKRTCIceConnectionState) {}
    func peerConnection(_ peerConnection: LKRTCPeerConnection, didRemove candidates: [LKRTCIceCandidate]) {}
}

extension ControlChannels {
    fileprivate func workAsync(_ block: @escaping () -> Void) { work.async(execute: block) }
}
