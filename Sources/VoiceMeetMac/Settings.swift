import AppKit
import SpeechText
import SwiftUI
import VoiceMeetCore

/// SETTINGS (design/HANDOFF.md, section 4): one window, 800 points wide, opened by ⌘, and the
/// panel's Settings button. A sidebar of 212 points has two groups: This Mac (General, Dictation:
/// what holds whichever mind the Mac is lent to) and Minds (a page for each mind this Mac knows,
/// with everything that belongs to that mind and nowhere else, then Add a Mind…).
///
/// Where each value lives (HANDOFF 4.2): config.json, through `cli.mjs` alone (`login`,
/// `wordsExpression` and a mind's own; `use`, `add`, `remove` as the panel does them); the
/// defaults (`Choices`, `activity.pill`, `speechModel`); the lend's phase; the iterate CLI's
/// sign-in (`SignIn`). The views read none of them: `SettingsState` and `Choices` hold what they show.
struct SettingsView: View {
    @ObservedObject var state: SettingsState
    @ObservedObject var choices: Choices
    @ObservedObject var speech: SpeechChoice
    @ObservedObject var words: Words
    var actions = SettingsActions()
    /// False in a drawing: the page is as tall as it needs, with no scroll view.
    var scrolls = true

    static let width: CGFloat = 800
    static let sidebarWidth: CGFloat = 212

    var body: some View {
        HStack(spacing: 0) {
            SettingsSidebar(state: state, actions: actions)
                .frame(width: Self.sidebarWidth)
                .frame(maxHeight: .infinity, alignment: .top)
                .background(SettingsLook.sidebar)
                .overlay(alignment: .trailing) { SettingsLook.line.frame(width: 1) }
            Group {
                if scrolls {
                    ScrollView(.vertical) { page }
                } else {
                    page
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        }
        .frame(width: Self.width)
        .foregroundStyle(Theme.t1)
        .background(SettingsLook.ground)
    }

    private var page: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(title)
                .font(.system(size: Theme.Size.panelTitle, weight: .semibold))
                .frame(height: 38)
                .accessibilityAddTraits(.isHeader)
            Group {
                switch state.page {
                case .general:
                    GeneralPage(state: state, choices: choices, actions: actions)
                case .dictation:
                    DictationPage(state: state, choices: choices, speech: speech, actions: actions)
                case .mind(let mind):
                    MindPage(state: state, words: words, mind: mind, actions: actions).id(mind)
                }
            }
            .padding(.top, 4)
        }
        .padding(.horizontal, 22)
        .padding(.bottom, 22)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var title: String {
        switch state.page {
        case .general: "General"
        case .dictation: "Dictation"
        case .mind: "Minds"
        }
    }
}

// MARK: - The look

/// The window's colours, from the Theme: a solid ground, a darker sidebar, fields and their edge.
enum SettingsLook {
    static let ground = Theme.win
    static let sidebar = Theme.side
    static let line = Theme.line
    static let field = Theme.field
    static let fieldEdge = Theme.edge
    static let mono = Font.system(size: 12, design: .monospaced)
    /// A small button of a row: 24 points high, as the mocks' (Update Now, Fetch Now, Remove…).
    static let button = FillButtonStyle(height: 24, padding: 10)
}

/// A group of rows: its title (13 points, semibold), an optional line under it, and a card.
private struct SettingsGroup<Content: View>: View {
    let title: String
    var note: String?
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(title).font(.system(size: Theme.Size.settingsGroupTitle, weight: .semibold)).lineHeight(1.3, size: 13).padding(.horizontal, 2)
                .accessibilityAddTraits(.isHeader)
            if let note {
                Text(note).font(.system(size: 12)).lineHeight(1.45, size: 12).foregroundStyle(Theme.t2).padding(.horizontal, 2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            VStack(alignment: .leading, spacing: 0) { content }
                // inside the card's edge of 1 point
                .padding(1)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Theme.raised, in: RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous).strokeBorder(Theme.cardEdge))
        }
    }
}

/// A row of a card: the name, a line under it, and what goes at the right.
private struct SettingsRow<Trailing: View>: View {
    let title: String
    var detail: String?
    var isFirst = false
    @ViewBuilder var trailing: Trailing

    var body: some View {
        VStack(spacing: 0) {
            if !isFirst { SettingsLook.line.frame(height: 1).padding(.leading, 12) }
            HStack(alignment: .center, spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.system(size: 13)).lineHeight(1.3, size: 13)
                    if let detail {
                        Text(detail).font(.system(size: 11.5)).lineHeight(1.4, size: 11.5).foregroundStyle(Theme.t3)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .layoutPriority(1)
                trailing.fixedSize()
            }
            .frame(minHeight: 24)
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
        }
        .fixedSize(horizontal: false, vertical: true)
    }
}

/// A line in a colour with its dot: "Allowed by a member", "Signed in · 3 h 12 min left".
private struct DotLine: View {
    let words: String
    let color: Color
    var text: Color?

    var body: some View {
        HStack(spacing: 6) {
            Circle().fill(color).frame(width: 7, height: 7)
            Text(words).lineLimit(1)
        }
        .font(.system(size: 12))
        .foregroundStyle(text ?? color)
        .fixedSize()
    }
}

