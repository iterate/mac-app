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

    /// The pill's clock: none while it is hidden, so that nothing ticks then.
    enum Clock: Equatable {
        case none
        case since(Date)
        /// A drawing's fixed time.
        case fixed(TimeInterval)
    }

    @Published var phase: Phase = .listening
    /// It stays on with no key held (double-tap fn, or a tap of ⌥⇧D).
    @Published var locked = false
    @Published var clock = Clock.none
    @Published var level: Float = 0
    /// The text that is written: the terms alone.
    @Published private(set) var text = ""
    /// What the pill shows of it: its end, with each correction of the word list as the heard
    /// words struck through and the term after them. Made once for each new text, not when it draws.
    @Published private(set) var shown = AttributedString()
    /// Settings › Dictation, "Show the words in one row": off, the pill has the level bars and the time alone.
    @Published var showsWords = true

    /// The most characters the pill shows: the end of the text is plenty for one row.
    static let shownLength = 200

    /// A new text, as it was heard and with its corrections.
    func show(_ heard: HeardText) {
        text = heard.text
        shown = Self.shown(heard)
    }

    /// The heard text with each correction struck through in the second colour, a space, and
    /// the term in the first: its last `shownLength` characters.
    static func shown(_ heard: HeardText) -> AttributedString {
        var shown = AttributedString()
        var at = heard.heard.startIndex
        for correction in heard.corrections {
            shown += AttributedString(heard.heard[at..<correction.range.lowerBound])
            var struck = AttributedString(correction.heard)
            struck.foregroundColor = Theme.t2
            struck.strikethroughStyle = Text.LineStyle(pattern: .solid, color: Theme.t2)
            shown += struck
            // a whole space (a thin one let the struck line run into the term), then the term, in the
            // text's own colour
            shown += AttributedString(" " + correction.term)
            at = correction.range.upperBound
        }
        shown += AttributedString(heard.heard[at...])
        let count = shown.characters.count
        guard count > shownLength else { return shown }
        return AttributedString(shown[shown.characters.index(shown.startIndex, offsetBy: count - shownLength)...])
    }
}

/// DICTATION: talk in any app, and what you said is written where the cursor is (README,
/// "Dictation"). Hold fn (🌐) and talk; let go, and the text is written. Double-tap fn to keep it
/// on with no key held: the next press of fn writes the text. Esc throws it away. ⌥⇧D works too:
/// hold it and talk, or tap it to keep it on until the next press. One `DictationKey` decides for
/// both keys; this class holds its timer.
///
/// fn is heard by one event tap (`FnTap`), which macOS gives only to an app with Accessibility.
/// Without it, ⌥⇧D (a Carbon hot key, no permission) still works, and its first use opens the
/// permission's guide.
///
/// The listening is the app's one foreground listening (`SpeechSession`), on this Mac: no sound and
/// no text leaves it. The word list of the mind this Mac is lent to makes the mind's names and
/// terms come out right. The text goes in through the clipboard and ⌘V, which needs the
/// Accessibility permission too; without it the text stays on the clipboard for the person's own ⌘V.
///
/// Settings › Dictation changes it (`Choices`): fn can be turned off (⌥⇧D stays), the double tap
/// too (a tap alone then ends at once), the pill can leave the words out, and the text can go on
/// the clipboard only.
///
/// A copy with a home of its own (`AppEnvironment`) taps no key and opens no microphone unless
/// an audio fixture is set; it writes nothing: the text is kept for the control socket alone.
@MainActor
final class Dictation: SpeechClient {
    var words: () -> WordList = { .empty }
    /// The words of a stretch of the transcription stream between two Unix times (`Listening.said`).
    var said: (_ from: Double, _ to: Double, _ stretch: String) -> String = { _, _, _ in "" }
    /// Opens the guide for a permission of macOS.
    var allow: (Permission) -> Void = { _ in }
    var onChange: () -> Void = {}
    /// How the last dictation ended, for the panel.
    private(set) var lastLine: String?
    /// The last dictation failed or wrote nothing where the cursor is: the panel draws its line in orange.
    private(set) var lastFailed = false
    /// The last dictation's text, in memory only: for the control socket, never for the log.
    private(set) var lastText: String?
    /// How many dictations ended with a line, for the control socket.
    private var ends = 0
    var isRunning: Bool { session.isListening(for: self) }
    /// Whether fn is heard in every app.
    var hearsFn: Bool { tap.isRunning }

