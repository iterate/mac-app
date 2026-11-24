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
        let width: CGFloat = 340
        let height: CGFloat = lead.detail == nil ? 40 : 56
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

    var body: some View {
        HStack(spacing: 9) {
            if let entry = shown.entry {
                if let mind = shown.mind { MindAvatar(mind: mind, size: 24) }
                VStack(alignment: .leading, spacing: 1) {
                    Text(ActivityLine.title(of: entry) + (shown.others > 0 ? " · \(shown.others) more" : ""))
                        .font(.system(size: 13, weight: .medium))
                        .lineLimit(1)
                    if let detail = entry.detail {
                        Text(detail).font(.system(size: 11, design: .monospaced)).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                    }
                }
                Spacer(minLength: 0)
                if entry.isRunning { ProgressView().controlSize(.small) }
                Button(action: dismiss) {
                    Image(systemName: "xmark").font(.system(size: 10, weight: .bold)).foregroundStyle(.secondary)
                        .frame(width: 18, height: 18).contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Hide until the next act. The panel's Activity keeps the list.")
            }
        }
        .padding(.leading, 8)
        .padding(.trailing, 12)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(.separator))
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
        let things: [Shareable] = [.microphone, .speaker, .accessibility, .commands, .live, .banners]
        return things.first { $0.id == thing }?.symbol ?? "circle"
    }
}

/// The panel's "Activity": a line that opens the list of the last acts, each with its time.
struct ActivityList: View {
    @ObservedObject var log: ActivityLog
    @Binding var isOpen: Bool
    /// How many acts the open list shows.
    var shown = 8

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button {
                isOpen.toggle()
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.semibold))
                        .rotationEffect(.degrees(isOpen ? 90 : 0))
                        .foregroundStyle(.secondary)
                    Text("Activity").font(.subheadline.weight(.semibold))
                    if let last = log.rows.first, !isOpen {
                        Text("\(ActivityLine.title(of: last)), \(Self.clock(last.startedAt))")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.tail)
                    }
                    Spacer(minLength: 0)
                    if !log.rows.isEmpty {
                        Text("\(log.rows.count)").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("What a mind did with this Mac: the acts on this Mac's context in the mind")
            if isOpen {
                Text(context).font(.caption.monospaced()).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                    .textSelection(.enabled)
                    .accessibilityIdentifier("activity.context")
                Toggle("Show each act on the screen", isOn: $log.showsPill).toggleStyle(.checkbox).font(.caption)
                    .accessibilityIdentifier("activity.showsPill")
                if log.rows.isEmpty {
                    Text(log.path == nil ? "No mind has used this Mac since the app started." : "No act on this context yet.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                ForEach(log.rows.prefix(shown)) { entry in row(entry) }
                if log.rows.count > shown {
                    Text("and \(log.rows.count - shown) before these").font(.caption).foregroundStyle(.tertiary)
                }
            }
        }
    }

    /// The log's header: the context it shows, on which mind, and the presence it last heard.
    private var context: String {
        guard let path = log.path, let mind = log.mind else { return "Lent to no mind: these acts are on this Mac only" }
        return "\(path) on \(mind)" + (log.fold.presence.map { " · \($0.state)" } ?? "")
    }

    private func row(_ entry: ActivityLog.Row) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(Self.clock(entry.startedAt)).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            Image(systemName: ActivityLine.symbol(entry.thing)).font(.caption).frame(width: 16).foregroundStyle(entry.isRunning ? Color.red : Color.secondary)
            VStack(alignment: .leading, spacing: 1) {
                Text(ActivityLine.title(of: entry)).font(.caption).lineLimit(2)
                if let detail = entry.detail {
                    Text(detail).font(.system(size: 10, design: .monospaced)).foregroundStyle(.secondary).lineLimit(2).truncationMode(.middle).textSelection(.enabled)
                }
            }
            Spacer(minLength: 0)
            if !entry.isInMind {
                Image(systemName: "icloud.slash").font(.caption2).foregroundStyle(.orange).help("Not yet in the mind: it goes when the connection is back")
            }
            if let took = ActivityLine.took(entry) { Text(took).font(.caption.monospacedDigit()).foregroundStyle(.tertiary) }
        }
    }

    private static func clock(_ date: Date) -> String {
        Lend.clock(date)
    }
}

extension ActivityLog {
    /// Draws the pill and the panel's open list to PNG files in `folder`, with sample acts, in
    /// light and dark: a look with no Mac bar (`--render-activity <folder>`).
    static func render(to folder: URL) -> Bool {
        _ = NSApplication.shared
        Rendering.fixFaces()
        let log = ActivityLog()
        let now = Rendering.now
        log.mind = "iterate.example.com"
        log.path = "/devices/jane.mac"
        // the context's events, and one act of this app that the context has not echoed yet
        let events: [(DeviceFact, TimeInterval, Int?)] = [
            (.actStarted(act: "1", thing: "commands", doing: "Running a command", detail: "/usr/bin/false"), -300, 1),
            (.actEnded(act: "1", did: "Ran a command", failure: "it ended with status 1"), -299, 2),
            (.actStarted(act: "2", thing: "microphone", doing: "Listening to the microphone for 5 s", detail: nil), -95, 3),
            (.actEnded(act: "2", did: "Listened to the microphone for 5 s", failure: nil), -90, 4),
            (.presenceChanged(state: "active"), -60, 5),
            (.actStarted(act: "3", thing: "screen.1", doing: "Taking a picture of the display “Built-in Retina Display”", detail: nil), -42, 6),
            (.actEnded(act: "3", did: "Took a picture of the display “Built-in Retina Display”", failure: nil), -41.6, 7),
            (.actStarted(act: "4", thing: "commands", doing: "Running a command", detail: "/bin/zsh -lc git -C ~/src/app status --short"), 0, nil),
        ]
        for (fact, seconds, offset) in events { log.fold.take(ContextEvent(fact, at: now.addingTimeInterval(seconds), offset: offset)) }
        let shown = ShownActivity()
        shown.entry = log.rows.first
        shown.mind = log.mind
        var drawn = true
        for (dark, tone) in [(false, "light"), (true, "dark")] {
            let pill = ActivityPillView(shown: shown).frame(width: 340, height: 56).padding(12).background(Color(nsColor: .windowBackgroundColor))
            drawn = Rendering.png(of: pill, dark: dark, to: folder.appendingPathComponent("activity-pill-\(tone).png")) && drawn
            let list = ActivityList(log: log, isOpen: .constant(true)).frame(width: 398).padding(16).background(Color(nsColor: .windowBackgroundColor))
            drawn = Rendering.png(of: list, dark: dark, to: folder.appendingPathComponent("activity-list-\(tone).png")) && drawn
        }
        return drawn
    }
}
