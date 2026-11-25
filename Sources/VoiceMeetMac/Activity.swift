import AppKit
import SwiftUI
import VoiceMeetCore

/// WHAT A MIND DID WITH THIS MAC, as the person sees it: one line for each act of a caller of the
/// local endpoint ("Ran a command", "Took a picture of the display"), with its time.
///
/// The log is a view of the device's context `/devices/<name>` in the mind of the session: each
/// act is a `device/act-started` and a `device/act-ended` there (`DeviceFact`), and the rows are
/// those events folded by act (`ActivityFold`). An act of this app shows at once, before the
/// context echoes it, and is marked as not yet in the mind until it does. Another session is
/// another context: the log starts empty and reads that context.
///
/// Each act shows twice. While it runs and for a few seconds after, a pill at the top right of the
/// screen names it, with the face of the mind the Mac is lent to. And the panel lists the last
/// acts under "Activity".
@MainActor
final class ActivityLog: ObservableObject {
    typealias Row = ActivityFold.Row

    @Published fileprivate(set) var fold = ActivityFold()
    /// The newest first, at most `ActivityFold.kept`.
    var rows: [Row] { fold.rows }
    /// The mind of the session, by its address, and the path of its device context.
    fileprivate(set) var mind: String?
    fileprivate(set) var path: String?
    /// Appends an act's event to the device's context (`DeviceEvents.publish`).
    var publish: (DeviceFact) -> Void = { _ in }

    /// The words of each act of this session that runs, for its end.
    private var running: [String: String] = [:]
    private let pill = ActivityPillWindow()
    /// The person's choice in the panel: each act shows in a pill on the screen. Off: the panel's
    /// list and the red 𝑖 in the menu bar alone.
    @Published var showsPill = AppEnvironment.current.defaults.object(forKey: "activity.pill") as? Bool ?? true {
        didSet {
            AppEnvironment.current.defaults.set(showsPill, forKey: "activity.pill")
            if !showsPill { pill.close() }
        }
    }

    /// Another session, or none: the log is of its context, empty until the context is read. An
    /// act of the old session that runs on ends nowhere.
    func use(_ session: MindSession?) {
        mind = session?.mind
        path = session?.path
        fold = ActivityFold()
        running = [:]
        pill.forget()
    }

    /// An act starts. The answer names it for `ended`.
    func began(_ thing: Shareable, doing: String, did: String, detail: String? = nil) -> String {
        let act = UUID().uuidString.lowercased()
        running[act] = did
        let fact = DeviceFact.actStarted(act: act, thing: thing.id, doing: doing, detail: detail)
        fold.take(ContextEvent(fact, at: Date()))
        publish(fact)
        if showsPill, let row = rows.first(where: { $0.act == act }) { pill.show(rows, mind: mind, newAct: row.order) }
        return act
    }

    /// The act is over, well or with a failure.
    func ended(_ act: String, failure: String? = nil) {
        guard let did = running.removeValue(forKey: act) else { return }
        let fact = DeviceFact.actEnded(act: act, did: did, failure: failure)
        fold.take(ContextEvent(fact, at: Date()))
        publish(fact)
        if showsPill { pill.show(rows, mind: mind) }
    }

    /// An event of the context, read back.
    func heard(_ event: ContextEvent) {
        fold.take(event)
    }

    func stop() {
        pill.close()
    }

    var isPillVisible: Bool { pill.isVisible }

    /// The log's header: the context it shows, on which mind, and the presence it last heard.
    var contextLine: String {
        guard let path, let mind else { return "Lent to no mind: these acts are on this Mac only" }
        return "\(path) on \(mind)" + (fold.presence.map { " · \($0.state)" } ?? "")
    }
}

/// The pill at the top right of the screen with the pointer: the acts that run, or the last one
/// for a few seconds after its end. Its × hides it until the next act begins, also while an act
/// runs on. A picture of the screen that a mind takes does not show it.
@MainActor
private final class ActivityPillWindow {
    /// How long the last act stays after its end.
    private static let lingers: TimeInterval = 4
    private var panel: NSPanel?
    private let shown = ShownActivity()
    private var hide: DispatchWorkItem?
    /// The act that was showing when the person pressed ×: the pill stays away until a newer one.
    private var dismissedUpTo = 0

