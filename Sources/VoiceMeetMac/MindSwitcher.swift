import AppKit
import SwiftUI

/// The mind this Mac is lent to, at the top of the panel: its avatar with the lend's dot, its name,
/// its address and this Mac's name there, and at the right the lend's phase in two lines. A click
/// opens the list of the minds under it (the active one has a check mark and its phase), then Add
/// a Mind and Remove a Mind, and Reconnect Now while the lend has no block of its own (live or
/// connecting). A click on another mind lends this Mac to it (`LendActions.use`).
struct MindSwitcher: View {
    let lend: LendView
    @Binding var isOpen: Bool
    let actions: LendActions
    /// The lend's phase as a colour: the dot on the active mind's avatar.
    let dot: Color
    /// The colour of the phase's name at the right.
    var phaseColor: Color = Theme.t2

    private static let avatar: CGFloat = 34
    private static let rowAvatar: CGFloat = 26

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            trigger
            if isOpen {
                list.transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .animation(.easeOut(duration: 0.15), value: isOpen)
    }

    private var active: LendView.Mind? { lend.minds.first { $0.mind == lend.active } }

    /// The whole row is the switcher's button: the face with the lend's dot, the name, the address,
    /// and at the right the phase in two lines and the chevron.
    private var trigger: some View {
        Button {
            isOpen.toggle()
        } label: {
            HStack(spacing: 11) {
                if let active {
                    MindAvatar(mind: active.mind, size: Self.avatar, badge: dot)
                    MindLines(mind: active.mind, note: "itx.\(active.name)").frame(maxWidth: .infinity, alignment: .leading)
                } else {
                    Circle()
                        .fill(Theme.btn)
                        .frame(width: Self.avatar, height: Self.avatar)
                        .overlay(Image(systemName: "plus").font(.system(size: 15, weight: .regular)).foregroundStyle(Theme.t2))
                    VStack(alignment: .leading, spacing: 1) {
                        Text(lend.minds.isEmpty ? "No mind yet" : "Lent to no mind")
                            .font(.system(size: Theme.Size.panelTitle, weight: .semibold))
                        Text(lend.minds.isEmpty ? "This Mac is lent to no mind" : "Choose the mind to lend this Mac to")
                            .font(.system(size: 12))
                            .foregroundStyle(Theme.t2)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                VStack(alignment: .trailing, spacing: 1) {
                    Text(lend.words.title)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(phaseColor)
                    Text(lend.words.detail)
                        .font(.system(size: 11).monospacedDigit())
                        .foregroundStyle(Theme.t3)
                }
                .lineLimit(1)
                .fixedSize()
                Image(systemName: "chevron.up.chevron.down")
                    .font(.system(size: 11, weight: .regular))
                    .foregroundStyle(Theme.t3)
                    .frame(width: 14)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
        }
        .buttonStyle(SwitcherHeadStyle(isSelected: isOpen))
        .help("The mind this Mac is lent to: one at a time")
    }

    /// Reconnect Now is the list's last entry while the lend shows no block with its own.
    private var reconnectsHere: Bool {
        active != nil && (lend.phase == "live" || lend.phase == "connecting")
    }

    private var list: some View {
        VStack(alignment: .leading, spacing: 0) {
            if !lend.minds.isEmpty {
                Text("MINDS")
                    .sectionTitle()
                    .padding(.horizontal, 8)
                    .padding(.top, 6)
                    .padding(.bottom, 4)
                ForEach(lend.minds) { mind in
                    let isActive = mind.mind == lend.active
                    Button {
                        isOpen = false
                        if !isActive { actions.use(mind.mind) }
                    } label: {
                        HStack(spacing: 10) {
                            // the state of the active mind alone: the app knows no other's (HANDOFF 8.2)
                            MindAvatar(mind: mind.mind, size: Self.rowAvatar, badge: isActive ? dot : nil)
                            MindLines(mind: mind.mind, note: "itx.\(mind.name)", titleSize: 13).frame(maxWidth: .infinity, alignment: .leading)
                            if isActive {
                                Text(lend.words.title).font(.system(size: 11)).foregroundStyle(phaseColor)
                            }
                            Image(systemName: "checkmark")
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundStyle(Theme.t1)
                                .opacity(isActive ? 1 : 0)
                        }
                    }
                    .buttonStyle(SwitcherRowStyle())
                    .disabled(lend.isCommandRunning)
                }
                Theme.line.frame(height: 1).padding(.vertical, 6).padding(.horizontal, 8)
            }
            Button {
                isOpen = false
                actions.add()
            } label: {
                actionLabel("Add a Mind…", systemImage: "plus")
            }
            .buttonStyle(SwitcherRowStyle())
            .disabled(!lend.isSetUp || lend.isCommandRunning)
            if !lend.minds.isEmpty {
                Menu {
                    ForEach(lend.minds) { mind in
                        Button("\(mind.mind)…") {
                            isOpen = false
                            actions.remove(mind.mind)
                        }
                    }
                } label: {
                    actionLabel("Remove a Mind…", systemImage: "minus")
                }
                .menuStyle(.button)
                .menuIndicator(.hidden)
                .buttonStyle(SwitcherRowStyle())
                .disabled(lend.isCommandRunning)
            }
            if reconnectsHere {
                Button {
                    isOpen = false
                    actions.reconnect()
                } label: {
                    actionLabel("Reconnect Now", systemImage: "arrow.clockwise")
                }
                .buttonStyle(SwitcherRowStyle())
                .help("Ends the connection, and starts the lend again at once")
                .accessibilityIdentifier("panel.reconnect")
            }
        }
        .padding(.horizontal, 6)
        .padding(.top, 2)
        .padding(.bottom, 8)
    }

    /// An action of the list: its sign in a square of the avatars' size, and its words.
    private func actionLabel(_ title: String, systemImage: String) -> some View {
        HStack(spacing: 10) {
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .strokeBorder(Theme.edge)
                .frame(width: Self.rowAvatar, height: Self.rowAvatar)
                .overlay(Image(systemName: systemImage).font(.system(size: 12, weight: .regular)).foregroundStyle(Theme.t2))
            Text(title).font(.system(size: 13))
            Spacer(minLength: 0)
        }
    }
}

/// The name of a mind over its address and this Mac's name there.
private struct MindLines: View {
    let mind: String
    let note: String
    /// The name's size: 15 at the head of the panel, 13 in the list.
    var titleSize: CGFloat = Theme.Size.panelTitle
    @ObservedObject private var faces = MindFaces.shared

    var body: some View {
        VStack(alignment: .leading, spacing: titleSize > 13 ? 1 : 0) {
            Text(faces.face(of: mind).title)
                .font(.system(size: titleSize, weight: .semibold))
                .lineLimit(1)
            Text("\(mind) · \(note)")
                .font(.system(size: titleSize > 13 ? 12 : 11))
                .foregroundStyle(Theme.t2)
                .lineLimit(1)
                .truncationMode(.middle)
        }
    }
}

/// The head of the panel: the whole row takes the click, and is tinted (`Theme.sel`) under the
/// pointer, while pressed and while the list is open.
struct SwitcherHeadStyle: ButtonStyle {
    var isSelected = false

    func makeBody(configuration: Configuration) -> some View {
        Head(configuration: configuration, isSelected: isSelected)
    }

    private struct Head: View {
        let configuration: Configuration
        let isSelected: Bool
        @State private var isHovered = false

        var body: some View {
            configuration.label
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
                .background(isSelected || configuration.isPressed ? Theme.sel : isHovered ? Theme.t1.opacity(0.04) : .clear)
                .onHover { isHovered = $0 }
        }
    }
}

/// A row of the switcher's list: the whole row takes the click, and is tinted under the pointer,
/// while pressed and while `isSelected`.
struct SwitcherRowStyle: ButtonStyle {
    var isSelected = false

    func makeBody(configuration: Configuration) -> some View {
        Row(configuration: configuration, isSelected: isSelected)
    }

    private struct Row: View {
        let configuration: Configuration
        let isSelected: Bool
        @State private var isHovered = false
        @Environment(\.isEnabled) private var isEnabled

        var body: some View {
            configuration.label
                .foregroundStyle(Theme.t1)
                .padding(.horizontal, 8)
                .padding(.vertical, 6)
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
                .background(
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(configuration.isPressed ? Theme.t1.opacity(0.12) : (isHovered && isEnabled) || isSelected ? Theme.sel : .clear)
                )
                .opacity(isEnabled ? 1 : 0.45)
                .onHover { isHovered = $0 }
        }
    }
}

extension MindSwitcher {
    /// Draws the switcher of the drawings' minds (`Rendering`), closed and open, in the light and
    /// the dark appearance: four PNG files in `folder`, for a look with no Mac bar. The first mind
    /// has a name and an icon, the second a name alone, the last neither: its face is its letter.
    @MainActor
    static func render(to folder: URL) -> Bool {
        Rendering.fixFaces()
        let lend = Panel.sampleLend("live")
        var drawn = true
        for (isOpen, open) in [(false, "closed"), (true, "open")] {
            for (dark, tone) in [(false, "light"), (true, "dark")] {
                // as at the top of the panel: its width, ground, edge and corners
                let view = MindSwitcher(lend: lend, isOpen: .constant(isOpen), actions: LendActions(), dot: Theme.ok, phaseColor: Theme.okText)
                    .foregroundStyle(Theme.t1)
                    .padding(1)
                    .frame(width: Panel.width)
                    .background(Theme.surface, in: Panel.shape)
                    .clipShape(Panel.shape)
                    .overlay(Panel.shape.strokeBorder(Theme.edge, lineWidth: 1))
                drawn = Rendering.png(of: view, dark: dark, to: folder.appendingPathComponent("switcher-\(open)-\(tone).png")) && drawn
            }
        }
        return drawn
    }
}
