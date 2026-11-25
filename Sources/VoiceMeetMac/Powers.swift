import AppKit
import ApplicationServices
import CoreImage
import Record
import ScreenCaptureKit
import VoiceMeetCore

/// A still picture of a whole display, at any time. It needs the Screen Recording permission.
enum Screen {
    /// This Mac's displays, the main one first.
    static var displays: [(id: CGDirectDisplayID, name: String)] {
        NSScreen.screens.compactMap { screen in
            (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID).map { ($0, screen.localizedName) }
        }
    }

    /// The display a caller means: by its number (0 is the main one), or the first one that is not
    /// off. A display that is off is refused.
    static func resolve(_ index: Int?) throws -> Shareable {
        let things = displays.map(Shareable.display)
        guard let index else {
            guard let first = things.first(where: { $0.sharing != .off }) else {
                throw EndpointRefusal("Every display is off in the iterate panel on the Mac.")
            }
            return first
        }
        guard things.indices.contains(index) else {
            throw EndpointRefusal("No display \(index): this Mac has \(things.count) display(s), numbered from 0.")
        }
        return things[index]
    }

    /// The display of a thing made by `Shareable.display`.
    static func id(of thing: Shareable) -> CGDirectDisplayID {
        CGDirectDisplayID(thing.id.dropFirst("screen.".count)) ?? CGMainDisplayID()
    }

    /// What of a display a picture or a movie shows: never the windows of the apps that
    /// `ExcludeList` names (the password managers), as the record. With `onlyOwn`, of this app's
    /// own windows those alone (a capture's ink, not its pill, the input bar or a panel).
    static func filter(of display: SCDisplay, in content: SCShareableContent, onlyOwn: Set<CGWindowID>? = nil) -> SCContentFilter {
        let exclude = ExcludeList()
        var left = content.applications.filter { exclude.excludes($0.bundleIdentifier) }
        var kept: [SCWindow] = []
        let me = ProcessInfo.processInfo.processIdentifier
        // a window that macOS does not list yet would be left out with the rest: then this app's
        // windows all stay, and its others keep out by their `sharingType`
        if let onlyOwn, let own = content.applications.first(where: { $0.processID == me }) {
            kept = content.windows.filter { onlyOwn.contains($0.windowID) }
            if kept.count == onlyOwn.count { left.append(own) } else { kept = [] }
        }
        return SCContentFilter(display: display, excludingApplications: left, exceptingWindows: kept)
    }

    /// A picture of one display, at most `maxWidth` pixels wide. `onlyOwn`: as `filter`.
    static func image(of wanted: CGDirectDisplayID, maxWidth: Int, onlyOwn: Set<CGWindowID>? = nil) async throws -> CGImage {
        guard Permission.screenRecording.isGranted else {
            throw EndpointRefusal("macOS has not given this app Screen Recording. The Mac's owner gives it from the iterate panel.")
        }
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        guard let display = content.displays.first(where: { $0.displayID == wanted }) else {
            throw EndpointRefusal("That display is not connected.")
        }
        let filter = filter(of: display, in: content, onlyOwn: onlyOwn)
        let pixelWidth = filter.contentRect.width * CGFloat(filter.pointPixelScale)
        let scale = min(1, CGFloat(max(maxWidth, 1)) / pixelWidth)
        let configuration = SCStreamConfiguration()
        configuration.width = Int(pixelWidth * scale)
        configuration.height = Int(filter.contentRect.height * CGFloat(filter.pointPixelScale) * scale)
        configuration.showsCursor = true
        return try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: configuration)
    }

    static func snapshot(of display: CGDirectDisplayID, maxWidth: Int) async throws -> (data: Data, width: Int, height: Int) {
        let image = try await image(of: display, maxWidth: maxWidth)
        guard let picture = Snapshot.jpeg(of: CIImage(cgImage: image), maxWidth: maxWidth) else {
            throw EndpointRefusal("The app could not make a picture of the display.")
        }
        return picture
    }
}

