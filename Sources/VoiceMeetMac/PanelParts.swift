import AppKit
import SwiftUI

/// WHAT EACH COLOUR MEANS in the panel (design/HANDOFF.md, section 1), from the system's colours:
///
/// - green: the lend is live;
/// - orange: something waits or is held up (connecting, not yet in the mind, a permission);
/// - red: a mind uses this Mac now, or the Mac records or is watched; a lend that stopped;
/// - the accent: how far a thing is opened to a mind, and nothing else;
/// - neutral: what the person does.
///
/// Each colour is made once, as a dynamic colour that the appearance resolves when it draws: no
/// view computes one in its body.
enum Palette {
    /// A system colour, darkened in the light appearance and lightened in the dark one, to stay
    /// readable as text on the panel's ground.
    private static func text(_ base: NSColor, light: CGFloat, dark: CGFloat) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            var resolved = base
            appearance.performAsCurrentDrawingAppearance { resolved = base.usingColorSpace(.sRGB) ?? base }
            return resolved.blended(withFraction: isDark ? dark : light, of: isDark ? .white : .black) ?? resolved
        })
    }

    private static func pair(light: NSColor, dark: NSColor) -> Color {
        Color(nsColor: NSColor(name: nil) { $0.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? dark : light })
    }

    private static func tint(_ base: NSColor, light: CGFloat, dark: CGFloat) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            var resolved = base
            appearance.performAsCurrentDrawingAppearance { resolved = base.usingColorSpace(.sRGB) ?? base }
            return resolved.withAlphaComponent(isDark ? dark : light)
        })
    }

    static let liveText = text(.systemGreen, light: 0.35, dark: 0.3)
    static let waitText = text(.systemOrange, light: 0.45, dark: 0.15)
    static let redText = text(.systemRed, light: 0.2, dark: 0.45)
    static let accentText = text(.controlAccentColor, light: 0.15, dark: 0.45)
    /// The Ask segment: the accent at about 16% (light) or 30% (dark), with text that stays readable.
    static let askFill = tint(.controlAccentColor, light: 0.16, dark: 0.32)
    static let askText = text(.controlAccentColor, light: 0.3, dark: 0.7)

    static let redWash = tint(.systemRed, light: 0.09, dark: 0.15)
    static let redEdge = tint(.systemRed, light: 0.45, dark: 0.5)
    static let waitWash = tint(.systemOrange, light: 0.16, dark: 0.13)
    static let waitEdge = tint(.systemOrange, light: 0.55, dark: 0.5)

    /// A card on the panel's ground: white in light, a faint raise in dark.
    static let card = pair(light: .white, dark: NSColor(white: 1, alpha: 0.05))
    static let cardEdge = pair(light: NSColor(white: 0, alpha: 0.07), dark: .clear)
    /// The fill of a neutral button, and of a segmented control's track.
    static let fill = pair(light: NSColor(white: 0, alpha: 0.065), dark: NSColor(white: 1, alpha: 0.10))
    static let track = pair(light: NSColor(white: 0, alpha: 0.065), dark: NSColor(white: 1, alpha: 0.07))
    /// The selected Off segment: a neutral knob, as a native segmented control draws it.
    static let knob = pair(light: .white, dark: NSColor(white: 1, alpha: 0.16))
    static let knobShadow = pair(light: NSColor(white: 0, alpha: 0.14), dark: .clear)
    /// The ground of a block of monospace: what a mind asks, an event's text.
    static let codeFill = pair(light: NSColor(white: 0, alpha: 0.035), dark: NSColor(white: 0, alpha: 0.32))
}

/// A section's title in small capitals, and what goes at its right.
struct SectionTitle<Trailing: View>: View {
    let title: String
    @ViewBuilder var trailing: Trailing

    var body: some View {
        HStack(alignment: .center, spacing: 8) {
            Text(title.uppercased())
                .font(.system(size: 11, weight: .semibold))
                .tracking(0.6)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .fixedSize()
            Spacer(minLength: 8)
            trailing
        }
        .padding(.horizontal, 2)
        .frame(minHeight: 16)
    }
}

extension SectionTitle where Trailing == EmptyView {
    init(_ title: String) {
        self.init(title: title) { EmptyView() }
    }
}

/// A card: a rounded ground for rows.
struct Card<Content: View>: View {
    var padding: CGFloat = 4
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 0) { content }
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Palette.card, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Palette.cardEdge))
    }
}

/// OFF, ASK, SHARED: three buttons in one group. The fill grows with what is opened, so the safe
/// choice is the quiet one: Off a neutral knob, Ask the accent's tint, Shared the solid accent. A
/// native segmented picker cannot colour one segment. The group has the identifier
/// (`sharing.<thing>`), and each button its word, so `ui.press {"id":…,"label":"Ask"}` picks one.
struct SharingControl: View {
    let id: String
    let title: String
    let selection: Sharing
    let choose: (Sharing) -> Void
    /// The group's identifier: `sharing.<thing>` unless another view names it (the Activity window).
    var identifier: String?

