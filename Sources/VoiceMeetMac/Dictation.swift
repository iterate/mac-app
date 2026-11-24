import AppKit
import Carbon.HIToolbox
import SpeechText
import SwiftUI
import VoiceMeetCore

/// What the dictation pill shows.
@MainActor
final class DictationPillModel: ObservableObject {
    enum Phase: Equatable {
        /// The model comes: the part of its download, or nil while it only loads.
        case loading(Double?)
        case listening
        case writing
        case failed(String)
    }

    /// How the dictation goes on: with the key held, or with no key (and what ends it).
    enum Mode: Equatable {
        case holding(key: String)
        case handsFree(stop: String)

        var line: String {
            switch self {
            case .holding(let key): return "let go of \(key) to write"
            case .handsFree(let stop): return "hands-free · \(stop) to stop · esc cancels"
            }
        }
    }

    @Published var phase: Phase = .listening
    @Published var mode: Mode?
    @Published var level: Float = 0
    @Published var text = ""
}

/// DICTATION: talk in any app, and what you said is written where the cursor is (README,
/// "Dictation"). Two keys start it:
///
/// - fn (🌐), as Wispr Flow has it (`FnKey`): hold it to talk and let go to write; tap it twice to
///   talk hands-free until the next tap. Escape cancels.
/// - ⌥⇧D, as Hex has it (`DictationKey`): hold it and talk; a short press keeps it on until the
///   next press.
///
/// The listening is the app's one foreground listening (`SpeechSession`), on this Mac: no sound and
/// no text leaves it. The word list of the mind this Mac is lent to makes the mind's names and
/// terms come out right. The text goes in through the clipboard and ⌘V, which needs the
/// Accessibility permission; without it the text stays on the clipboard for the person's own ⌘V.
/// fn is read with a monitor of the keyboard's modifier keys, which macOS gives only to an app
/// with Accessibility.
///
/// A copy with a home of its own (`AppEnvironment`) watches no key and opens no microphone unless
/// an audio fixture is set; it writes nothing: the text is kept for the control socket alone.
@MainActor
final class Dictation: SpeechClient {
    var words: () -> WordList = { .empty }
    /// Opens the guide for a permission of macOS.
    var allow: (Permission) -> Void = { _ in }
    var onChange: () -> Void = {}
    /// How the last dictation ended, for the panel.
    private(set) var lastLine: String?
    /// The last dictation failed or wrote nothing where the cursor is: the panel draws its line in orange.
    private(set) var lastFailed = false
    /// The last dictation's text, in memory only: for the control socket, never for the log.
    private(set) var lastText: String?
    var isRunning: Bool { session.isListening(for: self) }

    private let session: SpeechSession
    private let log = AppLog("dictation")
    private var key = DictationKey()
    private var fn = FnKey()
    private var fnMonitors: [Any] = []
    /// Whether macOS gave Accessibility when the fn monitors were made: they hear nothing without it.
    private var fnIsTrusted = false
    private var trustWatch: Timer?
    private let pill = DictationPillModel()
    private var panel: NSPanel?
    private var hide: DispatchWorkItem?

    init(session: SpeechSession) {
        self.session = session
    }

    // MARK: - The keys

    /// ⌥⇧D down.
    func pressed() {
        switch key.pressed(at: Date()) {
        case .start: start(.holding(key: "⌥⇧D"))
        case .finish: finish()
        case .nothing: break
        }
    }

    /// ⌥⇧D up: a short press keeps the dictation on.
    func released() {
        if key.released(at: Date()) == .finish { return finish() }
        if key.isOn, isRunning { pill.mode = .handsFree(stop: "press ⌥⇧D") }
    }

    /// fn went down or up (the monitor, or `dictation.fn` on the control socket).
    func fnChanged(down: Bool) {
        let now = Date()
        act(down ? fn.fnDown(at: now) : fn.fnUp(at: now))
        // a press longer than `FnKey.hold` is a hold: one look after it
        if down {
            DispatchQueue.main.asyncAfter(deadline: .now() + FnKey.hold + 0.02) { [weak self] in
                MainActor.assumeIsolated { guard let self else { return }; self.act(self.fn.tick(at: Date())) }
            }
        }
    }

