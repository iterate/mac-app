import AppKit
import SwiftUI

// THE PANEL'S PARTS, drawn as the design's mocks draw them (design/html), in the colours of
// `Theme`: a section's title, a card, Off / Ask / Shared, the tiles, the buttons.

/// A section's title in small capitals, and what goes at its right.
struct SectionTitle<Trailing: View>: View {
    let title: String
    @ViewBuilder var trailing: Trailing

    var body: some View {
        HStack(alignment: .center, spacing: 8) {
            Text(title.uppercased())
                .sectionTitle()
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

/// What goes at the right of a section's title: 11 pt in the third text colour.
struct TitleNote: View {
    let words: String

    init(_ words: String) { self.words = words }

    var body: some View {
        Text(words).font(.system(size: 11)).foregroundStyle(Theme.t3).lineLimit(1)
    }
}

/// A button at the right of a section's title, as "Set all" and "All": 12 pt, the second text
/// colour, and a small chevron.
struct TitleLink: View {
    let title: String
    var chevron = "chevron.right"

    var body: some View {
        HStack(spacing: 3) {
            Text(title).font(.system(size: 12))
            Image(systemName: chevron).font(.system(size: 9, weight: .semibold))
        }
        .foregroundStyle(Theme.t2)
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
            .background(Theme.raised, in: RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous).strokeBorder(Theme.cardEdge))
    }
}

/// A hairline between the groups of a card: 1 point, 8 points in from each side.
struct CardDivider: View {
    var body: some View {
        Theme.line.frame(height: 1).padding(.horizontal, 8).padding(.vertical, 3)
    }
}

/// A hairline across the panel.
struct PanelDivider: View {
    var body: some View {
        Theme.line.frame(height: 1)
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
    /// A segment's width: 50 points in the panel, 48 in the Activity window: "Shared" in semibold is
    /// about 42 points, and needs air on both sides.
    var segmentWidth = Theme.Metric.segment.width

    var body: some View {
        HStack(spacing: 2) {
            ForEach(Sharing.allCases) { choice in
                let isSelected = choice == selection
                Button {
                    if !isSelected { choose(choice) }
                } label: {
                    Text(choice.title)
                        .font(.system(size: Theme.Size.control, weight: weight(choice, isSelected)))
                        .foregroundStyle(textColor(choice, isSelected))
                        .frame(width: segmentWidth, height: Theme.Metric.segment.height)
                        .background {
                            let shape = RoundedRectangle(cornerRadius: Theme.Radius.segment, style: .continuous)
                            shape.fill(fill(choice, isSelected))
                                .overlay(shape.strokeBorder(isSelected && choice == .off ? Theme.knobRing : .clear, lineWidth: 0.5))
                                .shadow(color: isSelected && choice == .off ? Theme.knobShadow : .clear, radius: 1, y: 1)
                        }
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(choice.title)
                .accessibilityAddTraits(isSelected ? .isSelected : [])
            }
        }
        .padding(2)
        .background(Theme.track, in: RoundedRectangle(cornerRadius: Theme.Radius.segmentTrack, style: .continuous))
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
        guard isSelected else { return Theme.segIdle }
        switch choice {
        case .off: return Theme.knobText
        case .ask: return Theme.accentTintText
        case .shared: return Theme.onAccent
        }
    }

    private func fill(_ choice: Sharing, _ isSelected: Bool) -> Color {
        guard isSelected else { return .clear }
        switch choice {
        case .off: return Theme.knob
        case .ask: return Theme.accentTint
        case .shared: return Theme.accent
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
            let shape = RoundedRectangle(cornerRadius: Theme.Radius.actionButton, style: .continuous)
            configuration.label
                .foregroundStyle(foreground)
                .frame(maxWidth: .infinity, minHeight: Theme.Metric.actionButtonHeight, maxHeight: Theme.Metric.actionButtonHeight)
                .background(background, in: shape)
                .overlay(shape.strokeBorder(edge))
                .overlay(shape.fill(Theme.t1.opacity(configuration.isPressed ? 0.08 : 0)))
                .contentShape(shape)
                .opacity(isEnabled ? 1 : 0.45)
        }

        private var foreground: Color {
            switch tint {
            case .on: return Theme.liveText
            case .held: return Theme.warnText
            case nil: return Theme.t1
            }
        }

        private var background: Color {
            switch tint {
            case .on: return Theme.liveWash
            case .held: return Theme.warnWash
            case nil: return Theme.btn
            }
        }

        private var edge: Color {
            switch tint {
            case .on: return Theme.liveEdge
            case .held: return Theme.warnEdge
            case nil: return .clear
            }
        }
    }
}

/// A small button with a rounded fill: Reconnect Now, Copy Command, Allow…, End. A prominent one
/// is filled with the text colour (`Theme.primary`), as the mocks' Accept and End.
struct FillButtonStyle: ButtonStyle {
    var prominent = false
    var height: CGFloat = 26
    var fontSize: CGFloat = 12
    var padding: CGFloat = 11
    /// Semibold for a prominent button, medium for another, unless given.
    var weight: Font.Weight?

    func makeBody(configuration: Configuration) -> some View {
        Look(configuration: configuration, style: self)
    }

    private struct Look: View {
        let configuration: Configuration
        let style: FillButtonStyle
        @Environment(\.isEnabled) private var isEnabled

        var body: some View {
            let shape = RoundedRectangle(cornerRadius: Theme.Radius.button, style: .continuous)
            configuration.label
                .font(.system(size: style.fontSize, weight: style.weight ?? (style.prominent ? .semibold : .medium)))
                .lineLimit(1)
                .foregroundStyle(style.prominent ? Theme.onPrimary : Theme.t1)
                .padding(.horizontal, style.padding)
                .frame(height: style.height)
                .background(style.prominent ? Theme.primary : Theme.btn, in: shape)
                .overlay(shape.fill(Theme.t1.opacity(configuration.isPressed ? 0.1 : 0)))
                .contentShape(shape)
                .opacity(isEnabled ? 1 : 0.45)
        }
    }
}

/// A plain button in the second text colour, with a fill under the pointer: the footer's Settings
/// and Quit.
struct QuietButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        Look(configuration: configuration)
    }

    private struct Look: View {
        let configuration: Configuration
        @State private var isHovered = false

        var body: some View {
            configuration.label
                .font(.system(size: 12))
                .foregroundStyle(Theme.t2)
                .padding(.horizontal, 7)
                .frame(height: 26)
                .background(
                    Theme.t1.opacity(configuration.isPressed ? 0.12 : isHovered ? 0.06 : 0),
                    in: RoundedRectangle(cornerRadius: 6, style: .continuous)
                )
                .contentShape(Rectangle())
                .onHover { isHovered = $0 }
        }
    }
}

/// A missing permission of macOS, in orange, with the button that starts its guide.
struct MissingPermission: View {
    let words: String
    let allow: () -> Void

    var body: some View {
        HStack(alignment: .center, spacing: 6) {
            Image(systemName: "exclamationmark.triangle.fill").font(.system(size: 11))
            Text(words).font(.system(size: 11)).fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 6)
            Button("Allow…", action: allow).buttonStyle(FillButtonStyle(height: 22, padding: 9))
        }
        .foregroundStyle(Theme.warnText)
    }
}

/// The panel's switch: a Toggle in the mocks' switch style.
struct PanelSwitch: View {
    let title: String
    @Binding var isOn: Bool

