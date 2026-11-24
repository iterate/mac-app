import AppKit
import ServiceManagement
import SwiftUI
import VoiceMeetCore

/// A menu-bar-only app: the iterate mark, and a panel under it (`Panel`). No window, no Dock icon.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSPopoverDelegate {
    private lazy var model = AppModel()
    private let log = AppLog("app")
    private let panelState = PanelState()
    private let lend = Lend()
    private let popover = NSPopover()
    private var statusItem: NSStatusItem?
    private var recordDot: RecordDotView?
    private var shownStatusIcon = ""
    private var terminationSignal: DispatchSourceSignal?
    private var grantWatch: Timer?
    private var displayPictureTimer: Timer?
    /// The cameras that run for the open panel's previews.
    private var camerasHeldByThePanel: Set<String> = []
    /// The person's own capture (⌥⇧S). It needs macOS 15: nil before.
    private var capture: AnyObject?
    /// The person's input to a mind (⌥⇧Space).
    private let input = MindInput()
    /// The person's dictation into the app in front (⌥⇧D).
    private let dictation = Dictation()
    /// The minds' word lists, for the speech model.
    private let words = Words()
    /// The control socket, for a test with no hand: nil unless `AppEnvironment` asks for it.
    private var control: ControlSocket?
    private let environment = AppEnvironment.current

    func applicationDidFinishLaunching(_ notification: Notification) {
        logRunStart()
        quitOnTerminationSignal()
        if environment.controlSocket != nil { ControlSocket.makeAccessibilityElements() }

        let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.target = self
        statusItem.button?.action = #selector(togglePanel)
        // the button's cell is its accessibility element
        statusItem.button?.cell?.setAccessibilityIdentifier("statusItem")
        self.statusItem = statusItem
        let markSize = environment.hasOwnHome ? IterateIcon.testImage(MenuBarMark(ink: .live, dot: .none)).size : IterateIcon.plain.size
        if let button = statusItem.button { recordDot = RecordDotView.attach(to: button, imageSize: markSize) }

        let panel = Panel(
            state: panelState,
            model: model,
            changed: { [weak self] in self?.choiceChanged() },
            allow: { [weak self] permission in self?.guide(permission) },
            copyPrompt: { [weak self] in self?.copyPrompt() },
            pressBanner: { [weak self] index in
                self?.popover.performClose(nil)
                if let index { self?.model.banners.press(index) } else { self?.model.banners.dismiss() }
            },
            openInput: { [weak self] in
                self?.popover.performClose(nil)
                self?.input.toggle()
            },
            lendActions: LendActions(
                reconnect: { [weak self] in self?.lend.reconnectNow() },
                use: { [weak self] mind in self?.lend.use(mind) },
                add: { [weak self] in self?.addMind() },
                remove: { [weak self] mind in self?.removeMind(mind) },
                open: { link in if let url = URL(string: link) { NSWorkspace.shared.open(url) } }
            )
        )
        let host = NSHostingController(rootView: panel)
        // The panel is as tall as its rows need.
        host.sizingOptions = [.preferredContentSize]
        popover.contentViewController = host
        // A test's copy is not the app in front, and a click elsewhere would close it at once: its
        // panel closes by its mark alone.
        popover.behavior = environment.hasOwnHome ? .applicationDefined : .transient
        popover.delegate = self

        model.onChange = { [weak self] in self?.stateDidChange() }
        // the address as the CLI says it (`iterate.example.com`), not the config's short name
        model.banners.activeMind = { [weak self] in self?.lend.state.mindAddress }
        model.record.onChange = { [weak self] in self?.stateDidChange() }
        model.banners.onChange = { [weak self] in self?.stateDidChange() }
        model.start()
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
        stateDidChange()
        watchForGrants()

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
    /// `npx @iterate-com/mac-app` (its config's `login`). A build run from elsewhere registers
    /// nothing, so that one copy alone is ever registered, and so does a copy with a home of its own.
    /// System Settings › General › Login Items shows it and can turn it off.
    private func openAtLogin() {
        guard Bundle.main.bundlePath.hasPrefix("/Applications/"), !environment.hasOwnHome else { return }
        let service = SMAppService.mainApp
        let wanted = lend.config?.login ?? false
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
        self.capture = capture
        control?.toggleCapture = { capture.toggle() }
        control?.markCapture = { capture.mark($0) }
        register(.capture, "capture", "starts and ends one", pressed: { capture.toggle() })
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
        register(.input, "input", "opens it", pressed: { [weak self] in self?.input.toggle() })
    }

    /// ⌥⇧D dictates into the app in front, with the word list of the mind this Mac is lent to
    /// (`Dictation`). The lists are fetched now, so that the first dictation has them.
    private func startDictation() {
        words.helpers = { [weak self] in self?.lend.helpers }
        for mind in lend.config?.minds ?? [] { words.refresh(mind.mind) }
        dictation.words = { [weak self] in self?.words.list(of: self?.lend.session?.mind) ?? .empty }
        dictation.allow = { [weak self] permission in self?.guide(permission) }
        dictation.onChange = { [weak self] in self?.stateDidChange() }
        control?.dictationPressed = { [weak self] in self?.dictation.pressed() }
        control?.dictationReleased = { [weak self] in self?.dictation.released() }
        register(.dictation, "dictation", "held, dictates", pressed: { [weak self] in self?.dictation.pressed() }, released: { [weak self] in self?.dictation.released() })
    }

    /// A key that works in any app. A copy with a home of its own registers none: the keys are the
    /// installed app's, and a test presses them through the control socket.
    private func register(_ combo: HotKey.Combo, _ what: String, _ does: String, pressed: @escaping () -> Void, released: (() -> Void)? = nil) {
        guard !environment.hasOwnHome else { return log.info("\(what): \(combo.words) is not registered in a home of its own") }
        let isRegistered = HotKey.register(combo, pressed: pressed, released: released)
        log.info(isRegistered ? "\(what): \(combo.words) \(does)" : "\(what): macOS refused the key \(combo.words)")
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
            "panel": ["visible": popover.isShown, "switcherOpen": panelState.isSwitcherOpen, "activityOpen": panelState.isActivityOpen],
            "input": input.controlState(),
            "dictation": dictation.controlState(),
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
        view.phase = lend.state.phase.name
        view.link = lend.state.phase.link ?? lend.commandLink
        view.commandLine = lend.commandLine
        view.isCommandRunning = lend.isCommandRunning
        view.source = lend.config.map { $0.source.line(home: NSHomeDirectory()) }
        if view != panelState.lend { panelState.lend = view }
    }

    /// "Add a Mind…": its address (the iterate CLI's profiles are offered) and the name this Mac
    /// is available under. The CLI's `add` makes the key and opens the link where a member allows it.
    private func addMind() {
        popover.performClose(nil)
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
        popover.performClose(nil)
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
        updateStatusButton()
        panelState.things = Shareable.all
        panelState.revision += 1
        let banner = model.banners.state.showing
        if banner != panelState.banner { panelState.banner = banner }
        if #available(macOS 15.0, *) { panelState.captureLine = (capture as? Capture)?.lastLine }
        if panelState.inputLine != input.lastLine { panelState.inputLine = input.lastLine }
        if panelState.dictationLine != dictation.lastLine { panelState.dictationLine = dictation.lastLine }
        showLend()
    }

    /// The iterate mark: green while a banner shows, red for 3 seconds at each use by a
    /// mind, orange while the microphone or a camera is on. Else the lend at a glance: plain while
    /// live, dimmed while it connects, dimmed and slashed while it is not lent. The record adds a
    /// red dot at its lower right, filled while it records, a ring while it is paused, and does not
    /// change the ink (`MenuBarMark`).
    private func updateStatusButton() {
        guard let button = statusItem?.button else { return }
        let isInUse = model.lastUse.map { Date().timeIntervalSince($0.at) < 3 } ?? false
        if isInUse {
            DispatchQueue.main.asyncAfter(deadline: .now() + 3.1) { [weak self] in self?.updateStatusButton() }
        }
        let record = model.record
        let isCapturing = model.microphone.isRunning || model.isAnyCameraRunning || self.isCapturing
        let banner = model.banners.state.showing
        let glance = lend.state.phase.glance
        let mark = MenuBarMark.of(
            bannerShows: banner != nil, inUse: isInUse, microphoneOrCameraOn: isCapturing, glance: glance,
            isRecording: record.isRecording, isPaused: record.isPaused)
        // a test copy's mark is its own: the owner never quits the installed app for it
        button.image = environment.hasOwnHome ? IterateIcon.testImage(mark) : IterateIcon.image(mark)
        recordDot?.dot = mark.dot
        let lendWords: String
        switch glance {
        case .live: lendWords = "iterate: lent"
        case .connecting: lendWords = "iterate: connecting"
        case .down: lendWords = "iterate: not lent"
        }
        let words =
            banner.map { $0.isCall ? "iterate: \($0.title) calls" : "iterate: \($0.title)" }
            ?? (isInUse ? "iterate: a mind uses this Mac now" : self.isCapturing ? "iterate: your capture runs" : isCapturing ? "iterate: microphone or camera on" : lendWords)
        let label = [words, mark.dot.words(tracks: record.tracks.count, pausedBecause: record.pausedBecause)].compactMap { $0 }.joined(separator: ", ")
        let shown = environment.hasOwnHome ? "iterate test copy: \(environment.folder.path). \(label)" : label
        button.toolTip = environment.hasOwnHome ? "iterate test copy: \(environment.folder.path)" : label
        button.setAccessibilityLabel(shown)
        // the cell is the accessibility element (`ui.tree`, VoiceOver)
        button.cell?.setAccessibilityLabel(shown)
        if mark.name != shownStatusIcon {
            shownStatusIcon = mark.name
            log.info("menu-bar icon: the iterate mark, \(mark.name)")
        }
    }

    @objc private func togglePanel() {
        guard let button = statusItem?.button else { return }
        if popover.isShown {
            popover.performClose(nil)
        } else {
            // a lend that waits for its next start starts now: the owner looks at it
            lend.panelOpened()
            stateDidChange()
            NSApp.activate(ignoringOtherApps: true)
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        }
    }

    /// While the panel is open, a thing that is not off shows what a mind would get: a camera runs
    /// for its picture, and a display's picture is a new small one every second.
    func popoverDidShow(_ notification: Notification) {
        log.info("the panel opens")
        syncPreviews()
        let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshDisplayPictures() }
        }
        RunLoop.main.add(timer, forMode: .common)
        displayPictureTimer = timer
    }

    func popoverDidClose(_ notification: Notification) {
        displayPictureTimer?.invalidate()
        displayPictureTimer = nil
        camerasHeldByThePanel.forEach(model.releaseCamera)
        camerasHeldByThePanel = []
        panelState.displayPictures = [:]
        panelState.isSwitcherOpen = false
    }

    private func choiceChanged() {
        log.info("sharing: " + Shareable.all.map(Self.line).joined(separator: "; "))
        stateDidChange()
        model.liveChoicesChanged()
        if popover.isShown { syncPreviews() }
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

    private func refreshDisplayPictures() {
        for thing in Shareable.all where thing.power == .screen {
            guard thing.sharing != .off, thing.isPermitted else {
                panelState.displayPictures[thing.id] = nil
                continue
            }
            Task { @MainActor in
                guard let picture = try? await Screen.image(of: Screen.id(of: thing), maxWidth: 480), popover.isShown else { return }
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
        NSApp.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertFirstButtonReturn else {
            return log.info("the guide for \(permission.title): the person chose Not Now")
        }
        log.info("the guide for \(permission.title): macOS asks the person")
        permission.request()
        watchForGrants()
    }

    /// Looks once a second, for at most 5 minutes, whether macOS gave what the things that are not
    /// off still wait for. It runs after the guide and at the start of the app, so a switch set in
    /// System Settings is seen without another click. After the 5 minutes, the panel's "Allow…"
    /// button starts it again.
    private func watchForGrants() {
        var waiting = Set(Shareable.all.filter { $0.sharing != .off }.compactMap(\.power.permission).filter { !$0.isGranted })
        grantWatch?.invalidate()
        grantWatch = nil
        guard !waiting.isEmpty else { return }
        var looksLeft = 300
        let timer = Timer(timeInterval: 1, repeats: true) { [weak self] timer in
            MainActor.assumeIsolated {
                guard let self else { return timer.invalidate() }
                looksLeft -= 1
                for permission in waiting where permission.isGranted {
                    waiting.remove(permission)
                    self.log.info("macOS gave \(permission.title)")
                    self.stateDidChange()
                    if self.popover.isShown { self.syncPreviews() }
                }
                if waiting.contains(.screenRecording), Permission.screenRecordingWaitsForRestart {
                    timer.invalidate()
                    self.log.info("macOS gave Screen Recording; the app starts again to use it")
                    Permission.restartTheApp()
                } else if waiting.isEmpty || looksLeft <= 0 {
                    timer.invalidate()
                    self.grantWatch = nil
                    if !waiting.isEmpty {
                        self.log.info("no answer from macOS in 5 minutes for: \(waiting.map(\.title).sorted().joined(separator: ", ")); the panel still offers it")
                    }
                }
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        grantWatch = timer
    }
}