    private func act(_ act: FnKey.Act) {
        switch act {
        case .nothing: break
        case .startHolding: start(.holding(key: "fn"))
        case .startHandsFree: start(.handsFree(stop: "tap fn"))
        case .finish: finish()
        case .cancel: cancel()
        }
    }

    /// Watches fn in every app. Made again once macOS gives Accessibility.
    func watchFn() {
        guard !AppEnvironment.current.hasOwnHome else { return log.info("fn: not watched in a home of its own (dictation.fn on the control socket)") }
        for monitor in fnMonitors { NSEvent.removeMonitor(monitor) }
        let handle: (NSEvent) -> Void = { [weak self] event in MainActor.assumeIsolated { self?.keyboard(event) } }
        fnMonitors = [
            NSEvent.addGlobalMonitorForEvents(matching: [.flagsChanged, .keyDown], handler: handle),
            NSEvent.addLocalMonitorForEvents(matching: [.flagsChanged, .keyDown]) { event in
                handle(event)
                return event
            },
        ].compactMap { $0 }
        fnIsTrusted = AXIsProcessTrusted()
        log.info(fnIsTrusted ? "fn: held, dictates; tapped twice, dictates hands-free" : "fn: needs Accessibility to be heard in other apps")
        trustWatch?.invalidate()
        trustWatch = nil
        guard !fnIsTrusted else { return }
        trustWatch = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, AXIsProcessTrusted() else { return }
                self.watchFn()
                self.onChange()
            }
        }
    }

    private func keyboard(_ event: NSEvent) {
        if event.type == .flagsChanged {
            // fn is 63; some keyboards' 🌐 key says 179
            if event.keyCode == UInt16(kVK_Function) || event.keyCode == 179 {
                fnChanged(down: event.modifierFlags.contains(.function))
            } else {
                act(fn.otherKey())
            }
        } else if event.keyCode == UInt16(kVK_Escape) {
            escape()
        } else {
            act(fn.otherKey())
        }
    }

    /// Escape ends a hands-free dictation and writes nothing.
    private func escape() {
        if fn.escape() == .cancel { return cancel() }
        if key.isOn, isRunning, case .handsFree = pill.mode { cancel() }
    }

    /// The lines that the panel shows under the speech model about fn: what keeps it from working.
    var fnLines: [String] {
        guard !AppEnvironment.current.isRendering, !AppEnvironment.current.hasOwnHome else { return [] }
        var lines: [String] = []
        if !AXIsProcessTrusted() { lines.append("fn dictation needs Accessibility") }
        // 0 is "Do Nothing"; with no value macOS does its default (the emoji picker or its own dictation)
        if UserDefaults(suiteName: "com.apple.HIToolbox")?.object(forKey: "AppleFnUsageType") as? Int != 0 {
            lines.append("macOS acts on 🌐 too: set System Settings › Keyboard › “Press 🌐 key to” to “Do Nothing”")
        }
        return lines
    }

    // MARK: - The listening

    private func start(_ mode: DictationPillModel.Mode) {
        pill.text = ""
        pill.level = 0
        pill.mode = mode
        switch session.start(self, words: words()) {
        case nil:
            showPill()
            log.info("start: \(mode.line)")
        case .ownHome:
            ended()
            end("Not started at \(Lend.clock(Date())): a home of its own opens no microphone", failed: nil)
        case .asking:
            // macOS asks now; the next press dictates
            ended()
        case .notAllowed:
            ended()
            allow(.microphone)
        }
        onChange()
    }

    /// The keys know that no dictation runs.
    private func ended() {
        key.ended()
        fn.ended()
    }

    func speech(_ event: SpeechSession.Event) {
        switch event {
        case .phase(let phase):
            guard pill.phase != .writing else { return }
            if case .loading(let part) = phase { pill.phase = .loading(part) } else { pill.phase = .listening }
        case .text(let text):
            pill.text = text
        case .level(let level):
            pill.level = level
        case .failed(let reason):
            ended()
            end("Not written at \(Lend.clock(Date())): \(reason)", failed: reason)
        case .ended(let text):
            // after this dictation's own end, or when the input bar started to listen
            ended()
            write(text)
        }
    }

    private func finish() {
        guard isRunning else { return ended() }
        pill.phase = .writing
        pill.level = 0
        session.finish(self)
        onChange()
    }

    private func cancel() {
        guard isRunning else { return ended() }
        session.cancel(self)
        ended()
        end("Cancelled at \(Lend.clock(Date()))", failed: nil)
    }

    /// The text goes where the cursor is: on the clipboard, ⌘V, and the clipboard as it was.
    private func write(_ text: String) {
        lastText = text
        guard !text.isEmpty else { return end("Heard no words at \(Lend.clock(Date()))", failed: nil) }
        let words = Spoken.wordCount(text)
        guard !AppEnvironment.current.hasOwnHome else {
            return end("Heard \(words) words at \(Lend.clock(Date())); a home of its own writes them nowhere", failed: nil)
        }
        let pasteboard = NSPasteboard.general
        guard AXIsProcessTrusted() else {
            pasteboard.clearContents()
            pasteboard.setString(text, forType: .string)
            allow(.accessibility)
            return end("\(words) words are on the clipboard (\(Lend.clock(Date()))): iterate needs Accessibility to write them for you", failed: "On the clipboard: press ⌘V")
        }
        // what the clipboard held, to put it back
        let kept = (pasteboard.pasteboardItems ?? []).map { item in
            item.types.compactMap { type in item.data(forType: type).map { (type, $0) } }
        }
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
        let source = CGEventSource(stateID: .hidSystemState)
        for isDown in [true, false] {
            let event = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(kVK_ANSI_V), keyDown: isDown)
            // ⌘ alone, whatever keys the person still holds
            event?.flags = .maskCommand
            event?.post(tap: .cgSessionEventTap)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
            // the person copied something else meanwhile: that stays
            guard pasteboard.string(forType: .string) == text else { return }
            pasteboard.clearContents()
            pasteboard.writeObjects(kept.map { types in
                let item = NSPasteboardItem()
                for (type, data) in types { item.setData(data, forType: type) }
                return item
            })
        }
        end("Wrote \(words) words at \(Lend.clock(Date()))", failed: nil)
    }

    private func end(_ line: String, failed: String?) {
        // the log holds counts, never the words
        log.info(line)
        lastLine = line
        lastFailed = failed != nil
        if let failed {
            pill.phase = .failed(failed)
            hidePill(after: 4)
        } else {
            hidePill(after: 0)
        }
        onChange()
    }

    /// For `ui.state` on the control socket.
    func controlState() -> [String: Any] {
        var phase: String
        switch pill.phase {
        case .loading(let part): phase = part == nil ? "loading" : "downloading"
        case .listening: phase = "listening"
        case .writing: phase = "writing"
        case .failed(let reason): phase = "failed: \(reason)"
        }
        var mode: Any = NSNull()
        if isRunning, let shown = pill.mode {
            if case .holding = shown { mode = "holding" } else { mode = "hands-free" }
        }
        return [
            "running": isRunning, "pillVisible": panel?.isVisible ?? false, "phase": phase, "mode": mode, "text": pill.text,
            "lastLine": lastLine ?? NSNull(), "lastText": lastText ?? NSNull(),
        ]
    }

    // MARK: - The pill

    private func showPill() {
        hide?.cancel()
        let panel = self.panel ?? makePanel()
        // at the bottom of the display under the pointer
        let pointer = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { NSMouseInRect(pointer, $0.frame, false) } ?? NSScreen.main
        if let visible = screen?.visibleFrame {
            panel.setFrameOrigin(NSPoint(x: visible.midX - panel.frame.width / 2, y: visible.minY + 90))
        }
        panel.orderFrontRegardless()
    }

    private func hidePill(after seconds: Double) {
        hide?.cancel()
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                guard let self, !self.isRunning else { return }
                self.panel?.orderOut(nil)
            }
        }
        hide = work
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: work)
    }

    private func makePanel() -> NSPanel {
        let host = NSHostingView(rootView: DictationPill(model: pill))
        let panel = NSPanel(contentRect: NSRect(origin: .zero, size: host.fittingSize), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        // it takes no click and no key: the app in front keeps both
        panel.ignoresMouseEvents = true
        panel.contentView = host
        self.panel = panel
        return panel
    }
}

