import AppKit
import SwiftUI

/// The mind this Mac is lent to, at the top of the panel: its avatar with the lend's dot, its name,
/// its address and this Mac's name there. A click opens the list of the minds under it (the active
/// one has a check mark), then Add a Mind and Remove a Mind. A click on another mind lends this
/// Mac to it (`LendActions.use`).
struct MindSwitcher: View {
    let lend: LendView
    @Binding var isOpen: Bool
    let actions: LendActions
    /// The lend's phase as a colour: the dot on the active mind's avatar.
    let dot: Color

    private static let avatar: CGFloat = 32
    private static let rowAvatar: CGFloat = 24

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            trigger
            if isOpen {
                list.transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .animation(.easeOut(duration: 0.15), value: isOpen)
    }

    private var active: LendView.Mind? { lend.minds.first { $0.mind == lend.active } }

    private var trigger: some View {
        Button {
            isOpen.toggle()
        } label: {
            HStack(spacing: 10) {
                if let active {
                    MindLabel(mind: active.mind, size: Self.avatar, note: "itx.\(active.name)", badge: dot)
                } else {
                    Circle()
                        .strokeBorder(Color.secondary.opacity(0.6), style: StrokeStyle(lineWidth: 1.2, dash: [3, 3]))
                        .frame(width: Self.avatar, height: Self.avatar)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(lend.minds.isEmpty ? "No mind yet" : "Lent to no mind")
                            .font(.system(size: 13, weight: .semibold))
                        Text(lend.minds.isEmpty ? "Add a mind to lend this Mac to" : "Choose the mind to lend this Mac to")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer(minLength: 8)
                Image(systemName: "chevron.up.chevron.down")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
            }
        }
        .buttonStyle(SwitcherRowStyle(isSelected: isOpen))
        .help("The mind this Mac is lent to: one at a time")
    }

    private var list: some View {
        VStack(alignment: .leading, spacing: 1) {
            if !lend.minds.isEmpty {
                Text("MINDS")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 8)
                    .padding(.top, 3)
                    .padding(.bottom, 3)
                ForEach(lend.minds) { mind in
                    Button {
                        isOpen = false
                        if mind.mind != lend.active { actions.use(mind.mind) }
                    } label: {
                        HStack(spacing: 8) {
                            MindLabel(mind: mind.mind, size: Self.rowAvatar, note: "itx.\(mind.name)")
                            Spacer(minLength: 8)
                            Image(systemName: "checkmark")
                                .font(.system(size: 12, weight: .semibold))
                                .opacity(mind.mind == lend.active ? 1 : 0)
                        }
                    }
                    .buttonStyle(SwitcherRowStyle())
                    .disabled(lend.isCommandRunning)
                }
                Divider().padding(.vertical, 4).padding(.horizontal, 4)
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
        }
        .padding(4)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color(nsColor: .controlBackgroundColor))
                .shadow(color: .black.opacity(0.12), radius: 6, y: 2)
        )
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Color.primary.opacity(0.1)))
    }

    /// An action of the list: its sign in a square of the avatars' size, and its words.
    private func actionLabel(_ title: String, systemImage: String) -> some View {
        HStack(spacing: 8) {
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.18))
                .frame(width: Self.rowAvatar, height: Self.rowAvatar)
                .overlay(Image(systemName: systemImage).font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary))
            Text(title).font(.system(size: 13))
            Spacer(minLength: 0)
        }
    }
}

/// A row of the switcher: the whole row takes the click, and is tinted under the pointer, while
/// pressed and while `isSelected`.
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
                .padding(.horizontal, 8)
                .padding(.vertical, 5)
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
                .background(
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(Color.primary.opacity(configuration.isPressed ? 0.12 : (isHovered && isEnabled) || isSelected ? 0.07 : 0))
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
                let view = MindSwitcher(lend: lend, isOpen: .constant(isOpen), actions: LendActions(), dot: .green)
                    .frame(width: 398)
                    .padding(16)
                    .background(Color(nsColor: .windowBackgroundColor))
                drawn = Rendering.png(of: view, dark: dark, to: folder.appendingPathComponent("switcher-\(open)-\(tone).png")) && drawn
            }
        }
        return drawn
    }
}