/// An orange row of a card: what keeps something from working, and the button that helps.
private struct WarningRow: View {
    let words: String
    var button: String?
    var action: () -> Void = {}

    var body: some View {
        VStack(spacing: 0) {
            SettingsLook.line.frame(height: 1).padding(.leading, 12)
            HStack(alignment: .center, spacing: 10) {
                Image(systemName: "exclamationmark.triangle").font(.system(size: 12))
                Text(words).font(.system(size: 12)).lineHeight(1.4, size: 12).fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                if let button {
                    Button(button, action: action).buttonStyle(SettingsLook.button)
                }
            }
            .foregroundStyle(Theme.warnText)
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
        }
    }
}

/// Two or more choices as a neutral segmented control: the selected one is a knob, as a native
/// control draws it. Each segment is a button with its words, so `ui.press {id, label}` picks one.
private struct Segments: View {
    let id: String
    let choices: [String]
    let selection: String
    let choose: (String) -> Void

    var body: some View {
        HStack(spacing: 2) {
            ForEach(choices, id: \.self) { choice in
                let isSelected = choice == selection
                Button {
                    if !isSelected { choose(choice) }
                } label: {
                    Text(choice)
                        .font(.system(size: 12, weight: isSelected ? .semibold : .regular))
                        .foregroundStyle(isSelected ? Theme.t1 : Theme.segIdle)
                        .padding(.horizontal, 12)
                        .frame(height: 22)
                        .background(isSelected ? Theme.knob : .clear, in: RoundedRectangle(cornerRadius: Theme.Radius.segment, style: .continuous))
                        .shadow(color: isSelected ? Theme.knobShadow : .clear, radius: 1, y: 0.5)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(choice)
                .accessibilityAddTraits(isSelected ? .isSelected : [])
            }
        }
        .padding(2)
        .background(Theme.track, in: RoundedRectangle(cornerRadius: Theme.Radius.segmentTrack, style: .continuous))
        .fixedSize()
        .accessibilityElement(children: .contain)
        .accessibilityValue(selection)
        .accessibilityIdentifier(id)
    }
}

/// A switch of Settings, small as System Settings draws them.
private struct SettingsSwitch: View {
    let id: String
    let label: String
    let isOn: Bool
    let set: (Bool) -> Void

    var body: some View {
        Toggle(label, isOn: Binding(get: { isOn }, set: set))
            .toggleStyle(ThemeSwitchStyle())
            .labelsHidden()
            .accessibilityIdentifier(id)
    }
}

/// An itx expression in a field of one line, in monospace. `onSave` takes the text at Return and
/// at Save; Save shows while the text is not the saved one.
private struct ExpressionField: View {
    let id: String
    let saved: String
    var isEditable = true
    var failed = false
    let save: (String) -> Void
    @State private var draft: String?

    var body: some View {
        let text = draft ?? saved
        HStack(spacing: 8) {
            TextField(
                "Expression",
                text: Binding(get: { text }, set: { draft = $0 }),
                prompt: Text(Words.builtInExpression)
            )
            .textFieldStyle(.plain)
            .font(SettingsLook.mono)
            .labelsHidden()
            .disabled(!isEditable)
            .foregroundStyle(isEditable ? Theme.t1 : Theme.t2)
            .onSubmit(commit)
            .padding(.horizontal, 10)
            .frame(height: 30)
            .background(isEditable ? SettingsLook.field : Theme.track, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous).strokeBorder(failed ? Theme.live : SettingsLook.fieldEdge))
            .accessibilityIdentifier(id)
            if isEditable, let draft, draft != saved {
                Button("Save", action: commit).buttonStyle(FillButtonStyle(prominent: true, height: 28, padding: 9))
                    .accessibilityIdentifier("\(id).save")
            }
        }
        .onChange(of: saved) { draft = nil }
    }

    private func commit() {
        guard let draft else { return }
        save(draft.trimmingCharacters(in: .whitespacesAndNewlines))
    }
}

/// Words that lay out in rows and wrap: the first terms of a word list.
private struct Flow: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let rows = rows(width: proposal.width ?? .infinity, subviews: subviews)
        let height = rows.map(\.height).reduce(0, +) + spacing * CGFloat(max(0, rows.count - 1))
        return CGSize(width: proposal.width ?? rows.map(\.width).max() ?? 0, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var y = bounds.minY
        for row in rows(width: bounds.width, subviews: subviews) {
            var x = bounds.minX
            for index in row.items {
                let size = subviews[index].sizeThatFits(.unspecified)
                subviews[index].place(at: CGPoint(x: x, y: y + (row.height - size.height) / 2), proposal: .unspecified)
                x += size.width + spacing
            }
            y += row.height + spacing
        }
    }

    private func rows(width: CGFloat, subviews: Subviews) -> [(items: [Int], width: CGFloat, height: CGFloat)] {
        var rows: [(items: [Int], width: CGFloat, height: CGFloat)] = []
        var current: (items: [Int], width: CGFloat, height: CGFloat) = ([], 0, 0)
        for index in subviews.indices {
            let size = subviews[index].sizeThatFits(.unspecified)
            let needed = current.items.isEmpty ? size.width : current.width + spacing + size.width
            if needed > width, !current.items.isEmpty {
                rows.append(current)
                current = ([index], size.width, size.height)
            } else {
                current = (current.items + [index], needed, max(current.height, size.height))
            }
        }
        if !current.items.isEmpty { rows.append(current) }
        return rows
    }
}

