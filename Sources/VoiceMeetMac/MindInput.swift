import AppKit
import Combine
import SpeechText
import SwiftUI
import UniformTypeIdentifiers
import VoiceMeetCore

/// What the input bar shows: the draft, the minds it can go to, and the one that is chosen.
@MainActor
final class MindInputModel: ObservableObject {
    static let fontSize: CGFloat = 20
    /// One line of the text, as the text view sets it: the font's own line height.
    static let lineHeight: CGFloat = ceil(NSLayoutManager().defaultLineHeight(for: .systemFont(ofSize: fontSize)))
    /// The text grows to this many lines, then scrolls inside.
    static let mostLines: CGFloat = 6
    static let mindKey = "inputMind"

    @Published var draft = InputDraft(id: MindInputModel.newId())
    @Published var minds: [LendView.Mind] = []
    /// The mind the input goes to, by its address.
    @Published var mind: String?
    @Published var textHeight: CGFloat = MindInputModel.lineHeight
    @Published var isDropTargeted = false
    /// The command that fixes the last failure (`iterate login <address>`), or nil.
    @Published var fix: String?
    /// The microphone of the bar: it listens when the bar opens, and its button turns it off.
    @Published var voice: Voice = .off
    let level = VoiceLevel()
    /// The typed and the spoken words as one text, while the microphone is on.
    var spoken: SpokenText?
    var send: () -> Void = {}
    var close: () -> Void = {}
    var toggleMicrophone: () -> Void = {}
    /// A click on the face: the minds, in a menu under it.
    var showMinds: () -> Void = {}
    /// The text view, for the keyboard's focus.
    weak var field: NSTextView?
    private var pictures = 0

    enum Voice: Equatable {
        case off
        /// The speech model comes: the part of its download, or nil while it only loads. The
        /// microphone is open: what is said is kept.
        case loading(Double?)
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

    /// What of a draft sets the bar's height besides its text: the files (they wrap), the failure
    /// and its fix.
    struct Height: Equatable {
        let files: [String]
        let failure: String?
        let fix: Bool