/// The accessibility tree of the window in front: what is on screen as text and controls, not as
/// a picture. It needs the Accessibility permission.
///
/// A read asks another app for each element, and that app may be busy: every read of this app's
/// own features goes to one serial queue (`read`), never to the main thread, and each call waits at
/// most `timeout` for an answer. The window of an app that `ExcludeList` names (a password
/// manager) is never read.
enum Accessibility {
    /// The most seconds an app is waited for, for one element.
    static let timeout: Float = 0.5
    /// The most elements one read describes.
    static let mostNodes = 5_000

    private static let queue = DispatchQueue(label: "com.iterate.accessibility", qos: .userInitiated)
    /// Set once, for every element of every app: the default is 6 s.
    private static let timeouts: Void = { AXUIElementSetMessagingTimeout(AXUIElementCreateSystemWide(), timeout) }()

    /// The app in front, as a read needs it: taken on the main actor, read on the queue.
    struct App: Sendable {
        let pid: pid_t
        let name: String?
        let bundle: String?
        var isExcluded: Bool { ExcludeList().excludes(bundle) }

        @MainActor static var front: App? {
            NSWorkspace.shared.frontmostApplication.map { App(pid: $0.processIdentifier, name: $0.localizedName, bundle: $0.bundleIdentifier) }
        }
    }

    /// A value that is used on one side at a time: an answer of the queue.
    struct Handed<Value>: @unchecked Sendable {
        let value: Value
    }