// MARK: - The sidebar

private struct SettingsSidebar: View {
    @ObservedObject var state: SettingsState
    let actions: SettingsActions

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            // the window's buttons
            Color.clear.frame(height: 38)
            header("This Mac")
            item(.general, id: "settings.page.general") { symbol("slider.horizontal.3") } title: { Text("General") }
            item(.dictation, id: "settings.page.dictation") { symbol("waveform") } title: { Text("Dictation") }
            header("Minds")
            ForEach(state.lend.minds) { mind in
                item(.mind(mind.mind), id: "settings.page.mind.\(mind.mind)") {
                    MindAvatar(mind: mind.mind, size: 20)
                } title: {
                    MindName(mind: mind.mind)
                } trailing: {
                    // the lend's state of the active mind alone: the app knows no other's (HANDOFF 8.2)
                    if mind.mind == state.lend.active {
                        Circle().fill(Panel.color(of: state.lend.state.phase)).frame(width: 7, height: 7)
                    }
                }
            }
            Button(action: actions.lend.add) {
                HStack(spacing: 8) {
                    Image(systemName: "plus").font(.system(size: 13, weight: .light)).frame(width: 20)
                    Text("Add a Mind…").font(.system(size: 13))
                    Spacer(minLength: 0)
                }
                .foregroundStyle(Theme.t2)
                .padding(.horizontal, 8)
                .frame(height: 30)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(!state.lend.isSetUp || state.lend.isCommandRunning)
            .accessibilityIdentifier("settings.addMind")
        }
        .padding(.horizontal, 8)
        .padding(.bottom, 12)
    }

    private func header(_ title: String) -> some View {
        Text(title)
            .font(.system(size: 11, weight: .semibold))
            .lineHeight(1.3, size: 11)
            .foregroundStyle(Theme.t3)
            .padding(.horizontal, 8)
            .padding(.top, 10)
            .padding(.bottom, 4)
    }

    private func symbol(_ name: String) -> some View {
        Image(systemName: name).font(.system(size: 13, weight: .regular))
    }

    private func item<Lead: View, Title: View, Trailing: View>(
        _ page: SettingsState.Page, id: String, @ViewBuilder lead: () -> Lead, @ViewBuilder title: () -> Title,
        @ViewBuilder trailing: () -> Trailing = { EmptyView() }
    ) -> some View {
        let isSelected = state.page == page
        return Button {
            state.page = page
            actions.pageChanged()
        } label: {
            HStack(spacing: 8) {
                lead().frame(width: 20)
                title().font(.system(size: 13)).lineLimit(1).frame(maxWidth: .infinity, alignment: .leading)
                trailing()
            }
            .foregroundStyle(isSelected ? Theme.onAccent : Theme.t1)
            .padding(.horizontal, 8)
            .frame(height: 30)
            .background(isSelected ? Theme.accent : .clear, in: RoundedRectangle(cornerRadius: Theme.Radius.button, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier(id)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

/// A mind's name as it calls itself, else its address.
private struct MindName: View {
    let mind: String
    @ObservedObject private var faces = MindFaces.shared

    var body: some View {
        Text(faces.face(of: mind).title)
    }
}

// MARK: - General

private struct GeneralPage: View {
    @ObservedObject var state: SettingsState
    @ObservedObject var choices: Choices
    let actions: SettingsActions

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            SettingsGroup(title: "This app") {
                SettingsRow(title: "Open at login", isFirst: true) {
                    SettingsSwitch(id: "settings.login", label: "Open at login", isOn: state.login, set: actions.setLogin)
                        .disabled(!state.lend.isSetUp || state.lend.isCommandRunning)
                }
                SettingsRow(title: "Show each act on the screen", detail: "A pill at the top right names what a mind does, while it does it.") {
                    SettingsSwitch(id: "settings.showsPill", label: "Show each act on the screen", isOn: state.showsPill, set: actions.setShowsPill)
                }
                SettingsRow(title: "An approval can last", detail: "After that, a thing set to Ask asks again.") {
                    Picker("An approval can last", selection: Binding(get: { choices.approvalMinutes }, set: { choices.approvalMinutes = $0 })) {
                        ForEach(Choices.approvalChoices, id: \.self) { minutes in
                            Text(Choices.approvalWords(minutes).lowercased()).tag(minutes)
                        }
                    }
                    .labelsHidden()
                    .fixedSize()
                    .accessibilityIdentifier("settings.approvalMinutes")
                }
            }
            SettingsGroup(title: "Keys") {
                SettingsRow(title: "Capture", detail: "Talk, click and draw, then send.", isFirst: true) {
                    KeyRecorder(id: HotKey.Combo.capture.id, combo: choices.captureKey, problem: state.keyProblems[HotKey.Combo.capture.id], actions: actions)
                        .accessibilityElement(children: .contain)
                        .accessibilityIdentifier("settings.key.capture")
                }
                SettingsRow(title: "Input", detail: "One bar: talk or type to a mind.") {
                    KeyRecorder(id: HotKey.Combo.input.id, combo: choices.inputKey, problem: state.keyProblems[HotKey.Combo.input.id], actions: actions)
                        .accessibilityElement(children: .contain)
                        .accessibilityIdentifier("settings.key.input")
                }
                SettingsRow(title: "Dictate") {
                    Text(choices.dictationOnFn ? "fn, under Dictation" : "⌥⇧D, under Dictation").font(.system(size: 12)).foregroundStyle(Theme.t2)
                }
            }
            SettingsGroup(title: "Version") {
                SettingsRow(title: state.update.title, detail: state.update.detail, isFirst: true) {
                    if state.update.updatesItself {
                        Button("Update Now", action: actions.updateNow).buttonStyle(SettingsLook.button)
                            .accessibilityIdentifier("settings.updateNow")
                    }
                }
                if state.update.updatesItself {
                    SettingsRow(title: "Update by itself", detail: "Once an hour, unless the microphone or a camera is in use.") {
                        SettingsSwitch(id: "settings.updatesByItself", label: "Update by itself", isOn: choices.updatesByItself) { choices.updatesByItself = $0 }
                    }
                }
                SettingsRow(title: "Prompt for an agent", detail: "How an agent finds this Mac in a mind and uses it.") {
                    Button(action: actions.copyPrompt) {
                        HStack(spacing: 6) {
                            Image(systemName: "doc.on.doc").font(.system(size: 11, weight: .regular))
                            Text("Copy Prompt")
                        }
                    }
                    .buttonStyle(SettingsLook.button)
                        .accessibilityIdentifier("settings.copyPrompt")
                }
            }
        }
    }
}

/// A key that works in any app, recordable: a click listens for the next key with ⌘, ⌥ or ⌃
/// (Esc stops), × removes it. A key that macOS refused says so under it.
private struct KeyRecorder: View {
    let id: UInt32
    let combo: HotKey.Combo?
    let problem: String?
    let actions: SettingsActions
    @State private var isRecording = false
    @State private var monitor: Any?
    @State private var hint: String?

    var body: some View {
        VStack(alignment: .trailing, spacing: 4) {
            HStack(spacing: 8) {
                Button {
                    isRecording ? stop() : start()
                } label: {
                    Text(isRecording ? "Press a key…" : combo?.words ?? "None")
                        .font(.system(size: 13))
                        .foregroundStyle(isRecording || combo == nil ? Theme.t3 : Theme.t1)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(isRecording ? "Press a key" : combo?.words ?? "None")
                if combo != nil, !isRecording {
                    Button {
                        _ = actions.setKey(id, nil)
                    } label: {
                        Image(systemName: "xmark").font(.system(size: 9, weight: .medium)).foregroundStyle(Theme.t3)
                    }
                    .buttonStyle(.plain)
                    .help("Remove the key")
                    .accessibilityLabel("Remove the key")
                }
            }
            .padding(.leading, 10)
            .padding(.trailing, 7)
            .frame(height: 24)
            .background(SettingsLook.field, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .strokeBorder(isRecording ? Theme.accent : SettingsLook.fieldEdge, lineWidth: isRecording ? 1.5 : 1))
            if let words = hint ?? problem {
                Text(words).font(.system(size: 11)).foregroundStyle(Theme.warnText).fixedSize(horizontal: false, vertical: true)
                    .multilineTextAlignment(.trailing)
                    .frame(width: 220, alignment: .trailing)
            }
        }
        .onDisappear(perform: stop)
    }

    private func start() {
        hint = nil
        isRecording = true
        actions.recording(id, true)
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            if event.keyCode == 53 {
                stop()
                return nil
            }
            guard let combo = HotKey.Combo.from(event, id: id) else {
                hint = "A key needs ⌘, ⌥ or ⌃."
                return nil
            }
            hint = actions.setKey(id, combo)
            stop()
            return nil
        }
    }

    private func stop() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        if isRecording { actions.recording(id, false) }
        isRecording = false
    }
}

// MARK: - Dictation

private struct DictationPage: View {
    @ObservedObject var state: SettingsState
    @ObservedObject var choices: Choices
    @ObservedObject var speech: SpeechChoice
    let actions: SettingsActions

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            SettingsGroup(title: "Key") {
                SettingsRow(title: "Hold to talk", detail: "Let go, and the text is written where the cursor is.", isFirst: true) {
                    fnKey
                }
                SettingsRow(title: "Double-tap to keep it on", detail: "The next press of fn writes the text. Esc throws it away.") {
                    SettingsSwitch(id: "settings.doubleTap", label: "Double-tap to keep it on", isOn: choices.doubleTap) { choices.doubleTap = $0 }
                        .disabled(!choices.dictationOnFn)
                }
                ForEach(state.fnLines, id: \.self) { line in
                    if line.contains("Accessibility") {
                        WarningRow(words: "fn dictation needs Accessibility. Until then ⌥⇧D works.", button: "Allow…", action: actions.allowAccessibility)
                    } else {
                        WarningRow(
                            words: "macOS also acts on fn. In Keyboard settings, set “Press 🌐 key to” to Do Nothing.", button: "Open Keyboard Settings",
                            action: actions.openKeyboardSettings)
                    }
                }
            }
            SettingsGroup(title: "Speech model") {
                SettingsRow(
                    title: "Put speech into words",
                    detail: "\(speech.chosen.name), \(speech.chosen.megabytes) MB, \(speech.isOnDisk(speech.chosen) ? "on this Mac" : "not downloaded"). No sound and no text leaves this Mac.",
                    isFirst: true
                ) {
                    Segments(id: "settings.speechWhere", choices: ["On this Mac"], selection: "On this Mac", choose: { _ in })
                }
                ForEach(SpeechModel.all) { model in
                    modelRow(model)
                }
                if let failure = speech.failure {
                    WarningRow(words: failure)
                }
            }
            SettingsGroup(title: "While you talk") {
                SettingsRow(title: "Show the words in one row", detail: "A pill at the bottom of the screen. The newest words are at the right.", isFirst: true) {
                    SettingsSwitch(id: "settings.pillWords", label: "Show the words in one row", isOn: choices.pillShowsWords) { choices.pillShowsWords = $0 }
                }
                SettingsRow(
                    title: "Put the text",
                    detail: choices.write == .cursor
                        ? "Pastes with ⌘V, then gives the clipboard back. Needs Accessibility."
                        : "The text goes on the clipboard, and you paste it yourself."
                ) {
                    Picker("Put the text", selection: Binding(get: { choices.write }, set: { choices.write = $0 })) {
                        ForEach(Choices.Write.allCases, id: \.self) { Text($0.title).tag($0) }
                    }
                    .labelsHidden()
                    .fixedSize()
                    .accessibilityIdentifier("settings.write")
                }
            }
            SettingsGroup(title: "Word list") {
                VStack(alignment: .leading, spacing: 10) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Default itx expression").font(.system(size: 13)).lineHeight(1.3, size: 13)
                        Text("Used for each mind that does not set its own. It runs as you on that mind and must answer text with one “- term: wrong form, wrong form” on a line.")
                            .font(.system(size: 11.5)).lineHeight(1.4, size: 11.5).foregroundStyle(Theme.t3).fixedSize(horizontal: false, vertical: true)
                    }
                    ExpressionField(id: "settings.wordsExpression", saved: state.defaultExpression ?? Words.builtInExpression, isEditable: state.lend.isSetUp) {
                        actions.setDefaultExpression($0.isEmpty || $0 == Words.builtInExpression ? nil : $0)
                    }
                    Text("A mind’s list, and whether it was read, is under that mind.").font(.system(size: 11.5)).lineHeight(1.3, size: 11.5)
                        .foregroundStyle(Theme.t3)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
            }
        }
    }

    /// "fn ×" while fn dictates; "Use fn" when the person removed it.
    private var fnKey: some View {
        HStack(spacing: 8) {
            Text(choices.dictationOnFn ? "fn" : "None").font(.system(size: 13)).foregroundStyle(choices.dictationOnFn ? Theme.t1 : Theme.t3)
            Button {
                choices.dictationOnFn.toggle()
            } label: {
                if choices.dictationOnFn {
                    Image(systemName: "xmark").font(.system(size: 9, weight: .medium)).foregroundStyle(Theme.t3)
                } else {
                    Text("Use fn").font(.system(size: 12)).foregroundStyle(Theme.accentText)
                }
            }
            .buttonStyle(.plain)
            .help(choices.dictationOnFn ? "fn does nothing for dictation; ⌥⇧D still works" : "Hold fn to dictate")
            .accessibilityLabel(choices.dictationOnFn ? "Remove fn" : "Use fn")
        }
        .padding(.leading, 10)
        .padding(.trailing, 7)
        .frame(height: 24)
        .background(SettingsLook.field, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous).strokeBorder(SettingsLook.fieldEdge))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("settings.dictationKey")
    }

    /// A model of the list: its name, size and licence, whether it is on this Mac, and a check on the chosen one.
    private func modelRow(_ model: SpeechModel) -> some View {
        VStack(spacing: 0) {
            SettingsLook.line.frame(height: 1).padding(.leading, 12)
            Button {
                speech.choose(model)
            } label: {
                HStack(spacing: 10) {
                    Image(systemName: "checkmark")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(Theme.accentText)
                        .opacity(model == speech.chosen ? 1 : 0)
                        .frame(width: 14)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(model.name).font(.system(size: 13)).lineHeight(1.3, size: 13)
                        Text("\(model.megabytes) MB · \(model.license)").font(.system(size: 11.5)).lineHeight(1.4, size: 11.5).foregroundStyle(Theme.t3)
                    }
                    Spacer(minLength: 8)
                    Text(status(of: model)).font(.system(size: 12)).foregroundStyle(Theme.t2)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 7)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("speech.model.\(model.id)")
        }
    }

    private func status(of model: SpeechModel) -> String {
        if let getting = speech.getting, getting.id == model.id {
            if case .downloading(let part) = getting.load { return "Downloading: \(Int(part * 100))%" }
            return "Loading…"
        }
        return speech.isOnDisk(model) ? "On this Mac" : "Download"
    }
}