        init(_ draft: InputDraft, fix: String?) {
            files = draft.attachments.map(\.name)
            if case .failed(let reason) = draft.phase { failure = reason } else { failure = nil }
            self.fix = failure != nil && fix != nil
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
    static func newId() -> String { InputDraft.newId() }

    /// The person chose another mind (its menu, Tab): the bar's listening hears with its words.
    var mindChanged: () -> Void = {}

    func choose(_ mind: String) {
        guard mind != self.mind else { return }
        self.mind = mind
        AppEnvironment.current.defaults.set(mind, forKey: Self.mindKey)
        mindChanged()
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
    /// The decoding and the writing are off the main actor: a picture of a display is many megabytes.
    func attachPicture(_ data: Data) {
        pictures += 1
        let clock = DateFormatter()
        clock.dateFormat = "HH.mm.ss"
        let folder = MindInput.pasted
        let file = folder.appendingPathComponent("Pasted picture \(clock.string(from: Date())) \(pictures).png")
        Task {
            let refusal = await Task.detached(priority: .userInitiated) { () -> String? in
                guard let picture = NSBitmapImageRep(data: data), let png = picture.representation(using: .png, properties: [:]) else {
                    return "That picture could not be read."
                }
                do {
                    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                    try png.write(to: file)
                    return nil
                } catch {
                    return "The picture was not kept: \(AppLog.describe(error))"
                }
            }.value
            if let refusal { draft.refuse(refusal) } else { attach(file) }
        }
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
/// What is said is written on this Mac (the app's one foreground listening, `SpeechSession`, with
/// the chosen mind's word list). The microphone is open only while the bar is open and has the
/// keyboard, and its button turns it off. A dictation that starts meanwhile ends the bar's
/// listening: its last words are written into the bar.
///
/// The bar closes at once. The job `input` of that mind's `MindBridge` (`bridge/input.mjs`) puts
/// the files into that mind's files and appends one event, `device/input-submitted`, to `/devices/<name>`, as the person (the iterate
/// CLI's own sign-in). The app knows no agent and no backend: what a mind does with an input is the
/// mind's config. An input that did not go comes back: the bar opens again with the text, the
/// files and the reason, and Return sends the same input again; a changed one is another input (`InputDraft`).
@MainActor
final class MindInput: SpeechClient {
    /// The helpers, the minds this Mac knows, and the one it is lent to.
    typealias Choices = (helpers: MindSession.Helpers, minds: [LendView.Mind], active: String?)

    static let folder = AppEnvironment.current.folder.appendingPathComponent("inputs")
    /// The pictures that came with no file, until their input is sent.
    static let pasted = folder.appendingPathComponent("pasted")

    /// Read once at each opening of the bar: the input sent from it goes with that value.
    var choices: () -> Choices? = { nil }
    /// The word list of a mind, for the speech model.
    var words: (String?) -> WordList = { _ in .empty }
    /// Opens the guide for a permission of macOS.
    var allow: (Permission) -> Void = { _ in }
    var onChange: () -> Void = {}
    /// How the last input ended, for the panel.
    private(set) var lastLine: String?
    /// The last input was not sent: the panel draws its line in orange.
    private(set) var lastFailed = false

    private let log = AppLog("input")
    private let model = MindInputModel()
    private var panel: InputPanel?
    private var host: NSHostingView<MindInputBar>?
    private var changes: AnyCancellable?
    private var sendingTo = ""
    /// The choices at the bar's opening.
    private var opened: Choices?
    private let session: SpeechSession
    /// What waits for the listening's last words (Return sends after them).
    private var afterLastWords: [() -> Void] = []
    var isListening: Bool { session.isListening(for: self) }
    /// The bridge each input that is being sent holds, by its id.
    private var sending: [String: MindBridge] = [:]
    /// A click in another app or on the desktop while the bar has the keyboard: it closes the bar.
    private var outside: [Any] = []
    private var downAt: NSPoint?

    init(session: SpeechSession) {
        self.session = session
        model.send = { [weak self] in self?.submit() }
        model.close = { [weak self] in self?.close() }
        model.toggleMicrophone = { [weak self] in self?.toggleMicrophone() }
        model.mindChanged = { [weak self] in self?.hearWithTheMindsWords() }
        model.showMinds = { [weak self] in self?.showMinds() }
        // The bar is made once, soon after the app starts, so that ⌥⇧Space shows it at once.
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.panel == nil else { return }
                _ = self.makePanel()
                self.fit()
            }
        }
    }

    /// ⌥⇧Space: open the bar, give it the keyboard when it is open without it, or close it.
    func toggle() {
        if let panel, panel.isVisible, panel.isKeyWindow { return close() }
        show(takingKeys: true)
    }

    private func close() {
        // a closed bar never listens
        stopListening(keepingLastWords: false)
        stopWatchingClicks()
        panel?.orderOut(nil)
    }

    /// While the bar has the keyboard, a click elsewhere closes it, as Spotlight's does; the draft
    /// stays. A drag that starts elsewhere (a file for the bar) is not a click: it moved.
    private func watchClicks() {
        guard outside.isEmpty else { return }
        let down = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            MainActor.assumeIsolated { self?.downAt = NSEvent.mouseLocation }
        }
        let up = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseUp, .rightMouseUp]) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, let at = self.downAt else { return }
                self.downAt = nil
                let now = NSEvent.mouseLocation
                if hypot(now.x - at.x, now.y - at.y) < 4 { self.close() }
            }
        }
        outside = [down, up].compactMap { $0 }
    }

    private func stopWatchingClicks() {
        outside.forEach(NSEvent.removeMonitor)
        outside = []
        downAt = nil
    }

    /// The minds this Mac knows, in a native menu under the face: each one's face, its name and
    /// address; the menu's own type-ahead finds one by its name.
    private func showMinds() {
        guard let host, !model.minds.isEmpty, !model.draft.isSending else { return }
        let menu = NSMenu()
        menu.autoenablesItems = false
        for mind in model.minds {
            let face = MindFaces.shared.face(of: mind.mind)
            let item = NSMenuItem(title: face.title, action: #selector(MindMenuTarget.choose(_:)), keyEquivalent: "")
            let title = NSMutableAttributedString(string: face.title, attributes: [.font: NSFont.menuFont(ofSize: 13)])
            title.append(NSAttributedString(string: "  \(mind.mind)", attributes: [.font: NSFont.menuFont(ofSize: 11), .foregroundColor: NSColor.secondaryLabelColor]))
            item.attributedTitle = title
            item.target = MindMenuTarget.shared
            item.representedObject = mind.mind
            item.image = MindMenuTarget.avatar(of: mind.mind)
            item.state = mind.mind == model.mind ? .on : .off
            menu.addItem(item)
        }
        MindMenuTarget.shared.chosen = { [weak self] mind in self?.model.choose(mind) }
        // under the face, whose top left is the bar's padding
        let below = NSPoint(x: MindInputBar.padding - 4, y: host.isFlipped ? MindInputBar.padding + 34 : host.bounds.height - MindInputBar.padding - 34)
        menu.popUp(positioning: nil, at: below, in: host)
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
        guard !isListening, model.voice != .finishing, !model.draft.isSending, panel?.isVisible == true else { return }
        model.spoken = SpokenText(base: model.draft.text)
        model.level.level = 0
        switch session.start(self, words: words(model.mind), allowed: { [weak self] in self?.listen(asking: false) }) {
        case nil:
            log.info("listening: on")
            onChange()
        case .ownHome, .asking:
            model.spoken = nil
        case .notAllowed:
            model.spoken = nil
            model.voice = .failed("iterate may not use the microphone")
            if asking { allow(.microphone) }
        case .failed(let reason):
            model.spoken = nil
            model.voice = .failed(reason)
            log.error("listening: \(reason)")
        }
    }

    func speech(_ event: SpeechSession.Event) {
        switch event {
        case .phase(let phase):
            guard model.voice != .finishing else { return }
            if case .loading(let part) = phase { model.voice = .loading(part) } else { model.voice = .listening }
        case .text(let said):
            model.heard(said)
        case .level(let level):
            model.level.level = level
        case .failed(let reason):
            model.spoken = nil
            model.voice = .failed(reason)
            log.error("listening: \(reason)")
            onChange()
        case .ended(let said):
            // after the bar's own stop, or when a dictation started
            model.heard(said)
            model.spoken = nil
            if model.voice == .finishing || model.voice.isOpen { model.voice = .off }
            onChange()
            let waiting = afterLastWords
            afterLastWords = []
            waiting.forEach { $0() }
        }
    }

    /// Another mind was chosen while the bar listens: a listening keeps the word list of its start,
    /// so it ends, its last words are written, and a new one starts with that mind's list.
    private func hearWithTheMindsWords() {
        guard isListening else { return }
        log.info("listening: again, with the words of the mind chosen now")
        stopListening(keepingLastWords: true) { [weak self] in self?.listen(asking: false) }
    }

    /// Closes the microphone. With `keepingLastWords` the words that were said last are still
    /// written, and `then` runs after them.
    private func stopListening(keepingLastWords: Bool, then: @escaping () -> Void = {}) {
        if model.voice == .finishing { return afterLastWords.append(then) }
        guard isListening else {
            if model.voice.isOpen { model.voice = .off }
            return then()
        }
        model.level.level = 0
        log.info("listening: off")
        guard keepingLastWords else {
            session.cancel(self)
            model.spoken = nil
            model.voice = .off
            onChange()
            return then()
        }
        model.voice = .finishing
        afterLastWords.append(then)
        session.finish(self)
    }

    private func show(takingKeys: Bool) {
        opened = choices()
        model.minds = opened?.minds ?? []
        // the mind chosen last, else the one this Mac is lent to, else the first
        let wanted = [AppEnvironment.current.defaults.string(forKey: MindInputModel.mindKey), opened?.active].compactMap { $0 }
        model.mind = wanted.first { address in model.minds.contains { $0.mind == address } } ?? model.minds.first?.mind
        let panel = self.panel ?? makePanel()
        fit()
        let appears = !panel.isVisible
        if appears {
            // on the display under the pointer, a little above its middle, as Spotlight; it grows down
            let pointer = NSEvent.mouseLocation
            let screen = NSScreen.screens.first { NSMouseInRect(pointer, $0.frame, false) } ?? NSScreen.main
            if let visible = screen?.visibleFrame {
                panel.setFrameOrigin(NSPoint(x: visible.midX - panel.frame.width / 2, y: visible.maxY - visible.height * 0.3 - panel.frame.height))
            }
        }
        if takingKeys { panel.makeKeyAndOrderFront(nil) } else { panel.orderFrontRegardless() }
        if appears { appear(panel) }
        guard takingKeys else { return }
        focus()
        // The bar starts by listening, after its first frame is on the screen. At the first
        // opening the text view may not be made yet: the keyboard goes to it once more then.
        DispatchQueue.main.async {
            MainActor.assumeIsolated {
                self.focus()
                if panel.isKeyWindow { self.listen(asking: false) }
            }
        }
    }

    /// A short fade and scale from 97%, under 120 ms; with Reduce Motion, the fade alone.
    private func appear(_ panel: NSPanel) {
        panel.alphaValue = 0
        if !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion, let layer = panel.contentView?.layer {
            let size = layer.bounds.size
            let scale: CGFloat = 0.97
            var from = CATransform3DMakeTranslation(size.width * (1 - scale) / 2, size.height * (1 - scale) / 2, 0)
            from = CATransform3DScale(from, scale, scale, 1)
            let grow = CABasicAnimation(keyPath: "transform")
            grow.fromValue = from
            grow.toValue = CATransform3DIdentity
            grow.duration = 0.11
            grow.timingFunction = CAMediaTimingFunction(name: .easeOut)
            layer.add(grow, forKey: "appear")
        }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.1
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            panel.animator().alphaValue = 1
        }
    }

    /// The keyboard goes to the text.
    private func focus() {
        guard let panel, panel.isKeyWindow, let field = model.field, panel.firstResponder !== field else { return }
        panel.makeFirstResponder(field)
    }

    private func makePanel() -> InputPanel {
        let host = NSHostingView(rootView: MindInputBar(model: model))
        host.wantsLayer = true
        // The app in front stays in front: the bar takes the keyboard and nothing else.
        let panel = InputPanel(contentRect: NSRect(origin: .zero, size: host.fittingSize), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        // the window's own shadow, of the bar's rounded shape (the material's mask)
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
        // The bar grows down with its text and its files: its top stays where it is. It is laid
        // out again only when what sets its height changed, not at each word.
        changes = model.$draft.combineLatest(model.$fix).map(MindInputModel.Height.init).combineLatest(model.$textHeight)
            .removeDuplicates { $0 == $1 }
            .sink { [weak self] _ in
                DispatchQueue.main.async { MainActor.assumeIsolated { self?.fit() } }
            }
        NotificationCenter.default.addObserver(forName: NSWindow.didBecomeKeyNotification, object: panel, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.watchClicks() }
        }
        return panel
    }

    private func fit() {
        guard let panel, let host else { return }
        host.layoutSubtreeIfNeeded()
        let size = host.fittingSize
        guard size.width > 0, size.height > 0, abs(size.height - panel.frame.height) > 0.5 || abs(size.width - panel.frame.width) > 0.5 else { return }
        panel.setFrame(NSRect(x: panel.frame.minX, y: panel.frame.maxY - size.height, width: size.width, height: size.height), display: true)
        panel.invalidateShadow()
    }

    // MARK: - Send

    /// Return: the input goes to the chosen mind, and the bar closes. The words that were said last
    /// are written first.
    private func submit() {
        guard model.voice != .finishing, !model.draft.isSending else { return }
        stopListening(keepingLastWords: true) { [weak self] in self?.send() }
    }

    private func send() {
        guard let opened, let mind = opened.minds.first(where: { $0.mind == model.mind }) else {
            return model.draft.refuse("No mind is set up: add one in the panel under the 𝑖.")
        }
        let files = model.draft.attachments.count
        let characters = model.draft.text.count
        guard let input = model.draft.submit(at: Date()) else { return }
        let id = model.draft.id
        let folder = Self.folder.appendingPathComponent(id)
        sendingTo = mind.mind
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try input.write(to: folder.appendingPathComponent("input.json"))
        } catch {
            let reason = "The input was not written: \(AppLog.describe(error))"
            model.draft.senderDidNotStart(reason)
            return settle(.failed(reason), of: id)
        }
        // the mind's bridge, held until the input went or failed
        let bridge = MindBridge.of(mind: mind.mind, name: mind.name, helpers: opened.helpers)
        sending[id] = bridge
        bridge.on("input") { [weak self, weak bridge] line in
            guard let self, let bridge else { return }
            self.bridgeSaid(line, from: bridge)
        }
        bridge.hold("input \(id)")
        bridge.send("input", ["input": id, "folder": folder.path])
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

    /// A line of the job `input`: an input's progress or end, or the end of the process.
    private func bridgeSaid(_ line: [String: Any], from bridge: MindBridge) {
        if let status = line["exited"] as? Int {
            for (id, held) in sending where held === bridge {
                letGo(id)
                senderEnded(Int32(status), of: id)
            }
            return
        }
        guard let id = line["input"] as? String, sending[id] === bridge else { return }
        if line["done"] != nil || line["failed"] != nil { letGo(id) }
        senderSaid(line, of: id)
    }

    private func letGo(_ id: String) {
        sending.removeValue(forKey: id)?.release("input \(id)")
    }

    private func senderSaid(_ line: [String: Any], of id: String) {
        guard id == model.draft.id else { return }
        settle(model.draft.senderSaid(line, next: MindInputModel.newId()), of: id)
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
            lastFailed = false
            // the new draft names none of the pictures that came with no file
            try? FileManager.default.removeItem(at: Self.pasted)
        case .failed(let reason):
            log.error("input \(id): not sent to \(sendingTo): \(reason)")
            // the fix, when the reason or the CLI's own file says the sign-in is missing
            let mind = sendingTo
            let address = SignIn.address(of: mind)
            model.fix = InputDraft.fix(for: reason, address: address)
            if model.fix == nil, !mind.isEmpty {
                Task { [weak self] in
                    let notSignedIn = await SignIn.read(mind) == .notSignedIn
                    guard let self, notSignedIn, self.model.draft.id == id, case .failed = self.model.draft.phase else { return }
                    self.model.fix = InputDraft.fix(for: reason, address: address, notSignedIn: true)
                }
            }
            lastLine = "Not sent to \(sendingTo) at \(Lend.clock(Date())): \(reason)"
            lastFailed = true
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

/// The bar, as a launcher draws it: the mind's face at the left; one column that the text, the
/// files, the line of keys and a failure all start at; the microphone and send at the right, at the
/// height of the first line.
struct MindInputBar: View {
    @ObservedObject var model: MindInputModel
    @ObservedObject private var faces = MindFaces.shared
    /// Drawn to a file (`--render-input`): a ground of its own colour and shadow, since no
    /// material blurs behind a picture.
    var isDrawing = false

    static let width: CGFloat = 720
    static let padding: CGFloat = 16
    static let radius: CGFloat = 18
    /// The face (30), its chevron and their gaps: where the text column starts.
    static let column: CGFloat = 58

    init(model: MindInputModel, isDrawing: Bool = false) {
        self.model = model
        self.isDrawing = isDrawing
    }

    private var shape: RoundedRectangle { RoundedRectangle(cornerRadius: Self.radius, style: .continuous) }

    private var title: String { model.mind.map { faces.face(of: $0).title } ?? "a mind" }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 12) {
                mindButton
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
                .padding(.top, (30 - MindInputModel.lineHeight) / 2)
                HStack(spacing: 10) {
                    MicrophoneButton(voice: model.voice, level: model.level, press: model.toggleMicrophone)
                        .disabled(model.draft.isSending)
                        .accessibilityIdentifier("input.microphone")
                    SendButton(phase: model.draft.phase, isEnabled: model.mind != nil && !model.draft.isEmpty && !model.draft.isSending, press: model.send)
                }
            }
            VStack(alignment: .leading, spacing: 10) {
                if !model.draft.attachments.isEmpty {
                    Flow(spacing: 6) {
                        ForEach(model.draft.attachments) { attachment in
                            AttachmentChip(attachment: attachment, remove: model.draft.isSending ? nil : { model.draft.remove(attachment.id) })
                        }
                    }
                }
                if case .failed(let reason) = model.draft.phase {
                    FailureLines(reason: reason, fix: model.fix)
                } else {
                    hints
                }
            }
            .padding(.leading, Self.column)
        }
        .padding(.top, Self.padding)
        .padding(.horizontal, Self.padding)
        .padding(.bottom, 12)
        .frame(width: Self.width)
        .background { ground }
        .overlay(
            shape.strokeBorder(
                model.isDropTargeted ? Color.accentColor : Self.edge,
                lineWidth: model.isDropTargeted ? 2 : 1))
        .onDrop(of: [UTType.fileURL, UTType.image], isTargeted: $model.isDropTargeted) { providers in
            model.drop(providers)
            return true
        }
    }

    /// A hairline, as a launcher's edge: dark on light, light on dark.
    private static let edge = Color(nsColor: NSColor(name: nil) {
        $0.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? NSColor(white: 1, alpha: 0.16) : NSColor(white: 0, alpha: 0.12)
    })
    /// The drawing's stand-in for the material: what `.popover` looks like over a desktop.
    private static let drawnGround = Color(nsColor: NSColor(name: nil) {
        $0.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? NSColor(calibratedWhite: 0.13, alpha: 1) : NSColor(calibratedWhite: 0.955, alpha: 1)
    })

    @ViewBuilder
    private var ground: some View {
        if isDrawing {
            shape.fill(Self.drawnGround).shadow(color: .black.opacity(0.3), radius: 16, y: 8)
        } else {
            BarMaterial()
        }
    }

    /// The mind the input goes to: its face; a click lists the minds this Mac knows.
    private var mindButton: some View {
        Button(action: model.showMinds) {
            HStack(spacing: 4) {
                if let mind = model.mind {
                    MindAvatar(mind: mind, size: 30)
                } else {
                    Circle()
                        .strokeBorder(Color.secondary.opacity(0.6), style: StrokeStyle(lineWidth: 1.2, dash: [3, 3]))
                        .frame(width: 30, height: 30)
                }
                Image(systemName: "chevron.down")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 12)
            }
        }
        .buttonStyle(MindMenuStyle())
        .fixedSize()
        .disabled(model.minds.isEmpty || model.draft.isSending)
        .help("The mind this input goes to. Tab chooses the next one.")
        .accessibilityLabel("To \(title). Choose the mind")
        .accessibilityIdentifier("input.mind")
    }

    /// The line under the text: where it goes (or what holds it up) at the left, the keys at the right.
    private var hints: some View {
        HStack(spacing: 12) {
            status
                .font(.system(size: 12))
                .lineLimit(1)
                .truncationMode(.tail)
                .layoutPriority(1)
            Spacer(minLength: 0)
            HStack(spacing: 12) {
                KeyHint(keys: "↩", words: "send")
                KeyHint(keys: "⇧↩", words: "new line")
                if model.minds.count > 1 { KeyHint(keys: "⇥", words: "next mind") }
                KeyHint(keys: "⌘D", words: "microphone")
                KeyHint(keys: "esc", words: "close")
            }
            .fixedSize()
        }
    }

    @ViewBuilder
    private var status: some View {
        if let refusal = model.draft.refusal {
            Label(refusal, systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(Palette.waitText)
        } else if model.draft.isSending {
            Text("Sending to \(title)…")
                .foregroundStyle(.secondary)
        } else if case .loading(let part) = model.voice {
            Text(SpeechSession.loadingLine(part))
                .foregroundStyle(.secondary)
        } else if case .failed(let reason) = model.voice {
            Label("Not listening: \(reason)", systemImage: "mic.slash")
                .foregroundStyle(Palette.waitText)
        } else if let mind = model.mind {
            Text("To \(title) · \(mind)")
                .foregroundStyle(.secondary)
        } else {
            Text("No mind is set up: add one in the panel under the 𝑖.")
                .foregroundStyle(.secondary)
        }
    }
}

