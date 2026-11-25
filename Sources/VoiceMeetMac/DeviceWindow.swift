import AppKit
import ApplicationServices
import Record
import VoiceMeetCore

/// THE WINDOW IN FRONT, told to the mind as two events on `/devices/<name>` (`DeviceEvents`):
///
/// - `device/app-focused { app, bundle, title }`: the front app or its window's title changed.
///   Always while the Mac is lent, and kept, like presence. The title needs Accessibility; without
///   it the title is empty.
/// - `device/window-read { app, title, text, trigger }`: the front window's text, when the person
///   ticked "Window text" (off by default). On a new app or window, a click, a pause after typing
///   and the end of a scroll; at most once every 2 s, only when the text changed, cut to 20,000
///   characters.
///
/// An excluded app in front (a password manager: `ExcludeList`) is told as `{ app, bundle }` with
/// no title, so that the run of the app before it ends; its window is never read. Every
/// Accessibility call runs on a queue of its own: an app that does not answer holds no other work.
/// A read is of the session and the setting it began in (`SessionWork`): one that ends after a
/// switch to another mind, or after "Window text" was turned off, is told to no mind.
@MainActor
final class DeviceWindow: ObservableObject {
    nonisolated static let maxCharacters = 20_000

    @Published var readsWindowText = AppEnvironment.current.defaults.bool(forKey: "device.windowText") {
        didSet {
            AppEnvironment.current.defaults.set(readsWindowText, forKey: "device.windowText")
            if !readsWindowText { endReads() }
            watchInput()
            if readsWindowText { trigger("window") }
        }
    }

    /// One event on the device's context (`DeviceEvents.publish`).
    var publish: (_ type: String, _ payload: [String: Any]) -> Void = { _, _ in }
    /// Whether the Mac is lent to a mind now.
    var isLent: () -> Bool = { false }

    private let exclude = ExcludeList()
    private struct Front: Equatable {
        let app, bundle: String
        /// nil for an excluded app
        let title: String?
    }
    private var front: Front?
    private var isChecking = false
    /// A change came while a check ran: one more check after it.
    private var checksAgain = false
    private var observer: NSObjectProtocol?
    /// The front app's own notifications of its focused window and its titles (`observeFront`).
    private var windowWatch: AXObserver?
    private var watchedPid: pid_t?
    private var monitors: [Any] = []
    private var lastKey: Date?
    private var lastScroll: Date?
    /// The one wait for the end of typing, and of a scroll.
    private var typingWait: DispatchWorkItem?
    private var scrollWait: DispatchWorkItem?
    /// Every Accessibility call runs here, the title's and the text's.
    private let reader = DispatchQueue(label: "device.window-read")
    private var lastRead = Date.distantPast
    private var waitingTrigger: String?
    private var lastText: String?
    private var work = SessionWork()