// MARK: - A mind

private struct MindPage: View {
    @ObservedObject var state: SettingsState
    @ObservedObject var words: Words
    let mind: String
    let actions: SettingsActions
    @ObservedObject private var faces = MindFaces.shared
    /// "Its own" chosen, before an expression of its own is saved.
    @State private var wantsOwn = false
    @State private var name: String?

    private var entry: LendView.Mind? { state.lend.minds.first { $0.mind == mind } }
    private var isActive: Bool { state.lend.active == mind }
    private var title: String { faces.face(of: mind).title }
    private var own: String? { state.expressions[mind] }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            header
            SettingsGroup(title: "This Mac in \(title)") {
                SettingsRow(title: "Its name there", isFirst: true) { nameField }
                SettingsRow(title: "This Mac’s key", detail: "It lends this Mac under that one name, and does nothing else.") { keyState }
                SettingsRow(title: "Your sign-in", detail: "The events, the record, captures, inputs and the word list go as you.") { signIn }
            }
            wordList
            SettingsGroup(title: "Remove") {
                SettingsRow(
                    title: "Forget this mind", detail: "Deletes its key on this Mac. The key stays on the mind’s /keys page until a member removes it there.",
                    isFirst: true
                ) {
                    Button("Remove…") { actions.lend.remove(mind) }
                        .buttonStyle(SettingsLook.button)
                        .disabled(state.lend.isCommandRunning)
                        .accessibilityIdentifier("settings.mind.remove")
                }
            }
        }
        .task(id: mind) { actions.showMind(mind) }
    }

    private var header: some View {
        HStack(spacing: 13) {
            MindAvatar(mind: mind, size: 44)
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(.system(size: 17, weight: .semibold)).lineHeight(1.2, size: 17).lineLimit(1)
                Text(mind).font(.system(size: 12)).lineHeight(1.3, size: 12).foregroundStyle(Theme.t2).lineLimit(1)
            }
            Spacer(minLength: 8)
            if isActive {
                HStack(spacing: 5) {
                    Circle().fill(Theme.ok).frame(width: 6, height: 6)
                    Text("Lent now").font(.system(size: 11, weight: .semibold))
                }
                .foregroundStyle(Theme.okText)
                .padding(.horizontal, 9)
                .frame(height: 22)
                .background(Capsule().strokeBorder(Theme.ok, lineWidth: 1))
                .fixedSize()
            } else {
                Button("Lend to This Mind") { actions.lend.use(mind) }
                    .buttonStyle(FillButtonStyle(prominent: true, height: 24, padding: 10))
                    .disabled(state.lend.isCommandRunning)
                    .accessibilityIdentifier("settings.mind.use")
            }
        }
        .padding(.horizontal, 2)
        .padding(.top, 2)
    }

    private var nameField: some View {
        let saved = entry?.name ?? ""
        return HStack(spacing: 4) {
            Text("itx.").font(SettingsLook.mono).foregroundStyle(Theme.t3)
            TextField("Name", text: Binding(get: { name ?? saved }, set: { name = $0 }))
                .textFieldStyle(.plain)
                .font(SettingsLook.mono)
                .labelsHidden()
                .padding(.horizontal, 8)
                .frame(width: 96, height: 24)
                .background(SettingsLook.field, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous).strokeBorder(SettingsLook.fieldEdge))
                .onSubmit {
                    let typed = (name ?? saved).trimmingCharacters(in: .whitespaces)
                    guard typed != saved, !typed.isEmpty else { return name = nil }
                    actions.rename(mind, typed)
                    name = nil
                }
                .disabled(state.lend.isCommandRunning)
                .accessibilityIdentifier("settings.mind.name")
        }
    }

    /// The key's state: known only for the mind this Mac is lent to, from the lend's phase (HANDOFF 8.2).
    @ViewBuilder private var keyState: some View {
        if !isActive {
            Text("Not checked").font(.system(size: 12)).foregroundStyle(Theme.t2)
                .help("The app knows a key's state only for the mind this Mac is lent to.")
        } else {
            switch state.lend.state.phase {
            case .live: DotLine(words: "Allowed by a member", color: Theme.ok, text: Theme.okText)
            case .notAllowed:
                HStack(spacing: 8) {
                    DotLine(words: "Not allowed yet", color: Theme.warn, text: Theme.warnText)
                    if let link = state.lend.link { Button("Open the Link") { actions.lend.open(link) }.buttonStyle(SettingsLook.button) }
                }
            case .connecting: Text("Checked when it connects").font(.system(size: 12)).foregroundStyle(Theme.t2)
            default: Text("Not checked").font(.system(size: 12)).foregroundStyle(Theme.t2)
            }
        }
    }

    @ViewBuilder private var signIn: some View {
        switch state.signIns[mind] ?? .unknown {
        case .unknown:
            Text("Reading…").font(.system(size: 12)).foregroundStyle(Theme.t2)
        case .until(let end):
            if let now = state.fixedNow {
                DotLine(words: "Signed in · \(SignIn.left(until: end, now: now))", color: Theme.ok, text: Theme.okText)
            } else {
                TimelineView(.everyMinute) { context in
                    DotLine(words: "Signed in · \(SignIn.left(until: end, now: context.date))", color: Theme.ok, text: Theme.okText)
                }
            }
        case .renews:
            DotLine(words: "Signed in · renews at its next use", color: Theme.ok, text: Theme.okText)
        case .notSignedIn:
            DotLine(words: "Not signed in", color: Theme.warn, text: Theme.warnText)
                .help("Run iterate login \(SignIn.address(of: mind)) in a terminal.")
        }
    }

    // MARK: The word list

    private var usesOwn: Bool { own != nil || wantsOwn }
    private var status: Words.Status { words.status[mind] ?? Words.Status() }

    private var wordList: some View {
        SettingsGroup(title: "Word list", note: "The names and terms dictation must get right while it works for this mind.") {
            SettingsRow(title: "Expression", detail: usesOwn ? "It runs as you on this mind." : "Set under Dictation. It runs as you on this mind.", isFirst: true) {
                Segments(id: "settings.mind.wordsSource", choices: ["The default", "Its own"], selection: usesOwn ? "Its own" : "The default") { choice in
                    if choice == "Its own" {
                        wantsOwn = true
                    } else {
                        wantsOwn = false
                        if own != nil { actions.setExpression(mind, nil) }
                    }
                }
            }
            VStack(spacing: 0) {
                SettingsLook.line.frame(height: 1).padding(.leading, 12)
                VStack(alignment: .leading, spacing: 9) {
                    ExpressionField(
                        id: "settings.mind.expression", saved: own ?? state.defaultExpression ?? Words.builtInExpression,
                        isEditable: usesOwn && !state.lend.isCommandRunning, failed: usesOwn && status.failure != nil
                    ) { text in
                        actions.setExpression(mind, text.isEmpty ? nil : text)
                    }
                    result
                }
                .padding(.horizontal, 12)
                .padding(.top, 10)
                .padding(.bottom, 12)
            }
        }
    }

    @ViewBuilder private var result: some View {
        let status = status
        if let failure = status.failure, !status.isFetching {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Image(systemName: "exclamationmark.triangle").font(.system(size: 12)).foregroundStyle(Theme.liveText)
                (Text(failure).foregroundStyle(Theme.liveText) + Text(" ") + Text(kept(status)).foregroundStyle(Theme.t2))
                    .font(.system(size: 12))
                    .lineHeight(1.45, size: 12)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                if own != nil {
                    Button("Use the Default") {
                        wantsOwn = false
                        actions.setExpression(mind, nil)
                    }
                    .buttonStyle(SettingsLook.button)
                    .accessibilityIdentifier("settings.mind.useDefault")
                } else {
                    fetchButton
                }
            }
        } else {
            HStack(spacing: 8) {
                if status.isFetching {
                    ProgressView().controlSize(.small)
                    Text("Fetching…").font(.system(size: 12)).foregroundStyle(Theme.t2)
                } else if let list = status.list, let at = status.fetchedAt {
                    if let now = state.fixedNow {
                        fetchedLine(list, at: at, now: now)
                    } else {
                        TimelineView(.everyMinute) { context in fetchedLine(list, at: at, now: context.date) }
                    }
                } else {
                    Text("Not fetched yet.").font(.system(size: 12)).foregroundStyle(Theme.t2)
                }
                Spacer(minLength: 8)
                fetchButton
            }
            if let list = status.list, !list.entries.isEmpty {
                Flow(spacing: 6) {
                    ForEach(Array(list.entries.prefix(5).enumerated()), id: \.offset) { _, entry in
                        HStack(spacing: 6) {
                            Text(entry.term).fontWeight(.medium)
                            if !entry.wrong.isEmpty { Text(entry.wrong.joined(separator: ", ")).foregroundStyle(Theme.t3) }
                        }
                        .font(.system(size: 12))
                        .lineLimit(1)
                        .padding(.horizontal, 8)
                        .frame(height: 22)
                        .background(Theme.btn, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                    }
                    if list.entries.count > 5 {
                        Text("and \(list.entries.count - 5) more").font(.system(size: 12)).foregroundStyle(Theme.t3).frame(height: 22)
                    }
                }
            }
        }
    }

    private var fetchButton: some View {
        Button {
            actions.fetchNow(mind)
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "arrow.clockwise").font(.system(size: 11, weight: .regular))
                Text("Fetch Now")
            }
        }
        .buttonStyle(SettingsLook.button)
        .disabled(status.isFetching)
        .accessibilityIdentifier("settings.mind.fetch")
    }

    /// "The list of 13:48 is still used: 12 terms."
    private func kept(_ status: Words.Status) -> String {
        guard let list = status.list, let at = status.fetchedAt else { return "No list is used." }
        return "The list of \(Lend.shortClock(at)) is still used: \(list.entries.count) terms."
    }

    /// "38 terms · fetched 4 min ago", or "No terms · …" for a list with none.
    @ViewBuilder private func fetchedLine(_ list: WordList, at: Date, now: Date) -> some View {
        let minutes = max(0, Int(now.timeIntervalSince(at) / 60))
        let fetched = minutes == 0 ? "fetched just now" : minutes < 60 ? "fetched \(minutes) min ago" : "fetched at \(Lend.shortClock(at))"
        if list.entries.isEmpty {
            Text("No terms · \(fetched)").font(.system(size: 12)).foregroundStyle(Theme.t2)
        } else {
            DotLine(words: "\(list.entries.count) terms · \(fetched)", color: Theme.ok, text: Theme.okText)
        }
    }
}

