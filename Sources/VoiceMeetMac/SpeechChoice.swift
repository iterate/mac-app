import Network
import SpeechText
import SwiftUI
import VoiceMeetCore

/// THE SPEECH MODEL as Settings › Dictation shows it, and the inputs of the one rule that picks who
/// hears every use (`route`, `SpeechRoute`; README, "Listening"): the person's stored choice among
/// `SpeechModel.all`, the network (`NWPathMonitor`), the lent mind's OpenAI and this Mac's key. A
/// model that is not on this Mac is downloaded first, with its progress in the panel. The local
/// model (`local`) is the chosen one, else Oruk Fourier 2B; while only Parakeet v3 is on this Mac,
/// it stands in for Fourier, and the installed app gets Fourier in the background (`getDefault`).
///
/// It also holds whether the person's own OpenAI key is set (`OpenAIKey`, in the login Keychain),
/// and sets and removes it for Settings › Dictation. The key itself is read only by the online
/// recognizer, at each start of a listening, off the main thread, and only when the lent mind opens
/// no socket.
@MainActor
final class SpeechChoice: ObservableObject {
    static let key = "speechModel"

    @Published private(set) var chosen: SpeechModel
    /// The model that is being got now, and how far.
    @Published private(set) var getting: (id: String, load: SpeechLoad)?
    @Published private(set) var failure: String?
    /// What keeps fn dictation from working (`Dictation.fnLines`).
    @Published var fnLines: [String] = []
    var allowAccessibility: () -> Void = {}
    /// Settings › Dictation, where the models are listed and chosen.
    var openSettings: () -> Void = {}
    var onChange: () -> Void = {}

    /// Whether this Mac has an OpenAI key of its own. A drawing has none.
    @Published private(set) var hasKey = false
    /// The lent mind, when it opens OpenAI's sockets with its own key (`MindSockets`).
    @Published private(set) var openAIMind: String?
    /// The lent mind and what it can do with OpenAI, for the rule: a mind not asked yet is tried.
    private var lentMind: (mind: String, state: MindOpenAI)?
    /// Whether this Mac has a network now (`NWPathMonitor`). A drawing says yes.
    @Published private(set) var isNetworkUp = true
    private var network: NWPathMonitor?

    /// Whether GPT Live Transcribe can run: through the lent mind, or with this Mac's own key.
    var isOnline: Bool { openAIMind != nil || hasKey }

    private let log = AppLog("speech")
    private var gettingTask: Task<Void, Never>?

    /// The Keychain item of this home; nil in a drawing, which reads no Keychain.
    let openAIKey: OpenAIKey? = {
        let environment = AppEnvironment.current
        guard !environment.isRendering else { return nil }
        return OpenAIKey(service: OpenAIKey.service(home: environment.hasOwnHome ? environment.folder.path : nil))
    }()

    init() {
        let hasKey = openAIKey?.isSet ?? false
        chosen = SpeechModel.chosen(AppEnvironment.current.defaults.string(forKey: Self.key), isOnline: hasKey, isOnDisk: Self.isOnDisk)
        self.hasKey = hasKey
    }

