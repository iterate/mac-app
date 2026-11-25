import AppKit
import SwiftUI
import VoiceMeetCore

/// What the panel shows that is not in its sub-models: the things that exist now, their choices,
/// the permissions macOS has not given, the newest small picture of each display. The app fills it
/// when the panel opens and at each change while it is open (`AppDelegate.refreshPanel`), so no
/// view reads the defaults, a device or a permission while it draws.
@MainActor
final class PanelState: ObservableObject {
    @Published var things: [Shareable] = []
    /// Each thing's choice, by its id.
    @Published var sharing: [String: Sharing] = [:]
    /// The permissions of macOS that are not given.
    @Published var missing: Set<Permission> = []
    /// The things approved for a while (`Approval`), and until when.
    @Published var approvals: [String: Date] = [:]
    /// How many times a mind used each thing since the app started.
    @Published var uses: [String: Int] = [:]
    /// Each display's small picture, the size it is drawn at (60 pixels wide), made off the main thread.
    @Published var displayPictures: [String: CGImage] = [:]
    @Published var didCopy = false
    @Published var didCopyCommand = false
    /// The lend (AppDelegate `showLend`): the minds, the active one, the state in words.
    @Published var lend = LendView()
    /// The banner on the screen, while one shows (`Banners`).
    @Published var banner: Banner?
    /// How the newest of the person's capture (⌥⇧S), input (⌥⇧Space) and dictation ended.
    @Published var lastResult: LastResult?
    /// The capture needs macOS 15.
    @Published var canCapture = true
    /// The mind switcher shows its list of minds. It closes with the panel.
    @Published var isSwitcherOpen = false
    /// The Activity page shows in place of the middle of the panel.
    @Published var isActivityOpen = false

    /// One line: "Last input: Sent to … at 14:01", orange when it failed.
    struct LastResult: Equatable {
        let what: String
        let line: String
        let failed: Bool
    }
}

/// What the panel shows of the lend.
struct LendView: Equatable {
    struct Mind: Equatable, Identifiable {
        let mind: String
        let name: String
        var id: String { mind }
    }

    var minds: [Mind] = []
    var active: String?
    var isSetUp = false
    /// The phase in words: `LendState.statusLine`.
    var status = ""
    /// The phase as the panel lays it out: `LendState.words`.
    var words = LendWords(title: "Not lent", detail: "no mind is active")
    /// The phase's name (`LendPhase.name`), for `ui.state` and the views that still compare it;
    /// a view decides by `state.phase`.
    var phase = "idle"
    /// Where a member allows the key, when the CLI printed one.
    var link: String?
    /// The last words of a command the panel ran (add, use, remove).
    var commandLine: String?
    var isCommandRunning = false
    /// Where the app came from: its version and whether it updates itself, or the owner's copy it
    /// was built from (`UpdateSource.line`).
    var source: String?
    /// The lend's state that `status` and `words` were made from: the panel's countdown makes them
    /// again each second (`at`), while it shows.
    var state = LendState()

    /// The words at `date`: a countdown's seconds of then.
    @MainActor func at(_ date: Date) -> LendView {
        var view = self
        view.status = state.statusLine(now: date, clock: Lend.clock)
        view.words = state.words(now: date, clock: Lend.shortClock)
        return view
    }
}

/// What the panel's lend section does.
struct LendActions {
    var reconnect: () -> Void = {}
    var use: (String) -> Void = { _ in }
    var add: () -> Void = {}
    var remove: (String) -> Void = { _ in }
    var open: (String) -> Void = { _ in }
}

/// What the panel's three action buttons do.
struct PanelActions {
    var capture: () -> Void = {}
    var openInput: () -> Void = {}
    var dictate: () -> Void = {}
}