/// A key and what it does, quiet: the key in secondary, the words in tertiary.
private struct KeyHint: View {
    let keys: String
    let words: String

    var body: some View {
        (Text(keys).foregroundStyle(.secondary) + Text(" \(words)").foregroundStyle(.tertiary))
            .font(.system(size: 11))
            .lineLimit(1)
    }
}

/// An input that did not go: the reason, the command that fixes it (with Copy), and what Return does now.
private struct FailureLines: View {
    let reason: String
    let fix: String?
    @State private var copied = false

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Label {
                    Text("Not sent: \(reason)")
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                } icon: {
                    Image(systemName: "exclamationmark.triangle.fill")
                }
                .font(.system(size: 12))
                .foregroundStyle(Palette.redText)
                .lineLimit(3)
                if fix == nil {
                    Spacer(minLength: 12)
                    again
                }
            }
            if let fix {
                HStack(spacing: 8) {
                    Text(fix)
                        .font(.system(size: 11.5, design: .monospaced))
                        .lineLimit(1)
                        .textSelection(.enabled)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 3)
                        .background(Palette.codeFill, in: RoundedRectangle(cornerRadius: 5, style: .continuous))
                    Button(copied ? "Copied" : "Copy") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(fix, forType: .string)
                        copied = true
                        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { copied = false }
                    }
                    .buttonStyle(FillButtonStyle(height: 22))
                    .help("Copy the command, then run it in a terminal.")
                    .accessibilityIdentifier("input.copyFix")
                    Spacer(minLength: 12)
                    again
                }
            }
        }
    }

    private var again: some View {
        KeyHint(keys: "↩", words: "sends it again").fixedSize()
    }
}