    /// `newAct` is the order of an act that starts now (`ActivityFold.Row.order`).
    func show(_ rows: [ActivityLog.Row], mind: String?, newAct: Int? = nil) {
        if let newAct, newAct <= dismissedUpTo { return }
        guard newAct != nil || (rows.first?.order ?? 0) > dismissedUpTo else { return }
        let running = rows.filter(\.isRunning)
        guard let lead = running.first ?? rows.first else { return close() }
        shown.entry = lead
        shown.mind = mind
        shown.others = max(running.count - 1, 0)
        let screen = NSScreen.screens.first { $0.frame.contains(NSEvent.mouseLocation) } ?? NSScreen.main
        let width = ActivityPillView.width
        let height = ActivityPillView.height(hasDetail: lead.detail != nil)
        let frame = NSRect(
            x: (screen?.visibleFrame.maxX ?? 800) - width - 12, y: (screen?.visibleFrame.maxY ?? 600) - height - 10, width: width, height: height)
        let panel = self.panel ?? makePanel(frame)
        self.panel = panel
        panel.setFrame(frame, display: true)
        panel.orderFrontRegardless()
        hide?.cancel()
        // while an act runs the pill stays
        guard running.isEmpty else { return }
        let work = DispatchWorkItem { [weak self] in self?.close() }
        hide = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.lingers, execute: work)
    }

    func close() {
        hide?.cancel()
        panel?.orderOut(nil)
    }

    var isVisible: Bool { panel?.isVisible ?? false }

    /// Another session: its acts count from one again, and none of them was dismissed.
    func forget() {
        dismissedUpTo = 0
        close()
    }

    private func dismiss() {
        dismissedUpTo = shown.entry?.order ?? dismissedUpTo
        close()
    }

    private func makePanel(_ frame: NSRect) -> NSPanel {
        let panel = NSPanel(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.level = NSWindow.Level(rawValue: NSWindow.Level.statusBar.rawValue + 1)
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        // only the × takes a click; the pill is small and at the edge
        panel.ignoresMouseEvents = false
        // not in a picture or a recording of the screen: the mind asked for the screen, not for this
        panel.sharingType = .none
        panel.contentView = NSHostingView(rootView: ActivityPillView(shown: shown, dismiss: { [weak self] in self?.dismiss() }))
        return panel
    }
}

@MainActor
private final class ShownActivity: ObservableObject {
    @Published var entry: ActivityLog.Row?
    @Published var mind: String?
    /// How many more acts run beside the one shown.
    @Published var others = 0
}

private struct ActivityPillView: View {
    @ObservedObject var shown: ShownActivity
    var dismiss: () -> Void = {}

    static let width: CGFloat = 380
    static let shape = RoundedRectangle(cornerRadius: Theme.Radius.panel, style: .continuous)

    /// The pill's height: two lines with a detail, one without.
    static func height(hasDetail: Bool) -> CGFloat { hasDetail ? 52 : 48 }