// MARK: - The window

/// The Settings window: made when it opens and let go when it closes, so that nothing of it draws
/// or ticks while it is not on the screen.
@MainActor
final class SettingsWindow: NSObject, NSWindowDelegate {
    private var window: NSWindow?
    private let makeView: () -> AnyView
    /// The window closed.
    var closed: () -> Void = {}

    init(view: @escaping () -> AnyView) {
        makeView = view
    }

    var isVisible: Bool { window?.isVisible ?? false }

    func show() {
        if window == nil {
            let host = NSHostingController(rootView: makeView())
            host.sizingOptions = []
            // the content goes under the see-through title bar (`SettingsView` sets its title there)
            host.safeAreaRegions = []
            let window = SettingsNSWindow(
                contentRect: NSRect(x: 0, y: 0, width: SettingsView.width, height: 680),
                styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView], backing: .buffered, defer: false)
            window.contentViewController = host
            window.title = "Settings"
            window.tallTitleBar()
            window.isReleasedWhenClosed = false
            window.contentMinSize = NSSize(width: SettingsView.width, height: 420)
            window.contentMaxSize = NSSize(width: SettingsView.width, height: 4000)
            window.setContentSize(NSSize(width: SettingsView.width, height: 680))
            window.delegate = self
            window.center()
            self.window = window
        }
        OffScreen.activate()
        if let window { OffScreen.orderFront(window) { window.makeKeyAndOrderFront(nil) } }
    }

    func close() {
        window?.close()
    }

    func windowWillClose(_ notification: Notification) {
        // the views go with the window: no TimelineView or task of theirs runs on
        window?.contentViewController = nil
        window = nil
        closed()
    }
}

