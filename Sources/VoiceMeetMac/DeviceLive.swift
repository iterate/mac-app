import Live
import Record
import SwiftUI
import VoiceMeetCore

/// LIVE: a member's page (record.<domain>) watches this Mac now: its screens, its camera, its
/// microphone, peer to peer over WebRTC (`Sources/Live`). The mind carries only the signalling, on
/// `/devices/<name>`, through the job `live` of the session's `MindBridge` (`bridge/live.mjs`),
/// which runs while the Mac is lent.
///
/// A watch is a use of the screen, the camera and the microphone under their switches, through
/// the same gate as every other use (`AppModel.liveTracks`): Off, the track is not offered; Ask,
/// the person is asked once for the watch; Shared, it is sent. While a watcher is connected,
/// Activity shows it as a running act, and the panel lists it with a button that ends it.
///
/// The job listens for one mind session (`MindSession`): `use` ends the old session's job and its
/// watches at once. What the peer says on its own queue (signals, the watch's records, its start
/// and end, the watchers) waits in one outbox with the session's stamp (`SessionWork`) and goes to
/// the main queue in order; `use` delivers what the old session said to the old bridge before it
/// stops that job, and a late word of an old session lands nowhere. The peer (WebRTC's factory
/// and threads) is made at the first signal of a watcher, not at the start.
@MainActor
final class DeviceLive: ObservableObject {
    /// A connected watcher, for the panel and `live.state()`.
    struct Watcher: Identifiable, Equatable {
        let id: String
        let who: String
        let tracks: [String]
        let since: Date
    }

    @Published private(set) var watchers: [Watcher] = []

    /// The session the bridge listens for; none while the Mac is lent to no mind.
    private(set) var session: MindSession?
    /// The tracks a watcher gets, by the owner's switches, and the reason when it gets none.
    var decide: (_ who: String) async -> (tracks: [String], reason: String) = { _ in ([], "nothing to show") }
    /// The sources the watchers need changed: the recorder runs them (`DeviceRecord.live`).
    var sourcesChanged: (Set<RecordSource>) -> Void = { _ in }
    var began: (_ who: String, _ tracks: [String]) -> String = { _, _ in "" }
    var finished: (_ act: String, _ failure: String?) -> Void = { _, _ in }
    /// The peer is made: the recorder hands it the capture (`DeviceRecord.sink`).
    var peerMade: (LivePeer) -> Void = { _ in }

    /// The capture's sink, once a watcher came.
    private(set) var peer: LivePeer?
    private let log = AppLog("live")
    /// The session's bridge, whose job `live` signals.
    private var bridge: MindBridge?
    private var acts: [String: String] = [:]
    private var work = SessionWork()
    private let outbox = Outbox()
    /// The ICE servers the job said before the peer was made.
    private var iceServers: [String: Any]?
    private var isStopped = false

    /// What the peer says, for the main queue.
    private enum Said {
        case line([String: Any])
        case began(watcher: String, who: String, tracks: [String])
        case ended(watcher: String, why: String)
        case changed(watchers: [Watcher], sources: Set<RecordSource>)
    }

    /// The outbox and the stamp it puts things with: the peer's queue and the main queue share it.
    private final class Outbox: @unchecked Sendable {
        private let lock = NSLock()
        private var box = SessionOutbox<Said>()
        private var stamp = SessionWork().stamp

        var now: SessionWork.Stamp { lock.withLock { stamp } }
        func set(_ stamp: SessionWork.Stamp) { lock.withLock { self.stamp = stamp } }
        /// True when the box was empty: then one drain is to be scheduled.
        func put(_ said: Said) -> Bool { lock.withLock { box.put(said, at: stamp) } }
        func take(for work: SessionWork) -> [Said] { lock.withLock { box.take(for: work) } }
    }

    func stop() {
        isStopped = true
        peer?.endAll(why: "the Mac stopped")
        // the byes and the records go now: the bridge closes next
        drain()
    }

    /// For a drawing (`Rendering`): watchers as given, with no peer.
    func fixForDrawing(_ watchers: [Watcher]) {
        self.watchers = watchers
    }

    /// The panel's button, or `live.end` on the endpoint.
    func end(_ watcher: String, why: String) {
        log.info("\(watcher.prefix(8)): ended, \(why)")
        peer?.end(watcher, why: why)
    }

    /// Every watch and its tracks, connected or still connecting (`AppModel.liveChoicesChanged`).
    var everyWatch: [(id: String, tracks: [String])] {
        peer?.state.watches.map { ($0.id, $0.tracks) } ?? []
    }

    /// For `live.state()` on the endpoint.
    func state() -> [String: Any] {
        [
            "watchers": watchers.map { ["watcher": $0.id, "who": $0.who, "tracks": $0.tracks, "since": Int($0.since.timeIntervalSince1970 * 1000)] },
            "signalling": bridge?.isConnected ?? false,
        ]
    }

