import AVFoundation
import AppKit
import Carbon.HIToolbox
import SpeechText
import SwiftUI
import VoiceMeetCore

/// What the dictation pill shows.
@MainActor
final class DictationPillModel: ObservableObject {
    enum Phase: Equatable {
        case loading(Double)
        case listening
        case writing
        case failed(String)
    }

    @Published var phase: Phase = .listening
    @Published var level: Float = 0
    @Published var text = ""
}

/// DICTATION: hold ⌥⇧D in any app and talk; let go, and what you said is written where the cursor
/// is (README, "Dictation"). A short press starts a dictation that goes on with no key held, and
/// the next press ends it. After the open source app Hex (github.com/anomalyco/hex).
///
/// The speech model runs on this Mac (`SpeechListener`): no sound and no text leaves it. The word
/// list of the mind this Mac is lent to makes the mind's names and terms come out right. The text
/// goes in through the clipboard and ⌘V, which needs the Accessibility permission; without it the
/// text stays on the clipboard for the person's own ⌘V.
@MainActor
final class Dictation {
    var words: () -> WordList = { .empty }
    /// Opens the guide for a permission of macOS.
    var allow: (Permission) -> Void = { _ in }
    var onChange: () -> Void = {}
    /// How the last dictation ended, for the panel.
    private(set) var lastLine: String?
    var isRunning: Bool { listener != nil }

    private let log = AppLog("dictation")
    private var key = DictationKey()
    private var listener: SpeechListener?
    /// Counts the listenings, so that a late word of an old one changes nothing.
    private var round = 0
    private let pill = DictationPillModel()
    private var panel: NSPanel?
    private var hide: DispatchWorkItem?

    func pressed() {
        switch key.pressed(at: Date()) {
        case .start: start()
        case .finish: finish()
        case .nothing: break
        }
    }

    func released() {
        if key.released(at: Date()) == .finish { finish() }
    }

    private func start() {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            break
        case .notDetermined:
            // macOS asks now; the next press dictates
            key.ended()
            AVCaptureDevice.requestAccess(for: .audio) { _ in }
            return
        default:
            key.ended()
            return allow(.microphone)
        }
        round += 1
        let round = round
        let listener = SpeechListener()
        self.listener = listener
        pill.phase = SpeechModels.isOnDisk ? .listening : .loading(0)
        pill.text = ""
        pill.level = 0
        showPill()
        log.info("start")
        listener.start(words: words()) { [weak self] event in
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.heard(event, round: round) } }
        }
        onChange()
    }

    private func heard(_ event: SpeechListener.Event, round: Int) {
        if case .note(let note) = event { return log.info(note) }
        guard round == self.round, listener != nil else { return }
        switch event {
        case .loading(let progress):
            if progress < 1 { pill.phase = .loading(progress) }
        case .listening:
            if case .loading = pill.phase { pill.phase = .listening }
        case .text(let text):
            pill.text = text
        case .level(let level):
            pill.level = level
        case .failed(let reason):
            listener = nil
            key.ended()
            end("Not written at \(Lend.clock(Date())): \(reason)", failed: reason)
        case .note:
            break
        }
    }

    private func finish() {
        guard let listener else { return }
        self.listener = nil
        pill.phase = .writing
        pill.level = 0
        Task { @MainActor in
            let text = await listener.finish()
            self.write(text)
        }
    }

    /// The text goes where the cursor is: on the clipboard, ⌘V, and the clipboard as it was.
    private func write(_ text: String) {
        guard !text.isEmpty else { return end("Heard no words at \(Lend.clock(Date()))", failed: nil) }
        let words = Spoken.wordCount(text)
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
        if let failed {
            pill.phase = .failed(failed)
            hidePill(after: 4)
        } else {
            hidePill(after: 0)
        }
        onChange()
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
            MainActor.assumeIsolated { if self?.listener == nil { self?.panel?.orderOut(nil) } }
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

/// The microphone's loudness as five bars.
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
            case .loading(let progress):
                ProgressView(value: progress).frame(width: 44)
                Text(progress > 0 ? "Getting the speech model: \(Int(progress * 100))%. Talk now, it is kept." : "Loading the speech model. Talk now, it is kept.")
                    .foregroundStyle(.secondary)
            case .listening:
                LevelBars(level: model.level)
                Text(model.text.isEmpty ? "Listening" : tail)
                    .foregroundStyle(model.text.isEmpty ? .secondary : .primary)
                    .lineLimit(2)
                    .truncationMode(.head)
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
        .background(.regularMaterial, in: Capsule())
        .overlay(Capsule().strokeBorder(Color.primary.opacity(0.15), lineWidth: 1))
    }
}

extension Dictation {
    /// Draws the pill in its states, light and dark: PNG files in `folder` (`--render-input`).
    static func render(to folder: URL) -> Bool {
        var drawn = true
        let states: [(String, DictationPillModel.Phase, String)] = [
            ("loading", .loading(0.42), ""),
            ("listening", .listening, "Open the roadmap on Misha's computer and tell him why. The two files are what"),
            ("failed", .failed("On the clipboard: press ⌘V"), ""),
        ]
        for (name, phase, text) in states {
            let model = DictationPillModel()
            model.phase = phase
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

/// A SwiftUI view as a PNG file, for a look with no Mac (the `--render-*` flags).
@MainActor
enum Rendering {
    static func png<Content: View>(of content: Content, dark: Bool, to file: URL) -> Bool {
        _ = NSApplication.shared
        let appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        let view = NSHostingView(rootView: content)
        view.appearance = appearance
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: view.fittingSize), styleMask: [.borderless], backing: .buffered, defer: false)
        window.appearance = appearance
        window.contentView = view
        view.layoutSubtreeIfNeeded()
        // A text view learns its height after the first layout: size the window again to it.
        for _ in 0..<3 {
            RunLoop.main.run(until: Date().addingTimeInterval(0.05))
            window.setContentSize(view.fittingSize)
            view.layoutSubtreeIfNeeded()
        }
        guard let picture = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return false }
        view.cacheDisplay(in: view.bounds, to: picture)
        return picture.representation(using: .png, properties: [:]).map { (try? $0.write(to: file)) != nil } ?? false
    }
}