struct LevelBars: View {
    let level: Float
    var color: Color = .red

    var body: some View {
        HStack(spacing: 2) {
            ForEach(0..<5, id: \.self) { index in
                // the middle bars are the tallest
                let shape: CGFloat = [0.5, 0.8, 1, 0.8, 0.5][index]
                Capsule()
                    .fill(color)
                    .frame(width: 3, height: 4 + 12 * shape * CGFloat(min(max(level, 0), 1)))
            }
        }
        .frame(height: 16)
        .animation(.easeOut(duration: 0.12), value: level)
    }
}

/// The pill at the bottom of the screen while a dictation goes: what is heard, as it is heard.
struct DictationPill: View {
    @ObservedObject var model: DictationPillModel

    static let width: CGFloat = 460

    /// The end of the text: the words that were said last.
    private var tail: String {
        model.text.count <= 120 ? model.text : "…" + model.text.suffix(120)
    }

    var body: some View {
        HStack(spacing: 10) {
            switch model.phase {
            case .loading(let part):
                if let part { ProgressView(value: part).frame(width: 44) } else { ProgressView().controlSize(.small) }
                Text(SpeechSession.loadingLine(part))
                    .foregroundStyle(.secondary)
            case .listening:
                LevelBars(level: model.level)
                VStack(alignment: .leading, spacing: 2) {
                    Text(model.text.isEmpty ? "Listening" : tail)
                        .foregroundStyle(model.text.isEmpty ? .secondary : .primary)
                        .lineLimit(2)
                        .truncationMode(.head)
                    if let mode = model.mode {
                        Text(mode.line).font(.system(size: 11)).foregroundStyle(.secondary)
                    }
                }
            case .writing:
                ProgressView().controlSize(.small)
                Text(model.text.isEmpty ? "Writing" : tail)
                    .lineLimit(2)
                    .truncationMode(.head)
            case .failed(let reason):
                Image(systemName: "exclamationmark.circle.fill").foregroundStyle(.red)
                Text(reason).lineLimit(2)
            }
            Spacer(minLength: 0)
        }
        .font(.system(size: 13))
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .frame(width: Self.width, alignment: .leading)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Color.primary.opacity(0.15), lineWidth: 1))
    }
}

extension Dictation {
    /// Draws the pill in its states, light and dark: PNG files in `folder` (`--render-input`).
    static func render(to folder: URL) -> Bool {
        var drawn = true
        let states: [(String, DictationPillModel.Phase, String, DictationPillModel.Mode?)] = [
            ("loading", .loading(0.42), "", nil),
            ("listening", .listening, "Open the roadmap on Misha's computer and tell him why. The two files are what", .handsFree(stop: "tap fn")),
            ("failed", .failed("On the clipboard: press ⌘V"), "", nil),
        ]
        for (name, phase, text, mode) in states {
            let model = DictationPillModel()
            model.phase = phase
            model.mode = mode
            model.text = text
            model.level = 0.7
            for (dark, tone) in [(false, "light"), (true, "dark")] {
                let view = DictationPill(model: model).padding(24).background(Color(nsColor: .windowBackgroundColor))
                drawn = drawn && Rendering.png(of: view, dark: dark, to: folder.appendingPathComponent("dictation-\(name)-\(tone).png"))
            }
        }
        return drawn
    }
}
