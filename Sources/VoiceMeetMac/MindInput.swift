import AppKit
import Combine
import AVFoundation
import SpeechText
import SwiftUI
import UniformTypeIdentifiers
import VoiceMeetCore

/// What the input bar shows: the draft, the minds it can go to, and the one that is chosen.
@MainActor
final class MindInputModel: ObservableObject {
    static let fontSize: CGFloat = 18
    static let lineHeight: CGFloat = 22
    static let mindKey = "inputMind"

    @Published var draft = InputDraft(id: MindInputModel.newId())
    @Published var minds: [LendView.Mind] = []
    /// The mind the input goes to, by its address.
    @Published var mind: String?
    @Published var textHeight: CGFloat = MindInputModel.lineHeight
    @Published var isDropTargeted = false
    /// The microphone of the bar: it listens when the bar opens, and its button turns it off.
    @Published var voice: Voice = .off
    let level = VoiceLevel()
    /// The typed and the spoken words as one text, while the microphone is on.
    var spoken: SpokenText?
    var send: () -> Void = {}
    var close: () -> Void = {}
    var toggleMicrophone: () -> Void = {}
    /// The text view, for the keyboard's focus.
    weak var field: NSTextView?
    private var pictures = 0

    enum Voice: Equatable {
        case off
        /// The speech model loads or downloads, 0 to 1. The microphone is open: what is said is kept.
        case loading(Double)
        case listening
        /// The last words are written after the microphone closed.
        case finishing
        case failed(String)

        var isOpen: Bool {
            switch self {
            case .loading, .listening: return true
            case .off, .finishing, .failed: return false
            }
        }
    }

    /// The person changed the text by hand.
    func edited(_ text: String) {
        draft.text = text
        spoken?.edited(text)
    }

    /// Everything said in this listening so far.
    func heard(_ said: String) {
        guard !draft.isSending else { return }
        spoken?.heard(said)
        if let text = spoken?.text, text != draft.text { draft.text = text }
    }

    /// An input's id: its time and four random digits, as a capture's.
    static func newId() -> String {
        let stamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: "-", with: "").replacingOccurrences(of: ":", with: "")
        return "\(stamp)-\(String(format: "%04x", UInt16.random(in: 0...UInt16.max)))"
    }

    func choose(_ mind: String) {
        self.mind = mind
        AppEnvironment.current.defaults.set(mind, forKey: Self.mindKey)
    }

    /// Tab: the next mind of the list (`by` 1), or the one before (-1).
    func chooseNext(by step: Int) {
        guard minds.count > 1, !draft.isSending else { return }
        let index = minds.firstIndex { $0.mind == mind } ?? 0
        choose(minds[(index + step + minds.count) % minds.count].mind)
    }

    /// A file of this Mac, from the clipboard or a drop.
    func attach(_ url: URL) {
        guard let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .fileSizeKey, .contentTypeKey]) else {
            return draft.refuse("\(url.lastPathComponent) could not be read.")
        }
        draft.attach(
            name: url.lastPathComponent, local: url.path, bytes: values.fileSize ?? 0,
            contentType: values.contentType?.preferredMIMEType ?? "application/octet-stream",
            isFolder: values.isDirectory ?? false)
    }

    /// A picture with no file (a screenshot on the clipboard, a picture dragged out of a page): it
    /// becomes a PNG file in the app's folder, and that file is attached.
    func attachPicture(_ data: Data) {
        guard let picture = NSBitmapImageRep(data: data), let png = picture.representation(using: .png, properties: [:]) else {
            return draft.refuse("That picture could not be read.")
        }
        pictures += 1
        let clock = DateFormatter()
        clock.dateFormat = "HH.mm.ss"
        let time = clock.string(from: Date())
        let file = MindInput.pasted.appendingPathComponent("Pasted picture \(time) \(pictures).png")
        do {
            try FileManager.default.createDirectory(at: MindInput.pasted, withIntermediateDirectories: true)
            try png.write(to: file)
        } catch {
            return draft.refuse("The picture was not kept: \(AppLog.describe(error))")
        }
        attach(file)
    }

    /// ⌘V. True when the clipboard held files or a picture, which are attached now; false when it
    /// holds text, which the text view pastes.
    func paste(_ pasteboard: NSPasteboard) -> Bool {
        if let files = pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL], !files.isEmpty {
            files.forEach(attach)
            return true
        }
        // a table cell or a paragraph is copied with a picture of itself: its text is what is meant
        if pasteboard.string(forType: .string) != nil { return false }
        guard let type = pasteboard.availableType(from: [.png, .tiff]), let data = pasteboard.data(forType: type) else { return false }
        attachPicture(data)
        return true
    }

    /// A drop on the bar: files, and pictures with no file.
    func drop(_ providers: [NSItemProvider]) {
        for provider in providers {
            if provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
                _ = provider.loadObject(ofClass: URL.self) { url, _ in
                    guard let url, url.isFileURL else { return }
                    DispatchQueue.main.async { MainActor.assumeIsolated { self.attach(url) } }
                }
            } else if provider.hasItemConformingToTypeIdentifier(UTType.image.identifier) {
                _ = provider.loadDataRepresentation(forTypeIdentifier: UTType.image.identifier) { data, _ in
                    guard let data else { return }
                    DispatchQueue.main.async { MainActor.assumeIsolated { self.attachPicture(data) } }
                }
            }
        }
    }
}