    private let session: SpeechSession
    private let log = AppLog("dictation")
    private var key = DictationKey()
    /// Ends the window of a single tap of fn (`DictationKey.Act.wait`).
    private var window: DispatchWorkItem?
    private lazy var tap = FnTap { [weak self] event in self?.heard(event) }
    private var trustWatch: NSObjectProtocol?
    private var guideOpened = false
    private let pill = DictationPillModel()
    private var panel: NSPanel?
    private var hide: DispatchWorkItem?
    /// The start sound of a hold of fn, which waits `fnCueDelay`.
    private var startCue: DispatchWorkItem?
    /// This dictation made its start sound (or would have, in a home of its own).
    private var cued = false
    /// fn down plays the start sound only after this, with fn still held and no other key: a tap
    /// of fn alone and most fn-arrow combinations make no sound. The microphone opens at once.
    static let fnCueDelay: TimeInterval = 0.2

    init(session: SpeechSession) {
        self.session = session
    }

    // MARK: - The keys

    /// ⌥⇧D down, or the panel's Dictate button.
    func shortcutPressed() {
        if !guideOpened, !tap.isRunning, !AppEnvironment.current.hasOwnHome, !AXIsProcessTrusted() {
            // the first use with no fn: the permission that fn and writing the text need
            guideOpened = true
            allow(.accessibility)
        }
        act(key.down(.shortcut, at: Date()))
    }

    /// ⌥⇧D up: a short press keeps the dictation on.
    func shortcutReleased() {
        act(key.up(at: Date()))
    }

    /// fn went down or up (the tap, or `dictation.fn` on the control socket).
    func fnChanged(down: Bool, at time: Date = Date()) {
        act(down ? key.down(.fn, at: time) : key.up(at: time))
    }

    /// `dictation.start` on the control socket: fn down, as a hold.
    func holdStarted() {
        fnChanged(down: true)
    }

    /// `dictation.stop`: fn up, at least `DictationKey.hold` after its press.
    func holdEnded() {
        var time = Date()
        if case .pressed(let since) = key.state { time = max(time, since.addingTimeInterval(DictationKey.hold)) }
        fnChanged(down: false, at: time)
    }

    /// Esc (the tap, or `dictation.esc` on the control socket).
    func escape() {
        act(key.escape())
    }

    private func heard(_ event: FnTap.Event) {
        switch event {
        case .fn(let down, let time):
            // Settings › Dictation, "Hold to talk" removed: fn is the keyboard's alone
            guard Choices.shared.dictationOnFn || key.state != .idle else { return }
            fnChanged(down: down, at: time)
        case .escape: escape()
        case .otherKey:
            if key.wantsOtherKeys { log.info("fn with another key: a combination, the dictation ends") }
            act(key.otherKey())
        }
    }

    private func act(_ act: DictationKey.Act) {
        switch act {
        case .nothing: break
        case .start: start()
        case .wait(let until):
            // no double tap: a tap alone ends at once, with no sign
            if Choices.shared.doubleTap { waitForSecondTap(until: until) } else { return self.act(key.windowEnded(at: until)) }
        case .lock:
            // a double tap of fn: its first press was too short for the start sound
            cueStart()
            pill.locked = true
            log.info("locked: on until the next press")
            onChange()
        case .finish: finish()
        case .cancel(let quietly): cancel(quietly: quietly)
        }
        keyChanged()
    }