    var body: some View {
        Toggle(title, isOn: $isOn)
            .toggleStyle(ThemeSwitchStyle())
            .labelsHidden()
    }
}

/// A Toggle drawn as the mocks' switch: 34 × 20 points, the accent when on (`toggleOff` when
/// off), a white knob of 16 points with its shadow. A native switch draws grey while its window is
/// not the key window, as a menu-bar app's often is; the mocks' is always in the accent.
struct ThemeSwitchStyle: ToggleStyle {
    func makeBody(configuration: Configuration) -> some View {
        Look(configuration: configuration)
    }

    private struct Look: View {
        let configuration: Configuration
        @Environment(\.isEnabled) private var isEnabled

        var body: some View {
            Button {
                withAnimation(.easeOut(duration: 0.15)) { configuration.isOn.toggle() }
            } label: {
                Capsule()
                    .fill(configuration.isOn ? Theme.accent : Theme.toggleOff)
                    .frame(width: 34, height: 20)
                    .overlay(alignment: configuration.isOn ? .trailing : .leading) {
                        Circle().fill(Theme.switchKnob).frame(width: 16, height: 16).shadow(color: Theme.switchKnobShadow, radius: 1, y: 1).padding(2)
                    }
                    .contentShape(Capsule())
            }
            .buttonStyle(.plain)
            .opacity(isEnabled ? 1 : 0.45)
            .accessibilityValue(configuration.isOn ? "1" : "0")
            .accessibilityAddTraits(.isToggle)
        }
    }
}