/// The microphone's loudness, apart from the bar's model: it changes many times a second.
@MainActor
final class VoiceLevel: ObservableObject {
    @Published var level: Float = 0
}

/// THE INPUT: ⌥⇧Space in any app opens one bar. It listens at once: the person talks, types, or
/// both, pastes or drops files, chooses the mind, and presses Return (README, "Input").
///
/// What is said is written on this Mac (`SpeechListener`, with the chosen mind's word list). The
/// microphone is open only while the bar is open and has the keyboard, and its button turns it off.
///
/// The bar closes at once. `bridge/input-send.mjs` puts the files into that mind's files and
/// appends one event, `device/input-submitted`, to `/devices/<name>`, as the person (the iterate
/// CLI's own sign-in). The app knows no agent and no backend: what a mind does with an input is the
/// mind's config. An input that did not go comes back: the bar opens again with the text, the
/// files and the reason, and Return sends the same input again.
@MainActor
final class MindInput {
    /// Node, the iterate CLI and the sender, the minds this Mac knows, and the one it is lent to.
    struct Destination {
        let node: String
        let iterateBin: String
        let sender: String
        let minds: [LendView.Mind]
        let active: String?
    }

    static let folder = AppEnvironment.current.folder.appendingPathComponent("inputs")
    /// The pictures that came with no file, until their input is sent.
    static let pasted = folder.appendingPathComponent("pasted")

    var destination: () -> Destination? = { nil }
    /// The word list of a mind, for the speech model.
    var words: (String?) -> WordList = { _ in .empty }
    /// Opens the guide for a permission of macOS.
    var allow: (Permission) -> Void = { _ in }
    var onChange: () -> Void = {}
    /// How the last input ended, for the panel.
    private(set) var lastLine: String?

    private let log = AppLog("input")
    private let model = MindInputModel()
    private var panel: InputPanel?
    private var host: NSHostingView<MindInputBar>?
    private var changes: AnyCancellable?
    private var sendingTo = ""
    private var listener: SpeechListener?
    /// Counts the listenings, so that a late word of an old one changes nothing.
    private var round = 0
    var isListening: Bool { listener != nil }
    /// What the sender printed after its last whole line.
    private var pending = ""

    init() {
        model.send = { [weak self] in self?.submit() }
        model.close = { [weak self] in self?.close() }
        model.toggleMicrophone = { [weak self] in self?.toggleMicrophone() }
    }

    /// ⌥⇧Space: open the bar, give it the keyboard when it is open without it, or close it.
    func toggle() {
        if let panel, panel.isVisible, panel.isKeyWindow { return close() }
        show(takingKeys: true)
    }

    private func close() {
        // a closed bar never listens
        stopListening(keepingLastWords: false)
        panel?.orderOut(nil)
    }

    // MARK: - The microphone

