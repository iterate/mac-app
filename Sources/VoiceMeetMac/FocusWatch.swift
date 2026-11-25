import AppKit
import ApplicationServices
import Carbon
import VoiceMeetCore

/// THE PASSWORD RULE FOR EACH KEY, cheap (`SecretKeys`): a key typed into a password goes to no
/// mind, not even the first one after the focus moved, and a key asks no other process when it can
/// be helped. Measured on 25 Nov 2026: each key asked LaunchServices for the front app's pid and
/// bundle id (`NSRunningApplication` fetches them again after each turn of the run loop), the
/// window server twice for secure input, and the front app three times for its focus.
///
/// - The app in front is kept, with its pid, bundle id and name, from one activation
///   (`didActivateApplicationNotification`, which `frontmostApplication` follows too) to the next.
/// - The front app's own notifications of its focus (an `AXObserver` for
///   `kAXFocusedUIElementChangedNotification` and `kAXFocusedWindowChangedNotification`) are read
///   once each, into a verdict (`FocusVerdict`). Before a key reads it, the notifications that
///   wait are heard: their source is also in a run loop mode of its own, run for them alone.
/// - With no observer (no Accessibility, an app that did not answer, the moment after an
///   activation) or no verdict (a read that failed), the key asks the app, as each key did before.
///
/// The observer is made on a queue of its own: an app that does not answer holds no other work.
@MainActor
final class FocusWatch {
    /// The app in front, as a key reads it.
    struct Front {
        let pid: pid_t
        let bundle: String?
        let name: String?
    }

    /// The mode in which the observer's notifications are heard before a key.
    private static let mode = CFRunLoopMode("com.iterate.focus-watch" as CFString)
    /// The most an app may take to answer one question about its focus.
    nonisolated private static let timeout: Float = 0.05

    private var front: Front?
    private var verdict = FocusVerdict()
    private var observer: AXObserver?
    private var observedPid: pid_t?
    private var activation: NSObjectProtocol?
    private let maker = DispatchQueue(label: "device.focus-watch")
    private let log = AppLog("device")
    private(set) var isRunning = false

    func start() {
        guard !isRunning else { return }
        isRunning = true
        activation = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
        ) { [weak self] _ in MainActor.assumeIsolated { _ = self?.read() } }
        _ = read()
    }

    func stop() {
        isRunning = false
        if let activation { NSWorkspace.shared.notificationCenter.removeObserver(activation) }
        activation = nil
        endObserver()
        front = nil
        verdict.front(nil)
    }

    /// The app in front now: while the watch runs, the one of the last activation.
    func current() -> Front? {
        if isRunning, let front { return front }
        return read()
    }

    /// The app in front, read again; another one than before is observed.
    private func read() -> Front? {
        let now = NSWorkspace.shared.frontmostApplication.map { Front(pid: $0.processIdentifier, bundle: $0.bundleIdentifier, name: $0.localizedName) }
        front = now
        verdict.front(now?.pid)
        if isRunning, let pid = now?.pid { observe(pid) }
        return now
    }

    /// Whether a key typed now goes into a password (`SecretKeys.withholds`).
    func isSecret() -> Bool {
        if IsSecureEventInputEnabled() { return true }
        let front = current()
        if let bundle = front?.bundle, SecretKeys.apps.contains(bundle.lowercased()) { return true }
        guard let pid = front?.pid else { return false }
        // the focus changes that the app told and the run loop has not given yet
        if observer != nil {
            while CFRunLoopRunInMode(Self.mode, 0, true) == .handledSource {}
        }
        if let kept = verdict.verdict(for: pid) { return kept }
        Perf.count("focusAsks")
        let (role, subrole, read) = Self.focus(of: pid)
        // the answer holds for the next keys, for `FocusVerdict.maxAge` if it is "not a password"
        verdict.read(pid: pid, role: role, subrole: subrole, read: read)
        return SecretKeys.isPasswordField(role: role, subrole: subrole)
    }

    /// The role and subrole of the focused element of `pid`; `read` is false when it did not answer.
    nonisolated private static func focus(of pid: pid_t) -> (role: String?, subrole: String?, read: Bool) {
        let element = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(element, timeout)
        var focused: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXFocusedUIElementAttribute as CFString, &focused) == .success,
            let focused, CFGetTypeID(focused) == AXUIElementGetTypeID()
        else { return (nil, nil, false) }
        let field = focused as! AXUIElement
        AXUIElementSetMessagingTimeout(field, timeout)
        var values: CFArray?
        // one question for both: an attribute the element lacks comes back as an error value
        guard AXUIElementCopyMultipleAttributeValues(field, [kAXRoleAttribute, kAXSubroleAttribute] as CFArray, [], &values) == .success,
            let list = values as? [Any], list.count == 2
        else { return (nil, nil, false) }
        return (list[0] as? String, list[1] as? String, true)
    }

    /// The front app's focus, heard from now on. Until the observer is made, keys ask.
    private func observe(_ pid: pid_t) {
        guard pid != observedPid else { return }
        endObserver()
        observedPid = pid
        guard AXIsProcessTrusted() else { return }
        nonisolated(unsafe) let box = Unmanaged.passUnretained(self).toOpaque()
        maker.async { [weak self] in
            var made: AXObserver?
            let callback: AXObserverCallback = { _, _, _, refcon in
                guard let refcon else { return }
                // on the main run loop: the source is added there alone
                MainActor.assumeIsolated { Unmanaged<FocusWatch>.fromOpaque(refcon).takeUnretainedValue().focusMoved() }
            }
            guard AXObserverCreate(pid, callback, &made) == .success, let made else { return }
            let element = AXUIElementCreateApplication(pid)
            AXUIElementSetMessagingTimeout(element, 0.3)
            let added = [kAXFocusedUIElementChangedNotification, kAXFocusedWindowChangedNotification].map {
                AXObserverAddNotification(made, element, $0 as CFString, box)
            }
            // an app that hears no focus change keeps the question at each key
            guard added.allSatisfy({ $0 == .success || $0 == .notificationAlreadyRegistered }) else { return }
            // the focus now, after the registration: a change from here on is told after it
            let now = Self.focus(of: pid)
            let handed = Handed(observer: made)
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    // another app came in front meanwhile: this one is not heard
                    guard let self, self.isRunning, self.observedPid == pid, self.observer == nil else { return }
                    let source = AXObserverGetRunLoopSource(handed.observer)
                    CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
                    CFRunLoopAddSource(CFRunLoopGetMain(), source, Self.mode)
                    self.observer = handed.observer
                    self.verdict.read(pid: pid, role: now.role, subrole: now.subrole, read: now.read)
                }
            }
        }
    }

    /// The front app's focus moved: read once, for every key until the next move.
    private func focusMoved() {
        guard let pid = observedPid else { return }
        Perf.count("focusMoves")
        let now = Self.focus(of: pid)
        verdict.read(pid: pid, role: now.role, subrole: now.subrole, read: now.read)
    }

    private func endObserver() {
        if let observer {
            let source = AXObserverGetRunLoopSource(observer)
            CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
            CFRunLoopRemoveSource(CFRunLoopGetMain(), source, Self.mode)
        }
        observer = nil
        observedPid = nil
        verdict.forget()
    }

    /// An observer handed from the maker's queue to the main one.
    private struct Handed: @unchecked Sendable {
        let observer: AXObserver
    }
}