/// The bar's microphone. Off: a neutral circle. Listening: a red-tinted capsule with the loudness
/// and the microphone. Only the bars follow the loudness: the bar's text is not laid out again.
private struct MicrophoneButton: View {
    let voice: MindInputModel.Voice
    @ObservedObject var level: VoiceLevel
    let press: () -> Void

    var body: some View {
        Button(action: press) {
            Group {
                switch voice {
                case .listening:
                    HStack(spacing: 6) {
                        LevelBars(level: level.level, color: Palette.redText)
                        Image(systemName: "mic.fill").foregroundStyle(Palette.redText)
                    }
                    .padding(.horizontal, 10)
                    .frame(width: 62, height: 30)
                    .background(Palette.redWash, in: Capsule())
                case .loading:
                    HStack(spacing: 6) {
                        ProgressView().controlSize(.mini)
                        Image(systemName: "mic.fill").foregroundStyle(Palette.redText)
                    }
                    .frame(width: 62, height: 30)
                    .background(Palette.redWash, in: Capsule())
                case .finishing:
                    ProgressView().controlSize(.mini)
                        .frame(width: 30, height: 30)
                        .background(Palette.fill, in: Circle())
                case .off:
                    Image(systemName: "mic").foregroundStyle(.secondary)
                        .frame(width: 30, height: 30)
                        .background(Palette.fill, in: Circle())
                case .failed:
                    Image(systemName: "mic.slash").foregroundStyle(Palette.waitText)
                        .frame(width: 30, height: 30)
                        .background(Palette.fill, in: Circle())
                }
            }
            .font(.system(size: 14, weight: .medium))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .fixedSize()
        .help(voice.isOpen ? "The microphone is on: what you say is written here, on this Mac. Click to turn it off (⌘D)." : "The microphone is off. Click to talk (⌘D).")
        .accessibilityLabel(voice.isOpen ? "Microphone on" : "Microphone off")
    }
}

/// The bar's send button: what Return does. While the input goes, a ring shows how much went.
private struct SendButton: View {
    let phase: InputDraft.Phase
    let isEnabled: Bool
    let press: () -> Void