    /// The bar's microphone button.
    private func toggleMicrophone() {
        switch model.voice {
        case .loading, .listening: stopListening(keepingLastWords: true)
        case .off, .failed: listen(asking: true)
        case .finishing: break
        }
    }

    /// Opens the microphone. `asking` is true for the person's own click: then a permission that
    /// macOS refused opens its guide; the bar's own start only says so.
    private func listen(asking: Bool) {
        guard listener == nil, !model.draft.isSending, panel?.isVisible == true else { return }
        // a home of its own opens no microphone: only an audio fixture is heard (`Dictation` too)
        let hearsFixture = SpeechListener.environmentFixture != nil
        if AppEnvironment.current.hasOwnHome, !hearsFixture { return }
        switch hearsFixture ? .authorized : AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            break
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .audio) { [weak self] isGranted in
                DispatchQueue.main.async { MainActor.assumeIsolated { if isGranted { self?.listen(asking: false) } } }
            }
            return
        default:
            model.voice = .failed("iterate may not use the microphone")
            if asking { allow(.microphone) }
            return
        }
        round += 1
        let round = round
        let listener = SpeechListener()
        self.listener = listener
        model.spoken = SpokenText(base: model.draft.text)
        model.voice = SpeechModels.isOnDisk ? .listening : .loading(0)
        model.level.level = 0
        log.info("listening: on")
        listener.start(words: words(model.mind)) { [weak self] event in
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.heard(event, round: round) } }
        }
        onChange()
    }

    private func heard(_ event: SpeechListener.Event, round: Int) {
        if case .note(let note) = event { return log.info("listening: \(note)") }
        guard round == self.round, listener != nil else { return }
        switch event {
        case .loading(let progress):
            if progress < 1 { model.voice = .loading(progress) }
        case .listening:
            if case .loading = model.voice { model.voice = .listening }
        case .text(let said):
            model.heard(said)
        case .level(let level):
            model.level.level = level
        case .failed(let reason):
            listener = nil
            model.spoken = nil
            model.voice = .failed(reason)
            log.error("listening: \(reason)")
            onChange()
        case .note:
            break
        }
    }

    /// Closes the microphone. With `keepingLastWords` the words that were said last are still
    /// written, and `then` runs after them.
    private func stopListening(keepingLastWords: Bool, then: @escaping () -> Void = {}) {
        guard let listener else {
            if model.voice.isOpen { model.voice = .off }
            return then()
        }
        self.listener = nil
        round += 1
        model.level.level = 0
        log.info("listening: off")
        guard keepingLastWords else {
            listener.cancel()
            model.spoken = nil
            model.voice = .off
            onChange()
            return then()
        }
        model.voice = .finishing
        Task { @MainActor in
            let said = await listener.finish()
            self.model.heard(said)
            self.model.spoken = nil
            if self.model.voice == .finishing { self.model.voice = .off }
            self.onChange()
            then()
        }
    }

    private func show(takingKeys: Bool) {
        let destination = destination()
        model.minds = destination?.minds ?? []
        // the mind chosen last, else the one this Mac is lent to, else the first
        let wanted = [AppEnvironment.current.defaults.string(forKey: MindInputModel.mindKey), destination?.active].compactMap { $0 }
        model.mind = wanted.first { address in model.minds.contains { $0.mind == address } } ?? model.minds.first?.mind
        let panel = self.panel ?? makePanel()
        fit()
        if !panel.isVisible {
            // on the display under the pointer, in its upper third
            let pointer = NSEvent.mouseLocation
            let screen = NSScreen.screens.first { NSMouseInRect(pointer, $0.frame, false) } ?? NSScreen.main
            if let visible = screen?.visibleFrame {
                panel.setFrameOrigin(NSPoint(x: visible.midX - panel.frame.width / 2, y: visible.minY + visible.height * 0.72 - panel.frame.height))
            }
        }
        guard takingKeys else { return panel.orderFrontRegardless() }
        panel.makeKeyAndOrderFront(nil)
        // the bar starts by listening
        listen(asking: false)
        focus()
        // at the first opening the text view may not be made yet: once more after the layout
        DispatchQueue.main.async { MainActor.assumeIsolated { self.focus() } }
    }

    /// The keyboard goes to the text.
    private func focus() {
        guard let panel, panel.isKeyWindow, let field = model.field, panel.firstResponder !== field else { return }
        panel.makeFirstResponder(field)
    }

    private func makePanel() -> InputPanel {
        let host = NSHostingView(rootView: MindInputBar(model: model))
        // The app in front stays in front: the bar takes the keyboard and nothing else.
        let panel = InputPanel(contentRect: NSRect(origin: .zero, size: host.fittingSize), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        // It stays while another app is in front, so that a file can be dragged to it from there.
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.isMovableByWindowBackground = true
        panel.cancelled = { [weak self] in self?.close() }
        panel.microphone = { [weak self] in self?.toggleMicrophone() }
        panel.contentView = host
        self.panel = panel
        self.host = host
        // The bar grows down with its text and its files: its top stays where it is.
        changes = model.objectWillChange.sink { [weak self] _ in
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.fit() } }
        }
        return panel
    }

    private func fit() {
        guard let panel, let host else { return }
        host.layoutSubtreeIfNeeded()
        let size = host.fittingSize
        guard size.width > 0, size.height > 0, abs(size.height - panel.frame.height) > 0.5 || abs(size.width - panel.frame.width) > 0.5 else { return }
        panel.setFrame(NSRect(x: panel.frame.minX, y: panel.frame.maxY - size.height, width: size.width, height: size.height), display: true)
    }

    // MARK: - Send

    /// Return: the input goes to the chosen mind, and the bar closes. The words that were said last
    /// are written first.
    private func submit() {
        guard model.voice != .finishing else { return }
        stopListening(keepingLastWords: true) { [weak self] in self?.send() }
    }

    private func send() {
        guard let destination = destination(), let mind = destination.minds.first(where: { $0.mind == model.mind }) else {
            return model.draft.refuse("No mind is set up: add one in the panel under the 𝑖.")
        }
        let files = model.draft.attachments.count
        let characters = model.draft.text.count
        guard let input = model.draft.submit(at: Date()) else { return }
        let id = model.draft.id
        let folder = Self.folder.appendingPathComponent(id)
        let process = Process()
        let output = Pipe()
        process.executableURL = URL(fileURLWithPath: destination.node)
        process.arguments = [destination.sender, folder.path, "--name", mind.name, "--iterate", destination.iterateBin, "--mind", mind.mind]
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        output.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let text = String(decoding: handle.availableData, as: UTF8.self)
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.senderWrote(text, of: id) } }
        }
        process.terminationHandler = { [weak self] ended in
            output.fileHandleForReading.readabilityHandler = nil
            let rest = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            let status = ended.terminationStatus
            // after the last line that the handler above queued
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                MainActor.assumeIsolated {
                    self?.senderWrote(rest, of: id)
                    self?.senderEnded(status, of: id)
                }
            }
        }
        sendingTo = mind.mind
        pending = ""
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try input.write(to: folder.appendingPathComponent("input.json"))
            try process.run()
        } catch {
            output.fileHandleForReading.readabilityHandler = nil
            let reason = "The sender did not start: \(AppLog.describe(error))"
            model.draft.senderDidNotStart(reason)
            return settle(.failed(reason), of: id)
        }
        // The log holds counts, never the words.
        log.info("input \(id): \(characters) characters and \(files) files go to \(mind.mind) as \(mind.name)")
        close()
    }

    /// For `ui.state` on the control socket.
    func controlState() -> [String: Any] {
        var phase: String
        switch model.draft.phase {
        case .editing: phase = "editing"
        case .sending(let progress): phase = "sending \(Int(progress * 100))%"
        case .failed(let reason): phase = "failed: \(reason)"
        }
        return [
            "visible": panel?.isVisible ?? false, "hasKeyboard": panel?.isKeyWindow ?? false, "text": model.draft.text,
            "files": model.draft.attachments.map(\.name), "mind": model.mind ?? NSNull(), "minds": model.minds.map(\.mind),
            "phase": phase, "listening": isListening, "lastLine": lastLine ?? NSNull(),
        ]
    }

    private func senderWrote(_ text: String, of id: String) {
        guard id == model.draft.id else { return }
        var lines = (pending + text).components(separatedBy: "\n")
        pending = lines.removeLast()
        for line in lines {
            guard let object = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any] else { continue }
            settle(model.draft.senderSaid(object, next: MindInputModel.newId()), of: id)
        }
    }

    private func senderEnded(_ status: Int32, of id: String) {
        guard id == model.draft.id else { return }
        settle(model.draft.senderEnded(status: status), of: id)
    }

    private func settle(_ outcome: InputDraft.Outcome, of id: String) {
        switch outcome {
        case .nothing:
            return
        case .sent:
            log.info("input \(id): sent to \(sendingTo)")
            lastLine = "Sent to \(sendingTo) at \(Lend.clock(Date()))"
            // the new draft names none of the pictures that came with no file
            try? FileManager.default.removeItem(at: Self.pasted)
        case .failed(let reason):
            log.error("input \(id): not sent to \(sendingTo): \(reason)")
            lastLine = "Not sent to \(sendingTo) at \(Lend.clock(Date())): \(reason)"
            // The input comes back with its reason. It takes no keyboard: the person may be typing elsewhere.
            show(takingKeys: false)
        }
        try? FileManager.default.removeItem(at: Self.folder.appendingPathComponent(id))
        onChange()
    }
}

