import SpeechText
import SwiftUI

/// THE SPEECH MODEL of dictation, the input bar and capture: the person's stored choice among
/// `SpeechModel.all` (README, "Dictation"). A model that is not on this Mac is downloaded first,
/// with its progress in the panel; it is the model once it loaded.
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

    private let log = AppLog("speech")
    private var gettingTask: Task<Void, Never>?

    init() {
        chosen = SpeechModel.chosen(AppEnvironment.current.defaults.string(forKey: Self.key))
    }

    /// A drawing knows nothing of this Mac: the default model is on it, and no other.
    func isOnDisk(_ model: SpeechModel) -> Bool {
        AppEnvironment.current.isRendering ? model == .default : model.isOnDisk
    }

    /// The person chose `model` in Settings › Dictation (or `ui.press` did).
    func choose(_ model: SpeechModel) {
        guard model != chosen, getting?.id != model.id else { return }
        failure = nil
        if isOnDisk(model) {
            use(model)
            SpeechModels.shared.preload(model)
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
            "failure": failure ?? NSNull(), "fnLines": fnLines,
        ]
    }
}