    var body: some View {
        // while the input goes, the button shows it at full strength and does nothing
        Button { if progress == nil { press() } } label: {
            ZStack {
                Circle().fill(isEnabled || progress != nil ? Color.accentColor : Palette.fill)
                if let progress {
                    Circle().stroke(Color.white.opacity(0.3), lineWidth: 2.5).padding(6)
                    Circle()
                        .trim(from: 0, to: max(0.06, progress))
                        .stroke(Color.white, style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                        .padding(6)
                        .animation(.easeOut(duration: 0.2), value: progress)
                } else {
                    Image(systemName: "arrow.up")
                        .font(.system(size: 14, weight: .bold))
                        .foregroundStyle(isEnabled ? Color.white : Color.secondary.opacity(0.6))
                }
            }
            .frame(width: 30, height: 30)
            .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled && progress == nil)
        .help("Send (↩)")
        .accessibilityLabel(progress == nil ? "Send" : "Sending")
        .accessibilityIdentifier("input.send")
    }

    private var progress: Double? {
        if case .sending(let progress) = phase { return progress }
        return nil
    }
}

private struct MindMenuStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .padding(.trailing, 2)
            .background(Color.primary.opacity(configuration.isPressed ? 0.1 : 0), in: Capsule())
            .contentShape(Capsule())
    }
}

