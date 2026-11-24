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
    @Published var isOpen = false
    /// What keeps fn dictation from working (`Dictation.fnLines`).
    @Published var fnLines: [String] = []
    var allowAccessibility: () -> Void = {}
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

    /// The person chose `model` in the panel (or `ui.press` did).
    func choose(_ model: SpeechModel) {
        isOpen = false
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

/// The panel's speech row, under the action buttons: the model, under a click the list of models (each with its size,
/// and whether it is on this Mac), and what keeps fn dictation from working.
struct SpeechSection: View {
    @ObservedObject var choice: SpeechChoice

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            trigger
            if choice.isOpen {
                list.transition(.opacity.combined(with: .move(edge: .top)))
            }
            if let failure = choice.failure {
                Label(failure, systemImage: "exclamationmark.triangle.fill").font(.caption).foregroundStyle(.orange)
            }
            ForEach(choice.fnLines, id: \.self) { line in
                HStack(spacing: 8) {
                    Label(line, systemImage: "globe").font(.caption).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
                    if line.contains("Accessibility") {
                        Spacer()
                        Button("Allow…", action: choice.allowAccessibility).controlSize(.small)
                    }
                }
            }
        }
        .animation(.easeOut(duration: 0.15), value: choice.isOpen)
    }

    private var trigger: some View {
        Button {
            choice.isOpen.toggle()
        } label: {
            HStack(spacing: 10) {
                Image(systemName: "waveform").font(.system(size: 13)).frame(width: 18).foregroundStyle(.secondary)
                Text("Speech: \(choice.chosen.name)").font(.system(size: 12)).lineLimit(1)
                Text(status(of: choice.chosen) ?? "on this Mac")
                    .font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
                Spacer(minLength: 8)
                Image(systemName: "chevron.up.chevron.down").font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
            }
        }
        .buttonStyle(SwitcherRowStyle(isSelected: choice.isOpen))
        .padding(.horizontal, -8)
        .help("The speech model: it runs on this Mac, and no sound leaves it")
        .accessibilityIdentifier("speech.model")
    }

    private var list: some View {
        VStack(alignment: .leading, spacing: 1) {
            ForEach(SpeechModel.all) { model in
                Button {
                    choice.choose(model)
                } label: {
                    HStack(spacing: 8) {
                        VStack(alignment: .leading, spacing: 1) {
                            Text(model.name).font(.system(size: 13))
                            Text("\(model.megabytes) MB · \(model.license)").font(.system(size: 11)).foregroundStyle(.secondary)
                        }
                        Spacer(minLength: 8)
                        Text(status(of: model) ?? (choice.isOnDisk(model) ? "On this Mac" : "Download"))
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                        Image(systemName: "checkmark")
                            .font(.system(size: 12, weight: .semibold))
                            .opacity(model == choice.chosen ? 1 : 0)
                    }
                }
                .buttonStyle(SwitcherRowStyle(isSelected: false))
                .accessibilityIdentifier("speech.model.\(model.id)")
            }
        }
        .padding(4)
        .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    /// The download or the load that goes on for `model`, in words.
    private func status(of model: SpeechModel) -> String? {
        guard let getting = choice.getting, getting.id == model.id else { return nil }
        if case .downloading(let part) = getting.load { return "Downloading: \(Int(part * 100))%" }
        return "Loading…"
    }
}