/// The app's one piece of interface: a panel under the mark in the menu bar, 400 points wide. From
/// the top: the banner while one shows, the mind and the lend's phase, who watches live, the three
/// action buttons, the things a mind can use (each with Off, Ask, Shared), the events, the record,
/// the newest acts, and the footer. "All" shows the Activity page in place of the middle.
struct Panel: View {
    @ObservedObject var state: PanelState
    let model: AppModel
    /// The speech model and what keeps fn dictation from working.
    var speech = SpeechChoice()
    /// The person changed a choice.
    let changed: () -> Void
    /// The person wants to give a permission of macOS: the guide starts.
    let allow: (Permission) -> Void
    let copyPrompt: () -> Void
    /// The person presses a button of the banner (its index), or closes it (nil).
    var pressBanner: (Int?) -> Void = { _ in }
    var actions = PanelActions()
    var lendActions = LendActions()
    /// A camera's live picture, for its small picture in the row. Nil in a drawing.
    var cameraLayer: ((String) -> CALayer)?
    /// A large picture of a display or a camera, made at a click on its small one.
    var bigPicture: (Shareable) async -> CGImage? = { _ in nil }
    /// The footer's Settings button and ⌘,.
    var openSettings: () -> Void = {}
    /// The Activity page's "Open in a Window".
    var openActivityWindow: () -> Void = {}
    /// The height the scrolling middle needs; it is at most `middleMaxHeight`.
    @State private var middleHeight: CGFloat = 400

    static let width: CGFloat = 400

    /// The middle's room: the screen's height under the menu bar, less the banner, the mind,
    /// the footer and the popover's own margins (about 300 points together).
    static var middleMaxHeight: CGFloat {
        // a drawing is the same on every screen
        if AppEnvironment.current.isRendering { return 1200 }
        let screen = NSScreen.screens.first { NSMouseInRect(NSEvent.mouseLocation, $0.frame, false) } ?? NSScreen.main
        return max(240, (screen?.visibleFrame.height ?? 900) - 300)
    }