/// The window of Settings and of the Activity window. Its Edit and Window keys (⌘X, ⌘C, ⌘V, ⌘A,
/// ⌘Z, ⇧⌘Z, ⌘W) come from the app's one main menu (`AppDelegate.installMainMenu`), which a
/// menu-bar app has though it shows no menu bar.
final class SettingsNSWindow: NSWindow {}

extension NSWindow {
    /// The design's title bar: 38 points (an empty toolbar in the compact style), see-through, with
    /// no title of its own and no line under it. The content goes under it and sets its title there.
    func tallTitleBar() {
        styleMask.insert(.fullSizeContentView)
        titleVisibility = .hidden
        titlebarAppearsTransparent = true
        titlebarSeparatorStyle = .none
        let toolbar = NSToolbar(identifier: "iterate.titleBar")
        toolbar.showsBaselineSeparator = false
        toolbar.allowsUserCustomization = false
        self.toolbar = toolbar
        toolbarStyle = .unifiedCompact
    }
}

// MARK: - Drawings

extension SettingsView {
    /// The pages `render` draws: General, Dictation, a mind that is lent and uses the default list,
    /// and a mind whose own expression fails.
    static let renderPages = ["general", "dictation", "mind-lent", "mind-failing"]

    /// Draws the Settings window's pages, light and dark, with the drawings' minds (`Rendering`):
    /// `settings-<page>-<light|dark>.png` in `folder`. It reads no config, no sign-in and no list.
    @MainActor
    static func render(to folder: URL) -> Bool {
        _ = NSApplication.shared
        Rendering.fixFaces()
        let now = Rendering.now
        var drawn = true
        for page in renderPages {
            let state = SettingsState()
            state.fixedNow = now
            state.lend = Panel.sampleLend("live")
            state.login = true
            state.update = .init(title: "0.1.0, from npm", detail: "Up to date. Checked at \(Lend.shortClock(now.addingTimeInterval(-22 * 60))).", updatesItself: true)
            state.signIns = [
                Rendering.minds[0].mind: .until(now.addingTimeInterval(3 * 3600 + 12 * 60 + 30)),
                Rendering.minds[1].mind: .until(now.addingTimeInterval(3600 + 5 * 60 + 30)),
            ]
            // the drawing shows the orange row of 🌐, which a Mac shows when macOS acts on fn
            state.fnLines = ["macOS acts on 🌐 too"]
            let words = Words()
            let list = WordList(markdown: (["- Templestein: temple stein, temple steen", "- Herdr", "- Beelink", "- Doppler", "- itx"] + (1...33).map { "- Term\($0)" }).joined(separator: "\n"))
            words.fixForDrawing(Rendering.minds[0].mind, Words.Status(list: list, fetchedAt: now.addingTimeInterval(-4 * 60 - 20)))
            let older = WordList(markdown: (1...12).map { "- Term\($0)" }.joined(separator: "\n"))
            let failure = "This answered a commit id, with no line that starts with “- ”."
            let lastGood = Rendering.now.addingTimeInterval(-14 * 60)
            words.fixForDrawing(Rendering.minds[1].mind, Words.Status(list: older, fetchedAt: lastGood, failure: failure))
            switch page {
            case "dictation": state.page = .dictation
            case "mind-lent": state.page = .mind(Rendering.minds[0].mind)
            case "mind-failing":
                state.page = .mind(Rendering.minds[1].mind)
                state.expressions = [Rendering.minds[1].mind: #"itx.repos.get("/repos/config").tip()"#]
            default: state.page = .general
            }
            let view = SettingsView(state: state, choices: Choices.shared, speech: SpeechChoice(), words: words, scrolls: false)
            for (dark, tone) in [(false, "light"), (true, "dark")] {
                drawn = Rendering.png(of: view, dark: dark, to: folder.appendingPathComponent("settings-\(page)-\(tone).png"), titled: true) && drawn
            }
        }
        return drawn
    }
}