/// The bar's window. A window with no title bar takes no keyboard unless it says so; and this app
/// has no Edit menu, which is where ⌘V, ⌘C, ⌘X, ⌘A and ⌘Z come from in other apps.
private final class InputPanel: NSPanel {
    var cancelled: () -> Void = {}
    var microphone: () -> Void = {}

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    /// Escape.
    override func cancelOperation(_ sender: Any?) {
        cancelled()
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard event.type == .keyDown else { return super.performKeyEquivalent(with: event) }
        let flags = event.modifierFlags.intersection([.command, .shift, .option, .control])
        let key = event.charactersIgnoringModifiers?.lowercased() ?? ""
        var action: Selector?
        if flags == .command {
            switch key {
            case "v": action = #selector(NSText.paste(_:))
            case "c": action = #selector(NSText.copy(_:))
            case "x": action = #selector(NSText.cut(_:))
            case "a": action = #selector(NSResponder.selectAll(_:))
            case "z": action = Selector(("undo:"))
            case "w":
                cancelled()
                return true
            case "d":
                microphone()
                return true
            default: break
            }
        } else if flags == [.command, .shift], key == "z" {
            action = Selector(("redo:"))
        }
        if let action, NSApp.sendAction(action, to: nil, from: self) { return true }
        return super.performKeyEquivalent(with: event)
    }
}