    var body: some View {
        HStack(spacing: 10) {
            if let entry = shown.entry {
                if let mind = shown.mind { MindAvatar(mind: mind, size: 26) }
                VStack(alignment: .leading, spacing: 1) {
                    Text(ActivityLine.title(of: entry) + (shown.others > 0 ? " · \(shown.others) more" : ""))
                        .font(.system(size: 13, weight: .semibold))
                        .lineLimit(1)
                    if let detail = entry.detail {
                        Text(detail).font(.system(size: 11, design: .monospaced)).foregroundStyle(Theme.t3).lineLimit(1).truncationMode(.tail)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                if entry.isRunning { ProgressView().controlSize(.small) }
                Button(action: dismiss) {
                    Image(systemName: "xmark").font(.system(size: 12, weight: .regular)).foregroundStyle(Theme.t2)
                        .frame(width: 18, height: 18).contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Hide until the next act. The panel's Activity keeps the list.")
            }
        }
        .foregroundStyle(Theme.t1)
        .padding(.horizontal, 12)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.surface, in: Self.shape)
        .overlay(Self.shape.strokeBorder(Theme.edge, lineWidth: 1))
    }
}

/// One act as words.
@MainActor
enum ActivityLine {
    static func title(of row: ActivityLog.Row) -> String {
        if let did = row.did { return row.failure.map { "\(did): \($0)" } ?? did }
        // an act of the context with no end: the app that ran it ended first
        return row.isRunning ? row.doing : "\(row.doing): no end in the log"
    }

    /// How long an act took, when that is worth a word: a second or more.
    static func took(_ row: ActivityLog.Row) -> String? {
        if row.isRunning { return "now" }
        guard let endedAt = row.endedAt else { return nil }
        let seconds = endedAt.timeIntervalSince(row.startedAt)
        return seconds < 1 ? nil : seconds < 60 ? "\(Int(seconds.rounded())) s" : "\(Int(seconds / 60)) min"
    }

    /// The symbol of the thing of the Mac (`Shareable.id`) that leads the line.
    static func symbol(_ thing: String) -> String {
        if thing.hasPrefix("screen.") { return "display" }
        if thing.hasPrefix("camera.") { return "video" }
        if thing.hasPrefix("record.") {
            return DeviceRecord.switches.first { "record.\($0.source.rawValue)" == thing }?.symbol ?? "text.viewfinder"
        }
        let things: [Shareable] = [.microphone, .speaker, .accessibility, .commands, .live, .banners, .pages]
        return things.first { $0.id == thing }?.symbol ?? "circle"
    }
}

/// The panel's "Activity", closed: the two newest acts, the count, and "All", which shows the
/// Activity page in place of the panel's middle.
struct ActivitySummary: View {
    @ObservedObject var log: ActivityLog
    @Binding var isOpen: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            SectionTitle(title: "Activity") {
                HStack(spacing: 8) {
                    if !log.rows.isEmpty {
                        Text("\(log.rows.count)").font(.system(size: 11).monospacedDigit()).foregroundStyle(Theme.t3)
                    }
                    Button {
                        isOpen = true
                    } label: {
                        TitleLink(title: "All").contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help("What a mind did with this Mac: the acts on this Mac's context in the mind")
                    .accessibilityLabel("All")
                    .accessibilityIdentifier("activity.all")
                }
            }
            VStack(alignment: .leading, spacing: 0) {
                if log.rows.isEmpty {
                    Text(log.path == nil ? "No mind has used this Mac since the app started." : "No act on this context yet.")
                        .font(.system(size: 11)).foregroundStyle(Theme.t3).padding(.horizontal, 2)
                }
                ForEach(log.rows.prefix(2)) { ActivityRow(entry: $0) }
            }
        }
    }
}

/// The Activity page: the context the log shows, the tick for the pill, and the last acts.
struct ActivityPage: View {
    @ObservedObject var log: ActivityLog
    @Binding var isOpen: Bool
    /// How many acts the page shows.
    var shown = 9
    /// "Open in a Window": the Activity window (`ActivityWindow`), with every event of the context.
    var openWindow: () -> Void = {}

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Button {
                    isOpen = false
                } label: {
                    HStack(spacing: 2) {
                        Image(systemName: "chevron.left").font(.system(size: 11, weight: .semibold)).frame(width: 14)
                        Text("Activity").font(.system(size: 13, weight: .semibold))
                    }
                    .foregroundStyle(Theme.t1)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Back to the panel")
                .accessibilityLabel("Back")
                .accessibilityIdentifier("activity.back")
                if !log.rows.isEmpty {
                    Text("\(log.rows.count)").font(.system(size: 11).monospacedDigit()).foregroundStyle(Theme.t3)
                }
                Spacer(minLength: 0)
                Button(action: openWindow) {
                    TitleLink(title: "Open in a Window").contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Every event of this context, in a window of its own")
                .accessibilityLabel("Open in a Window")
                .accessibilityIdentifier("activity.window")
            }
            .padding(.horizontal, 12)
            .padding(.top, 10)
            Text(log.contextLine).font(.system(size: 11, design: .monospaced)).foregroundStyle(Theme.t2).lineLimit(1).truncationMode(.middle)
                .textSelection(.enabled)
                .accessibilityIdentifier("activity.context")
                .padding(.horizontal, 14)
                .padding(.top, 8)
            Toggle("Show each act on the screen", isOn: $log.showsPill).toggleStyle(.checkbox).font(.system(size: 12))
                .tint(Theme.accent)
                .accessibilityIdentifier("activity.showsPill")
                .padding(.horizontal, 14)
                .padding(.top, 10)
                .padding(.bottom, 4)
            VStack(alignment: .leading, spacing: 0) {
                if log.rows.isEmpty {
                    Text(log.path == nil ? "No mind has used this Mac since the app started." : "No act on this context yet.")
                        .font(.system(size: 11)).foregroundStyle(Theme.t3)
                }
                ForEach(log.rows.prefix(shown)) { ActivityRow(entry: $0, inset: 0, vertical: 4) }
                if log.rows.count > shown {
                    Text("and \(log.rows.count - shown) before these").font(.system(size: 11)).foregroundStyle(Theme.t3).padding(.top, 6)
                }
            }
            .padding(.horizontal, 14)
            .padding(.top, 4)
        }
    }

}

/// One act: its time, the thing's icon (red while it runs or when it failed), what it did, its
/// detail in monospace, the orange cloud while it is not yet in the mind, and how long it took.
struct ActivityRow: View {
    let entry: ActivityLog.Row
    var inset: CGFloat = 2
    var vertical: CGFloat = 3

