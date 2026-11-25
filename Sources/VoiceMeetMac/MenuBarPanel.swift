import AppKit

/// THE PANEL'S WINDOW, under the mark in the menu bar. The panel draws its own ground: a solid
/// surface with rounded corners of 14 points and an edge (`Panel`, design/html). This window is
/// borderless and see-through around it, with the system's shadow, so nothing of a popover's
/// material or arrow shows.
///
/// It is as tall as the panel's content needs (`preferredContentSize` of its controller), with its
/// top edge kept under the menu bar. When it `closesByItself`, a click in another app, another app
/// coming to the front, or Esc closes it, as a transient popover; a test copy's panel closes by its
/// mark alone.
@MainActor
final class MenuBarPanel: NSObject {
    /// What the panel shows. Its `preferredContentSize` is the window's size.
    var contentViewController: NSViewController? {
        didSet { watchSize() }
    }
    var closesByItself = true
    var onShow: () -> Void = {}
    var onClose: () -> Void = {}
    private(set) var isShown = false

    private var window: Window?
    private var monitors: [Any] = []
    private var resignWatch: NSObjectProtocol?
    private var sizeWatch: NSKeyValueObservation?
    /// The points between the menu bar and the panel's top.
    private static let gap: CGFloat = 5

    /// Shows the panel under `anchor` (the mark's button), centred on it and kept on its screen.
    func show(under anchor: NSView) {
        guard let controller = contentViewController else { return }
        let window = self.window ?? makeWindow()
        if window.contentViewController !== controller { window.contentViewController = controller }
        let size = Self.size(of: controller)
        let screen = anchor.window?.screen ?? NSScreen.main
        var origin = CGPoint.zero
        if let anchorWindow = anchor.window {
            let mark = anchorWindow.convertToScreen(anchor.convert(anchor.bounds, to: nil))
            origin = CGPoint(x: mark.midX - size.width / 2, y: mark.minY - Self.gap - size.height)
        }
        if let visible = screen?.visibleFrame {
            origin.x = min(max(origin.x, visible.minX + 6), visible.maxX - 6 - size.width)
            if origin.y + size.height > visible.maxY - Self.gap { origin.y = visible.maxY - Self.gap - size.height }
        }
        window.setFrame(NSRect(origin: origin, size: size), display: true)
        window.makeKeyAndOrderFront(nil)
        window.invalidateShadow()
        isShown = true
        if closesByItself { watchOutside() }
        onShow()
    }

    func performClose(_ sender: Any?) {
        guard isShown else { return }
        isShown = false
        stopWatchingOutside()
        window?.orderOut(sender)
        onClose()
    }

    private func makeWindow() -> Window {
        let window = Window(contentRect: .zero, styleMask: [.borderless], backing: .buffered, defer: true)
        window.isFloatingPanel = true
        window.level = .statusBar
        window.backgroundColor = .clear
        window.isOpaque = false
        window.hasShadow = true
        window.isReleasedWhenClosed = false
        window.hidesOnDeactivate = false
        window.animationBehavior = .utilityWindow
        window.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary, .transient, .ignoresCycle]
        window.cancel = { [weak self] in if self?.closesByItself == true { self?.performClose(nil) } }
        self.window = window
        return window
    }

    private static func size(of controller: NSViewController) -> CGSize {
        let preferred = controller.preferredContentSize
        return preferred.width > 0 && preferred.height > 0 ? preferred : controller.view.fittingSize
    }

    /// The window follows the content's size, its top edge where it is.
    private func watchSize() {
        sizeWatch = contentViewController?.observe(\.preferredContentSize, options: [.new]) { [weak self] controller, _ in
            MainActor.assumeIsolated {
                guard let self, let window = self.window, self.isShown else { return }
                let size = Self.size(of: controller)
                let frame = window.frame
                guard frame.size != size else { return }
                window.setFrame(NSRect(x: frame.minX, y: frame.maxY - size.height, width: size.width, height: size.height), display: true)
                window.invalidateShadow()
            }
        }
    }

    private func watchOutside() {
        stopWatchingOutside()
        if let monitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown], handler: { [weak self] _ in
            MainActor.assumeIsolated { self?.performClose(nil) }
        }) {
            monitors.append(monitor)
        }
        resignWatch = NotificationCenter.default.addObserver(forName: NSApplication.didResignActiveNotification, object: nil, queue: .main) {
            [weak self] _ in
            MainActor.assumeIsolated { self?.performClose(nil) }
        }
    }

    private func stopWatchingOutside() {
        for monitor in monitors { NSEvent.removeMonitor(monitor) }
        monitors = []
        if let resignWatch { NotificationCenter.default.removeObserver(resignWatch) }
        resignWatch = nil
    }

    /// A panel that takes the keyboard (the panel's shortcuts: ⌘Q, ⌘,) and closes on Esc.
    private final class Window: NSPanel {
        var cancel: () -> Void = {}
        override var canBecomeKey: Bool { true }
        override var canBecomeMain: Bool { false }
        override func cancelOperation(_ sender: Any?) { cancel() }
    }
}