    var body: some View {
        let _ = Perf.count("panelBodies")
        let lend = state.lend
        VStack(alignment: .leading, spacing: 0) {
            if let banner = state.banner {
                bannerSection(banner)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 12)
                Divider()
            }
            lendSection
                .padding(.horizontal, 6)
                .padding(.vertical, 6)
            if lend.minds.isEmpty {
                noMind
            } else {
                Divider()
                // The middle scrolls when the panel would be taller than the screen, so the mind at the
                // top and Quit at the bottom are always reachable.
                ScrollView(.vertical) {
                    Group {
                        if state.isActivityOpen {
                            ActivityPage(log: model.acts, isOpen: $state.isActivityOpen, openWindow: openActivityWindow)
                        } else {
                            middle
                        }
                    }
                    .padding(.horizontal, 12)
                    .padding(.top, 12)
                    .padding(.bottom, 12)
                    .background(GeometryReader { geometry in
                        Color.clear.preference(key: MiddleHeight.self, value: geometry.size.height)
                    })
                }
                .frame(height: min(middleHeight, Panel.middleMaxHeight))
                .onPreferenceChange(MiddleHeight.self) { middleHeight = $0 }
            }
            Divider()
            footer
        }
        .frame(width: Self.width)
    }

    // MARK: - The mind and the phase

    /// The mind this Mac is lent to (`MindSwitcher`) with the phase at its right, and under it the
    /// phase's block while the lend is held up.
    @ViewBuilder
    private var lendSection: some View {
        let lend = state.lend
        // a wait counts down: its row alone is drawn again each second, and only while it shows
        if let next = lend.state.phase.nextStartAt, next > Date(), !AppEnvironment.current.isRendering {
            TimelineView(.periodic(from: Date(), by: 1)) { context in
                let _ = Perf.count("lendTicks")
                lendRows(lend.at(context.date))
            }
        } else {
            lendRows(lend)
        }
    }

    private func lendRows(_ lend: LendView) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            MindSwitcher(
                lend: lend, isOpen: $state.isSwitcherOpen, actions: lendActions, dot: Self.color(of: lend.state.phase),
                phaseColor: Self.textColor(of: lend.state.phase))
            if lend.active != nil, let block = lend.words.block {
                phaseBlock(block, lend: lend).padding(.horizontal, 6)
            }
            if !lend.isSetUp, !lend.minds.isEmpty {
                Text("Not set up: run npx @iterate-com/mac-app in a terminal")
                    .font(.system(size: 11)).foregroundStyle(.secondary).padding(.horizontal, 8)
            }
            if let line = lend.commandLine {
                HStack(spacing: 6) {
                    if lend.isCommandRunning { ProgressView().controlSize(.mini) }
                    Text(line).font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                .padding(.horizontal, 8)
            }
        }
    }

    /// The reason the lend is held up, in orange while the CLI tries again by itself and in red when
    /// it stopped, with what the person can do.
    private func phaseBlock(_ block: String, lend: LendView) -> some View {
        let waits = lend.words.tone == .waits
        return VStack(alignment: .leading, spacing: 8) {
            Text(block).font(.system(size: 12)).fixedSize(horizontal: false, vertical: true)
            if let code = lend.words.code {
                Text(code)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            }
            HStack(spacing: 8) {
                if case .incompatible = lend.state.phase {
                    Button {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(LendState.updateCommand, forType: .string)
                        state.didCopyCommand = true
                        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { state.didCopyCommand = false }
                    } label: {
                        Label(state.didCopyCommand ? "Copied" : "Copy Command", systemImage: "doc.on.doc")
                    }
                    .buttonStyle(FillButtonStyle())
                } else {
                    if let link = lend.link {
                        Button("Open the Link to Allow This Mac") { lendActions.open(link) }.buttonStyle(FillButtonStyle(prominent: true))
                    }
                    Button("Reconnect Now", action: lendActions.reconnect)
                        .buttonStyle(FillButtonStyle())
                        .help("Ends the wait or the attempt, and starts the lend at once")
                        .accessibilityIdentifier("panel.reconnect")
                }
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(waits ? Palette.waitWash : Palette.redWash, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(waits ? Palette.waitEdge : Palette.redEdge))
    }

    /// The dot on the mind's face.
    static func color(of phase: LendPhase) -> Color {
        switch phase {
        case .live: return .green
        case .connecting, .reconnecting: return .orange
        case .idle: return .secondary
        case .stopped, .notAllowed, .incompatible: return .red
        }
    }

    /// The phase's name at the right of the row.
    private static func textColor(of phase: LendPhase) -> Color {
        switch phase {
        case .live: return Palette.liveText
        case .connecting, .reconnecting: return Palette.waitText
        case .idle: return .secondary
        case .stopped, .notAllowed, .incompatible: return Palette.redText
        }
    }

    // MARK: - The middle

    private var middle: some View {
        VStack(alignment: .leading, spacing: 14) {
            LiveWatching(live: model.live)
            actionsSection(hasMind: true)
            CanUseSection(
                state: state, acts: model.acts, live: model.live, changed: changed, allow: allow, cameraLayer: cameraLayer,
                bigPicture: bigPicture)
            DeviceEventsSection(events: model.deviceEvents, accessibilityMissing: state.missing.contains(.accessibility), allow: allow)
            RecordSection(record: model.record, window: model.deviceWindow, missing: state.missing, allow: allow)
            ActivitySummary(log: model.acts, isOpen: $state.isActivityOpen)
        }
    }

    /// Capture, Input and Dictate, how the newest of them ended, and the speech model.
    private func actionsSection(hasMind: Bool) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                actionButton("Capture", symbol: "viewfinder", key: "⌥⇧S", action: actions.capture)
                    .disabled(!hasMind || !state.canCapture)
                    .help("Talk, click, hold ⇧ and move the pointer to draw. ⌥⇧S again sends it to the mind and copies its text for an agent.")
                actionButton("Input", symbol: "text.bubble", key: "⌥⇧Space", action: actions.openInput)
                    .disabled(!hasMind)
                    .help("Talk or type what you want, paste or drop files, choose the mind, Return sends.")
                    .accessibilityIdentifier("panel.openInput")
                actionButton("Dictate", symbol: "waveform", key: "hold fn", action: actions.dictate)
                    .help("Hold fn and talk: what you say is written where the cursor is, on this Mac. Tap fn twice to keep it on until the next tap. This button keeps it on until ⌥⇧D.")
            }
            if let last = state.lastResult {
                Text("\(last.what): \(last.line)")
                    .font(.system(size: 11))
                    .foregroundStyle(last.failed ? Palette.waitText : Color.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
                    .padding(.horizontal, 2)
            }
            SpeechSection(choice: speech)
        }
    }

    private func actionButton(_ title: String, symbol: String, key: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 2) {
                Label(title, systemImage: symbol).font(.system(size: 12, weight: .semibold))
                Text(key).font(.system(size: 11)).foregroundStyle(.secondary)
            }
        }
        .buttonStyle(TileStyle())
    }

    // MARK: - No mind yet

    private var noMind: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Add a mind to lend this Mac to. It gets a key for one name, and a member of the mind allows it with a passkey.")
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Button(action: lendActions.add) {
                Text("Add a Mind…").font(.system(size: 13, weight: .semibold)).frame(maxWidth: .infinity)
            }
            .buttonStyle(FillButtonStyle(prominent: true, height: 32))
            .disabled(!state.lend.isSetUp || state.lend.isCommandRunning)
            VStack(alignment: .leading, spacing: 5) {
                Text("Or in a terminal").font(.system(size: 11)).foregroundStyle(.secondary)
                Text("npx @iterate-com/mac-app")
                    .font(.system(size: 12, design: .monospaced))
                    .textSelection(.enabled)
                    .padding(.horizontal, 12)
                    .frame(maxWidth: .infinity, minHeight: 36, alignment: .leading)
                    .background(Palette.fill, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(Color.primary.opacity(0.1)))
            }
            VStack(alignment: .leading, spacing: 8) {
                meaning("lock", "Everything starts at Off. You choose Off, Ask or Shared for each thing.")
                meaning("touchid", "Ask means you approve each use with Touch ID.")
                meaning("waveform", "Dictation already works: it runs on this Mac and needs no mind.")
            }
            actionsSection(hasMind: false)
        }
        .padding(.horizontal, 12)
        .padding(.top, 4)
        .padding(.bottom, 12)
    }

    private func meaning(_ symbol: String, _ words: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Image(systemName: symbol).font(.system(size: 12)).frame(width: 16).foregroundStyle(.secondary)
            Text(words).font(.system(size: 12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: - The footer

    private var footer: some View {
        HStack(spacing: 8) {
            if !state.lend.minds.isEmpty {
                Button(state.didCopy ? "Copied" : "Copy Prompt", action: copyPrompt)
                    .buttonStyle(FillButtonStyle(height: 26))
                    .accessibilityIdentifier("panel.copyPrompt")
                    .help("Copies how an agent uses this Mac, to paste into a chat with it")
            }
            if let source = state.lend.source {
                Text(source)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer(minLength: 8)
            Button(action: openSettings) {
                Image(systemName: "gearshape").font(.system(size: 13))
            }
                .buttonStyle(.borderless)
                .foregroundStyle(.secondary)
                .accessibilityLabel("Settings")
                .keyboardShortcut(",")
                .help("This Mac's settings, and each mind's (⌘,)")
                .accessibilityIdentifier("panel.settings")
            Button("Quit") { NSApp.terminate(nil) }
                .buttonStyle(.borderless)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .keyboardShortcut("q")
                .accessibilityIdentifier("panel.quit")
        }
        .padding(.leading, 12)
        .padding(.trailing, 14)
        .padding(.vertical, 8)
    }

    // MARK: - The banner

    /// The banner on the screen, again: its title, its text and its buttons, and a close.
    private func bannerSection(_ banner: Banner) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 11) {
                Circle()
                    .fill(Color.green)
                    .frame(width: 34, height: 34)
                    .overlay(Image(systemName: banner.isCall ? "phone.fill" : "bell.badge").font(.system(size: 14)).foregroundStyle(.white))
                VStack(alignment: .leading, spacing: 2) {
                    Text(banner.isCall ? "\(banner.title) calls" : banner.title).font(.system(size: 13, weight: .semibold)).lineLimit(1)
                    if !banner.body.isEmpty {
                        Text(banner.body).font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(2)
                    }
                }
                Spacer(minLength: 8)
                Button { pressBanner(nil) } label: { Image(systemName: "xmark") }
                    .buttonStyle(.borderless)
                    .help(banner.isCall ? "Decline" : "Close the banner with no button")
            }
            HStack(spacing: 8) {
                ForEach(Array(banner.buttons.enumerated()), id: \.offset) { index, button in
                    Button { pressBanner(index) } label: { Text(button.label).frame(maxWidth: .infinity) }
                        .buttonStyle(FillButtonStyle(prominent: index == banner.defaultButton, height: 28))
                }
            }
        }
    }

    /// What "Copy Prompt" copies: how an agent of the mind uses this Mac. It names no secret.
    static var prompt: String {
        let mac = Host.current().localizedName ?? "This Mac"
        return """
        "\(mac)" is lent to this iterate mind through its menu-bar app "iterate". Think of it as an endpoint device that a person is often near: inputs (the screen, the camera, the microphone, the window in front as text), outputs (the speakers, banners on the screen) and compute (commands). In the mind it is one capability, lent with `iterate provide` under a name such as `itx.jonas.mac`. Find the name:

            (await itx.rewriteRules.list()).filter((rule) => rule.description?.includes("iterate menu-bar app")).map((rule) => rule.match)

        Below, `mac` stands for that capability (for example `const mac = itx.jonas.mac`).

        First read what the owner shares: `await mac.state()`. It lists every thing of the Mac (each display, each camera, the microphone, the speakers, banners, the window text, commands) with its `sharing`: "shared" (use it), "ask" (the owner approves each use on the Mac, which can take up to a minute) or "off" (the call fails with the reason: say so to the person, do not try again).

        `state()` also says whether a person is likely at the Mac: `presence: { idleSeconds, screenLocked, displayAsleep }`. `idleSeconds` is the time since the last key press, mouse move or click in any app; `screenLocked` is true while the screen is locked (or another user's session is in front); `displayAsleep` is true while every display sleeps. Idle under a few minutes, not locked and a display awake is the sign that a person is likely there: read it before you show a banner or ring. It says nothing of who is there.

        The calls:

        - `await mac.screen.snapshot({ display?, maxWidth? })`: one still picture of a display as JPEG bytes (`jpeg`). `display` is the number from `state()`.
        - `await mac.camera.snapshot({ camera?, maxWidth? })`: one still picture of a camera. `camera` is its name.
        - `await mac.microphone.listen({ seconds })`: up to 60 seconds of the microphone as the bytes of a WAV file (`wav`).
        - `await mac.speaker.say("words")` and `await mac.speaker.play(soundBytes)`: sound through the Mac's speakers.
        - `await mac.accessibility.frontWindow()`: the window in front as text (roles, titles, values), not as a picture.
        - `await mac.appleScript("…")`: run an AppleScript. This is the plainest way to use the Mac's apps.
        - `await mac.swift("…")`: run a Swift program given as source. Use it for anything the other calls cannot do, such as a dialog that asks the person something.
        - `await mac.run(["command", "argument"], { stdin?, timeoutSeconds? })`: run a command; it has the app's permissions for the screen, the camera, the microphone and Accessibility.
        - `await mac.banner.show({ title, body?, buttons?, sound?, seconds? })`: a banner on the Mac's screen, at the top right. `buttons` is one to three `{ label, style?: "accept" | "decline" | "plain", symbol?, open? }` (default one "OK"); a button with `open` opens that page in the browser after its press, and the page must be on this mind's domain. `sound` is "chime" (default), "ring" or "none"; `seconds` is 30 unless said (5 to 120). It answers `{ pressed: "<label>" }`, or `{ pressed: null, why: "no answer" | "dismissed" | "replaced" | "off", words }`. What happens next is yours. For example, to ask the person into meeting X: `await mac.banner.show({ title: "Design review is starting", body: "Misha asks you to join", buttons: [{ label: "Join", style: "accept", open: "<the meeting's page>" }, { label: "Not now" }] })`.
        - `await mac.call.ring({ agent, from?, reason?, url? })`: a banner that looks like a call, for a call on the agent `agent` (its path, such as your own): who calls, why, Decline and Accept, and a ring. Accept opens the call's page; with no `url` it is the agent's page in the Dash, which opens the call's lobby, where the person checks their camera and sound and presses Join now. It answers `{ accepted: true }` or `{ accepted: false, why: "declined" | "no answer" | "replaced" | "off", words }` after at most 30 seconds.
        - One banner at a time; a newer one replaces it, but a plain banner never replaces a call. At most 6 a minute. Show one only when the person asked for it, or for something they said may interrupt them.
        - `await mac.record.state()`: the record of the Mac into the mind's files (`/devices/<name>/record/`): which of `screens`, `cameras`, `mics`, `speakers` and `windowText` are on, whether it records or is paused (locked, asleep), its tracks. Reading it uses nothing.
        - `await mac.record.set({ screens?, cameras?, mics?, speakers?, windowText? })`: turn sources on or off; it answers the new state. Off is always allowed. On is a use of that thing under its `sharing`, as a snapshot is (Screens and Speakers go by the displays, Window text by the window text), and it records until switched off: turn one on only when the person asked for it.

        The owner sees each use in the menu bar. Say what you looked at or did, and why.
        """
    }
}

