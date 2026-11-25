import AppKit
import SwiftUI

/// THE ASK QUESTION ON THE SCREEN: a floating panel of the app (`Approval`), in the middle of the
/// screen with the pointer, over every window and on the active space. It takes the keys without
/// making the app the active one (a non-activating panel), so the app in front stays in front:
/// Return approves once, Esc denies. Its buttons, top to bottom: Approve Once, Approve for N
/// Minutes, Deny. The seconds left tick in one line of text; the panel's size is set once.
@MainActor
final class ApprovalWindow {
    private var panel: NSPanel?
    private let answer: (Bool, Bool) -> Void

    init(answer: @escaping (_ allow: Bool, _ keep: Bool) -> Void) {
        self.answer = answer
    }

    func show(_ question: Approval.Question) {
        let panel = self.panel ?? makePanel()
        self.panel = panel
        // a view made with its question knows its size at once; the panel's size is set here, not
        // at each tick of the seconds
        let view = NSHostingView(rootView: ApprovalView(question: question, answer: answer))
        let size = view.fittingSize
        // measured: from now the view does not size its window
        view.sizingOptions = []
        panel.contentView = view
        let screen = NSScreen.screens.first { NSMouseInRect(NSEvent.mouseLocation, $0.frame, false) } ?? NSScreen.main
        let visible = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        // a little above the middle, where an alert of macOS comes
        let origin = NSPoint(x: visible.midX - size.width / 2, y: visible.minY + visible.height * 0.62 - size.height / 2)
        panel.setFrame(NSRect(origin: origin, size: size), display: true)
        // over every window, and the keys go to it, while the app in front stays the active one
        panel.orderFrontRegardless()
        panel.makeKey()
    }

    func close() {
        panel?.orderOut(nil)
        // the view goes with the question: its timeline stops
        panel?.contentView = nil
    }

    private func makePanel() -> NSPanel {
        let panel = KeyPanel(
            contentRect: NSRect(x: 0, y: 0, width: ApprovalView.width, height: 300), styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered, defer: false)
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.becomesKeyOnlyIfNeeded = false
        panel.title = "Ask"
        return panel
    }

    /// A borderless panel takes no keys unless it says it can.
    private final class KeyPanel: NSPanel {
        override var canBecomeKey: Bool { true }
        override var canBecomeMain: Bool { false }
    }
}

