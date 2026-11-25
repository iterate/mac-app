import AppKit
import Combine
import ServiceManagement
import SpeechText
import SwiftUI
import VoiceMeetCore

/// A menu-bar-only app: the iterate mark, and a panel under it (`Panel`). No window, no Dock icon.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private lazy var model = AppModel()
    private let log = AppLog("app")
    private let panelState = PanelState()
    private let lend = Lend()
    /// The panel under the mark (`MenuBarPanel`).
    private let panelWindow = MenuBarPanel()
    private var statusItem: NSStatusItem?
    /// The mark: the status item's button, or a test copy's own (`OffScreen.markButton`).
    private var markButton: NSStatusBarButton?
    private var recordDot: RecordDotView?
    /// What the mark shows now: it is written again only when it changes.
    private var shownMark: MenuBarMark?
    private var shownLabel = ""
    /// The one look again at the end of a use's red (`MenuBarMark.inUse`).
    private var useEnds: DispatchWorkItem?
    private var terminationSignal: DispatchSourceSignal?
    private var grantWatch: Timer?
    private var displayPictureTimer: Timer?
    /// The panel's main page shows: its previews run (`startPreviews`).
    private var previewsShow = false
    /// The cameras that run for the open panel's previews.
    private var camerasHeldByThePanel: Set<String> = []
    /// The Activity page hides the previews: their timer and cameras stop while it shows.
    private var pageWatch: AnyCancellable?
    /// The last lines of capture, input and dictation the panel saw: a new one is the newest result.
    private var seenLines: [String: String] = [:]
    /// The person's own capture (⌥⇧S). It needs macOS 15: nil before.
    private var capture: AnyObject?
    /// The speech model of dictation, the input and capture: the person's choice in the panel.
    private let speechChoice = SpeechChoice()
    /// The one foreground listening, of dictation and the input.
    private let speech = SpeechSession()
    /// The listening layers: the transcription stream's segments, Always listen, ⌥⇧W (`Listening`).
    private let listening = Listening()
    private var alwaysListenWatch: AnyCancellable?
    /// The sign of Always listen on the mark.
    private var listenSign: ListenSignView?
    /// The person's input to a mind (⌥⇧Space).
    private lazy var input = MindInput(session: speech)
    /// The person's dictation into the app in front (fn, ⌥⇧D).
    private lazy var dictation = Dictation(session: speech)
    /// The minds' word lists, for the speech model.
    private let words = Words()
    /// The control socket, for a test with no hand: nil unless `AppEnvironment` asks for it.
    private var control: ControlSocket?
    private let environment = AppEnvironment.current
    /// The person's choices of Settings (`Choices`), and what Settings shows.
    private let choices = Choices.shared
    private let settingsState = SettingsState()
    private lazy var settings = SettingsWindow { [unowned self] in
        AnyView(SettingsView(state: settingsState, choices: choices, speech: speechChoice, words: words, actions: settingsActions()))
    }
    /// The Activity window: every event of the device's context, read only while it is open.
    private let contextLog = ContextLog()
    private lazy var activityWindow = ActivityWindow { [unowned self] in
        AnyView(ActivityWindowView(acts: model.acts, log: contextLog, state: panelState, actions: activityWindowActions()))
    }
    /// The word-list expressions of the config last seen: a change fetches the lists again.
    private var seenExpressions: [String: String] = [:]
    /// Drops the OpenAI standby socket when the Mac sleeps (`startDictation`).
    private var standbySleep: NSObjectProtocol?
    /// config.json's `login` as the login item was last set to it.
    private var appliedLogin: Bool?

    func applicationDidFinishLaunching(_ notification: Notification) {
        quitOnTerminationSignal()
        installMainMenu()
        if environment.controlSocket != nil { ControlSocket.makeAccessibilityElements() }

        // a test copy's mark is in a window of its own, off the menu bar (`OffScreen`)
        if OffScreen.isOn {
            markButton = OffScreen.markButton()
            // a plain button is its own accessibility element
            markButton?.setAccessibilityIdentifier("statusItem")
        } else {
            let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
            self.statusItem = statusItem
            markButton = statusItem.button
        }
        markButton?.target = self
        markButton?.action = #selector(togglePanel)
        // the button's cell is its accessibility element
        markButton?.cell?.setAccessibilityIdentifier("statusItem")
        let markSize = environment.hasOwnHome ? IterateIcon.testImage(MenuBarMark(ink: .live, dot: .none)).size : IterateIcon.plain.size
        if let markButton {
            recordDot = RecordDotView.attach(to: markButton, imageSize: markSize)
            listenSign = ListenSignView.attach(to: markButton, imageSize: markSize)
        }
        // after the mark: the first lines look for the cameras, which can take a moment
        logRunStart()

        let panel = Panel(
            state: panelState,
            model: model,
            changed: { [weak self] in self?.choiceChanged() },
            allow: { [weak self] permission in self?.guide(permission) },
            copyPrompt: { [weak self] in self?.copyPrompt() },
            pressBanner: { [weak self] index in
                self?.panelWindow.performClose(nil)
                if let index { self?.model.banners.press(index) } else { self?.model.banners.dismiss() }
            },
            actions: PanelActions(
                capture: { [weak self] in
                    self?.panelWindow.performClose(nil)
                    if #available(macOS 15.0, *) { (self?.capture as? Capture)?.toggle() }
                },
                openInput: { [weak self] in
                    self?.panelWindow.performClose(nil)
                    self?.input.toggle()
                },
                dictate: { [weak self] in
                    self?.panelWindow.performClose(nil)
                    // a tap of ⌥⇧D: a dictation that stays on until the next press
                    self?.dictation.shortcutPressed()
                    self?.dictation.shortcutReleased()
                }
            ),
            lendActions: LendActions(
                reconnect: { [weak self] in self?.lend.reconnectNow() },
                use: { [weak self] mind in self?.lend.use(mind) },
                add: { [weak self] in self?.addMind() },
                remove: { [weak self] mind in self?.removeMind(mind) },
                open: { link in if let url = URL(string: link) { NSWorkspace.shared.open(url) } }
            ),
            cameraLayer: { [weak self] id in self?.model.cameraPreviewLayer(for: id) ?? CALayer() },
            bigPicture: { [weak self] thing in await self?.bigPicture(of: thing) },
            openSettings: { [weak self] in self?.openSettings(.general) },
            openActivityWindow: { [weak self] in self?.openActivityWindow() }
        )
        if #unavailable(macOS 15.0) { panelState.canCapture = false }
        pageWatch = panelState.$isActivityOpen.removeDuplicates().dropFirst().sink { [weak self] isOpen in
            guard let self, self.panelWindow.isShown else { return }
            if isOpen { self.stopPreviews() } else { self.startPreviews() }
        }
        let host = NSHostingController(rootView: panel)
        // The panel is as tall as its rows need.
        host.sizingOptions = [.preferredContentSize]
        panelWindow.contentViewController = host
        // A test's copy is not the app in front, and a click elsewhere would close it at once: its
        // panel closes by its mark alone.
        panelWindow.closesByItself = !environment.hasOwnHome
        panelWindow.onShow = { [weak self] in self?.panelDidShow() }
        panelWindow.onClose = { [weak self] in self?.panelDidClose() }

        model.onChange = { [weak self] in self?.stateDidChange() }
        // the address as the CLI says it (`iterate.example.com`), not the config's short name
        model.banners.activeMind = { [weak self] in self?.lend.state.mindAddress }
        model.lendState = { [weak self] in self.map { ["phase": $0.lend.state.phase.name, "line": $0.lend.state.statusLine(now: Date(), clock: Lend.clock)] } ?? [:] }
        model.record.onChange = { [weak self] in self?.stateDidChange() }
        model.banners.onChange = { [weak self] in self?.stateDidChange() }
        model.start()
        model.deviceEvents.heardLog = { [weak self] line in self?.contextLog.heard(line) }
        contextLog.readOlder = { [weak self] before in self?.model.deviceEvents.readOlder(before: before) }
        contextLog.startOf = { [weak self] act in
            self?.model.acts.rows.first { $0.act == act }.map { ($0.thing, $0.detail, $0.startedAt) }
        }
        activityWindow.opened = { [weak self] isOpen in
            self?.model.deviceEvents.readLog(isOpen)
            self?.log.info("the Activity window \(isOpen ? "opens: the log of every event is read" : "closes: the log's read ends")")
        }
        lend.isBusy = { [weak self] in
            (self?.model.microphone.isRunning ?? false) || (self?.model.isAnyCameraRunning ?? false) || (self?.isCapturing ?? false)
                || (self?.dictation.isRunning ?? false) || (self?.input.isListening ?? false)
        }
        lend.onChange = { [weak self] in self?.stateDidChange() }
        startControl()
        startCapture()
        // the one place a mind session reaches the features
        lend.sessionChanged = { [weak self] session, isAuthorized in
            guard let self else { return }
            self.model.use(session, isAuthorized: isAuthorized)
            if #available(macOS 15.0, *) { (self.capture as? Capture)?.session = session }
        }
        lend.start()
        openAtLogin()
        startInput()
        startDictation()
        startListening()
        preloadSpeech()
        stateDidChange()

        // At the very first start the panel opens by itself, so that the person sees the choices.
        // A home of its own is a test's: it opens nothing by itself.
        if !environment.hasOwnHome, !environment.defaults.bool(forKey: "panelShownAtFirstStart") {
            environment.defaults.set(true, forKey: "panelShownAtFirstStart")
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in self?.togglePanel() }
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        control?.stop()
        lend.stop()
        model.shutDown()
        log.info("==== run end: the app quits")
    }

    /// The app's one main menu, never shown (a menu-bar app has no menu bar of its own) and still
    /// heard while the app is active: the Edit menu's keys in every field of Settings, the
    /// Activity window and a form (Add a Mind pastes an address), and ⌘W. No ⌘Q: the panel's Quit
    /// button quits, and a ⌘Q meant for another app does not end this one. The input bar is a panel
    /// that does not make the app active: it takes these keys itself.
    private func installMainMenu() {
        let main = NSMenu()
        let app = NSMenuItem()
        app.submenu = NSMenu(title: "iterate")
        main.addItem(app)
        let edit = NSMenu(title: "Edit")
        edit.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        edit.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "Z")
        edit.addItem(.separator())
        edit.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        let editItem = NSMenuItem(title: "Edit", action: nil, keyEquivalent: "")
        editItem.submenu = edit
        main.addItem(editItem)
        let window = NSMenu(title: "Window")
        window.addItem(withTitle: "Close", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        let windowItem = NSMenuItem(title: "Window", action: nil, keyEquivalent: "")
        windowItem.submenu = window
        main.addItem(windowItem)
        NSApp.mainMenu = main
    }

    /// `kill <process>` quits the app as its Quit button does: captures stop, the log gets its last
    /// line. So a script or an agent can end a run without a click.
    private func quitOnTerminationSignal() {
        signal(SIGTERM, SIG_IGN)
        let source = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
        source.setEventHandler {
            MainActor.assumeIsolated {
                AppLog("app").info("the termination signal arrived; the app quits")
                NSApp.terminate(nil)
            }
        }
        source.resume()
        terminationSignal = source
    }

    /// The installed app (in /Applications) starts at each login when the person said so to
    /// `npx @iterate-com/mac-app` or in Settings (its config's `login`). A build run from elsewhere registers
    /// nothing, so that one copy alone is ever registered, and so does a copy with a home of its own.
    /// System Settings › General › Login Items shows it and can turn it off.
    private func openAtLogin() {
        guard Bundle.main.bundlePath.hasPrefix("/Applications/"), !environment.hasOwnHome else { return }
        let service = SMAppService.mainApp
        let wanted = lend.config?.login ?? false
        appliedLogin = wanted
        do {
            if wanted, service.status != .enabled {
                try service.register()
            } else if !wanted, service.status == .enabled {
                try service.unregister()
            }
            log.info("login item: \(wanted ? "on" : "off") (status \(service.status.rawValue))")
        } catch {
            log.error("login item: not changed: \(AppLog.describe(error))")
        }
    }

    /// ⌥⇧S starts the person's capture and ends it: `Capture`. It goes to the mind this Mac is lent to.
    private func startCapture() {
        guard #available(macOS 15.0, *) else { return log.info("capture: off, it needs macOS 15") }
        let capture = Capture()
        capture.onChange = { [weak self] in self?.stateDidChange() }
        capture.allow = { [weak self] permission in self?.guide(permission) }
        // a capture hears with a local model, also when dictation runs at OpenAI
        capture.speech = { [weak self] in self?.speechChoice.local ?? .default }
        capture.words = { [weak self] mind in self?.words.list(of: mind) ?? .empty }
        self.capture = capture
        control?.toggleCapture = { capture.toggle() }
        control?.markCapture = { capture.mark($0) }
        if let combo = choices.captureKey { register(combo, "capture", "starts and ends one", pressed: { capture.toggle() }) }
    }

    /// ⌥⇧Space opens the input: a text and files, to one of the minds this Mac knows (`MindInput`).
    private func startInput() {
        input.choices = { [weak self] in
            guard let config = self?.lend.config, let helpers = self?.lend.helpers else { return nil }
            return (helpers, config.minds.map { LendView.Mind(mind: $0.mind, name: $0.name) }, self?.lend.session?.mind)
        }
        input.words = { [weak self] mind in self?.words.list(of: mind) ?? .empty }
        input.allow = { [weak self] permission in self?.guide(permission) }
        input.onChange = { [weak self] in self?.stateDidChange() }
        control?.toggleInput = { [weak self] in self?.input.toggle() }
        if let combo = choices.inputKey { register(combo, "input", "opens it", pressed: { [weak self] in self?.input.toggle() }) }
    }

    /// fn and ⌥⇧D dictate into the app in front, with the word list of the mind this Mac is lent to
    /// (`Dictation`). The lists are fetched now, so that the first dictation has them.
    private func startDictation() {
        speech.model = { [weak self] in
            // the key may have come (cli.mjs) or gone: the next listening knows
            self?.speechChoice.refreshKey()
            return self?.speechChoice.chosen ?? .default
        }
        // GPT Live Transcribe at OpenAI, with the local model behind it, and a socket that waits for
        // the next dictation (README, "Dictation"). Each socket opens through the lent mind, with
        // the mind's own key (its bridge relays the frames); else with this Mac's own key.
        let openAIKey = speechChoice.openAIKey
        let mindSockets = model.mindSockets
        let speechLog = AppLog("speech")
        let standby = OpenAIStandby(log: { speechLog.info($0) })
        let access = OpenAIAccess.mindFirst(
            mind: { await MainActor.run { mindSockets.mind.map { ($0, mindSockets.state) } } },
            socket: { try await MainActor.run { try mindSockets.socket() } },
            key: { openAIKey?.read() },
            log: { speechLog.info($0) })
        speech.online = { [weak self] model, words, heard in
            OnlineSpeech.recognizer(model, words: words, access: access, local: self?.speechChoice.local ?? .default, standby: standby, heard: heard)
        }
        speech.mayOpenMicrophone = !environment.hasOwnHome || environmentFixture != nil
        speech.log = { speechLog.info($0) }
        speechChoice.onChange = { [weak self] in
            guard let self else { return }
            if speechChoice.chosen.isLocal { standby.drop("the speech model is \(speechChoice.chosen.id)") }
            else if !speechChoice.isOnline { standby.drop("no mind with OpenAI and no OpenAI key") }
            stateDidChange()
        }
        // a standby of another mind is a socket through that mind: it goes at a switch
        var socketsMind = mindSockets.mind
        mindSockets.onChange = { [weak self] in
            guard let self else { return }
            if mindSockets.mind != socketsMind {
                standby.drop("the lent mind is now \(mindSockets.mind ?? "none")")
                socketsMind = mindSockets.mind
            }
            speechChoice.mindIs(mindSockets.mind, state: mindSockets.state)
        }
        speechChoice.mindIs(mindSockets.mind, state: mindSockets.state)
        // a socket that slept is likely dead: the next dictation opens a new one
        standbySleep = NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: nil) { _ in
            standby.drop("the Mac sleeps")
        }
        speechChoice.allowAccessibility = { [weak self] in self?.guide(.accessibility) }
        speechChoice.openSettings = { [weak self] in self?.openSettings(.dictation) }
        words.bridge = { [weak self] mind in
            guard let helpers = self?.lend.helpers, let known = self?.lend.config?.minds.first(where: { $0.mind == mind }) else { return nil }
            return MindBridge.of(mind: mind, name: known.name, helpers: helpers)
        }
        // the mind's own expression, else this Mac's default, else the built-in one (nil)
        words.expression = { [weak self] mind in
            guard let config = self?.lend.config else { return nil }
            return config.minds.first { $0.mind == mind }?.wordsExpression ?? config.wordsExpression
        }
        seenExpressions = expressions()
        // the lent mind's list now, for the first dictation; another mind's when the input bar
        // first chooses it (`Words.list` fetches it then), so no process starts for it at launch
        if let mind = lend.config?.activeMind { words.refresh(mind.mind) }
        dictation.words = { [weak self] in self?.words.list(of: self?.lend.session?.mind) ?? .empty }
        dictation.allow = { [weak self] permission in self?.guide(permission) }
        dictation.onChange = { [weak self] in self?.stateDidChange() }
        control?.dictationPressed = { [weak self] in self?.dictation.holdStarted() }
        control?.dictationReleased = { [weak self] in self?.dictation.holdEnded() }
        control?.dictationFn = { [weak self] down in self?.dictation.fnChanged(down: down) }
        control?.dictationEscape = { [weak self] in self?.dictation.escape() }
        dictation.watchKeys()
        register(.dictation, "dictation", "held, dictates; tapped, stays on", pressed: { [weak self] in self?.dictation.shortcutPressed() }, released: { [weak self] in self?.dictation.shortcutReleased() })
    }

    /// The chosen local speech model, loaded in the background a moment after the start when its
    /// files are on this Mac: the first dictation is then at once, not after Core ML prepared the
    /// model for the Neural Engine (24.8 s, seen on 24 Nov 2026) or MLX's process read Fourier. With
    /// dictation at OpenAI it is the model of captures and the one that hears when OpenAI fails. A
    /// home of its own loads it only for an audio fixture; a drawing never gets here. The installed
    /// app then gets the default model when it is not on this Mac (`SpeechChoice.getDefault`).
    private func preloadSpeech() {
        guard !environment.hasOwnHome || environmentFixture != nil else { return }
        let model = speechChoice.local
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [log, speechChoice] in
            speechChoice.getDefault()
            guard let task = SpeechModels.shared.preload(model) else { return log.info("speech: \(model.id) is not on this Mac; the first use downloads it") }
            Task { @MainActor in
                let seconds = await task.value
                log.info(seconds.map { "speech: \(model.id) loaded in the background in \(String(format: "%.1f", $0)) s" } ?? "speech: \(model.id) did not load in the background")
            }
        }
    }

    /// A key that works in any app. A copy with a home of its own registers none: the keys are the
    /// installed app's, and a test presses them through the control socket. False when macOS refused it.
    @discardableResult
    private func register(_ combo: HotKey.Combo, _ what: String, _ does: String, pressed: @escaping () -> Void, released: (() -> Void)? = nil) -> Bool {
        guard !environment.hasOwnHome else {
            log.info("\(what): \(combo.words) is not registered in a home of its own")
            return true
        }
        let isRegistered = HotKey.register(combo, pressed: pressed, released: released)
        log.info(isRegistered ? "\(what): \(combo.words) \(does)" : "\(what): macOS refused the key \(combo.words)")
        return isRegistered
    }

    /// The keys that Settings › General sets: what each is in the log and in a refusal, and what it does.
    private static let settableKeys: [UInt32: (what: String, name: String, does: String)] = [
        HotKey.Combo.capture.id: ("capture", "capture", "starts and ends one"),
        HotKey.Combo.input.id: ("input", "the input", "opens it"),
        HotKey.Combo.writeSaid.id: ("write what I just said", "Write what I just said", "writes the last stretch of speech"),
    ]

    /// The key that Settings set for `id`.
    private func chosenKey(_ id: UInt32) -> HotKey.Combo? {
        switch id {
        case HotKey.Combo.capture.id: return choices.captureKey
        case HotKey.Combo.writeSaid.id: return choices.writeSaidKey
        default: return choices.inputKey
        }
    }

    /// What the key of capture (`HotKey.Combo.capture.id`), of the input or of "write what I just said" does.
    private func pressed(_ id: UInt32) -> () -> Void {
        switch id {
        case HotKey.Combo.capture.id: return { [weak self] in if #available(macOS 15.0, *) { (self?.capture as? Capture)?.toggle() } }
        case HotKey.Combo.writeSaid.id: return { [weak self] in self?.writeSaid() }
        default: return { [weak self] in self?.input.toggle() }
        }
    }

    /// Settings recorded a key for capture, the input or "write what I just said", or removed it
    /// (nil). A key that macOS refuses leaves the one before; the answer says so.
    private func setKey(_ id: UInt32, _ combo: HotKey.Combo?) -> String? {
        guard let key = Self.settableKeys[id] else { return nil }
        let before = chosenKey(id)
        settingsState.keyProblems[id] = nil
        if let combo, let other = Self.settableKeys.keys.first(where: { $0 != id && chosenKey($0).map { $0.key == combo.key && $0.modifiers == combo.modifiers } == true }) {
            return "\(combo.words) is the key of \(Self.settableKeys[other]?.name ?? "another action") already."
        }
        HotKey.unregister(id)
        if let combo, !register(combo, key.what, key.does, pressed: pressed(id)) {
            if let before { register(before, key.what, "again", pressed: pressed(id)) }
            let problem = "macOS refused \(combo.words): another app may use it."
            settingsState.keyProblems[id] = problem
            return problem
        }
        switch id {
        case HotKey.Combo.capture.id: choices.captureKey = combo
        case HotKey.Combo.writeSaid.id: choices.writeSaidKey = combo
        default: choices.inputKey = combo
        }
        log.info("\(key.what): the person set the key to \(combo?.words ?? "none")")
        return nil
    }

    /// While a recorder listens, the key it replaces does nothing, so that pressing it records it.
    private func recordingKey(_ id: UInt32, _ isRecording: Bool) {
        guard !environment.hasOwnHome else { return }
        if isRecording { return HotKey.unregister(id) }
        if let combo = chosenKey(id) { _ = HotKey.register(combo, pressed: pressed(id), released: nil) }
    }

    /// The listening layers (README, "Listening"): every final segment of dictation, the input bar
    /// and Always listen goes into the transcript and the record's `transcript` track; Always listen
    /// runs while its switch is on; ⌥⇧W writes the last finished stretch.
    private func startListening() {
        listening.mayOpenMicrophone = !environment.hasOwnHome || environmentFixture != nil
        listening.localModel = { [weak self] in self?.speechChoice.local ?? .default }
        listening.words = { [weak self] in self?.words.list(of: self?.lend.session?.mind) ?? .empty }
        listening.record = { [weak self] line in self?.model.record.transcribed(line) }
        listening.onChange = { [weak self] in
            self?.model.record.tick()
            self?.stateDidChange()
        }
        model.record.alwaysListens = { [weak self] in self?.listening.isAlwaysListening ?? false }
        speech.transcribed = { [weak self] event in self?.listening.heard(event) }
        speech.onListening = { [weak self] isOn in self?.listening.keyListening(isOn) }
        dictation.said = { [weak self] from, to, stretch in self?.listening.said(from: from, to: to, of: stretch) ?? "" }
        alwaysListenWatch = choices.$alwaysListen.dropFirst().removeDuplicates().sink { [weak self] isOn in
            // `@Published` tells before the value is set
            DispatchQueue.main.async {
                self?.log.info("always listen: turned \(isOn ? "on" : "off") in Settings")
                self?.listening.apply()
            }
        }
        control?.writeSaid = { [weak self] in self?.writeSaid() }
        if let combo = choices.writeSaidKey { register(combo, "write what I just said", "writes the last stretch of speech", pressed: pressed(HotKey.Combo.writeSaid.id)) }
        listening.apply()
    }

    /// ⌥⇧W: the last finished stretch of speech, where the cursor is.
    private func writeSaid() {
        dictation.writeSaid(listening.lastStretch)
    }

    /// The control socket (`ControlSocket`), when the environment asks for it.
    private func startControl() {
        guard let url = environment.controlSocket else { return }
        let control = ControlSocket(socketURL: url, approval: model.approval)
        control.state = { [weak self] in self?.controlState() ?? [:] }
        control.start()
        self.control = control
    }

    /// What `ui.state` answers.
    private func controlState() -> [String: Any] {
        let active: Any = lend.config?.active ?? NSNull()
        var state: [String: Any] = [
            "home": environment.folder.path,
            "lend": ["phase": lend.state.phase.name, "status": lend.state.statusLine(now: Date(), clock: Lend.clock), "active": active],
            "minds": lend.config?.minds.map(\.mind) ?? [],
            "session": lend.session.map { ["generation": $0.generation, "mind": $0.mind, "name": $0.name, "authorized": lend.isAuthorized] } ?? NSNull(),
            "panel": [
                "visible": panelWindow.isShown, "switcherOpen": panelState.isSwitcherOpen, "activityOpen": panelState.isActivityOpen,
                "page": panelState.isActivityOpen ? "activity" : "main",
            ],
            "input": input.controlState(),
            "dictation": dictation.controlState(),
            "listening": listening.controlState(),
            "speech": speechChoice.controlState(),
            "sounds": DictationSound.shared.controlState(),
            "activity": [
                "pillVisible": model.acts.isPillVisible,
                "context": model.acts.path.map { $0 as Any } ?? NSNull(),
                "entries": model.acts.rows.prefix(10).map { row -> [String: Any] in
                    [
                        "act": row.act, "did": row.did ?? row.doing, "running": row.isRunning, "inMind": row.isInMind,
                        "failure": row.failure ?? NSNull(), "detail": row.detail ?? NSNull(),
                    ]
                },
            ],
            "settings": ["visible": settings.isVisible, "page": settingsState.page.name],
            "log": [
                "visible": activityWindow.isVisible, "read": contextLog.window.isRead, "held": contextLog.window.events.count,
                "hasOlder": contextLog.window.hasOlder, "failure": contextLog.failure ?? NSNull(),
                "types": contextLog.window.events.prefix(50).map(\.type), "shown": contextLog.shown.count,
            ] as [String: Any],
            "choices": [
                "approvalMinutes": choices.approvalMinutes, "captureKey": choices.captureKey?.words ?? NSNull(),
                "inputKey": choices.inputKey?.words ?? NSNull(), "dictationOnFn": choices.dictationOnFn, "doubleTap": choices.doubleTap,
                "pillShowsWords": choices.pillShowsWords, "sounds": choices.sounds, "write": choices.write.rawValue,
                "alwaysListen": choices.alwaysListen, "writeSaidKey": choices.writeSaidKey?.words ?? NSNull(),
            ],
            "banner": model.banners.state.showing.map { ["title": $0.title, "isCall": $0.isCall, "buttons": $0.buttons.map(\.label)] } ?? NSNull(),
            "record": model.record.state(),
            "sharing": Dictionary(uniqueKeysWithValues: Shareable.all.map { ($0.id, $0.sharing.rawValue) }),
        ]
        if #available(macOS 15.0, *), let capture = capture as? Capture { state["capture"] = capture.controlState() }
        return state
    }

    private var isCapturing: Bool {
        if #available(macOS 15.0, *) { return (capture as? Capture)?.isRunning ?? false }
        return false
    }

    /// The lend's state for the panel.
    private func showLend() {
        var view = LendView()
        view.isSetUp = lend.config != nil
        view.minds = lend.config?.minds.map { LendView.Mind(mind: $0.mind, name: $0.name) } ?? []
        view.active = lend.config?.activeMind?.mind
        view.status = lend.state.statusLine(now: Date(), clock: Lend.clock)
        view.words = lend.state.words(now: Date(), clock: Lend.shortClock)
        view.phase = lend.state.phase.name
        view.link = lend.state.phase.link ?? lend.commandLink
        view.commandLine = lend.commandLine
        view.isCommandRunning = lend.isCommandRunning
        view.source = lend.config.map { $0.source.line(home: NSHomeDirectory()) }
        view.state = lend.state
        if view != panelState.lend { panelState.lend = view }
    }

    /// "Add a Mind…": its address (the iterate CLI's profiles are offered) and the name this Mac
    /// is available under. The CLI's `add` makes the key and opens the link where a member allows it.
    private func addMind() {
        panelWindow.performClose(nil)
        lend.profiles { [weak self] profiles in
            guard let self else { return }
            let known = Set(self.lend.config?.minds.map(\.mind) ?? [])
            let name = self.lend.activeMind?.name ?? "\(NSUserName().filter { $0.isLetter || $0.isNumber }).mac"
            FormWindow.show(
                title: "Add a Mind",
                AddMindForm(
                    profiles: profiles.filter { !known.contains($0) },
                    name: name,
                    add: { [weak self] mind, name in
                        FormWindow.close()
                        self?.log.info("the person adds \(mind) as itx.\(name)")
                        self?.lend.add(mind: mind, name: name)
                    },
                    cancel: { FormWindow.close() }
                )
            )
        }
    }

    private func removeMind(_ mind: String) {
        panelWindow.performClose(nil)
        FormWindow.show(
            title: "Remove \(mind)?",
            RemoveMindForm(
                mind: mind,
                isActive: mind == lend.activeMind?.mind,
                remove: { [weak self] in
                    FormWindow.close()
                    self?.log.info("the person removes \(mind)")
                    self?.lend.remove(mind)
                },
                cancel: { FormWindow.close() }
            )
        )
    }

    /// The first lines of each run: which build ran, on what, and with which choices.
    private func logRunStart() {
        let executable = Bundle.main.executableURL
        let built = (try? executable?.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
        let builtText = built.map { ISO8601DateFormatter().string(from: $0) } ?? "unknown"
        log.info(
            "==== run start: process \(ProcessInfo.processInfo.processIdentifier), built \(builtText), macOS \(ProcessInfo.processInfo.operatingSystemVersionString), bundle \(Bundle.main.bundleIdentifier ?? "none (not run from the .app)"), log \(AppLog.fileURL.path)"
        )
        log.info("sharing: " + Shareable.all.map(Self.line).joined(separator: "; "))
    }

    private static func line(_ thing: Shareable) -> String {
        let waits = thing.sharing != .off && !thing.isPermitted ? ", waits for \(thing.power.permission?.title ?? "macOS")" : ""
        return "\(thing.id) (\(thing.title)) \(thing.sharing.rawValue)\(waits)"
    }

    // MARK: - The mark and the panel

    private func stateDidChange() {
        Perf.count("stateChanges")
        updateStatusButton()
        let banner = model.banners.state.showing
        if banner != panelState.banner { panelState.banner = banner }
        noteLastResult()
        showLend()
        configChanged()
        // the things, their choices and the permissions are read for an open panel only
        if panelWindow.isShown { refreshPanel() }
        if settings.isVisible { refreshSettings() }
    }

    /// The words expressions of config.json, by mind ("" for this Mac's default).
    private func expressions() -> [String: String] {
        var all: [String: String] = [:]
        if let config = lend.config {
            all[""] = config.wordsExpression
            for mind in config.minds { all[mind.mind] = mind.wordsExpression }
        }
        return all
    }

    /// config.json changed (the CLI's `set` among others): a new expression fetches its lists at
    /// once, and a new `login` sets the login item.
    private func configChanged() {
        let now = expressions()
        if now != seenExpressions {
            // a mind whose list comes from another expression now: its own changed, or the default it uses
            let effective = { (all: [String: String], mind: String) in all[mind] ?? all[""] }
            for mind in lend.config?.minds ?? [] where effective(now, mind.mind) != effective(seenExpressions, mind.mind) {
                words.refresh(mind.mind)
            }
            seenExpressions = now
        }
        if let login = lend.config?.login, appliedLogin != nil, login != appliedLogin { openAtLogin() }
    }

    // MARK: - The Activity window

    private func openActivityWindow() {
        panelWindow.performClose(nil)
        refreshPanel()
        activityWindow.show()
    }

    private func activityWindowActions() -> ActivityWindowActions {
        ActivityWindowActions(
            choose: { [weak self] thing, choice in
                guard let self else { return }
                thing.sharing = choice
                self.panelState.sharing[thing.id] = choice
                self.choiceChanged()
            },
            endApproval: { [weak self] thing in
                self?.model.approval.end(thing)
                self?.refreshPanel()
            },
            copy: { json in
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(json, forType: .string)
            })
    }

    // MARK: - Settings

    private func openSettings(_ page: SettingsState.Page) {
        panelWindow.performClose(nil)
        settingsState.page = page
        refreshSettings()
        settings.show()
        log.info("settings open: \(page.name)")
    }

    /// What Settings shows, read here and not while it draws.
    private func refreshSettings() {
        if panelState.lend != settingsState.lend { settingsState.lend = panelState.lend }
        let config = lend.config
        if settingsState.login != (config?.login ?? false) { settingsState.login = config?.login ?? false }
        if settingsState.defaultExpression != config?.wordsExpression { settingsState.defaultExpression = config?.wordsExpression }
        let own = Dictionary(uniqueKeysWithValues: (config?.minds ?? []).compactMap { mind in mind.wordsExpression.map { (mind.mind, $0) } })
        if settingsState.expressions != own { settingsState.expressions = own }
        let update = updateRow()
        if settingsState.update != update { settingsState.update = update }
        if settingsState.showsPill != model.acts.showsPill { settingsState.showsPill = model.acts.showsPill }
        // macOS's setting of 🌐 is read for the page that shows it alone
        if settingsState.page == .dictation {
            let fnLines = dictation.fnLines
            if settingsState.fnLines != fnLines { settingsState.fnLines = fnLines }
        }
        // a mind that was removed: its page goes
        if case .mind(let mind) = settingsState.page, !(config?.minds.contains { $0.mind == mind } ?? false) { settingsState.page = .general }
    }

    /// General's version rows, from where the app came from (`UpdateSource`) and the last ask of npm.
    private func updateRow() -> SettingsState.UpdateRow {
        UpdateStatus.of(
            lend.config?.source, home: NSHomeDirectory(), hasOwnHome: environment.hasOwnHome, updatesByItself: choices.updatesByItself,
            check: lend.updateCheck.map { (Lend.shortClock($0.at), $0.latest) })
    }

    private func settingsActions() -> SettingsActions {
        SettingsActions(
            setLogin: { [weak self] on in self?.lend.set([on ? "--login" : "--no-login"]) },
            setShowsPill: { [weak self] on in
                self?.model.acts.showsPill = on
                self?.settingsState.showsPill = on
            },
            setKey: { [weak self] id, combo in self?.setKey(id, combo) },
            recording: { [weak self] id, isRecording in self?.recordingKey(id, isRecording) },
            updateNow: { [weak self] in self?.lend.checkForUpdate(now: true) },
            copyPrompt: { [weak self] in self?.copyPrompt() },
            openKeyboardSettings: {
                if let url = URL(string: "x-apple.systempreferences:com.apple.Keyboard-Settings.extension") { NSWorkspace.shared.open(url) }
            },
            allowAccessibility: { [weak self] in self?.guide(.accessibility) },
            setDefaultExpression: { [weak self] expression in self?.lend.set(["--words-expression", expression ?? ""]) },
            setExpression: { [weak self] mind, expression in self?.lend.set(["--mind", mind, "--words-expression", expression ?? ""]) },
            fetchNow: { [weak self] mind in self?.words.fetchNow(mind) },
            showMind: { [weak self] mind in self?.showMind(mind) },
            rename: { [weak self] mind, name in self?.rename(mind, to: name) },
            pageChanged: { [weak self] in self?.refreshSettings() },
            lend: LendActions(
                reconnect: { [weak self] in self?.lend.reconnectNow() },
                use: { [weak self] mind in self?.lend.use(mind) },
                add: { [weak self] in self?.addMind() },
                remove: { [weak self] mind in self?.removeMind(mind) },
                open: { link in if let url = URL(string: link) { NSWorkspace.shared.open(url) } }
            )
        )
    }

    /// A mind's page shows: its sign-in and its word list are read again, away from the main thread.
    private func showMind(_ mind: String) {
        words.loadStatus(mind)
        words.refresh(mind)
        Task { @MainActor in
            let signIn = await SignIn.read(mind)
            if settingsState.signIns[mind] != signIn { settingsState.signIns[mind] = signIn }
        }
    }

    /// A new name for this Mac in a mind: a key is for one name, so the CLI's `add` makes a new key
    /// and a member allows it again. The person says yes first.
    private func rename(_ mind: String, to name: String) {
        let alert = NSAlert()
        alert.icon = NSApp.applicationIconImage
        if let problem = name.isEmpty ? "A name is needed, such as jane.mac." : MindProfile.deviceNameProblem(name) {
            alert.messageText = "\"\(name)\" is not a name"
            alert.informativeText = problem
            alert.runModal()
            return
        }
        alert.messageText = "Lend this Mac to \(mind) as itx.\(name)?"
        alert.informativeText = "A key is for one name. The new name needs a new key, and a member of the mind allows it again with a passkey. Until then this Mac is not lent to \(mind)."
        alert.addButton(withTitle: "Make a New Key")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        log.info("the person renames this Mac in \(mind) to itx.\(name)")
        lend.add(mind: mind, name: name)
    }

    /// What the panel shows of this Mac, read here and not while it draws: the things, their
    /// choices, the permissions macOS has not given, the approvals and uses, and what keeps fn
    /// dictation from working.
    private func refreshPanel() {
        let things = Shareable.all
        if things != panelState.things { panelState.things = things }
        let sharing = Dictionary(uniqueKeysWithValues: things.map { ($0.id, $0.sharing) })
        if sharing != panelState.sharing { panelState.sharing = sharing }
        let missing = Set(Permission.allCases.filter { !$0.isGranted })
        if missing != panelState.missing { panelState.missing = missing }
        let approvals = Dictionary(uniqueKeysWithValues: things.compactMap { thing in model.approval.isApproved(thing).map { (thing.id, $0) } })
        if approvals != panelState.approvals { panelState.approvals = approvals }
        if model.uses != panelState.uses { panelState.uses = model.uses }
        // Accessibility given since the last look: fn is heard from now
        if !dictation.hearsFn, !environment.hasOwnHome, AXIsProcessTrusted() { dictation.watchKeys() }
        let fnLines = dictation.fnLines
        if speechChoice.fnLines != fnLines { speechChoice.fnLines = fnLines }
    }

    /// The newest of the last capture, input and dictation: the one whose line changed last.
    private func noteLastResult() {
        var lines: [(what: String, line: String?, failed: Bool)] = [
            ("Last input", input.lastLine, input.lastFailed), ("Last dictation", dictation.lastLine, dictation.lastFailed),
        ]
        if #available(macOS 15.0, *), let capture = capture as? Capture { lines.append(("Last capture", capture.lastLine, capture.lastFailed)) }
        for (what, line, failed) in lines {
            guard let line, seenLines[what] != line else { continue }
            seenLines[what] = line
            panelState.lastResult = PanelState.LastResult(what: what, line: line, failed: failed)
        }
    }

    /// The iterate mark: green while a banner shows, red for 3 seconds at each use by a
    /// mind, orange while the microphone or a camera is on. Else the lend at a glance: plain while
    /// live, dimmed while it connects, dimmed and slashed while it is not lent. The record adds a
    /// red dot at its lower right, filled while it records, a ring while it is paused, and does not
    /// change the ink (`MenuBarMark`).
    private func updateStatusButton() {
        guard let button = markButton else { return }
        let use = MenuBarMark.inUse(lastUse: model.lastUse?.at, now: Date())
        // one look again, at the end of the red: a newer use moves it, and none is left behind
        useEnds?.cancel()
        useEnds = use.endsAt.map { end in
            let item = DispatchWorkItem { [weak self] in self?.updateStatusButton() }
            DispatchQueue.main.asyncAfter(wallDeadline: .now() + max(0.05, end.timeIntervalSinceNow + 0.05), execute: item)
            return item
        }
        let record = model.record
        let isOn = model.microphone.isRunning || model.isAnyCameraRunning || self.isCapturing
        let banner = model.banners.state.showing
        let glance = lend.state.phase.glance
        let mark = MenuBarMark.of(
            bannerShows: banner != nil, inUse: use.isInUse, microphoneOrCameraOn: isOn, glance: glance,
            isRecording: record.isRecording, isPaused: record.isPaused)
        let label = MenuBarMark.label(
            banner: banner.map { ($0.title, $0.isCall) }, inUse: use.isInUse, isCapturing: self.isCapturing, microphoneOrCameraOn: isOn,
            glance: glance, dot: mark.dot, tracks: record.tracks.count, pausedBecause: record.pausedBecause)
            + (listening.isAlwaysListening ? ". Always listen: the microphone is open" : "")
        // the button is written only when what it shows changed
        guard mark != shownMark || label != shownLabel else { return }
        Perf.count("statusWrites")
        // a test copy's mark is its own: the owner never quits the installed app for it
        if mark != shownMark { button.image = environment.hasOwnHome ? IterateIcon.testImage(mark) : IterateIcon.image(mark) }
        recordDot?.dot = mark.dot
        listenSign?.isOn = listening.isAlwaysListening
        let shown = environment.hasOwnHome ? "iterate test copy: \(environment.folder.path). \(label)" : label
        button.toolTip = environment.hasOwnHome ? "iterate test copy: \(environment.folder.path)" : label
        button.setAccessibilityLabel(shown)
        // the cell is the accessibility element (`ui.tree`, VoiceOver)
        button.cell?.setAccessibilityLabel(shown)
        if mark != shownMark { log.info("menu-bar icon: the iterate mark, \(mark.name)") }
        (shownMark, shownLabel) = (mark, label)
    }

    @objc private func togglePanel() {
        guard let button = markButton else { return }
        if panelWindow.isShown {
            panelWindow.performClose(nil)
        } else {
            // a lend that waits for its next start starts now: the owner looks at it
            lend.panelOpened()
            stateDidChange()
            refreshPanel()
            OffScreen.activate()
            panelWindow.show(under: button)
        }
    }

    /// While the panel is open, a thing that is not off shows what a mind would get: a camera runs
    /// for its picture, and a display's picture is a new small one every second.
    private func panelDidShow() {
        log.info("the panel opens")
        if !panelState.isActivityOpen { startPreviews() }
    }

    private func panelDidClose() {
        stopPreviews()
        panelState.isSwitcherOpen = false
        panelState.isActivityOpen = false
    }

    /// The previews run while the panel's main page shows: the cameras, and a display's picture
    /// each second.
    private func startPreviews() {
        previewsShow = true
        syncPreviews()
    }

    /// The displays whose small picture shows: on, with Screen Recording given.
    private var shownDisplays: [Shareable] {
        guard !panelState.missing.contains(.screenRecording) else { return [] }
        return panelState.things.filter { $0.power == .screen && panelState.sharing[$0.id, default: .off] != .off }
    }

    /// A new picture each second, only while a display's picture shows.
    private func syncDisplayTimer() {
        let wanted = previewsShow && panelWindow.isShown && !shownDisplays.isEmpty
        guard wanted != (displayPictureTimer != nil) else { return }
        displayPictureTimer?.invalidate()
        displayPictureTimer = nil
        guard wanted else { return }
        let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshDisplayPictures() }
        }
        timer.tolerance = 0.2
        RunLoop.main.add(timer, forMode: .common)
        displayPictureTimer = timer
    }

    private func stopPreviews() {
        previewsShow = false
        displayPictureTimer?.invalidate()
        displayPictureTimer = nil
        camerasHeldByThePanel.forEach(model.releaseCamera)
        camerasHeldByThePanel = []
        if !panelState.displayPictures.isEmpty { panelState.displayPictures = [:] }
    }

    /// A large picture of a display or a camera, for the popover of its small one.
    private func bigPicture(of thing: Shareable) async -> CGImage? {
        switch thing.power {
        case .screen:
            return try? await Screen.image(of: Screen.id(of: thing), maxWidth: 640)
        case .camera:
            guard let picture = model.cameraSnapshot(String(thing.id.dropFirst("camera.".count)), maxWidth: 640) else { return nil }
            return NSImage(data: picture)?.cgImage(forProposedRect: nil, context: nil, hints: nil)
        default:
            return nil
        }
    }

    private func choiceChanged() {
        log.info("sharing: " + Shareable.all.map(Self.line).joined(separator: "; "))
        stateDidChange()
        model.liveChoicesChanged()
        if panelWindow.isShown { syncPreviews() }
        // A thing was turned on whose permission macOS has not given: the guide starts.
        if let permission = Shareable.all.first(where: { $0.sharing != .off && !$0.isPermitted })?.power.permission,
            grantWatch == nil
        {
            guide(permission)
        }
    }

    /// The cameras whose choice is not off run for the open panel; the others do not.
    private func syncPreviews() {
        let wanted = Set(
            Shareable.all.filter { $0.power == .camera && $0.sharing != .off && $0.isPermitted }
                .map { String($0.id.dropFirst("camera.".count)) }
        )
        camerasHeldByThePanel.subtracting(wanted).forEach(model.releaseCamera)
        wanted.subtracting(camerasHeldByThePanel).forEach(model.holdCamera)
        camerasHeldByThePanel = wanted
        refreshDisplayPictures()
    }

    /// Each display's small picture, at the size it is drawn (30 points, 60 pixels wide), made by
    /// ScreenCaptureKit off the main thread.
    private func refreshDisplayPictures() {
        let shown = shownDisplays
        // a picture that no longer shows goes; a write that changes nothing tells no view
        let gone = Set(panelState.displayPictures.keys).subtracting(shown.map(\.id))
        if !gone.isEmpty { panelState.displayPictures = panelState.displayPictures.filter { !gone.contains($0.key) } }
        syncDisplayTimer()
        for thing in shown {
            Task { @MainActor in
                guard let picture = try? await Screen.image(of: Screen.id(of: thing), maxWidth: 60), panelWindow.isShown, !panelState.isActivityOpen else { return }
                panelState.displayPictures[thing.id] = picture
            }
        }
    }

    private func copyPrompt() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(Panel.prompt, forType: .string)
        log.info("the person copied the prompt")
        panelState.didCopy = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in self?.panelState.didCopy = false }
    }

    // MARK: - The guide to a permission

    /// A thing was turned on and macOS has not given what it needs. The app says what comes, then
    /// macOS shows its own prompt or settings pane; the person answers there. The app waits for the
    /// answer and finishes the step: after a Screen Recording grant it starts again by itself.
    private func guide(_ permission: Permission) {
        let alert = NSAlert()
        alert.messageText = "Allow iterate: \(permission.title)"
        alert.informativeText = permission.steps
        alert.icon = NSApp.applicationIconImage
        alert.addButton(withTitle: "Continue")
        alert.addButton(withTitle: "Not Now")
        OffScreen.activate()
        guard alert.runModal() == .alertFirstButtonReturn else {
            return log.info("the guide for \(permission.title): the person chose Not Now")
        }
        log.info("the guide for \(permission.title): macOS asks the person")
        permission.request()
        watchForGrants()
    }

    /// Looks every 3 s, for at most 5 minutes, whether macOS gave what the things that are not
    /// off still wait for (`GrantWatch`). It runs after the guide, so a switch set in System
    /// Settings is seen without another click; not at the start of the app, where the panel reads
    /// the permissions when it opens. Screen Recording's look is a new process, one at a time, and
    /// waited for off the main thread. After the 5 minutes, the panel's "Allow…" button starts it again.
    private func watchForGrants() {
        var waiting = Set(Shareable.all.filter { $0.sharing != .off }.compactMap(\.power.permission).filter { !$0.isGranted })
        grantWatch?.invalidate()
        grantWatch = nil
        guard !waiting.isEmpty else { return }
        var watch = GrantWatch(startedAt: Date())
        let timer = Timer(timeInterval: GrantWatch.interval, repeats: true) { [weak self] timer in
            MainActor.assumeIsolated {
                guard let self, self.grantWatch === timer else { return timer.invalidate() }
                for permission in waiting where permission.isGranted {
                    waiting.remove(permission)
                    self.log.info("macOS gave \(permission.title)")
                    self.stateDidChange()
                    if self.panelWindow.isShown { self.syncPreviews() }
                }
                if watch.probes(at: Date(), waitsForScreenRecording: waiting.contains(.screenRecording)) {
                    Task { @MainActor [weak self] in
                        let given = await Permission.screenRecordingWaitsForRestart()
                        watch.answered()
                        guard let self, self.grantWatch === timer, given else { return }
                        timer.invalidate()
                        self.log.info("macOS gave Screen Recording; the app starts again to use it")
                        Permission.restartTheApp()
                    }
                }
                if waiting.isEmpty || watch.isOver(at: Date()) {
                    timer.invalidate()
                    self.grantWatch = nil
                    if !waiting.isEmpty {
                        self.log.info("no answer from macOS in 5 minutes for: \(waiting.map(\.title).sorted().joined(separator: ", ")); the panel still offers it")
                    }
                }
            }
        }
        timer.tolerance = 0.5
        RunLoop.main.add(timer, forMode: .common)
        grantWatch = timer
    }
}