private struct MiddleHeight: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}

// MARK: - A mind can use

/// "A mind can use": one card, in the README's order of inputs (each display, each camera, the
/// microphone, the window text), outputs (the speakers, banners) and compute (commands). A row is
/// the thing's icon or its small picture, its name, a note, and Off, Ask, Shared.
private struct CanUseSection: View {
    @ObservedObject var state: PanelState
    /// The acts that run, and the watchers: their things get a red note.
    @ObservedObject var acts: ActivityLog
    @ObservedObject var live: DeviceLive
    let changed: () -> Void
    let allow: (Permission) -> Void
    let cameraLayer: ((String) -> CALayer)?
    let bigPicture: (Shareable) async -> CGImage?

    private static let groups: [[Power]] = [[.screen, .camera, .microphone, .accessibility], [.speaker, .banners], [.commands, .pages]]

    var body: some View {
        let busy = busyWords()
        let groups = Self.groups.map { powers in powers.flatMap { power in state.things.filter { $0.power == power } } }.filter { !$0.isEmpty }
        VStack(alignment: .leading, spacing: 7) {
            SectionTitle(title: "A mind can use") {
                Menu {
                    Button("Everything Off") { setAll(.off) }
                    Button("Ask for Everything") { setAll(.ask) }
                } label: {
                    Text("Set all").font(.system(size: 12))
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .foregroundStyle(.secondary)
            }
            Card {
                ForEach(Array(groups.enumerated()), id: \.offset) { index, group in
                    if index > 0 { Divider().padding(.horizontal, 8).padding(.vertical, 3) }
                    ForEach(group) { thing in
                        ThingRow(
                            thing: thing, sharing: state.sharing[thing.id] ?? .off, note: note(for: thing, busy: busy),
                            isMissing: thing.power.permission.map(state.missing.contains) ?? false,
                            picture: state.displayPictures[thing.id], cameraLayer: cameraLayer, bigPicture: bigPicture,
                            choose: { choice in
                                thing.sharing = choice
                                state.sharing[thing.id] = choice
                                changed()
                            },
                            allow: allow)
                    }
                }
            }
        }
    }

    private func setAll(_ choice: Sharing) {
        for thing in state.things {
            thing.sharing = choice
            state.sharing[thing.id] = choice
        }
        changed()
    }

    /// "running" for a thing whose act runs, "watched" for one whose track a watcher gets.
    private func busyWords() -> [String: String] {
        var words: [String: String] = [:]
        for watcher in live.watchers {
            for track in watcher.tracks {
                let power: Power? = track.hasPrefix("screen-") ? .screen : track.hasPrefix("camera-") ? .camera : track.hasPrefix("mic-") ? .microphone : nil
                for thing in state.things where thing.power == power && state.sharing[thing.id, default: .off] != .off {
                    words[thing.id] = "watched"
                }
            }
        }
        for row in acts.rows where row.isRunning { words[row.thing] = "running" }
        return words
    }

    private func note(for thing: Shareable, busy: [String: String]) -> ThingRow.Note? {
        if let word = busy[thing.id] { return .busy(word) }
        if let until = state.approvals[thing.id] { return .approved("Approved until \(Lend.shortClock(until))") }
        let uses = state.uses[thing.id] ?? 0
        return uses > 0 ? .used("Used \(uses)×") : nil
    }
}

private struct ThingRow: View {
    enum Note: Equatable {
        case busy(String)
        case approved(String)
        case used(String)
    }

