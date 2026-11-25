import AppKit
import SwiftUI

/// THE APP'S LOOK, from the design's tokens (`design/tokens.json`): every colour in its dark and
/// its light value, the type sizes, the radii and the sizes. A view takes its colours from here and
/// from nowhere else.
///
/// What each colour means (design/HANDOFF.md, section 1):
///
/// - ok (green): the lend is live;
/// - warn (orange): something waits or is held up (connecting, not yet in the mind, a permission);
/// - live (red): a mind uses this Mac now, or the Mac records or is watched; a lend that stopped;
/// - the accent: how far a thing is opened to a mind, and nothing else;
/// - neutral (`btn`, `t1`…`t3`): what the person does.
///
/// Each colour is made once, as a dynamic colour that the appearance resolves when it draws
/// (`NSColor(name:dynamicProvider:)`): no view computes one in its body, and light and dark follow
/// the system.
enum Theme {
    // MARK: Grounds

    /// The panel's, a pill's and a sheet's ground.
    static let surface = pair(dark: hex(0x1F2023), light: hex(0xF4F4F5))
    /// A card on the surface.
    static let raised = pair(dark: white(0.05), light: hex(0xFFFFFF))
    static let cardEdge = pair(dark: .clear, light: black(0.07))
    /// A hairline between parts.
    static let line = pair(dark: white(0.10), light: black(0.09))
    /// The edge of a panel, a pill or a window.
    static let edge = pair(dark: white(0.14), light: black(0.14))
    /// A window's ground (Settings, the Activity window) and its sidebar's.
    static let win = pair(dark: hex(0x232427), light: hex(0xF4F4F5))
    static let side = pair(dark: hex(0x1B1C1F), light: hex(0xE9E9EB))
    static let titlebar = pair(dark: hex(0x2C2D31), light: hex(0xE8E8EA))
    /// A text field's ground, and a block of monospace's.
    static let field = pair(dark: hex(0x17181A), light: hex(0xFFFFFF))
    static let code = pair(dark: hex(0x141517), light: hex(0xECEDEF))
    /// The selected row of a list, and a neutral block.
    static let sel = pair(dark: white(0.08), light: black(0.06))
    static let block = pair(dark: white(0.08), light: black(0.07))

    // MARK: Text

    /// Text: the first is the name of a thing, the second its line, the third what is said aside.
    static let t1 = pair(dark: hex(0xF2F2F3), light: hex(0x1B1C1F))
    static let t2 = pair(dark: hex(0xB4B6BC), light: hex(0x50535A))
    static let t3 = pair(dark: hex(0x9A9CA3), light: hex(0x666970))

    // MARK: The accent: how far a thing is opened

    static let accent = pair(dark: hex(0x2F6FE0), light: hex(0x1F5FD0))
    static let onAccent = pair(dark: hex(0xFFFFFF), light: hex(0xFFFFFF))
    static let accentText = pair(dark: hex(0x8FB8FF), light: hex(0x1A4FB0))
    /// The Ask segment's fill and its text.
    static let accentTint = pair(dark: rgba(47, 111, 224, 0.32), light: rgba(31, 95, 208, 0.15))
    static let accentTintText = pair(dark: hex(0xD3E2FF), light: hex(0x17479E))
    static let accentWash = pair(dark: rgba(47, 111, 224, 0.18), light: rgba(31, 95, 208, 0.08))
    static let accentEdge = pair(dark: rgba(120, 165, 255, 0.50), light: rgba(31, 95, 208, 0.40))

    // MARK: Warn: waits or is held up

    static let warn = pair(dark: hex(0xFFA53D), light: hex(0xF0921E))
    static let onWarn = pair(dark: hex(0x241300), light: hex(0x241300))
    static let warnText = pair(dark: hex(0xFFB45C), light: hex(0x8A4B00))
    static let warnWash = pair(dark: rgba(255, 165, 61, 0.13), light: rgba(240, 146, 30, 0.16))
    static let warnEdge = pair(dark: rgba(255, 165, 61, 0.50), light: rgba(190, 110, 10, 0.55))