    private func waitForSecondTap(until: Date) {
        window?.cancel()
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.act(self.key.windowEnded(at: max(Date(), until)))
            }
        }
        window = work
        DispatchQueue.main.asyncAfter(deadline: .now() + max(0, until.timeIntervalSinceNow), execute: work)
    }

    /// The tap hears only what the key's state needs.
    private func keyChanged() {
        if case .tapped = key.state {} else {
            window?.cancel()
            window = nil
        }
        tap.want(FnTap.Interest(escape: key.state != .idle, swallowsEscape: key.isLocked))
    }

    /// Hears fn in every app: one event tap, made once macOS gives Accessibility.
    func watchKeys() {
        guard !AppEnvironment.current.hasOwnHome else { return log.info("fn: not tapped in a home of its own (dictation.fn on the control socket)") }
        guard !tap.isRunning else { return }
        if tap.start() {
            log.info("fn: held, dictates; tapped twice, stays on")
            if let trustWatch { DistributedNotificationCenter.default().removeObserver(trustWatch) }
            trustWatch = nil
            onChange()
            return
        }
        log.info("fn: needs Accessibility to be heard; ⌥⇧D works")
        guard trustWatch == nil else { return }
        // macOS posts this when the list of apps with Accessibility changes; the answer of
        // `AXIsProcessTrusted` follows a moment later
        trustWatch = DistributedNotificationCenter.default().addObserver(
            forName: NSNotification.Name("com.apple.accessibility.api"), object: nil, queue: .main
        ) { [weak self] _ in
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { MainActor.assumeIsolated { self?.watchKeys() } }
        }
    }

    /// The lines that the panel shows under the speech model about fn: what keeps it from working.
    var fnLines: [String] {
        guard !AppEnvironment.current.isRendering, !AppEnvironment.current.hasOwnHome else { return [] }
        var lines: [String] = []
        if !tap.isRunning { lines.append("fn dictation needs Accessibility") }
        // 0 is "Do Nothing"; with no value macOS does its default (the emoji picker or its own dictation)
        if UserDefaults(suiteName: "com.apple.HIToolbox")?.object(forKey: "AppleFnUsageType") as? Int != 0 {
            lines.append("macOS acts on 🌐 too: set System Settings › Keyboard › “Press 🌐 key to” to “Do Nothing”")
        }
        return lines
    }

    // MARK: - The listening

    private func start() {
        pill.show(.empty)
        pill.level = 0
        pill.locked = false
        pill.showsWords = Choices.shared.pillShowsWords
        // the phase of an earlier dictation (writing) is not this one's
        pill.phase = .listening
        switch session.start(self, words: words()) {
        case nil:
            pill.clock = .since(Date())
            showPill()
            // after the microphone opened: the sound never holds it up
            cued = false
            if key.press == .fn { cueStartAfterHold() } else { cueStart() }
            log.info("start: \(key.press == .fn ? "fn" : "⌥⇧D")")
        case .ownHome:
            ended()
            end("Not started at \(Lend.clock(Date())): a home of its own opens no microphone", failed: nil)
        case .asking:
            // macOS asks now; the next press dictates
            ended()
        case .notAllowed:
            ended()
            allow(.microphone)
        case .failed(let reason):
            ended()
            end("Not started at \(Lend.clock(Date())): \(reason)", failed: reason)
        }
        onChange()
    }

    private func cueStart() {
        startCue?.cancel()
        startCue = nil
        guard !cued, isRunning else { return }
        cued = true
        DictationSound.shared.play(.start)
    }

    private func cueStartAfterHold() {
        startCue?.cancel()
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                guard let self, case .pressed = self.key.state else { return }
                self.cueStart()
            }
        }
        startCue = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.fnCueDelay, execute: work)
    }

    /// The key knows that no dictation runs.
    private func ended() {
        startCue?.cancel()
        startCue = nil
        key.ended()
        keyChanged()
    }

    func speech(_ event: SpeechSession.Event) {
        switch event {
        case .phase(let phase):
            guard pill.phase != .writing else { return }
            if case .loading(let part) = phase { pill.phase = .loading(part) } else { pill.phase = .listening }
        case .text(let text):
            // the session's text is the repaired one; it keeps what was heard beside it
            pill.show(session.heard(for: self) ?? HeardText(text, words: .empty))
        case .level(let level):
            pill.level = level
        case .failed(let reason):
            ended()
            end("Not written at \(Lend.clock(Date())): \(reason)", failed: reason)
        case .ended(let text):
            // after this dictation's own end, or when the input bar started to listen. A new
            // dictation may run already (fn went down again before the last words came): the key
            // is that one's, and only a listening taken by the input bar leaves it to be reset.
            if !isRunning { ended() }
            write(spoken(text))
        }
    }

    /// What this dictation said, from the transcription stream: the words of its stretch between its
    /// key's down and up (README, "Listening"). They are the listening's own final words; when the
    /// stream has none of them, the listening's text is written and the log says so.
    private func spoken(_ text: String) -> String {
        guard let ending = session.ending else { return text }
        let fromStream = said(ending.start - 0.5, ending.end + 0.5, ending.stretch)
        if fromStream.isEmpty, !text.isEmpty {
            log.error("\(ending.stretch): the stream has no words between the key's down and up; the listening's \(Spoken.wordCount(text)) are written")
            return text
        }
        return fromStream
    }

    /// ⌥⇧W, "write what I just said": the last finished stretch of the transcription stream, where
    /// the cursor is, though no key was held while it was said. Nothing while a dictation runs.
    func writeSaid(_ text: String?) {
        guard !isRunning else { return log.info("write what I just said: a dictation runs; nothing is written") }
        guard let text, !text.isEmpty else { return end("Nothing heard to write at \(Lend.clock(Date()))", failed: nil) }
        log.info("write what I just said: the last stretch, \(Spoken.wordCount(text)) words")
        write(text)
    }

    private func finish() {
        guard isRunning else { return ended() }
        pill.phase = .writing
        pill.level = 0
        session.finish(self)
        onChange()
    }

    /// Throws the sound away. `quietly`: no line in the panel (fn was a modifier, or one tap alone).
    private func cancel(quietly: Bool) {
        guard isRunning else { return ended() }
        session.cancel(self)
        ended()
        if !quietly, cued { DictationSound.shared.play(.cancelled) }
        guard quietly else { return end("Cancelled at \(Lend.clock(Date()))", failed: nil) }
        log.info("cancelled with no sign")
        hidePill(after: 0)
        onChange()
    }

    /// The text goes where the cursor is: on the clipboard, ⌘V, and the clipboard as it was.
    private func write(_ text: String) {
        lastText = text
        guard !text.isEmpty else { return end("Heard no words at \(Lend.clock(Date()))", failed: nil) }
        let words = Spoken.wordCount(text)
        // the text goes in now (or would, in a home of its own, which plays no sound and counts it)
        DictationSound.shared.play(.written)
        guard !AppEnvironment.current.hasOwnHome else {
            return end("Heard \(words) words at \(Lend.clock(Date())); a home of its own writes them nowhere", failed: nil)
        }
        let pasteboard = NSPasteboard.general
        if Choices.shared.write == .clipboard {
            pasteboard.clearContents()
            pasteboard.setString(text, forType: .string)
            return end("\(words) words are on the clipboard (\(Lend.clock(Date())))", failed: nil)
        }
        guard AXIsProcessTrusted() else {
            pasteboard.clearContents()
            pasteboard.setString(text, forType: .string)
            allow(.accessibility)
            return end("\(words) words are on the clipboard (\(Lend.clock(Date()))): iterate needs Accessibility to write them for you", failed: "On the clipboard: press ⌘V")
        }
        // what the clipboard held, to put it back
        let kept = ClipboardCopy(of: pasteboard)
        let change = ClipboardCopy.put(text, on: pasteboard)
        let source = CGEventSource(stateID: .hidSystemState)
        for isDown in [true, false] {
            let event = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(kVK_ANSI_V), keyDown: isDown)
            // ⌘ alone, whatever keys the person still holds
            event?.flags = .maskCommand
            event?.post(tap: .cgSessionEventTap)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
            // the person copied something else meanwhile, the same text too: that stays
            kept.restore(on: pasteboard, ifStill: change)
        }
        end("Wrote \(words) words at \(Lend.clock(Date()))", failed: nil)
    }

    private func end(_ line: String, failed: String?) {
        // the log holds counts, never the words
        log.info(line)
        lastLine = line
        ends += 1
        lastFailed = failed != nil
        // the pill is a newer dictation's now: it stays as it is
        guard !isRunning else { return onChange() }
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
        let keyState: String
        switch key.state {
        case .idle: keyState = "idle"
        case .pressed: keyState = "pressed"
        case .tapped: keyState = "tapped"
        case .locked: keyState = "locked"
        }
        return [
            "running": isRunning, "key": keyState, "locked": pill.locked, "pillVisible": panel?.isVisible ?? false, "phase": phase, "text": pill.text,
            "lastLine": lastLine ?? NSNull(), "ends": ends, "lastText": lastText ?? NSNull(),
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
        OffScreen.orderFront(panel) { panel.orderFrontRegardless() }
    }

    private func hidePill(after seconds: Double) {
        hide?.cancel()
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                guard let self, !self.isRunning else { return }
                self.panel?.orderOut(nil)
                // nothing ticks while it is hidden
                self.pill.clock = .none
            }
        }
        hide = work
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: work)
    }

    private func makePanel() -> NSPanel {
        let host = NSHostingView(rootView: DictationPill(model: pill))
        // one size for every state: a new word lays out the pill, never the window
        host.sizingOptions = []
        host.frame = NSRect(origin: .zero, size: NSSize(width: DictationPill.width, height: DictationPill.height))
        let panel = NSPanel(contentRect: host.frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
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
    var color: Color = Theme.live

    var body: some View {
        HStack(spacing: 2) {
            ForEach(0..<5, id: \.self) { index in
                // the middle bar is the tallest: 8, 14, 18, 12 and 7 points at the loudest
                let shape: CGFloat = [0.33, 0.73, 1, 0.6, 0.27][index]
                RoundedRectangle(cornerRadius: 1.5, style: .continuous)
                    .fill(color)
                    .frame(width: 3, height: 3 + 15 * shape * CGFloat(min(max(level, 0), 1)))
            }
        }
        .frame(height: 18)
        .animation(.easeOut(duration: 0.12), value: level)
    }
}

/// The pill at the bottom of the screen while a dictation goes: one row that runs sideways, the
/// newest words at the right, so that a long dictation shows at a glance that it is heard.
struct DictationPill: View {
    @ObservedObject var model: DictationPillModel

    static let width: CGFloat = 460
    static let height: CGFloat = 38
    /// A capsule, as a rounded rectangle of half the height: a `Capsule` drew a hairline beside its ends.
    static let shape = RoundedRectangle(cornerRadius: height / 2, style: .circular)

    var body: some View {
        HStack(spacing: 10) {
            switch model.phase {
            case .loading(let part):
                HStack(spacing: 12) {
                    if let part {
                        ProgressView(value: part).progressViewStyle(.linear).controlSize(.small).tint(Theme.t2).frame(width: 44)
                    } else {
                        ProgressView().controlSize(.small)
                    }
                    Text(SpeechSession.loadingLine(part))
                        .foregroundStyle(Theme.t2)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
            case .listening:
                LevelBars(level: model.level)
                if model.text.isEmpty || !model.showsWords {
                    Text("Listening").foregroundStyle(Theme.t3)
                    Spacer(minLength: 0)
                } else {
                    DictationWords(shown: model.shown)
                }
                if model.locked {
                    Image(systemName: "lock.fill")
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.accentText)
                        .accessibilityLabel("Stays on")
                }
                DictationClock(clock: model.clock)
            case .writing:
                ProgressView().controlSize(.small)
                if model.text.isEmpty || !model.showsWords {
                    Text("Writing").foregroundStyle(Theme.t3)
                    Spacer(minLength: 0)
                } else {
                    DictationWords(shown: model.shown)
                }
            case .failed(let reason):
                Circle().fill(Theme.live).frame(width: 9, height: 9)
                Text(reason).lineLimit(1)
                Spacer(minLength: 0)
            }
        }
        .font(.system(size: Theme.Size.pillText))
        .foregroundStyle(Theme.t1)
        // the design's padding (14) inside its edge of 1 point
        .padding(.horizontal, 15)
        .frame(width: Self.width, height: Self.height)
        .background(Theme.surface, in: Self.shape)
        .overlay(Self.shape.strokeBorder(Theme.edge, lineWidth: 1))
    }
}

/// The words on one line, set against the right edge and clipped at the left with a fade: the
/// newest words stay in sight. A value: SwiftUI skips it when only the level changed.
private struct DictationWords: View, Equatable {
    /// The end of the text, with its corrections (`DictationPillModel.shown`).
    let shown: AttributedString

    var body: some View {
        // the free width, whatever the text's: the text hangs out of it at the left and is clipped
        Color.clear
            .frame(maxWidth: .infinity, maxHeight: 22)
            .overlay(alignment: .trailing) {
                Text(shown)
                    .foregroundStyle(Theme.t1)
                    .lineLimit(1)
                    .fixedSize(horizontal: true, vertical: false)
            }
            .clipped()
            .mask(
                HStack(spacing: 0) {
                    LinearGradient(colors: [.clear, .black], startPoint: .leading, endPoint: .trailing).frame(width: 64)
                    Color.black
                }
            )
    }
}

/// The time since the start, m:ss: ticks once a second while the pill shows, and never while it is hidden.
private struct DictationClock: View, Equatable {
    let clock: DictationPillModel.Clock

    var body: some View {
        switch clock {
        case .none:
            EmptyView()
        case .fixed(let seconds):
            Self.text(seconds)
        case .since(let start):
            TimelineView(.periodic(from: start, by: 1)) { context in
                Self.text(context.date.timeIntervalSince(start))
            }
        }
    }

    private static func text(_ seconds: TimeInterval) -> some View {
        let whole = max(0, Int(seconds))
        return Text(String(format: "%d:%02d", whole / 60, whole % 60))
            .font(.system(size: 12).monospacedDigit())
            .foregroundStyle(Theme.t3)
    }
}

extension Dictation {
    /// Draws the pill in its states, light and dark: PNG files in `folder` (`--render-input`).
    /// "corrected" has a correction of the word list: the heard "b-link" struck through, then "Beelink".
    static func render(to folder: URL) -> Bool {
        var drawn = true
        let words = WordList(markdown: "- Beelink: b-link, be link, bee link, b link\n")
        let states: [(String, DictationPillModel.Phase, String, Bool, TimeInterval)] = [
            ("loading", .loading(0.42), "", false, 0),
            ("listening", .listening, "Open the roadmap on Misha’s computer and tell him why. The two files are what I mean, and the second one is the newer", false, 7),
            ("corrected", .listening, "Restart the bridge on the b-link box, then tell me when it is live", false, 12),
            ("locked", .listening, "so the panel opens on the mind and the lend first, then what I do myself, and only then the switches", true, 252),
            ("failed", .failed("On the clipboard: press ⌘V"), "", false, 0),
        ]
        for (name, phase, text, locked, seconds) in states {
            let model = DictationPillModel()
            model.phase = phase
            model.show(HeardText(text, words: words))
            model.locked = locked
            model.clock = phase == .listening ? .fixed(seconds) : .none
            model.level = 1
            for (dark, tone) in [(false, "light"), (true, "dark")] {
                let view = DictationPill(model: model).padding(24)
                drawn = drawn && Rendering.png(of: view, dark: dark, to: folder.appendingPathComponent("dictation-\(name)-\(tone).png"))
            }
        }
        return drawn
    }
}