    var body: some View {
        HStack(spacing: 2) {
            ForEach(Sharing.allCases) { choice in
                let isSelected = choice == selection
                Button {
                    if !isSelected { choose(choice) }
                } label: {
                    Text(choice.title)
                        .font(.system(size: 12, weight: weight(choice, isSelected)))
                        .foregroundStyle(textColor(choice, isSelected))
                        .frame(width: 46, height: 20)
                        .background(fill(choice, isSelected), in: RoundedRectangle(cornerRadius: 5, style: .continuous))
                        .shadow(color: isSelected && choice == .off ? Palette.knobShadow : .clear, radius: 1, y: 0.5)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(choice.title)
                .accessibilityAddTraits(isSelected ? .isSelected : [])
            }
        }
        .padding(2)
        .background(Palette.track, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
        .fixedSize()
        .accessibilityElement(children: .contain)
        .accessibilityLabel(title)
        .accessibilityValue(selection.title)
        .accessibilityIdentifier(identifier ?? "sharing.\(id)")
    }

    private func weight(_ choice: Sharing, _ isSelected: Bool) -> Font.Weight {
        guard isSelected else { return .regular }
        return choice == .off ? .medium : .semibold
    }

    private func textColor(_ choice: Sharing, _ isSelected: Bool) -> Color {
        guard isSelected else { return .secondary }
        switch choice {
        case .off: return .primary
        case .ask: return Palette.askText
        case .shared: return .white
        }
    }

    private func fill(_ choice: Sharing, _ isSelected: Bool) -> Color {
        guard isSelected else { return .clear }
        switch choice {
        case .off: return Palette.knob
        case .ask: return Palette.askFill
        case .shared: return .accentColor
        }
    }
}

/// A neutral tile: the three action buttons, and the record's switches.
struct TileStyle: ButtonStyle {
    /// The tile's tint: nil is neutral; red for a record switch that is on, orange for one held off.
    var tint: Tint?

    enum Tint { case on, held }

    func makeBody(configuration: Configuration) -> some View {
        Tile(configuration: configuration, tint: tint)
    }

    private struct Tile: View {
        let configuration: Configuration
        let tint: Tint?
        @Environment(\.isEnabled) private var isEnabled

        var body: some View {
            configuration.label
                .foregroundStyle(foreground)
                .frame(maxWidth: .infinity, minHeight: 46, maxHeight: 46)
                .background(background, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous).strokeBorder(edge))
                .overlay(
                    RoundedRectangle(cornerRadius: 9, style: .continuous).fill(Color.primary.opacity(configuration.isPressed ? 0.08 : 0)))
                .contentShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
                .opacity(isEnabled ? 1 : 0.45)
        }

        private var foreground: Color {
            switch tint {
            case .on: return Palette.redText
            case .held: return Palette.waitText
            case nil: return .primary
            }
        }

        private var background: Color {
            switch tint {
            case .on: return Palette.redWash
            case .held: return Palette.waitWash
            case nil: return Palette.fill
            }
        }

        private var edge: Color {
            switch tint {
            case .on: return Palette.redEdge
            case .held: return Palette.waitEdge
            case nil: return .clear
            }
        }
    }
}

/// A small neutral button with a rounded fill: Reconnect Now, Copy Command, Allow…, End.
struct FillButtonStyle: ButtonStyle {
    var prominent = false
    var height: CGFloat = 24

    func makeBody(configuration: Configuration) -> some View {
        Look(configuration: configuration, prominent: prominent, height: height)
    }

    private struct Look: View {
        let configuration: Configuration
        let prominent: Bool
        let height: CGFloat
        @Environment(\.isEnabled) private var isEnabled

        var body: some View {
            configuration.label
                .font(.system(size: 12, weight: .medium))
                .lineLimit(1)
                .foregroundStyle(prominent ? Color(nsColor: .windowBackgroundColor) : Color.primary)
                .padding(.horizontal, 10)
                .frame(height: height)
                .background(prominent ? Color.primary : Palette.fill, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 7, style: .continuous).fill(Color.primary.opacity(configuration.isPressed ? 0.1 : 0)))
                .contentShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
                .opacity(isEnabled ? 1 : 0.45)
        }
    }
}

/// A missing permission of macOS, in orange, with the button that starts its guide.
struct MissingPermission: View {
    let words: String
    let allow: () -> Void

    var body: some View {
        HStack(alignment: .center, spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill").font(.system(size: 11))
            Text(words).font(.system(size: 11)).fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 6)
            Button("Allow…", action: allow).buttonStyle(FillButtonStyle())
        }
        .foregroundStyle(Palette.waitText)
    }
}
