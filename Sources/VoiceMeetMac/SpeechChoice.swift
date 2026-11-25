import SpeechText
import SwiftUI

/// THE SPEECH MODEL of dictation, the input bar and capture: the person's stored choice among
/// `SpeechModel.all` (README, "Dictation"). A model that is not on this Mac is downloaded first,
/// with its progress in the panel; it is the model once it loaded. With no stored choice the model
/// is GPT Live Transcribe when this Mac has an OpenAI key, else Parakeet v3. A capture always uses
/// a local model (`local`).
///
/// It also holds whether the OpenAI key is set (`OpenAIKey`, in the login Keychain), and sets and
/// removes it for Settings › Dictation. The key itself is read only by the online recognizer, at
/// each start of a listening, off the main thread.
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

    /// Whether this Mac has an OpenAI key. A drawing has none.
    @Published private(set) var hasKey = false

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
        chosen = SpeechModel.chosen(AppEnvironment.current.defaults.string(forKey: Self.key), hasKey: hasKey)
        self.hasKey = hasKey
    }

    /// The local model: the chosen one, or Parakeet v3 when the chosen one runs online. Captures use
    /// it, and the app loads it at its start.
    var local: SpeechModel { chosen.isLocal ? chosen : .default }

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
        let model = SpeechModel.chosen(AppEnvironment.current.defaults.string(forKey: Self.key), hasKey: isSet)
        if model != chosen {
            chosen = model
            log.info("the speech model is \(model.id): the OpenAI key is \(isSet ? "set" : "gone")")
            if model.isLocal { SpeechModels.shared.preload(model) }
        }
        onChange()
    }

    /// A drawing knows nothing of this Mac: the default model is on it, and no other.
    func isOnDisk(_ model: SpeechModel) -> Bool {
        AppEnvironment.current.isRendering ? model == .default : model.isOnDisk
    }

    /// The person chose `model` in Settings › Dictation (or `ui.press` did).
    func choose(_ model: SpeechModel) {
        guard model != chosen, getting?.id != model.id else { return }
        failure = nil
        if !model.isLocal, !hasKey {
            failure = "\(model.name) needs an OpenAI key: set it below."
            return
        }
        if isOnDisk(model) {
            use(model)
            _ = SpeechModels.shared.preload(model)
            return
        }
        log.info("\(model.id): downloading \(model.megabytes) MB")
        getting = (model.id, .downloading(0))
        gettingTask?.cancel()
        gettingTask = Task { @MainActor in
            do {
                try await SpeechModels.shared.load(model) { load in
                    DispatchQueue.main.async { MainActor.assumeIsolated { if self.getting?.id == model.id { self.getting = (model.id, load) } } }
                }
                guard getting?.id == model.id else { return }
                getting = nil
                use(model)
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
            "failure": failure ?? NSNull(), "fnLines": fnLines, "openAIKey": hasKey,
        ]
    }
}