    let thing: Shareable
    let sharing: Sharing
    let note: Note?
    let isMissing: Bool
    let picture: CGImage?
    let cameraLayer: ((String) -> CALayer)?
    let bigPicture: (Shareable) async -> CGImage?
    let choose: (Sharing) -> Void
    let allow: (Permission) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 8) {
                lead.frame(width: 30)
                VStack(alignment: .leading, spacing: 1) {
                    Text(thing.title).font(.system(size: 13)).lineLimit(1).truncationMode(.tail)
                    if let note { noteView(note) }
                }
                Spacer(minLength: 6)
                SharingControl(id: thing.id, title: thing.title, selection: sharing, choose: choose)
            }
            .frame(minHeight: note == nil ? 28 : 40)
            if sharing != .off, isMissing, let permission = thing.power.permission {
                MissingPermission(words: "macOS has not allowed \(permission.title) yet") { allow(permission) }
                    .padding(.leading, 38)
                    .padding(.bottom, 4)
            }
        }
        .padding(.horizontal, 6)
        .help(note.flatMap { if case .used = $0 { return "Uses since the app started" } else { return nil } } ?? "")
    }

    @ViewBuilder
    private var lead: some View {
        if sharing != .off, !isMissing, thing.power == .screen || thing.power == .camera {
            Thumbnail(thing: thing, picture: picture, cameraLayer: cameraLayer, bigPicture: bigPicture)
        } else {
            Image(systemName: thing.symbol)
                .font(.system(size: 14))
                .foregroundStyle(sharing == .off ? Color.secondary : Palette.accentText)
        }
    }

    @ViewBuilder
    private func noteView(_ note: Note) -> some View {
        switch note {
        case .busy(let word):
            HStack(spacing: 5) {
                Circle().fill(Color.red).frame(width: 6, height: 6)
                Text(word)
            }
            .font(.system(size: 11))
            .foregroundStyle(Palette.redText)
        case .approved(let words):
            Text(words).font(.system(size: 11)).foregroundStyle(Palette.accentText)
        case .used(let words):
            Text(words).font(.system(size: 11)).foregroundStyle(.secondary)
        }
    }
}