    /// Watches the network: when it drops, the rule picks the local model at once, so that an
    /// offline dictation finds it loaded.
    func watchNetwork() {
        guard network == nil, !AppEnvironment.current.isRendering else { return }
        let monitor = NWPathMonitor()
        monitor.pathUpdateHandler = { [weak self] path in
            let isUp = path.status == .satisfied
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.networkIs(isUp) } }
        }
        monitor.start(queue: DispatchQueue(label: "com.iterate.speech.network"))
        network = monitor
    }

    private func networkIs(_ isUp: Bool) {
        guard isUp != isNetworkUp else { return }
        isNetworkUp = isUp
        log.info("the network is \(isUp ? "up" : "down")")
        follow(why: "the network is \(isUp ? "up" : "down")")
    }

    /// The person's stored choice, as the rule takes it: none, "On this Mac" (a local model) or
    /// "OpenAI".
    var choice: SpeechRoute.Choice {
        guard let model = SpeechModel.all.first(where: { $0.id == AppEnvironment.current.defaults.string(forKey: Self.key) }) else { return .automatic }
        return model.isLocal ? .onThisMac : .openAI
    }

    /// WHO HEARS EVERY USE NOW: the one rule (`SpeechRoute.pick`).
    var route: SpeechRoute {
        SpeechRoute.pick(choice: choice, isNetworkUp: isNetworkUp, mind: lentMind?.state, hasKey: hasKey)
    }

    /// The local model: the chosen one, or the default (`SpeechModel.localDefault`) when the chosen
    /// one runs online. It hears when the rule picks it and when OpenAI fails.
    var local: SpeechModel { chosen.isLocal ? chosen : SpeechModel.localDefault(isOnDisk: Self.isOnDisk) }

    /// Gets the default model in the background when it is not on this Mac and no local model is
    /// chosen: a Mac that had Parakeet v3 gets Oruk Fourier 2B, which is the local model once its files are here.
    /// Its progress is in its row in Settings › Dictation. The installed app alone does it.
    func getDefault() {
        let stored = AppEnvironment.current.defaults.string(forKey: Self.key).flatMap { id in SpeechModel.all.first { $0.id == id } }
        guard !AppEnvironment.current.hasOwnHome, stored?.isLocal != true, !Self.isOnDisk(.default), getting == nil else { return }
        let model = SpeechModel.default
        log.info("\(model.id): downloading \(model.megabytes) MB in the background, the default model")
        get(model) { [weak self] in self?.follow(why: "\(model.id) is on this Mac") }
    }

    /// Reads again whether the key is set (`cli.mjs --openai-key-from-env` may have written it),
    /// off the main thread. The default model follows.
    func refreshKey() {
        guard let key = openAIKey else { return }
        Task.detached(priority: .utility) {
            let isSet = key.isSet
            await MainActor.run { self.keyIs(isSet) }
        }
    }

    /// Settings › Dictation: a new key, in place of the one before.
    func setKey(_ text: String) {
        guard let key = openAIKey else { return }
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        Task.detached(priority: .userInitiated) {
            let isStored = key.store(text)
            await MainActor.run {
                if isStored {
                    self.failure = nil
                    self.log.info("the OpenAI key is stored in the Keychain")
                } else {
                    self.failure = "The Keychain did not take the OpenAI key."
                    self.log.error("the Keychain did not take the OpenAI key")
                }
                self.keyIs(isStored || key.isSet)
            }
        }
    }

    func removeKey() {
        guard let key = openAIKey else { return }
        Task.detached(priority: .userInitiated) {
            key.remove()
            await MainActor.run {
                self.log.info("the OpenAI key is removed from the Keychain")
                self.keyIs(key.isSet)
            }
        }
    }

    private func keyIs(_ isSet: Bool) {
        guard isSet != hasKey else { return }
        hasKey = isSet
        follow(why: "your own OpenAI key is \(isSet ? "set" : "gone")")
    }

    /// The lent mind, and what it can do with OpenAI (`MindSockets.onChange`).
    func mindIs(_ mind: String?, state: MindOpenAI) {
        let lent = mind.map { ($0, state) }
        let through = state == .yes ? mind : nil
        guard lent?.0 != lentMind?.mind || lent?.1 != lentMind?.state else { return }
        lentMind = lent
        openAIMind = through
        follow(why: through.map { "OpenAI opens through \($0)" } ?? mind.map { "\($0) opens OpenAI: \(state)" } ?? "lent to no mind")
    }

    /// The default model follows what can reach OpenAI; a stored choice stays.
    private func follow(why: String) {
        let model = SpeechModel.chosen(AppEnvironment.current.defaults.string(forKey: Self.key), isOnline: isOnline, isOnDisk: Self.isOnDisk)
        if model != chosen {
            chosen = model
            log.info("the speech model is \(model.id): \(why)")
        }
        onChange()
    }

    /// A drawing knows nothing of this Mac: the default model is on it, and no other.
    func isOnDisk(_ model: SpeechModel) -> Bool { Self.isOnDisk(model) }

    static func isOnDisk(_ model: SpeechModel) -> Bool {
        AppEnvironment.current.isRendering ? model == .default : model.isOnDisk
    }

    /// The person chose `model` in Settings › Dictation (or `ui.press` did).
    func choose(_ model: SpeechModel) {
        guard model != chosen, getting?.id != model.id else { return }
        failure = nil
        // another model in place of Fourier while it downloads: the download stops (it goes on
        // from there at the next try)
        if getting?.id == SpeechModel.fourier2b.id {
            getting = nil
            gettingTask?.cancel()
            Task { await FourierModel.shared.stopDownload() }
        }
        if !model.isLocal, !isOnline {
            failure = "\(model.name) needs a lent mind with an OpenAI key, or a key of your own: set it below."
            return
        }
        if isOnDisk(model) { return use(model) }
        log.info("\(model.id): downloading \(model.megabytes) MB")
        get(model) { [weak self] in self?.use(model) }
    }

    /// Downloads `model`, with its progress in `getting`; `done` runs when its files are here. It
    /// loads only when the rule needs it (`LocalSpeech`).
    private func get(_ model: SpeechModel, done: @escaping @MainActor () -> Void) {
        getting = (model.id, .downloading(0))
        gettingTask?.cancel()
        gettingTask = Task { @MainActor in
            do {
                try await SpeechModels.shared.download(model) { load in
                    DispatchQueue.main.async { MainActor.assumeIsolated { if self.getting?.id == model.id { self.getting = (model.id, load) } } }
                }
                guard getting?.id == model.id else { return }
                getting = nil
                done()
            } catch {
                guard getting?.id == model.id else { return }
                getting = nil
                failure = "\(model.name) did not download: \(error.localizedDescription)"
                log.error("\(model.id): \(error.localizedDescription)")
            }
        }
    }

    private func use(_ model: SpeechModel) {
        chosen = model
        AppEnvironment.current.defaults.set(model.id, forKey: Self.key)
        log.info("the speech model is \(model.id)")
        onChange()
    }

    /// For `ui.state` on the control socket.
    func controlState() -> [String: Any] {
        [
            "model": chosen.id, "models": SpeechModel.all.map { ["id": $0.id, "onDisk": isOnDisk($0)] as [String: Any] },
            "getting": getting.map { getting -> Any in
                if case .downloading(let part) = getting.load { return ["id": getting.id, "downloading": part] }
                return ["id": getting.id, "loading": true]
            } ?? NSNull(),
            "failure": failure ?? NSNull(), "fnLines": fnLines, "openAIKey": hasKey, "openAIMind": openAIMind ?? NSNull(),
            "network": isNetworkUp, "route": ["provider": route.provider.rawValue, "why": route.why.words, "local": local.id],
        ]
    }
}