/// The question: the mind's face and address, what it wants, what exactly in monospace, why it is
/// asked, the three answers, and the seconds left.
struct ApprovalView: View {
    static let width: CGFloat = 380
    let question: Approval.Question
    let answer: (Bool, Bool) -> Void
    /// A drawing's clock: the seconds left at that time, with no timeline.
    var now: Date?
    @ObservedObject private var faces = MindFaces.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                if let mind = question.mind {
                    MindAvatar(mind: mind, size: 40)
                } else {
                    Image(systemName: "questionmark.circle").font(.system(size: 34, weight: .light)).foregroundStyle(Theme.t3).frame(width: 40, height: 40)
                }
                VStack(alignment: .leading, spacing: 1) {
                    Text("\(question.mind.map { faces.face(of: $0).title } ?? "Your mind") wants to \(question.does)")
                        .font(.system(size: Theme.Size.panelTitle, weight: .semibold))
                        .lineHeight(1.25, size: Theme.Size.panelTitle)
                        .foregroundStyle(Theme.t1)
                        .fixedSize(horizontal: false, vertical: true)
                    Text(subtitle).font(.system(size: 12)).lineHeight(1.3, size: 12).foregroundStyle(Theme.t2).lineLimit(1).truncationMode(.middle)
                }
            }
            if let detail = question.detail {
                Text(detail)
                    .font(.system(size: 12, design: .monospaced))
                    // the mock sets 7 points to a character, SF Mono 7.2: a command of 45 fits one line
                    .tracking(-0.2)
                    .lineHeight(1.5, size: 12)
                    .foregroundStyle(Theme.t1)
                    .lineLimit(8)
                    .truncationMode(.tail)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Theme.code, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(Theme.line))
            }
            Text(question.note)
                .font(.system(size: 12))
                .lineHeight(1.45, size: 12)
                .foregroundStyle(Theme.t2)
                .fixedSize(horizontal: false, vertical: true)
            VStack(spacing: 6) {
                Button {
                    answer(true, false)
                } label: {
                    HStack(spacing: 6) {
                        if !question.byControl { Image(systemName: "touchid").font(.system(size: 14, weight: .light)) }
                        Text("Approve Once")
                    }
                }
                .buttonStyle(AnswerStyle(prominent: true))
                .keyboardShortcut(.defaultAction)
                .accessibilityLabel("Approve Once")
                .accessibilityIdentifier("approval.once")
                Button("Approve for \(question.keepWords)") { answer(true, true) }
                    .buttonStyle(AnswerStyle(prominent: false))
                    .accessibilityIdentifier("approval.minutes")
                Button {
                    answer(false, false)
                } label: {
                    HStack(spacing: 6) {
                        Text("Deny")
                        Text("esc").font(.system(size: 11, weight: .regular))
                    }
                }
                .buttonStyle(AnswerStyle(prominent: false))
                .keyboardShortcut(.cancelAction)
                .accessibilityLabel("Deny")
                .accessibilityIdentifier("approval.deny")
            }
            HStack(spacing: 7) {
                Image(systemName: "clock").font(.system(size: 12, weight: .light))
                if let now {
                    Text(left(at: now))
                } else {
                    // the one view that changes each second: the panel keeps its size
                    TimelineView(.periodic(from: question.askedAt, by: 1)) { context in Text(left(at: context.date)) }
                }
            }
            .font(.system(size: 11).monospacedDigit())
            .foregroundStyle(Theme.t3)
            .lineLimit(1)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        // the mock's padding (18, 18, 14) inside its edge of 1 point
        .padding(.horizontal, 19)
        .padding(.top, 19)
        .padding(.bottom, 15)
        .frame(width: Self.width)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(Theme.edge))
    }

    private var subtitle: String {
        guard let mind = question.mind else { return "This Mac is lent to no mind now" }
        return [mind, question.name.map { "itx.\($0)" }].compactMap { $0 }.joined(separator: " · ")
    }

    private func left(at date: Date) -> String {
        let seconds = max(0, Int(question.deadline.timeIntervalSince(date).rounded(.up)))
        let confirm = question.byControl ? "A test copy: no Touch ID is asked." : "Touch ID confirms an approval."
        return "No answer in \(seconds) s refuses it. \(confirm)"
    }

    /// The answers' buttons, 32 points high and the panel's width: the first one prominent and
    /// neutral (the text colour as its fill), the others a neutral fill.
    private struct AnswerStyle: ButtonStyle {
        let prominent: Bool

        func makeBody(configuration: Configuration) -> some View {
            let shape = RoundedRectangle(cornerRadius: Theme.Radius.button, style: .continuous)
            configuration.label
                .font(.system(size: 13, weight: prominent ? .semibold : .medium))
                .foregroundStyle(prominent ? Theme.onPrimary : Theme.t1)
                .frame(maxWidth: .infinity, minHeight: 32)
                .background(prominent ? Theme.primary : Theme.btn, in: shape)
                .overlay(shape.fill(Theme.t1.opacity(configuration.isPressed ? 0.12 : 0)))
                .contentShape(shape)
        }
    }
}

extension ApprovalWindow {
    /// The drawings' question: Iterate wants to run a command on Ask, 12 s after it was asked.
    static func sampleQuestion() -> Approval.Question {
        Approval.Question(
            mind: Rendering.minds[0].mind, name: Rendering.minds[0].name, does: "run commands",
            note: "Commands is set to Ask. A command runs with this app’s permissions for the screen, the camera, the microphone and Accessibility.",
            detail: "/bin/zsh -lc git -C ~/src/app status --short", keepWords: "30 Minutes",
            askedAt: Rendering.now.addingTimeInterval(-12), byControl: false)
    }

    /// The Ask question, light and dark, into `folder` (`--render-approval <folder>`).
    static func render(to folder: URL) -> Bool {
        _ = NSApplication.shared
        Rendering.fixFaces()
        var drawn = true
        for (dark, tone) in [(false, "light"), (true, "dark")] {
            // around it, the see-through panel's margin
            let view = ApprovalView(question: sampleQuestion(), answer: { _, _ in }, now: Rendering.now).padding(20)
            drawn = Rendering.png(of: view, dark: dark, to: folder.appendingPathComponent("approval-\(tone).png")) && drawn
        }
        return drawn
    }
}
