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
/// watches at once.
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

    /// The capture's sink: made once, at the start.
    let peer = LivePeer()
    private let log = AppLog("live")
    /// The session's bridge, whose job `live` signals.
    private var bridge: MindBridge?
    private var acts: [String: String] = [:]

    func start() {
        peer.log = { line in AppLog("live").info(line) }
        // the peer says these on its own queues: they go to the job in order, from the main queue
        peer.send = { [weak self] signal in
            let line = signal.json
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.bridge?.send("live", ["signal": line]) } }
        }
        peer.kept = { [weak self] facts in
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.bridge?.send("live", facts) } }
        }
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
    }

    func stop() {
        peer.endAll(why: "the Mac stopped")
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
            "signalling": bridge?.isConnected ?? false,
        ]
    }

    /// Another session and its bridge, or none: the old one's job and watches end now, and the new
    /// one's job starts.
    func use(_ session: MindSession?, bridge: MindBridge?) {
        if let old = self.bridge {
            peer.endAll(why: "the Mac is no longer lent to this mind")
            old.send("live", ["stop": true])
        }
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
        if peer.take(line) { return }
        if line["exited"] != nil {
            peer.endAll(why: "the signalling stopped")
        } else if line["started"] != nil {
            bridge?.send("live", ["start": true])
        } else if line["job"] != nil || line["connected"] != nil {
            log.info("bridge: \(line)")
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