    /// No poll: the front app is checked when it changes (`didActivateApplication`), and its window
    /// and title when it says so (an `AXObserver` on it, moved at each activation).
    func start() {
        observer = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
        ) { [weak self] _ in MainActor.assumeIsolated { self?.frontChanged() } }
        watchInput()
        frontChanged()
    }

    /// Another session, or none: what the old one began lands nowhere, and the new mind hears the
    /// window in front and its text from the start.
    func use(_ session: MindSession?) {
        work.use(generation: session?.generation)
        front = nil
        lastText = nil
        waitingTrigger = nil
        // on the next turn: the device's events take the session after this (`AppModel.use`)
        DispatchQueue.main.async { [weak self] in MainActor.assumeIsolated { self?.frontChanged() } }
    }

    /// "Window text" is off: a read that runs or waits is told to no mind.
    private func endReads() {
        work.end()
        lastText = nil
        waitingTrigger = nil
    }

    func stop() {
        if let observer { NSWorkspace.shared.notificationCenter.removeObserver(observer) }
        observer = nil
        endWindowWatch()
        typingWait?.cancel()
        scrollWait?.cancel()
        monitors.forEach(NSEvent.removeMonitor)
        monitors = []
    }

    /// The app in front changed, or the lend did: its notifications are heard from now, and it is
    /// checked at once.
    private func frontChanged() {
        observeFront()
        check()
    }

    /// Hears the front app's focused window change and its titles change, while the Mac is lent and
    /// Accessibility is given. The observer is made on the reader's queue (it asks the app) and
    /// heard on the main run loop, where its callback only starts a check.
    private func observeFront() {
        let app = isLent() && Permission.accessibility.isGranted ? NSWorkspace.shared.frontmostApplication : nil
        let pid = app.flatMap { exclude.excludes($0.bundleIdentifier) ? nil : $0.processIdentifier }
        guard pid != watchedPid else { return }
        endWindowWatch()
        watchedPid = pid
        guard let pid else { return }
        let box = Unmanaged.passUnretained(self).toOpaque()
        reader.async { [weak self] in
            var made: AXObserver?
            let callback: AXObserverCallback = { _, _, _, refcon in
                guard let refcon else { return }
                // on the main run loop: the source is added there
                MainActor.assumeIsolated { Unmanaged<DeviceWindow>.fromOpaque(refcon).takeUnretainedValue().windowChanged() }
            }
            guard AXObserverCreate(pid, callback, &made) == .success, let made else { return }
            let element = AXUIElementCreateApplication(pid)
            AXUIElementSetMessagingTimeout(element, 0.3)
            for name in [kAXFocusedWindowChangedNotification, kAXMainWindowChangedNotification, kAXTitleChangedNotification] {
                _ = AXObserverAddNotification(made, element, name as CFString, box)
            }
            let watch = Handed(observer: made)
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    // another app came in front meanwhile: this one is not heard
                    guard let self, self.watchedPid == pid, self.windowWatch == nil else { return }
                    CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(watch.observer), .commonModes)
                    self.windowWatch = watch.observer
                }
            }
        }
    }

    private func endWindowWatch() {
        if let windowWatch { CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(windowWatch), .commonModes) }
        windowWatch = nil
        watchedPid = nil
    }

    /// The front app's window or a title changed.
    private func windowChanged() {
        Perf.count("windowChanges")
        check()
    }

    /// An observer handed from the reader's queue to the main one.
    private struct Handed: @unchecked Sendable {
        let observer: AXObserver
    }

    /// The front app and its window's title; an event when either changed.
    private func check() {
        Perf.count("frontChecks")
        guard isLent(), let app = NSWorkspace.shared.frontmostApplication else { return front = nil }
        guard !isChecking else { return checksAgain = true }
        isChecking = true
        let bundle = app.bundleIdentifier ?? "", pid = app.processIdentifier
        let name = app.localizedName ?? bundle, isExcluded = exclude.excludes(bundle)
        // the title is told while the Mac is lent, Window text or not: it goes by the session alone
        let session = work.stamp.generation
        reader.async { [weak self] in
            // a password manager's title is never read
            let title = isExcluded ? nil : Self.title(of: pid) ?? ""
            DispatchQueue.main.async {
                MainActor.assumeIsolated { self?.checked(Front(app: name, bundle: bundle, title: title), session: session) }
            }
        }
    }

    private func checked(_ now: Front, session: Int?) {
        isChecking = false
        if checksAgain {
            checksAgain = false
            defer { check() }
        }
        guard isLent(), session != nil, session == work.stamp.generation, now != front else { return }
        let trigger = now.bundle == front?.bundle ? "window" : "app"
        front = now
        var payload: [String: Any] = ["app": now.app, "bundle": now.bundle]
        if let title = now.title { payload["title"] = title }
        publish("device/app-focused", payload)
        if now.title != nil { self.trigger(trigger) }
    }

    nonisolated private static func title(of pid: pid_t) -> String? {
        guard Permission.accessibility.isGranted else { return nil }
        let element = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(element, 0.3)
        guard let window = Accessibility.attribute(element, kAXFocusedWindowAttribute), CFGetTypeID(window) == AXUIElementGetTypeID() else { return nil }
        return Accessibility.attribute(window as! AXUIElement, kAXTitleAttribute) as? String
    }

    /// Clicks, keys and scrolls only start a read: what they are is not kept here.
    private func watchInput() {
        monitors.forEach(NSEvent.removeMonitor)
        monitors = []
        guard readsWindowText else { return }
        let kinds: NSEvent.EventTypeMask = [.leftMouseDown, .rightMouseDown, .keyDown, .scrollWheel]
        if let monitor = NSEvent.addGlobalMonitorForEvents(matching: kinds, handler: { [weak self] event in
            MainActor.assumeIsolated {
                switch event.type {
                case .keyDown: self?.typed()
                case .scrollWheel: self?.scrolled()
                default: self?.trigger("click")
                }
            }
        }) {
            monitors.append(monitor)
        }
    }

    /// A key: a read 1 s after the last one. One wait at a time; a key meanwhile moves its end.
    private func typed() {
        lastKey = Date()
        guard typingWait == nil else { return }
        waitForPause(after: 1, of: \.lastKey, trigger: "typing-pause", wait: \.typingWait)
    }

    /// A scroll: a read 0.3 s after its last step.
    private func scrolled() {
        lastScroll = Date()
        guard scrollWait == nil else { return }
        waitForPause(after: 0.3, of: \.lastScroll, trigger: "scroll-end", wait: \.scrollWait)
    }

    private func waitForPause(
        after seconds: TimeInterval, of last: ReferenceWritableKeyPath<DeviceWindow, Date?>, trigger name: String,
        wait: ReferenceWritableKeyPath<DeviceWindow, DispatchWorkItem?>
    ) {
        let left = max(0.01, seconds - Date().timeIntervalSince(self[keyPath: last] ?? Date()))
        let item = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                self[keyPath: wait] = nil
                guard let at = self[keyPath: last] else { return }
                if Date().timeIntervalSince(at) >= seconds {
                    self[keyPath: last] = nil
                    self.trigger(name)
                } else {
                    self.waitForPause(after: seconds, of: last, trigger: name, wait: wait)
                }
            }
        }
        self[keyPath: wait] = item
        DispatchQueue.main.asyncAfter(deadline: .now() + left, execute: item)
    }

    // MARK: - The window's text

    /// At most one read every 2 s: a trigger inside that time waits for its end, and the newest
    /// trigger's name goes with the read.
    private func trigger(_ name: String) {
        guard readsWindowText, isLent(), Permission.accessibility.isGranted else { return }
        if waitingTrigger != nil { return waitingTrigger = name }
        let wait = lastRead.addingTimeInterval(2).timeIntervalSinceNow
        guard wait > 0 else { return read(name) }
        waitingTrigger = name
        let stamp = work.stamp
        DispatchQueue.main.asyncAfter(deadline: .now() + wait) { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.work.lands(stamp), let name = self.waitingTrigger else { return }
                self.waitingTrigger = nil
                self.read(name)
            }
        }
    }

    private func read(_ trigger: String) {
        lastRead = Date()
        // The app checked is the one whose window is read.
        guard let app = NSWorkspace.shared.frontmostApplication, !exclude.excludes(app.bundleIdentifier) else { return }
        let name = app.localizedName ?? app.bundleIdentifier ?? ""
        let stamp = work.stamp
        reader.async { [weak self] in
            let element = AXUIElementCreateApplication(app.processIdentifier)
            AXUIElementSetMessagingTimeout(element, 0.5)
            guard let window = Accessibility.attribute(element, kAXFocusedWindowAttribute), CFGetTypeID(window) == AXUIElementGetTypeID() else { return }
            var budget = 5_000
            let tree = Accessibility.describe(window as! AXUIElement, depth: 40, budget: &budget)
            var lines: [String] = []
            Self.text(of: tree, into: &lines)
            let text = String(lines.joined(separator: "\n").prefix(Self.maxCharacters))
            let title = tree["title"] as? String ?? ""
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    // of the session and the setting it began in, or of none
                    guard let self, self.work.lands(stamp), self.readsWindowText, text != self.lastText else { return }
                    self.lastText = text
                    self.publish("device/window-read", ["app": name, "title": title, "text": text, "trigger": trigger])
                }
            }
        }
    }

    /// Plain text of an accessibility tree: titles, values and descriptions in tree order, without
    /// repeats in a row.
    nonisolated private static func text(of node: [String: Any], into lines: inout [String]) {
        for key in ["title", "value", "description"] {
            if let text = node[key] as? String, text != lines.last { lines.append(text) }
        }
        for child in node["children"] as? [[String: Any]] ?? [] { text(of: child, into: &lines) }
    }
}