    // MARK: Ok: the lend is live

    static let ok = pair(dark: hex(0x34C759), light: hex(0x1E9E48))
    static let okText = pair(dark: hex(0x72E08F), light: hex(0x14713A))
    /// A sign on the green: a call's icon (the mocks' value; tokens.json has no name for it).
    static let onOk = pair(dark: hex(0x06250F), light: hex(0xFFFFFF))

    // MARK: Live: a mind uses the Mac now, it records or is watched, a lend stopped

    static let live = pair(dark: hex(0xFF5A52), light: hex(0xD93A32))
    static let liveText = pair(dark: hex(0xFFB9B4), light: hex(0xB3261E))
    static let liveWash = pair(dark: rgba(255, 90, 82, 0.15), light: rgba(217, 58, 50, 0.09))
    static let liveEdge = pair(dark: rgba(255, 90, 82, 0.50), light: rgba(217, 58, 50, 0.45))
    static let onLive = pair(dark: hex(0x2A0907), light: hex(0xFFFFFF))

    // MARK: Controls

    /// A prominent button: the text colour as its fill.
    static let primary = pair(dark: hex(0xF2F2F3), light: hex(0x1B1C1F))
    static let onPrimary = pair(dark: hex(0x1B1C1F), light: hex(0xFFFFFF))
    /// A neutral button's fill, and its edge.
    static let btn = pair(dark: white(0.10), light: black(0.065))
    static let btnEdge = Color.clear
    /// The Off / Ask / Shared track, its selected Off knob, and the words of a segment.
    static let track = pair(dark: white(0.07), light: black(0.065))
    static let knob = pair(dark: white(0.16), light: hex(0xFFFFFF))
    static let knobText = pair(dark: hex(0xE2E3E6), light: hex(0x2E3035))
    /// The light knob's ring and its shadow (`0 0 0 0.5px …, 0 1px 2px …`); none in the dark.
    static let knobRing = pair(dark: .clear, light: black(0.10))
    static let knobShadow = pair(dark: .clear, light: black(0.14))
    static let segIdle = pair(dark: hex(0xAEB0B6), light: hex(0x50535A))
    /// A switch that is off, and a switch's knob and its shadow (`0 1px 2px rgba(0,0,0,0.3)`).
    static let toggleOff = pair(dark: white(0.20), light: black(0.20))
    static let switchKnob = pair(dark: hex(0xFFFFFF), light: hex(0xFFFFFF))
    static let switchKnobShadow = pair(dark: black(0.30), light: black(0.30))

    // MARK: Shadows

    /// A panel's and a window's shadow (`0 18px 50px`), and a pill's (`0 6px 20px`).
    static let shadow = pair(dark: black(0.45), light: black(0.20))
    static let shadowSmall = pair(dark: black(0.40), light: black(0.16))

    // MARK: Type, in points

    enum Size {
        static let sectionTitle: CGFloat = 11
        /// 0.06 em of the section title.
        static let sectionTracking: CGFloat = 0.66
        static let caption: CGFloat = 11
        /// The record switches' names: the mock's 11 pt Inter is as wide as 10 pt SF.
        static let recordChipLabel: CGFloat = 10
        static let control: CGFloat = 12
        static let row: CGFloat = 13
        static let panelTitle: CGFloat = 15
        static let pillText: CGFloat = 13
        static let inputText: CGFloat = 18
        static let settingsGroupTitle: CGFloat = 13
    }

    // MARK: Radii, in points

    enum Radius {
        static let panel: CGFloat = 14
        static let card: CGFloat = 10
        static let actionButton: CGFloat = 9
        static let segmentTrack: CGFloat = 7
        static let segment: CGFloat = 5
        static let button: CGFloat = 7
        static let pill: CGFloat = 19
        static let window: CGFloat = 12
        static let thumbnail: CGFloat = 4
    }