/// The bar: the mind, the text, the files, and one line of state.
struct MindInputBar: View {
    @ObservedObject var model: MindInputModel
    @ObservedObject private var faces = MindFaces.shared

    static let width: CGFloat = 680

    init(model: MindInputModel) {
        self.model = model
    }

    private var shape: RoundedRectangle { RoundedRectangle(cornerRadius: 16, style: .continuous) }

    private var title: String { model.mind.map { faces.face(of: $0).title } ?? "a mind" }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 10) {
                mindMenu
                ZStack(alignment: .topLeading) {
                    if model.draft.text.isEmpty {
                        Text(model.mind == nil ? "Add a mind first" : model.voice.isOpen ? "Talk or type: tell \(title) what you want" : "Tell \(title) what you want")
                            .font(.system(size: MindInputModel.fontSize))
                            .foregroundStyle(.tertiary)
                            .lineLimit(1)
                            .allowsHitTesting(false)
                    }
                    InputTextView(model: model).frame(height: model.textHeight)
                }
                .padding(.top, 5)
                MicrophoneButton(voice: model.voice, level: model.level, press: model.toggleMicrophone)
                    .disabled(model.draft.isSending)
                    .accessibilityIdentifier("input.microphone")
                SendButton(isEnabled: model.mind != nil && !model.draft.isEmpty && !model.draft.isSending, press: model.send)
            }
            if !model.draft.attachments.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        ForEach(model.draft.attachments) { attachment in
                            AttachmentChip(attachment: attachment, remove: model.draft.isSending ? nil : { model.draft.remove(attachment.id) })
                        }
                    }
                }
            }
            HStack(spacing: 8) {
                status
                Spacer(minLength: 12)
                if !isFailed {
                    Text("↩ sends · ⇧↩ new line · ⇥ next mind · ⌘V or drop a file · ⌘D microphone · esc closes")
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                }
            }
            .font(.system(size: 11))
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .frame(width: Self.width)
        .background(.regularMaterial, in: shape)
        .overlay(shape.strokeBorder(model.isDropTargeted ? Color.accentColor : Color.primary.opacity(0.15), lineWidth: model.isDropTargeted ? 2 : 1))
        .onDrop(of: [UTType.fileURL, UTType.image], isTargeted: $model.isDropTargeted) { providers in
            model.drop(providers)
            return true
        }
    }

    private var isFailed: Bool {
        if case .failed = model.draft.phase { return true }
        return false
    }

    /// The mind the input goes to: its face, and under a click the minds this Mac knows.
    private var mindMenu: some View {
        Menu {
            ForEach(model.minds) { mind in
                Button {
                    model.choose(mind.mind)
                } label: {
                    let words = "\(faces.face(of: mind.mind).title) · \(mind.mind)"
                    if mind.mind == model.mind { Label(words, systemImage: "checkmark") } else { Text(words) }
                }
            }
        } label: {
            HStack(spacing: 4) {
                if let mind = model.mind {
                    MindAvatar(mind: mind, size: 28)
                } else {
                    Circle()
                        .strokeBorder(Color.secondary.opacity(0.6), style: StrokeStyle(lineWidth: 1.2, dash: [3, 3]))
                        .frame(width: 28, height: 28)
                }
                Image(systemName: "chevron.down")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.secondary)
            }
        }
        .menuStyle(.button)
        .menuIndicator(.hidden)
        .buttonStyle(MindMenuStyle())
        .fixedSize()
        .disabled(model.minds.isEmpty || model.draft.isSending)
        .help("The mind this input goes to. Tab chooses the next one.")
        .accessibilityIdentifier("input.mind")
    }

    @ViewBuilder
    private var status: some View {
        if case .failed(let reason) = model.draft.phase {
            Label("Not sent: \(reason)", systemImage: "exclamationmark.circle.fill")
                .foregroundStyle(.red)
                .lineLimit(3)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
        } else if let refusal = model.draft.refusal {
            Label(refusal, systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
                .lineLimit(1)
        } else if case .sending(let progress) = model.draft.phase {
            HStack(spacing: 6) {
                ProgressView(value: progress).frame(width: 60)
                Text("Sending to \(title)…")
            }
            .foregroundStyle(.secondary)
        } else if case .loading(let progress) = model.voice {
            Text(progress > 0 ? "Getting the speech model: \(Int(progress * 100))%. Talk now, it is kept." : "Loading the speech model. Talk now, it is kept.")
                .foregroundStyle(.secondary)
                .lineLimit(1)
        } else if case .failed(let reason) = model.voice {
            Label("Not listening: \(reason)", systemImage: "mic.slash")
                .foregroundStyle(.orange)
                .lineLimit(1)
        } else if let mind = model.mind {
            Text("To \(title) · \(mind)")
                .foregroundStyle(.secondary)
                .lineLimit(1)
        } else {
            Text("No mind is set up: add one in the panel under the 𝑖.")
                .foregroundStyle(.secondary)
        }
    }
}