/// The target of the minds' menu, and the faces drawn for it.
@MainActor
private final class MindMenuTarget: NSObject {
    static let shared = MindMenuTarget()
    var chosen: (String) -> Void = { _ in }

    @objc func choose(_ item: NSMenuItem) {
        if let mind = item.representedObject as? String { chosen(mind) }
    }

    /// A mind's face as a menu draws an image, 18 points.
    static func avatar(of mind: String) -> NSImage? {
        let renderer = ImageRenderer(content: MindAvatar(mind: mind, size: 18))
        renderer.scale = NSScreen.main?.backingScaleFactor ?? 2
        return renderer.nsImage
    }
}

/// The system's material behind the bar, cut to its rounded shape. The window's shadow follows it.
private struct BarMaterial: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        // follows the appearance, light or dark, as a popover's (.hudWindow is always dark)
        view.material = .popover
        view.blendingMode = .behindWindow
        view.state = .active
        view.maskImage = Self.mask
        return view
    }

    func updateNSView(_ view: NSVisualEffectView, context: Context) {}

    /// The rounded shape, stretched to any size.
    private static let mask: NSImage = {
        let radius = MindInputBar.radius
        let side = radius * 2 + 2
        let image = NSImage(size: NSSize(width: side, height: side), flipped: false) { rect in
            NSColor.black.setFill()
            NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius).fill()
            return true
        }
        image.capInsets = NSEdgeInsets(top: radius, left: radius, bottom: radius, right: radius)
        image.resizingMode = .stretch
        return image
    }()
}

