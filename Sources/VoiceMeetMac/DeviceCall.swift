import Live
import Record
import SwiftUI
import VoiceMeetCore

/// THIS MAC IN A CALL (README, "A call's camera or screen from this Mac"): `call.publish` sends a
/// screen or the camera into the call on an agent's context, as a participant of its own. The job
/// `call` of the session's `MindBridge` (`bridge/call.mjs`) joins the call through the call facet
/// as the person who lent the Mac, and this app's own peer connection (`CallSender`) sends the
/// recorder's frames to the call's SFU: no second capture.
///
/// The gate is `AppModel.publishToCall`: a use of the display or the camera under its choice, as a
/// snapshot is. Here: the steps of each publication (join, offer, answer, connected), its act in
/// Activity from its start to its end, and its end: `call.unpublish`, the owner turning the thing
/// Off, the asking page leaving the call, the connection to the mind ending, another mind.
@MainActor
final class DeviceCall: ObservableObject {
    @Published private(set) var publications = CallPublications()

    /// The capture tracks the publications send: the recorder runs their sources.
    var sourcesChanged: (Set<RecordSource>) -> Void = { _ in }
    /// The sender is made: the recorder hands it the capture (`DeviceRecord.callSink`).
    var senderMade: (CallSender) -> Void = { _ in }
    var began: (_ thing: Shareable, _ doing: String, _ did: String) -> String = { _, _, _ in "" }
    var finished: (_ act: String, _ failure: String?) -> Void = { _, _ in }

    private let log = AppLog("call")
    private var sender: CallSender?
    private var bridge: MindBridge?
    private var session: MindSession?
    /// Each publication's act, its capture track, and the step that waits for the job's word.
    private var acts: [String: String] = [:]
    private var tracks: [String: String] = [:]
    private var waiting: [String: CheckedContinuation<[String: Any], Error>] = [:]
    /// Each wait's own number: a wait's time limit ends that wait alone, never a later step's.
    private var waits: [String: Int] = [:]
    private var waitCount = 0
    /// How long a publication may take to connect, from the call's join to the SFU's media.
    static let patience: Double = 20

    /// Another session and its bridge, or none: every publication of the old one ends first.
    func use(_ session: MindSession?, bridge: MindBridge?) {
        if self.bridge != nil {
            for id in publications.all.map(\.id) { end(id, why: "the Mac is no longer lent to this mind") }
        }
        self.session = session
        self.bridge = bridge
        bridge?.on("call") { [weak self, weak bridge] line in
            guard let self, let bridge, self.bridge === bridge else { return }
            self.said(line)
        }
    }

    func stop() {
        for id in publications.all.map(\.id) { end(id, why: "the Mac stopped") }
    }

    /// For `call.state()`.
    func state() -> [String: Any] {
        ["publications": publications.all.map { p -> [String: Any] in
            ["publication": p.id, "context": p.context, "source": p.source.text, "since": Int(p.since.timeIntervalSince1970 * 1000), "connected": p.connected, "who": p.who]
        }]
    }