/// The bar's microphone: red with the loudness while it listens, and a click turns it off or on.
private struct MicrophoneButton: View {
    let voice: MindInputModel.Voice
    @ObservedObject var level: VoiceLevel
    let press: () -> Void

    var body: some View {
        Button(action: press) {
            HStack(spacing: 5) {
                switch voice {
                case .listening:
                    LevelBars(level: level.level)
                    Image(systemName: "mic.fill").foregroundStyle(.red)
                case .loading:
                    ProgressView().controlSize(.small)
                    Image(systemName: "mic.fill").foregroundStyle(.red)
                case .finishing:
                    ProgressView().controlSize(.small)
                    Image(systemName: "mic").foregroundStyle(.secondary)
                case .off, .failed:
                    Image(systemName: "mic.slash").foregroundStyle(.secondary)
                }
            }
            .font(.system(size: 15))
            .frame(height: 28)
            .padding(.horizontal, 8)
            .background(Color.primary.opacity(voice.isOpen ? 0.08 : 0.04), in: Capsule())
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .fixedSize()
        .help(voice.isOpen ? "The microphone is on: what you say is written here, on this Mac. Click to turn it off (⌘D)." : "The microphone is off. Click to talk (⌘D).")
    }
}

/// The bar's send button: what Return does.
private struct SendButton: View {
    let isEnabled: Bool
    let press: () -> Void

