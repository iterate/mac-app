import AppKit

/// A TEST COPY SHOWS NOTHING TO THE PERSON AT THE MAC. A copy with a home of its own (`--home`,
/// `ITERATE_MAC_HOME`) runs beside the installed app while a person works, so each window it orders
/// in is transparent (alpha 0) and lets every click through, and it is never key: the app in front
/// keeps the keyboard. The copy never activates itself. It has no status item in the menu bar: its
/// mark is a button of the same image in a window of its own (`markButton`), transparent too.
///
/// The windows are still ordered in, at their frames, with their views laid out and drawn: the
/// control socket reads, presses and types into them as before, and `ui.key` sends its keys to the
/// front window when none is key. `harness/run.mjs` reads the window server's list and fails when a
/// window of a test copy shows on a display. `--on-screen` shows a test copy as the installed app
/// shows itself, for a person who wants to watch it. A drawing (`--render-*`) orders no window in.
/// README, "Testing with no hand".
@MainActor
enum OffScreen {
    static let isOn = AppEnvironment.current.hasOwnHome && !CommandLine.arguments.contains("--on-screen")

    /// The alpha of a window that is fully shown: 0 in a test copy.
    static var shown: CGFloat { isOn ? 0 : 1 }

    /// Orders `window` in: as `onScreen` does in the installed app; in a test copy transparent,
    /// through for the mouse, not key, over the other windows.
    static func orderFront(_ window: NSWindow, onScreen: () -> Void) {
        guard isOn else { return onScreen() }
        orderIn(window)
    }

    private static func orderIn(_ window: NSWindow) {
        // AppKit's own fade at the order-in would raise the alpha for a moment
        window.animationBehavior = .none
        window.alphaValue = 0
        window.ignoresMouseEvents = true
        window.orderFrontRegardless()
    }

    /// Makes the app the active one, except in a test copy.
    static func activate() {
        guard !isOn else { return }
        NSApp.activate(ignoringOtherApps: true)
    }

    /// A test copy's mark in place of a status item: a button in a borderless window where the
    /// menu bar's right end is on the main display, ordered in as every window of a test copy.
    static func markButton() -> NSStatusBarButton {
        let size = NSSize(width: 64, height: NSStatusBar.system.thickness)
        let screen = NSScreen.main?.frame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let frame = NSRect(x: screen.maxX - 320, y: screen.maxY - size.height, width: size.width, height: size.height)
        let window = NSPanel(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        window.level = .statusBar
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = false
        window.hidesOnDeactivate = false
        window.isReleasedWhenClosed = false
        window.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
        window.title = "Mark"
        let button = NSStatusBarButton(frame: NSRect(origin: .zero, size: size))
        button.isBordered = false
        button.imagePosition = .imageOnly
        button.autoresizingMask = [.width, .height]
        window.contentView = button
        orderIn(window)
        return button
    }
}