    // MARK: Sizes, in points

    enum Metric {
        static let panelWidth: CGFloat = 400
        static let rowHeight: CGFloat = 28
        static let rowHeightWithNote: CGFloat = 40
        static let leadColumn: CGFloat = 30
        static let segment = CGSize(width: 46, height: 20)
        static let actionButtonHeight: CGFloat = 46
        static let recordChipHeight: CGFloat = 46
        /// The record's five switches: one row of equal columns, 6 apart; the icon in a 15 pt
        /// square, 3 over the name; the name at least 6 in from the tile's edge.
        static let recordChipGap: CGFloat = 6
        static let recordChipIcon: CGFloat = 15
        static let recordChipIconGap: CGFloat = 3
        static let recordChipInset: CGFloat = 6
        static let faceInHeader: CGFloat = 34
        static let thumbnail = CGSize(width: 30, height: 19)
        static let dictationPill = CGSize(width: 460, height: 38)
        static let settingsWindowWidth: CGFloat = 800
        static let settingsSidebarWidth: CGFloat = 212
    }

    // MARK: - Making the colours

    /// One colour for the dark appearance and one for the light.
    private static func pair(dark: NSColor, light: NSColor) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? dark : light
        })
    }

    private static func hex(_ value: UInt32) -> NSColor {
        NSColor(
            srgbRed: CGFloat((value >> 16) & 0xFF) / 255, green: CGFloat((value >> 8) & 0xFF) / 255, blue: CGFloat(value & 0xFF) / 255,
            alpha: 1)
    }

    private static func rgba(_ red: CGFloat, _ green: CGFloat, _ blue: CGFloat, _ alpha: CGFloat) -> NSColor {
        NSColor(srgbRed: red / 255, green: green / 255, blue: blue / 255, alpha: alpha)
    }

    private static func white(_ alpha: CGFloat) -> NSColor { NSColor(srgbRed: 1, green: 1, blue: 1, alpha: alpha) }
    private static func black(_ alpha: CGFloat) -> NSColor { NSColor(srgbRed: 0, green: 0, blue: 0, alpha: alpha) }
}

/// The section's title in small capitals: 11 pt semibold, 0.06 em apart, the third text colour.
extension Text {
    func sectionTitle() -> some View {
        self.font(.system(size: Theme.Size.sectionTitle, weight: .semibold))
            .tracking(Theme.Size.sectionTracking)
            .foregroundStyle(Theme.t3)
    }
}

/// THE MOCKS' LINE HEIGHT. The mocks set a line `line-height` × the font's size tall (1.3 for most
/// text, 1.4 for a row's line, 1.45 for a paragraph); SwiftUI sets SF's own height (about 1.2).
/// The difference goes between the lines and half above and half under the text, as CSS does.
extension View {
    func lineHeight(_ factor: CGFloat, size: CGFloat) -> some View {
        let extra = max(0, (size * factor - Theme.naturalLineHeight(size)).rounded(toHalf: true))
        return self.lineSpacing(extra).padding(.vertical, extra / 2)
    }
}

extension Theme {
    /// The height of one line of the system font at `size`, as a `Text` lays it out: whole points,
    /// measured (macOS 15), since it follows neither `NSFont`'s metrics nor `NSLayoutManager`'s.
    static func naturalLineHeight(_ size: CGFloat) -> CGFloat {
        let measured: [CGFloat: CGFloat] = [10: 13, 10.5: 13, 11: 14, 11.5: 14, 12: 15, 12.5: 15, 13: 16, 14: 17, 15: 19, 16: 19, 17: 20, 18: 21]
        return measured[size] ?? NSLayoutManager().defaultLineHeight(for: .systemFont(ofSize: size)) + 1
    }
}

extension CGFloat {
    /// Rounded to the nearest half point (a pixel of a Retina screen) when `toHalf`.
    fileprivate func rounded(toHalf: Bool) -> CGFloat { toHalf ? (self * 2).rounded() / 2 : rounded() }
}