    /// Runs `work` on the queue of reads, one after the other.
    static func read<Value>(_ work: @escaping @Sendable () throws -> Value) async throws -> Value {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Handed<Value>, Error>) in
            queue.async {
                _ = timeouts
                continuation.resume(with: Result { Handed(value: try work()) })
            }
        }.value
    }

    /// The tree of the window in front, read on the queue. As `frontWindow`.
    @MainActor
    static func readFrontWindow(maxDepth: Int, maxNodes: Int) async throws -> [String: Any] {
        guard Permission.accessibility.isGranted else { throw notAllowed }
        guard let app = App.front else { throw EndpointRefusal("No application is in front.") }
        return try await read { Handed(value: try tree(of: app, maxDepth: maxDepth, maxNodes: maxNodes)) }.value
    }

    /// The tree of the window in front, on the caller's thread. `readFrontWindow` keeps the main thread free.
    @MainActor
    static func frontWindow(maxDepth: Int, maxNodes: Int) throws -> [String: Any] {
        guard Permission.accessibility.isGranted else { throw notAllowed }
        guard let app = App.front else { throw EndpointRefusal("No application is in front.") }
        _ = timeouts
        return try tree(of: app, maxDepth: maxDepth, maxNodes: maxNodes)
    }

    private static var notAllowed: EndpointRefusal {
        EndpointRefusal("This app has no Accessibility permission. The person gives it in the iterate menu (Grant Accessibility…).")
    }

    /// The focused window of `app`, at most `maxNodes` elements (and never more than `mostNodes`).
    static func tree(of app: App, maxDepth: Int, maxNodes: Int) throws -> [String: Any] {
        guard !app.isExcluded else {
            throw EndpointRefusal("The app in front, \(app.name ?? app.bundle ?? "a password manager"), is one whose windows are never read.")
        }
        let element = AXUIElementCreateApplication(app.pid)
        var budget = min(max(maxNodes, 1), mostNodes)
        var answer: [String: Any] = [
            "application": app.name ?? "",
            "bundleIdentifier": app.bundle ?? "",
        ]
        if let window = focusedWindow(of: element) {
            answer["window"] = describe(window, depth: maxDepth, budget: &budget)
        }
        answer["truncated"] = budget <= 0
        return answer
    }

    static func focusedWindow(of application: AXUIElement) -> AXUIElement? {
        guard let window = attribute(application, kAXFocusedWindowAttribute), CFGetTypeID(window) == AXUIElementGetTypeID() else { return nil }
        // The type was checked on the line above.
        return (window as! AXUIElement)
    }

    /// The window in front, for a capture: its title and its page (a browser's), on the queue. Nil
    /// title and page for an app whose windows are never read.
    static func window(of app: App) -> (title: String?, url: String?) {
        guard !app.isExcluded else { return (nil, nil) }
        guard let window = focusedWindow(of: AXUIElementCreateApplication(app.pid)) else { return (nil, nil) }
        let title = attribute(window, kAXTitleAttribute) as? String
        return (title, attribute(window, kAXDocumentAttribute) as? String ?? pageURL(in: window))
    }

    /// The element of `app` at a point of the desktop (from the top left of the first display):
    /// its role, title and value, each at most 300 characters. On the queue.
    static func element(of app: App, at point: CGPoint) -> [String: Any]? {
        guard !app.isExcluded else { return nil }
        var found: AXUIElement?
        guard AXUIElementCopyElementAtPosition(AXUIElementCreateApplication(app.pid), Float(point.x), Float(point.y), &found) == .success, let found else { return nil }
        var budget = 1
        let described = describe(found, depth: 0, budget: &budget)
        return described.isEmpty ? nil : described.mapValues { ($0 as? String).map { String($0.prefix(300)) } ?? $0 }
    }

    static func describe(_ element: AXUIElement, depth: Int, budget: inout Int) -> [String: Any] {
        budget -= 1
        var node: [String: Any] = [:]
        for (key, name) in [
            ("role", kAXRoleAttribute), ("title", kAXTitleAttribute), ("value", kAXValueAttribute),
            ("description", kAXDescriptionAttribute),
        ] {
            if let text = attribute(element, name) as? String, !text.isEmpty {
                node[key] = String(text.prefix(2_000))
            }
        }
        if depth > 0, let children = attribute(element, kAXChildrenAttribute) as? [AXUIElement], !children.isEmpty {
            var described: [[String: Any]] = []
            for child in children where budget > 0 {
                described.append(describe(child, depth: depth - 1, budget: &budget))
            }
            node["children"] = described
        }
        return node
    }

    static func attribute(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
        var value: CFTypeRef?
        return AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success ? value : nil
    }

    /// The page a browser's window shows: the URL of its first web area. A window that has no
    /// document of its own (Chrome's) has one. At most 400 elements are looked at, breadth first.
    static func pageURL(in window: AXUIElement) -> String? {
        var queue = [window]
        var next = 0
        while next < queue.count, next < 400 {
            let element = queue[next]
            next += 1
            if attribute(element, kAXRoleAttribute) as? String == "AXWebArea", let url = attribute(element, kAXURLAttribute) as? URL {
                return url.absoluteString
            }
            if queue.count < 400 { queue += attribute(element, kAXChildrenAttribute) as? [AXUIElement] ?? [] }
        }
        return nil
    }
}

/// Runs a command as a child of this app. macOS counts a child's use of the screen, the camera,
/// the microphone and Accessibility as this app's, so the command has the app's permissions. The
/// bounds (output, deadline, a process group of its own) are `CommandRun`'s.
enum Commands {
    static func run(_ argv: [String], stdin: Data, timeout: TimeInterval) async throws -> [String: Any] {
        guard let command = argv.first else { throw EndpointRefusal("run needs a command: argv is a list of strings.") }
        // A bare name is found on the PATH, as in a shell; a path is run as it is.
        let executable = command.contains("/") ? command : "/usr/bin/env"
        let arguments = command.contains("/") ? Array(argv.dropFirst()) : argv
        let result: CommandRun.Result
        do {
            result = try await CommandRun.run(executable, arguments, stdin: stdin, timeout: timeout)
        } catch {
            throw EndpointRefusal("The command did not start: \(error)")
        }
        return [
            "exitCode": Int(result.status),
            "timedOut": result.timedOut,
            "stdoutBase64": result.stdout.base64EncodedString(),
            "stderrBase64": result.stderr.base64EncodedString(),
        ]
    }
}