    var body: some View {
        Button(action: press) {
            Image(systemName: "arrow.up.circle.fill")
                .font(.system(size: 24))
                .foregroundStyle(isEnabled ? Color.accentColor : Color.secondary.opacity(0.5))
                .frame(height: 28)
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled)
        .help("Send (↩)")
        .accessibilityLabel("Send")
        .accessibilityIdentifier("input.send")
    }
}

private struct MindMenuStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .padding(3)
            .background(Color.primary.opacity(configuration.isPressed ? 0.12 : 0), in: Capsule())
            .contentShape(Capsule())
    }
}

/// One file of the draft: its icon, its name, its size, and a button that takes it away.
private struct AttachmentChip: View {
    let attachment: InputDraft.Attachment
    let remove: (() -> Void)?

    /// A long name keeps its start and its end, with the extension.
    private var name: String {
        attachment.name.count <= 30 ? attachment.name : "\(attachment.name.prefix(16))…\(attachment.name.suffix(11))"
    }

    var body: some View {
        HStack(spacing: 6) {
            Image(nsImage: NSWorkspace.shared.icon(forFile: attachment.local))
                .resizable()
                .frame(width: 18, height: 18)
            Text(name)
            Text(InputDraft.size(attachment.bytes)).foregroundStyle(.secondary)
            if let remove {
                Button(action: remove) { Image(systemName: "xmark.circle.fill") }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .help("Take this file away")
            }
        }
        .font(.system(size: 12))
        .lineLimit(1)
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(Color.primary.opacity(0.07), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
        .fixedSize()
        .help(attachment.local)
    }
}

/// The text: Return sends, ⇧Return and ⌥Return make a new line, Tab chooses the next mind, Escape
/// closes, and Delete in an empty text takes the last file away.
private final class InputField: NSTextView {
    weak var model: MindInputModel?

    /// The text is the one thing in the bar that takes keys.
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if let window, window.isKeyWindow { window.makeFirstResponder(self) }
    }

    /// A file dropped on the text is a file for the bar, not a path in the text.
    override var acceptableDragTypes: [NSPasteboard.PasteboardType] { [] }

    override func paste(_ sender: Any?) {
        if model?.paste(.general) == true { return }
        pasteAsPlainText(sender)
    }

    override func doCommand(by selector: Selector) {
        switch selector {
        case #selector(insertNewline(_:)):
            if NSApp.currentEvent?.modifierFlags.contains(.shift) == true {
                insertNewlineIgnoringFieldEditor(nil)
            } else {
                model?.send()
            }
        case #selector(cancelOperation(_:)), #selector(complete(_:)):
            model?.close()
        case #selector(insertTab(_:)):
            model?.chooseNext(by: 1)
        case #selector(insertBacktab(_:)):
            model?.chooseNext(by: -1)
        case #selector(deleteBackward(_:)):
            if string.isEmpty, let model, let last = model.draft.attachments.last {
                model.draft.remove(last.id)
            } else {
                super.doCommand(by: selector)
            }
        default:
            super.doCommand(by: selector)
        }
    }
}

/// The text view in the bar, as tall as its lines, at most ten of them: then it scrolls.
private struct InputTextView: NSViewRepresentable {
    @ObservedObject var model: MindInputModel

    @MainActor
    final class Coordinator: NSObject, NSTextViewDelegate {
        let model: MindInputModel

        init(_ model: MindInputModel) {
            self.model = model
        }

        func textDidChange(_ notification: Notification) {
            guard let field = notification.object as? NSTextView else { return }
            model.edited(field.string)
            measure(field)
        }

