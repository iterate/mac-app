import Foundation
import VoiceMeetCore

/// THE LOCAL MODEL'S LIFE (README, "Listening"): it is loaded only when it must hear. The rule
/// (`SpeechRoute`) says who hears; `LocalModelLife.step` says what to do with the model: load it
/// at once when the rule picks it (the network dropped, no OpenAI, "On this Mac"), and unload it
/// once OpenAI hears again and nothing used it for `idleSeconds`. A stretch whose OpenAI failed
/// loads it too, through `engines` (the transcriber's), which counts each use. Each load and unload
/// is a line in the log, with its reason and its seconds.
public actor LocalSpeech {
    public static let shared = LocalSpeech()
    /// How long the local model stays unused once OpenAI hears again.
    public static let idleSeconds: Double = 300

    /// What loads and unloads the models: `SpeechModels`, or a test's.
    public struct Models: Sendable {
        public var isOnDisk: @Sendable (SpeechModel) -> Bool
        public var load: @Sendable (SpeechModel) async throws -> Void
        public var unload: @Sendable (SpeechModel) async -> Void
        public var engine: @Sendable (SpeechModel, WordList, @escaping @Sendable (SpeechLoad) -> Void) async throws -> SpeechEngine

        public init(
            isOnDisk: @escaping @Sendable (SpeechModel) -> Bool, load: @escaping @Sendable (SpeechModel) async throws -> Void,
            unload: @escaping @Sendable (SpeechModel) async -> Void,
            engine: @escaping @Sendable (SpeechModel, WordList, @escaping @Sendable (SpeechLoad) -> Void) async throws -> SpeechEngine
        ) {
            self.isOnDisk = isOnDisk
            self.load = load
            self.unload = unload
            self.engine = engine
        }

        public static let standard = Models(
            isOnDisk: { $0.isOnDisk }, load: { try await SpeechModels.shared.load($0) }, unload: { await SpeechModels.shared.unload($0) },
            engine: { try await SpeechModels.shared.engine($0, words: $1, progress: $2) })
    }

    private let models: Models
    private let idleSeconds: Double
    private var log: @Sendable (String) -> Void = { _ in }
    /// The rule's answer; nil until the app sets it: nothing loads before.
    private var route: SpeechRoute?
    private var model = SpeechModel.default
    /// False in a home of its own with no audio fixture: nothing there would hear, so nothing loads
    /// before a use.
    private var mayLoad = true
    /// The model that is loaded, or loads now, and since when.
    private var loaded: (model: SpeechModel, at: Date)?
    private var users = 0
    /// The last of: a use ended, a load ended, OpenAI came back.
    private var idleSince = Date()
    private var check: Task<Void, Never>?
    /// The last reason a load did not happen, said once.
    private var refused: String?
    /// The loads and unloads, one after the other: an unload never ends a load that came after it.
    private var steps: Task<Void, Never>?

    public init(models: Models = .standard, idleSeconds: Double = LocalSpeech.idleSeconds) {
        self.models = models
        self.idleSeconds = idleSeconds
    }

    public func logs(_ log: @escaping @Sendable (String) -> Void) { self.log = log }

    /// Whether a model is loaded, or loads now.
    public var isLoaded: Bool { loaded != nil }
    /// The stretches that the local model hears now.
    public var uses: Int { users }

    /// The transcriber's engines: each use is counted, and a model that is not loaded loads for it.
    public nonisolated var engines: LocalEngines {
        LocalEngines(
            engine: { model, words, why, progress in try await self.engine(model, words: words, why: why, progress: progress) },
            done: { Task { await self.done() } })
    }

    /// The rule's answer now, and the local model. `mayLoad`: whether a load may come before a use.
    public func set(_ route: SpeechRoute, model: SpeechModel, mayLoad: Bool) {
        if route.provider == .openAI, self.route?.provider != .openAI { idleSince = Date() }
        self.route = route
        self.mayLoad = mayLoad
        if model != self.model {
            self.model = model
            if let loaded, loaded.model != model, users == 0 {
                self.loaded = nil
                then { [models] in await models.unload(loaded.model) }
                log("\(loaded.model.id) is unloaded after \(seconds(since: loaded.at)) s: the local model is now \(model.id)")
            }
        }
        apply()
    }

    private func engine(_ model: SpeechModel, words: WordList, why: String, progress: @escaping @Sendable (SpeechLoad) -> Void) async throws -> SpeechEngine {
        users += 1
        let isNew = loaded?.model != model
        let started = Date()
        if isNew {
            loaded = (model, started)
            log("\(model.id) loads: \(why)")
        }
        do {
            await steps?.value
            let engine = try await models.engine(model, words, progress)
            if isNew {
                idleSince = Date()
                log("\(model.id) is loaded in \(seconds(since: started)) s: \(why)")
            }
            return engine
        } catch {
            users -= 1
            if isNew, loaded?.model == model { loaded = nil }
            log("\(model.id) did not load: \(error.localizedDescription)")
            apply()
            throw error
        }
    }

    private func done() {
        users = max(0, users - 1)
        idleSince = Date()
        apply()
    }

    private func apply() {
        check?.cancel()
        check = nil
        guard let route else { return }
        let idle = Date().timeIntervalSince(idleSince)
        switch LocalModelLife.step(route: route, isLoaded: loaded != nil, users: users, idle: idle, limit: idleSeconds) {
        case .load(let why): load(why)
        case .unload(let why): unload(why)
        case .check(let after):
            check = Task { [weak self] in
                try? await Task.sleep(nanoseconds: UInt64(after * 1e9) + 10_000_000)
                guard !Task.isCancelled else { return }
                await self?.apply()
            }
        case .stay: break
        }
    }

    private func load(_ why: String) {
        let model = model
        let refusal = !mayLoad ? "nothing here would hear it" : !models.isOnDisk(model) ? "its files are not on this Mac; its first use downloads them" : nil
        if let refusal {
            if refused != refusal { log("\(model.id) is not loaded (\(why)): \(refusal)") }
            refused = refusal
            return
        }
        refused = nil
        let started = Date()
        loaded = (model, started)
        log("\(model.id) loads: \(why)")
        then { [models] in
            do {
                try await models.load(model)
                await self.didLoad(model, started: started, why: why)
            } catch {
                await self.didNotLoad(model, error: error)
            }
        }
    }

    private func didLoad(_ model: SpeechModel, started: Date, why: String) {
        guard loaded?.model == model else { return }
        idleSince = Date()
        log("\(model.id) is loaded in \(seconds(since: started)) s: \(why)")
        apply()
    }

    private func didNotLoad(_ model: SpeechModel, error: Error) {
        guard loaded?.model == model else { return }
        loaded = nil
        log("\(model.id) did not load: \(error.localizedDescription)")
    }

    private func unload(_ why: String) {
        guard let loaded else { return }
        self.loaded = nil
        then { [models] in await models.unload(loaded.model) }
        log("\(loaded.model.id) is unloaded after \(seconds(since: loaded.at)) s: \(why)")
    }

    private func then(_ step: @escaping @Sendable () async -> Void) {
        let previous = steps
        steps = Task {
            await previous?.value
            await step()
        }
    }

    private func seconds(since date: Date) -> String { String(format: "%.1f", Date().timeIntervalSince(date)) }
}