    /// After the gate: `track` of `thing` into the call on `context`, as `source`. Answers once the
    /// SFU has the picture, or fails in words (and the publication ends).
    func publish(context: String, source: CallSource, asker: String?, track: String, thing: Shareable) async throws -> [String: Any] {
        guard let bridge, let session else { throw EndpointRefusal("This Mac is lent to no mind now.") }
        if let refusal = publications.refusal(adding: source, in: context) { throw EndpointRefusal(refusal) }
        for id in publications.replaced(by: source, in: context) { end(id, why: "another \(source.kind) was chosen") }
        let id = String(UUID().uuidString.lowercased().prefix(8))
        let started = Date()
        publications.add(.init(id: id, context: context, source: source, asker: asker, who: "a page of the call", since: started))
        tracks[id] = track
        acts[id] = began(thing, "Showing \(thing.title) in a call", "Showed \(thing.title) in a call")
        let sender = makeSender()
        tracksChanged()
        do {
            let joined = try await step(id) { bridge.send("call", ["publication": id, "join": ["context": context, "kind": source.kind, "as": asker as Any, "device": session.name]]) }
            let ice = (joined["joined"] as? [String: Any])?["iceServers"] as? [[String: Any]] ?? []
            let offer: (sdp: String, mid: String) = try await withCheckedThrowingContinuation { continuation in
                sender.offer(id, track: track, iceServers: ice) { result in continuation.resume(with: result.mapError { EndpointRefusal($0.description) }) }
            }
            let answered = try await step(id) { bridge.send("call", ["publication": id, "offer": ["sdp": offer.sdp, "mid": offer.mid]]) }
            let sdp = (answered["answer"] as? [String: Any])?["sdp"] as? String ?? ""
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                sender.answer(id, sdp: sdp) { error in continuation.resume(with: error.map { .failure(EndpointRefusal($0.description)) } ?? .success(())) }
            }
            // connected meanwhile, or the wait for it
            if publications.all.first(where: { $0.id == id })?.connected != true { _ = try await step(id) {} }
            log.info("\(id): \(source.text) in \(context) after \(Int(Date().timeIntervalSince(started) * 1000)) ms")
            return state()
        } catch {
            end(id, why: "failed", failure: AppLog.describe(error))
            throw error
        }
    }

    /// `call.unpublish`: the named ones end. Always allowed.
    func unpublish(_ ids: [String], why: String) -> [String: Any] {
        for id in ids { end(id, why: why) }
        return state()
    }

    /// The owner turned a thing Off: its publications end now.
    func choicesChanged(isOff: (CallSource) -> Bool) {
        for id in publications.turnedOff(isOff) { end(id, why: "the owner turned it off") }
    }

    // MARK: - Inside

    private func makeSender() -> CallSender {
        if let sender { return sender }
        let made = CallSender()
        made.log = { AppLog("call").info($0) }
        made.changed = { [weak self] id, connected in
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.connection(id, connected: connected) } }
        }
        made.firstFrame = { id in AppLog("call").info("\(id): the first frame went to the encoder") }
        sender = made
        senderMade(made)
        return made
    }

    /// Sends a line (`send`) and waits for the job's next word about `id`: its answer, a failure,
    /// the connection's state, or `patience` seconds.
    private func step(_ id: String, send: () -> Void) async throws -> [String: Any] {
        try await withCheckedThrowingContinuation { continuation in
            waitCount += 1
            let wait = waitCount
            waiting[id] = continuation
            waits[id] = wait
            send()
            DispatchQueue.main.asyncAfter(deadline: .now() + Self.patience) { [weak self] in
                guard let self, self.waits[id] == wait else { return }
                self.waiting.removeValue(forKey: id)?.resume(throwing: EndpointRefusal("The call did not answer in \(Int(Self.patience)) s."))
            }
        }
    }

    private func said(_ line: [String: Any]) {
        guard let id = line["publication"] as? String else {
            if let failed = line["failed"] { log.error("job: \(failed)") }
            return
        }
        if let servers = line["iceServers"] as? [[String: Any]] {
            sender?.setIceServers(id, servers)
            return
        }
        if let failed = line["failed"] as? String {
            log.error("\(id): \(failed)")
            waiting.removeValue(forKey: id)?.resume(throwing: EndpointRefusal("The call refused: \(failed)"))
            return
        }
        if let gone = line["gone"] as? String { return end(id, why: gone) }
        if line["left"] != nil { return }
        waiting.removeValue(forKey: id)?.resume(returning: line)
    }

    private func connection(_ id: String, connected: Bool) {
        guard publications.all.contains(where: { $0.id == id }) else { return }
        if connected {
            publications.connected(id)
            waiting.removeValue(forKey: id)?.resume(returning: ["connected": true])
        } else {
            waiting.removeValue(forKey: id)?.resume(throwing: EndpointRefusal("The connection to the call's SFU failed."))
            end(id, why: "the connection to the call failed", failure: "the connection to the call failed")
        }
    }

    /// The publication ends here and in the call: its sender, its row and page, its act.
    private func end(_ id: String, why: String, failure: String? = nil) {
        guard publications.remove(id) != nil else { return }
        log.info("\(id): ended, \(why)")
        waiting.removeValue(forKey: id)?.resume(throwing: EndpointRefusal("It ended: \(why)."))
        sender?.close(id)
        bridge?.send("call", ["publication": id, "leave": why])
        tracks[id] = nil
        if let act = acts.removeValue(forKey: id) { finished(act, failure) }
        tracksChanged()
    }

    private func tracksChanged() {
        sourcesChanged(Set(tracks.values.compactMap(RecordSource.of(track:))))
    }
}
