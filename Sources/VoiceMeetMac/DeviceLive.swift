import Live
import Record
import SwiftUI
import VoiceMeetCore

/// LIVE: a member's page (record.<domain>) watches this Mac now: its screens, its camera, its
/// microphone, peer to peer over WebRTC (`Sources/Live`). The mind carries only the signalling, on
/// `/devices/<name>`, through `bridge/device-live.mjs`, which runs while the Mac is lent.
///
/// A watch is a use of the screen, the camera and the microphone under their switches, through
/// the same gate as every other use (`AppModel.liveTracks`): Off, the track is not offered; Ask,
/// the person is asked once for the watch; Shared, it is sent. While a watcher is connected,
/// Activity shows it as a running act, and the panel lists it with a button that ends it.
///
/// The bridge listens for one mind session (`MindSession`): `use` ends the old session's bridge and
/// its watches at once.
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
    var began: (_ who: String, _ tracks: [String]) -> Int = { _, _ in 0 }
    var finished: (_ act: Int, _ failure: String?) -> Void = { _, _ in }

    /// The capture's sink: made once, at the start.
    let peer = LivePeer()
    private let log = AppLog("live")
    private var bridge: LiveBridge?
    private var bridgeEndedAt = Date.distantPast
    /// The bridge's word: its connection to the mind is up (`{ connected }`).
    private var isSignalling = false
    private var acts: [String: Int] = [:]
    private var timer: Timer?

    func start() {
        peer.log = { line in AppLog("live").info(line) }
        peer.decide = { [weak self] _, who, answer in
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self else { return answer([], "the app is closing") }
                    Task { @MainActor in
                        let decided = await self.decide(who)
                        answer(decided.tracks, decided.reason)
                    }
                }
            }
        }
        peer.started = { [weak self] watcher, who, tracks in
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.watchBegan(watcher, who: who, tracks: tracks) } }
        }
        peer.ended = { [weak self] watcher, who, seconds, why in
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.watchEnded(watcher, why: why) } }
        }
        peer.changed = { [weak self] state in
            let sources = Set(state.tracks.compactMap(RecordSource.of(track:)))
            let connected = state.watches.compactMap { w in w.connected.map { Watcher(id: w.id, who: w.who, tracks: w.tracks, since: $0) } }
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self else { return }
                    if connected != self.watchers { self.watchers = connected }
                    self.sourcesChanged(sources)
                }
            }
        }
        let timer = Timer(timeInterval: 2, repeats: true) { [weak self] _ in MainActor.assumeIsolated { self?.tick() } }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
        tick()
    }

    func stop() {
        timer?.invalidate()
        peer.endAll(why: "the Mac stopped")
        bridge?.stop()
    }

    /// The panel's button, or `live.end` on the endpoint.
    func end(_ watcher: String, why: String) {
        log.info("\(watcher.prefix(8)): ended, \(why)")
        peer.end(watcher, why: why)
    }

    /// For `live.state()` on the endpoint.
    func state() -> [String: Any] {
        [
            "watchers": watchers.map { ["watcher": $0.id, "who": $0.who, "tracks": $0.tracks, "since": Int($0.since.timeIntervalSince1970 * 1000)] },
            "signalling": bridge != nil && isSignalling,
        ]
    }

    /// Another session, or none: the old one's bridge and watches end now. Nothing starts here:
    /// the next `tick` starts the bridge for the new session.
    func use(_ session: MindSession?) {
        self.session = session
        guard let old = bridge else { return }
        peer.endAll(why: "the Mac is no longer lent to this mind")
        old.stop()
        (bridge, bridgeEndedAt, isSignalling) = (nil, Date(), false)
    }

    /// Every 2 s: a bridge for the session. A bridge that ended starts again after 10 s.
    func tick() {
        guard let session, bridge == nil, Date().timeIntervalSince(bridgeEndedAt) > 10 else { return }
        let made = LiveBridge(
            node: session.helpers.node, script: session.helpers.deviceLive,
            arguments: [session.name, "--iterate", session.helpers.iterateBin, "--mind", session.mind], peer: peer)
        made.said = { [weak self] line in
            AppLog("live").info("bridge: \(line)")
            guard let up = line["connected"] as? Bool else { return }
            DispatchQueue.main.async { MainActor.assumeIsolated { if self?.bridge === made { self?.isSignalling = up } } }
        }
        made.exited = { [weak self] status in
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self, self.bridge === made else { return }
                    self.log.info("the bridge ended (status \(status))")
                    self.peer.endAll(why: "the signalling stopped")
                    (self.bridge, self.bridgeEndedAt, self.isSignalling) = (nil, Date(), false)
                }
            }
        }
        do {
            try made.start()
            bridge = made
            log.info("session \(session.generation): the bridge listens on \(session.mind) at \(session.path)")
        } catch {
            log.error("the bridge did not start: \(AppLog.describe(error))")
            bridgeEndedAt = Date()
        }
    }

    private func watchBegan(_ watcher: String, who: String, tracks: [String]) {
        acts[watcher] = began(who, tracks)
    }

    private func watchEnded(_ watcher: String, why: String) {
        guard let act = acts.removeValue(forKey: watcher) else { return }
        finished(act, why == "connection failed" ? why : nil)
    }
}

/// The panel's watchers, while there are any: who, what, since when, and a button that ends it.
struct LiveSection: View {
    @ObservedObject var live: DeviceLive

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            Text("WATCHED LIVE").font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
            ForEach(live.watchers) { watcher in
                HStack(spacing: 10) {
                    Image(systemName: "eye.fill").font(.system(size: 14)).frame(width: 20).foregroundStyle(.red)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(watcher.who).lineLimit(1).truncationMode(.middle)
                        Text("\(Self.words(watcher.tracks)) · since \(watcher.since.formatted(date: .omitted, time: .shortened))")
                            .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                    Spacer(minLength: 8)
                    Button("End") { live.end(watcher.id, why: "the owner ended it") }.controlSize(.small)
                }
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