    var body: some View {
        HStack(alignment: .center, spacing: 8) {
            Text(Lend.clock(entry.startedAt)).font(.system(size: 11).monospacedDigit()).foregroundStyle(Theme.t3).frame(width: 50, alignment: .leading)
            Image(systemName: ActivityLine.symbol(entry.thing))
                .font(.system(size: 12, weight: .regular))
                .frame(width: 14)
                .foregroundStyle(entry.isRunning || entry.failure != nil ? Theme.liveText : Theme.t2)
            VStack(alignment: .leading, spacing: 1) {
                Text(ActivityLine.title(of: entry)).font(.system(size: 12)).lineSpacing(1.3).lineLimit(2).fixedSize(horizontal: false, vertical: true)
                if let detail = entry.detail {
                    Text(detail).font(.system(size: 10.5, design: .monospaced)).foregroundStyle(Theme.t3).lineLimit(1).truncationMode(.tail)
                        .textSelection(.enabled)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            if !entry.isInMind {
                Image(systemName: "icloud.slash").font(.system(size: 12, weight: .regular)).foregroundStyle(Theme.warnText)
                    .help("Not yet in the mind: it goes when the connection is back")
            }
            if let took = ActivityLine.took(entry) {
                Text(took).font(.system(size: 11).monospacedDigit()).foregroundStyle(Theme.t3)
            }
        }
        .padding(.horizontal, inset)
        .padding(.vertical, vertical)
        .frame(minHeight: 30)
    }
}

extension ActivityLog {
    /// The drawings' acts (`Rendering`), as the context holds them: eight that ended, the newest at
    /// 14:01:29; with `running`, a command that runs now and that the context has not echoed yet;
    /// and `older` more acts before them.
    static func fillSample(_ log: ActivityLog, running: Bool, older: Int = 0) {
        let now = Rendering.now
        log.mind = Rendering.minds[0].mind
        log.path = "/devices/\(Rendering.minds[0].name)"
        let display = "“Built-in Retina Display”"
        var acts: [(thing: String, doing: String, did: String, failure: String?, detail: String?, at: TimeInterval, took: TimeInterval)] = []
        for index in 0..<older {
            acts.append(("screen.1", "Taking a picture of the display \(display)", "Took a picture of the display \(display)", nil, nil, -900 - Double(index) * 120, 0.4))
        }
        acts += [
            ("record.screens", "Recording the screens", "Record the screens until switched off", nil, nil, -761, 0.2),
            ("accessibility", "Reading the window in front", "Read the window in front", nil, "Ghostty “my project”", -726, 0.3),
            ("live", "Watched live by Misha", "Watched live by Misha", nil, "the screen, the microphone", -593, 190),
            ("banners", "Showing a banner", "Showed a banner: “Join” was pressed", nil, "Design review is starting", -451, 12),
            ("speaker", "Saying “Lunch is ready” through the speakers", "Said “Lunch is ready” through the speakers", nil, nil, -429, 2),
            ("commands", "Running a command", "Ran a command", "it ended with status 1", "/usr/bin/false", -300, 1),
            ("microphone", "Listening to the microphone for 5 s", "Listened to the microphone for 5 s", nil, nil, -95, 5),
            ("screen.1", "Taking a picture of the display \(display)", "Took a picture of the display \(display)", nil, nil, -42, 0.4),
        ]
        var offset = 0
        for (index, act) in acts.enumerated() {
            let id = "sample-\(index)"
            offset += 1
            log.fold.take(ContextEvent(.actStarted(act: id, thing: act.thing, doing: act.doing, detail: act.detail), at: now.addingTimeInterval(act.at), offset: offset))
            offset += 1
            log.fold.take(ContextEvent(.actEnded(act: id, did: act.did, failure: act.failure), at: now.addingTimeInterval(act.at + act.took), offset: offset))
        }
        log.fold.take(ContextEvent(.presenceChanged(state: "active"), at: now.addingTimeInterval(-30), offset: offset + 1))
        if running {
            // an act of this app that the context has not echoed yet
            log.fold.take(ContextEvent(.actStarted(act: "sample-running", thing: "commands", doing: "Running a command", detail: "/bin/zsh -lc git -C ~/src/app status --short"), at: now, offset: nil))
        }
    }

    /// Draws the pill and the Activity page to PNG files in `folder`, with sample acts, in light
    /// and dark: a look with no Mac bar (`--render-activity <folder>`).
    static func render(to folder: URL) -> Bool {
        _ = NSApplication.shared
        Rendering.fixFaces()
        let log = ActivityLog()
        fillSample(log, running: true)
        let shown = ShownActivity()
        shown.entry = log.rows.first
        shown.mind = log.mind
        var drawn = true
        for (dark, tone) in [(false, "light"), (true, "dark")] {
            let pill = ActivityPillView(shown: shown).frame(width: ActivityPillView.width, height: ActivityPillView.height(hasDetail: true)).padding(12)
            drawn = Rendering.png(of: pill, dark: dark, to: folder.appendingPathComponent("activity-pill-\(tone).png")) && drawn
            let list = ActivityPage(log: log, isOpen: .constant(true)).foregroundStyle(Theme.t1).frame(width: 398).padding(.bottom, 12)
                .background(Theme.surface)
            drawn = Rendering.png(of: list, dark: dark, to: folder.appendingPathComponent("activity-list-\(tone).png")) && drawn
        }
        return drawn
    }
}