/// What a mind would get of a display or a camera, 30 × 19 points; a click shows a large one.
private struct Thumbnail: View {
    let thing: Shareable
    let picture: CGImage?
    let cameraLayer: ((String) -> CALayer)?
    let bigPicture: (Shareable) async -> CGImage?
    @State private var isZoomed = false

    var body: some View {
        Button {
            isZoomed = true
        } label: {
            content
                .frame(width: 30, height: 19)
                .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 4, style: .continuous).strokeBorder(Color.primary.opacity(0.14)))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("What a mind gets. Click for a large picture.")
        .popover(isPresented: $isZoomed, arrowEdge: .leading) {
            BigPicture(thing: thing, make: bigPicture)
        }
    }

    @ViewBuilder
    private var content: some View {
        if thing.power == .screen, let picture {
            Image(decorative: picture, scale: 2).resizable().interpolation(.medium).aspectRatio(contentMode: .fill)
        } else if thing.power == .camera, let cameraLayer {
            LayerView(layer: cameraLayer(String(thing.id.dropFirst("camera.".count))))
        } else {
            ZStack {
                Palette.fill
                Image(systemName: thing.power == .camera ? "person" : thing.symbol).font(.system(size: 9)).foregroundStyle(.secondary)
            }
        }
    }
}

/// The large picture of a thumbnail's thing, made when it opens.
private struct BigPicture: View {
    let thing: Shareable
    let make: (Shareable) async -> CGImage?
    @State private var picture: CGImage?
    @State private var isDone = false