    /// Another session and its bridge, or none: the old one's watches end now, their byes and
    /// records go to the old bridge, then its job stops; the new one's job starts.
    func use(_ session: MindSession?, bridge: MindBridge?) {
        if let old = self.bridge {
            peer?.endAll(why: "the Mac is no longer lent to this mind")
            drain()
            old.send("live", ["stop": true])
        }
        work.use(generation: session?.generation)
        outbox.set(work.stamp)
        self.session = session
        self.bridge = bridge
        guard let bridge else { return }
        bridge.on("live") { [weak self, weak bridge] line in
            guard let self, let bridge, self.bridge === bridge else { return }
            self.said(line)
        }
        bridge.send("live", ["start": true])
        log.info("session \(session?.generation ?? 0): the bridge listens on \(bridge.mind) at \(session?.path ?? "")")
    }

    private func said(_ line: [String: Any]) {
        if line["iceServers"] != nil, peer == nil { return iceServers = line }
        if line["signal"] != nil, !isStopped { makePeer() }
        if peer?.take(line) == true { return }
        if line["exited"] != nil {
            peer?.endAll(why: "the signalling stopped")
        } else if line["started"] != nil {
            bridge?.send("live", ["start": true])
        } else if line["job"] != nil || line["connected"] != nil {
            log.info("bridge: \(line)")
        }
    }

    /// The peer, at the first watcher's signal: its callbacks put into the outbox.
    private func makePeer() {
        guard peer == nil else { return }
        let peer = LivePeer()
        self.peer = peer
        peer.log = { line in AppLog("live").info(line) }
        // the peer says these on its own queue: into the outbox, in order, with the session's stamp
        peer.send = { [weak self] signal in self?.put(.line(["signal": signal.json])) }
        peer.kept = { [weak self] facts in self?.put(.line(facts)) }
        peer.started = { [weak self] watcher, who, tracks in self?.put(.began(watcher: watcher, who: who, tracks: tracks)) }
        peer.ended = { [weak self] watcher, _, _, why in self?.put(.ended(watcher: watcher, why: why)) }
        peer.changed = { [weak self] state in
            let sources = Set(state.tracks.compactMap(RecordSource.of(track:)))
            let connected = state.watches.compactMap { w in w.connected.map { Watcher(id: w.id, who: w.who, tracks: w.tracks, since: $0) } }
            self?.put(.changed(watchers: connected, sources: sources))
        }
        peer.decide = { [weak self] _, who, answer in
            guard let self else { return answer([], "the app is closing") }
            let stamp = self.outbox.now
            let gone = "the Mac is no longer lent to this mind"
            Task { @MainActor in
                // asked in one session, answered in it only
                guard self.work.lands(stamp) else { return answer([], gone) }
                let decided = await self.decide(who)
                guard self.work.lands(stamp) else { return answer([], gone) }
                answer(decided.tracks, decided.reason)
            }
        }
        if let iceServers { _ = peer.take(iceServers) }
        iceServers = nil
        log.info("the peer is made for the first watcher")
        peerMade(peer)
    }

    /// From the peer's queue.
    nonisolated private func put(_ said: Said) {
        guard outbox.put(said) else { return }
        DispatchQueue.main.async { [weak self] in MainActor.assumeIsolated { self?.drain() } }
    }

    /// On the main queue: what the peer said in this session, in order, to its bridge and the app.
    private func drain() {
        for said in outbox.take(for: work) {
            switch said {
            case .line(let line): bridge?.send("live", line)
            case let .began(watcher, who, tracks): acts[watcher] = began(who, tracks)
            case let .ended(watcher, why): watchEnded(watcher, why: why)
            case let .changed(connected, sources):
                if connected != watchers { watchers = connected }
                sourcesChanged(sources)
            }
        }
    }

    private func watchEnded(_ watcher: String, why: String) {
        guard let act = acts.removeValue(forKey: watcher) else { return }
        finished(act, why == "connection failed" ? why : nil)
    }
}

/// The panel's watchers, while there are any, first under the mind: one red row for each, who,
/// what and since when, and the button that ends it.
struct LiveSection: View {
    @ObservedObject var live: DeviceLive

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(live.watchers) { watcher in
                HStack(spacing: 10) {
                    Image(systemName: "eye.fill").font(.system(size: 14)).frame(width: 22).foregroundStyle(Palette.redText)
                    VStack(alignment: .leading, spacing: 1) {
                        Text("\(watcher.who) is watching live").font(.system(size: 13, weight: .semibold)).lineLimit(1).truncationMode(.middle)
                        Text("\(Self.words(watcher.tracks)) · since \(Lend.shortClock(watcher.since))")
                            .font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
                    }
                    Spacer(minLength: 8)
                    Button("End") { live.end(watcher.id, why: "the owner ended it") }
                        .buttonStyle(FillButtonStyle(prominent: true, height: 26))
                        .help("Ends this watch now")
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 9)
                .background(Palette.redWash, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Palette.redEdge))
            }
        }
    }

    /// "the screen, the camera, the microphone"
    static func words(_ tracks: [String]) -> String {
        let screens = tracks.filter { $0.hasPrefix("screen-") }.count
        var words: [String] = []
        if screens > 0 { words.append(screens == 1 ? "the screen" : "\(screens) screens") }
        if tracks.contains("camera-0") { words.append("the camera") }
        if tracks.contains("mic-0") { words.append("the microphone") }
        return words.joined(separator: ", ")
    }
}