/// Views in rows that wrap: the files.
private struct Flow: Layout {
    var spacing: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? .infinity
        let rows = arrange(subviews, in: width)
        return CGSize(width: proposal.width ?? rows.width, height: rows.height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let rows = arrange(subviews, in: bounds.width)
        for (index, frame) in rows.frames.enumerated() {
            subviews[index].place(at: CGPoint(x: bounds.minX + frame.minX, y: bounds.minY + frame.minY), proposal: ProposedViewSize(frame.size))
        }
    }

    private func arrange(_ subviews: Subviews, in width: CGFloat) -> (frames: [CGRect], width: CGFloat, height: CGFloat) {
        var frames: [CGRect] = []
        var x: CGFloat = 0
        var y: CGFloat = 0
        var row: CGFloat = 0
        var widest: CGFloat = 0
        for subview in subviews {
            var size = subview.sizeThatFits(.unspecified)
            size.width = min(size.width, width)
            if x > 0, x + size.width > width {
                x = 0
                y += row + spacing
                row = 0
            }
            frames.append(CGRect(origin: CGPoint(x: x, y: y), size: size))
            x += size.width + spacing
            row = max(row, size.height)
            widest = max(widest, x - spacing)
        }
        return (frames, widest, y + row)
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

    /// Each file's icon, asked of macOS once, not at each drawing of the bar. A few dozen at most.
    private static var icons: [String: NSImage] = [:]

    private var icon: NSImage {
        if let icon = Self.icons[attachment.local] { return icon }
        if Self.icons.count >= 64 { Self.icons.removeAll() }
        let icon = NSWorkspace.shared.icon(forFile: attachment.local)
        Self.icons[attachment.local] = icon
        return icon
    }

    var body: some View {
        HStack(spacing: 6) {
            Image(nsImage: icon)
                .resizable()
                .frame(width: 16, height: 16)
            Text(name).fontWeight(.medium)
            Text(InputDraft.size(attachment.bytes)).foregroundStyle(.secondary)
            if let remove {
                Button(action: remove) {
                    Image(systemName: "xmark")
                        .font(.system(size: 9, weight: .semibold))
                        .frame(width: 16, height: 16)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .help("Take this file away")
                .accessibilityLabel("Remove \(attachment.name)")
            }
        }
        .font(.system(size: 12))
        .lineLimit(1)
        .padding(.leading, 8)
        .padding(.trailing, remove == nil ? 8 : 4)
        .frame(height: 26)
        .background(Palette.fill, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
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

/// The text view in the bar, as tall as its lines, at most six of them: then it scrolls inside.
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
            let height = min(max(ceil(layout.usedRect(for: container).height), MindInputModel.lineHeight), MindInputModel.lineHeight * MindInputModel.mostLines)
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
        // as wide as the scroll view's content (none yet): the width then follows it exactly. A
        // wider start stayed that much wider, and its lines wrapped under the buttons.
        let field = InputField(frame: NSRect(origin: .zero, size: scroll.contentSize))
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
    /// Draws the bar in its states (empty, listening, with a text and files, while it sends, not
    /// sent, not sent with the command that fixes it), each in the light and the dark appearance:
    /// PNG files in `folder`, for a look with no Mac (`--render-input <folder>`). The minds are the
    /// drawings' (`Rendering`). The ground around the bar stands for a desktop.
    static func render(to folder: URL) -> Bool {
        _ = NSApplication.shared
        Rendering.fixFaces()
        let minds = Rendering.minds
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        var drawn = true
        for state in ["empty", "listening", "filled", "sending", "failed", "failed-fix"] {
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
            if state == "filled" { model.voice = .listening; model.level.level = 0.7 }
            if state != "empty", state != "listening", state != "filled" { _ = model.draft.submit(at: Rendering.now) }
            if state == "sending" { _ = model.draft.senderSaid(["progress": 0.4], next: "next") }
            if state == "failed" { _ = model.draft.senderEnded(status: 1) }
            if state == "failed-fix" {
                let mind = minds.first?.mind ?? "example.com"
                let reason = "Not signed in to \(SignIn.address(of: mind)): run `iterate login` once."
                _ = model.draft.senderSaid(["failed": reason], next: "next")
                model.fix = InputDraft.fix(for: reason, address: SignIn.address(of: mind))
            }
            for (dark, tone) in [(false, "light"), (true, "dark")] {
                let desktop = Color(nsColor: dark ? NSColor(srgbRed: 0.2, green: 0.21, blue: 0.23, alpha: 1) : NSColor(srgbRed: 0.78, green: 0.8, blue: 0.82, alpha: 1))
                let view = MindInputBar(model: model, isDrawing: true).padding(32).background(desktop)
                drawn = Rendering.png(of: view, dark: dark, to: folder.appendingPathComponent("input-\(state)-\(tone).png")) && drawn
            }
        }
        return drawn
    }
}