    var body: some View {
        Group {
            if let picture {
                Image(decorative: picture, scale: 2).resizable().aspectRatio(contentMode: .fit)
            } else {
                Text(isDone ? "No picture: macOS or the device gave none." : "Making the picture…")
                    .font(.system(size: 12)).foregroundStyle(.secondary)
            }
        }
        .frame(width: 320, height: 200)
        .padding(8)
        .task {
            picture = await make(thing)
            isDone = true
        }
    }
}

/// Shows a Core Animation layer: a camera's live picture.
private struct LayerView: NSViewRepresentable {
    let layer: CALayer

    func makeNSView(context: Context) -> NSView {
        let view = NSView(frame: .zero)
        // A layer-hosting view: set the layer first, then `wantsLayer`.
        view.layer = layer
        view.wantsLayer = true
        layer.backgroundColor = CGColor(gray: 0, alpha: 1)
        return view
    }

    func updateNSView(_ view: NSView, context: Context) {}
}

/// The panel's live watchers: nothing while nobody watches.
private struct LiveWatching: View {
    @ObservedObject var live: DeviceLive

    var body: some View {
        if !live.watchers.isEmpty { LiveSection(live: live) }
    }
}

// MARK: - Drawings

extension Panel {
    /// The phases `render` draws: the lend's, and the panel's own states.
    static let renderPhases = [
        "connecting", "live", "reconnecting", "stopped", "not-allowed", "incompatible", "ringing", "busy", "blocked", "activity", "no-mind",
    ]