        func measure(_ field: NSTextView) {
            guard let container = field.textContainer, let layout = field.layoutManager else { return }
            layout.ensureLayout(for: container)
            let height = min(max(ceil(layout.usedRect(for: container).height), MindInputModel.lineHeight), MindInputModel.lineHeight * 10)
            if abs(height - model.textHeight) > 0.5 { model.textHeight = height }
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(model)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.drawsBackground = false
        scroll.borderType = .noBorder
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        let field = InputField(frame: NSRect(x: 0, y: 0, width: 400, height: MindInputModel.lineHeight))
        field.model = model
        field.delegate = context.coordinator
        field.isRichText = false
        field.importsGraphics = false
        field.allowsUndo = true
        field.drawsBackground = false
        field.font = .systemFont(ofSize: MindInputModel.fontSize)
        field.textColor = .labelColor
        field.textContainerInset = .zero
        field.textContainer?.lineFragmentPadding = 0
        field.textContainer?.widthTracksTextView = true
        field.isAutomaticQuoteSubstitutionEnabled = false
        field.isAutomaticDashSubstitutionEnabled = false
        field.isAutomaticTextReplacementEnabled = false
        field.isVerticallyResizable = true
        field.isHorizontallyResizable = false
        field.autoresizingMask = [.width]
        field.minSize = .zero
        field.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        field.string = model.draft.text
        field.setAccessibilityIdentifier("input.text")
        scroll.documentView = field
        model.field = field
        let coordinator = context.coordinator
        DispatchQueue.main.async { MainActor.assumeIsolated { coordinator.measure(field) } }
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let field = scroll.documentView as? InputField else { return }
        field.isEditable = !model.draft.isSending
        guard field.string != model.draft.text else { return }
        field.string = model.draft.text
        // spoken words came in: the cursor stays after them
        field.setSelectedRange(NSRange(location: (field.string as NSString).length, length: 0))
        field.scrollRangeToVisible(field.selectedRange())
        let coordinator = context.coordinator
        DispatchQueue.main.async { MainActor.assumeIsolated { coordinator.measure(field) } }
    }
}

extension MindInput {
    /// Draws the bar in four states (empty, with a text and files, while it sends, not sent), each in
    /// the light and the dark appearance: eight PNG files in `folder`, for a look with no Mac
    /// (`--render-input <folder>`). The minds are the drawings' (`Rendering`).
    static func render(to folder: URL) -> Bool {
        _ = NSApplication.shared
        Rendering.fixFaces()
        let minds = Rendering.minds
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        var drawn = true
        for state in ["empty", "listening", "filled", "sending", "failed"] {
            let model = MindInputModel()
            model.minds = minds
            model.mind = minds.first?.mind
            if state == "empty" || state == "listening" { model.voice = .listening }
            if state == "listening" {
                model.level.level = 0.7
                model.draft.text = "Open the roadmap on Misha's computer and tell him"
            } else if state != "empty" {
                model.draft.text = "Open the roadmap on Misha's computer, and tell him why.\nThe two files are what I mean."
                model.draft.attach(name: "Roadmap 2027.pdf", local: "/tmp/Roadmap 2027.pdf", bytes: 2_200_000, contentType: "application/pdf")
                model.draft.attach(name: "Pasted picture 14.02.11 1.png", local: "/tmp/Pasted picture 14.02.11 1.png", bytes: 35_000, contentType: "image/png")
            }
            if state == "sending" || state == "failed" { _ = model.draft.submit(at: Rendering.now) }
            if state == "sending" { _ = model.draft.senderSaid(["progress": 0.4], next: "next") }
            if state == "failed" { _ = model.draft.senderSaid(["failed": "Not signed in to \(minds.first?.mind ?? "example.com"): run `iterate login` once."], next: "next") }
            for (dark, tone) in [(false, "light"), (true, "dark")] {
                let view = MindInputBar(model: model).padding(24).background(Color(nsColor: .windowBackgroundColor))
                drawn = Rendering.png(of: view, dark: dark, to: folder.appendingPathComponent("input-\(state)-\(tone).png")) && drawn
            }
        }
        return drawn
    }
}
