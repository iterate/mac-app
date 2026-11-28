import AppKit
import SwiftUI

/// THE PILL: one window at the bottom of the display, for a dictation and for a capture alike. A
/// dictation that becomes a capture (README, "Dictation becomes a capture") changes the pill's
/// content in place; it is never two windows.
///
/// One owner draws in it at a time. A capture's pill takes clicks (Discard, Send) and is in no
/// screen picture, no movie and no share of the screen; a dictation's takes no click, so the app
/// in front keeps them. A newer owner covers the one before, which comes back when the newer one
/// hides (a dictation during a capture started by ⌥⇧S).
@MainActor
final class Pill {
    static let shared = Pill()

    enum Owner: String {
        case dictation, capture
    }

    static let height: CGFloat = 38
    /// A capsule, as a rounded rectangle of half the height: a `Capsule` drew a hairline beside its ends.
    static let shape = RoundedRectangle(cornerRadius: height / 2, style: .circular)
    /// From the bottom of the display's visible frame (above the Dock).
    static let bottom: CGFloat = 90

    private struct Shown {
        let owner: Owner
        let view: AnyView
        var width: CGFloat
        let screen: NSScreen?
        let takesClicks: Bool
        /// It comes back when a newer owner hides; not after `handOver`.
        var comesBack = true
    }

    private var panel: NSPanel?
    private var shown: Shown?
    /// The owner a newer one covers.
    private var covered: Shown?

    /// Whether `owner` draws in the pill and it is on the screen.
    func isShown(_ owner: Owner) -> Bool { shown?.owner == owner && panel?.isVisible == true }

    /// Whether the pill shows in pictures, movies and shares of the screen now.
    var isShared: Bool { panel.map { $0.sharingType != .none } ?? true }

    /// `owner` draws `view` in the pill, `width` points wide, at the bottom of `screen` (the
    /// display under the pointer when nil). The content is set again only when the owner changes.
    func show(_ owner: Owner, width: CGFloat, on screen: NSScreen? = nil, takesClicks: Bool, view: @autoclosure () -> some View) {
        if let shown, shown.owner != owner, shown.comesBack, panel?.isVisible == true, covered?.owner != owner { covered = shown }
        if shown?.owner != owner || panel?.isVisible != true {
            shown = Shown(owner: owner, view: AnyView(view()), width: width, screen: screen ?? Self.screenUnderPointer, takesClicks: takesClicks)
            put(content: true)
        } else if shown?.width != width {
            shown?.width = width
            put(content: false)
        } else {
            put(content: false)
        }
    }

    /// `owner` stays in sight until the next owner draws, which takes the pill for good: a dictation
    /// that becomes a capture. It goes by itself after `seconds` if nobody draws.
    func handOver(_ owner: Owner, orHideAfter seconds: Double) {
        if covered?.owner == owner { covered = nil }
        guard shown?.owner == owner else { return }
        shown?.comesBack = false
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds) { [weak self] in self?.hide(owner) }
    }

    /// `owner` is done: the pill goes, or shows the owner it covered.
    func hide(_ owner: Owner) {
        if covered?.owner == owner { covered = nil }
        guard shown?.owner == owner else { return }
        if let covered {
            self.covered = nil
            shown = covered
            return put(content: true)
        }
        shown = nil
        panel?.orderOut(nil)
    }

    private func put(content: Bool) {
        guard let shown else { return }
        let panel = self.panel ?? makePanel()
        if content {
            let host = NSHostingView(rootView: shown.view.frame(maxWidth: .infinity, maxHeight: .infinity))
            // one size for every state: a new word lays out the pill, never the window
            host.sizingOptions = []
            host.autoresizingMask = [.width, .height]
            panel.contentView = host
            panel.ignoresMouseEvents = !shown.takesClicks
            // a capture's pill is in no picture or movie of the screen: its ink is
            panel.sharingType = shown.owner == .capture ? .none : .readOnly
        }
        let visible = (shown.screen ?? NSScreen.main)?.visibleFrame ?? NSRect(x: 0, y: 0, width: 800, height: 600)
        panel.setFrame(NSRect(x: visible.midX - shown.width / 2, y: visible.minY + Self.bottom, width: shown.width, height: Self.height), display: true)
        OffScreen.orderFront(panel) { panel.orderFrontRegardless() }
    }

    private static var screenUnderPointer: NSScreen? {
        let pointer = NSEvent.mouseLocation
        return NSScreen.screens.first { NSMouseInRect(pointer, $0.frame, false) } ?? NSScreen.main
    }

    private func makePanel() -> NSPanel {
        let panel = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        // over the capture's ink
        panel.level = NSWindow.Level(rawValue: NSWindow.Level.statusBar.rawValue + 1)
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        self.panel = panel
        return panel
    }
}