    /// Draws the panel to a PNG file, with the drawings' things, minds and acts (`Rendering`): it
    /// opens nothing on screen and starts no capture. `phase` is the lend's (live, reconnecting,
    /// stopped, not-allowed, incompatible or connecting, the default), or one of the panel's:
    /// `ringing` (a call's banner), `busy` (watched, recording, an act that runs), `blocked` (two
    /// permissions not given), `activity` (the Activity page), `no-mind`.
    @MainActor
    static func render(to file: URL, phase: String? = nil, dark: Bool = false) -> Bool {
        _ = NSApplication.shared
        Rendering.fixFaces()
        let state = PanelState()
        let model = AppModel()
        let sample = Rendering.Sample(phase: phase ?? "connecting")
        state.things = sample.things
        state.sharing = Dictionary(uniqueKeysWithValues: sample.things.map { ($0.id, $0.sharing) })
        state.missing = sample.missing
        state.approvals = sample.approvals
        state.uses = sample.uses
        state.lastResult = phase == "no-mind" ? nil : sample.lastResult
        state.displayPictures = ["screen.1": Rendering.displayPicture]
        state.lend = sampleLend(phase == "no-mind" ? nil : phase ?? "connecting")
        if phase == "no-mind" { state.lend.minds = [] }
        state.isActivityOpen = phase == "activity"
        if phase == "ringing" { state.banner = BannerWindow.sample("ring") }
        ActivityLog.fillSample(model.acts, running: phase == "busy" || phase == "activity", older: phase == "activity" ? 12 : 0)
        sample.fix(model)
        let panel = Panel(state: state, model: model, changed: {}, allow: { _ in }, copyPrompt: {})
        // The panel has no background of its own (a popover gives it one); the file needs one.
        return Rendering.png(of: panel.background(Color(nsColor: .windowBackgroundColor)), dark: dark, to: file)
    }

    /// The drawings' lend (`Rendering.minds`), in a phase made from the CLI's own states: a copy
    /// that only draws starts no lend.
    @MainActor
    static func sampleLend(_ phase: String?) -> LendView {
        let name = Rendering.minds[0].name
        let mind = Rendering.minds[0].mind
        let now = Rendering.now
        var lend = LendState()
        let start = now.addingTimeInterval(-70)
        let live = #"{"state":"live","mind":"\#(mind)","name":"itx.\#(name)","again":false}"#
        let lines: [String] =
            switch phase {
            case "live", "ringing", "busy", "blocked", "activity": [live]
            case "reconnecting": [live, #"{"state":"reconnecting","attempt":2,"of":14,"inMs":90000,"lastFailure":"fetch failed"}"#]
            case "not-allowed": [#"{"state":"notAllowed","why":"No member has allowed this key yet.","link":"https://\#(mind)/keys/enrol?provide=\#(name)","waiting":true}"#]
            case "incompatible": [#"{"state":"incompatible","why":"the statement is for another mind: this iterate CLI and the mind do not agree on the protocol"}"#]
            case "stopped": [#"{"state":"stopped","why":"\#(mind) could not be reached. Check the address."}"#]
            default: []
            }
        if phase != nil { _ = lend.handle(.started, now: start) }
        for line in lines { _ = lend.handle(.stateLine(line), now: start.addingTimeInterval(10)) }
        if phase == "stopped" { _ = lend.handle(.processEnded(status: 1, ranFor: 3), now: now.addingTimeInterval(-1)) }
        var view = LendView()
        view.isSetUp = true
        view.minds = Rendering.minds
        view.active = mind
        view.status = lend.statusLine(now: now, clock: Lend.clock)
        view.words = lend.words(now: now, clock: Lend.shortClock)
        view.phase = lend.phase.name
        view.link = lend.phase.link
        view.source = Rendering.source
        view.state = lend
        return view
    }
}
