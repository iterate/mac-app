import AppKit
import SwiftUI
import VoiceMeetCore

// THE ACTIVITY WINDOW: a window on the device's context `/devices/<name>`, opened from the panel's
// Activity page ("Open in a Window"). Its switch shows the acts (the panel's rows, `ActivityLog`)
// or every event the context keeps (`ContextLog`), newest first; at the right, the chosen event's
// fields and the Off / Ask / Shared of its thing.
//
// "Every event" is read only while the window is open: the bridge subscribes to every kept type
// and reads the newest page of 100; a scroll to the end of the list reads the page below, until
// the window holds 500 (`EventWindow`). A new event over that pushes the oldest out. The window's
// close ends the subscription and lets go of the events. The list is lazy: only the rows on the
// screen are made, and each row's words are made once, when its event comes.

/// One row of the window: an event, or an act of the panel's list.
struct LogLine: Identifiable, OffsetEvent {
    struct Field: Hashable {
        let key: String
        let value: String
    }

    /// The filters at the top: what kind of event a row is.
    enum Group: String, CaseIterable, Identifiable {
        case acts, presence, app, window, record, live, inputs, keys, other
        var id: String { rawValue }

        var title: String {
            switch self {
            case .acts: "acts"
            case .presence: "presence"
            case .app: "app in front"
            case .window: "window text"
            case .record: "record"
            case .live: "live"
            case .inputs: "inputs"
            case .keys: "keys and mouse"
            case .other: "other"
            }
        }
    }

    let id: String
    let offset: Int
    let type: String
    let at: Date
    /// The time as the row shows it, made once.
    let time: String
    var symbol: String
    var isRed: Bool
    var title: String
    var detail: String?
    var detailIsCode: Bool
    var took: String?
    /// The context has not echoed it yet: an act of this app on its way.
    var notInMind: Bool
    /// The thing of the Mac it is about (`Shareable.id`), for its Off / Ask / Shared.
    var thing: String?
    var act: String?
    var fields: [Field]
    /// A long text of the event, shown in a block: a command, a window's text.
    var block: String?
    let group: Group
    /// The event as JSON, for Copy Event; an act's row makes it at the copy (`LogWords.json`).
    let json: String?
    /// The words a search looks in, in lower case.
    var search: String
}

/// THE WORDS OF EACH EVENT TYPE, made once for a row.
@MainActor
enum LogWords {
    /// The order of the fields of a payload; the others follow by name.
    private static let order = [
        "act", "thing", "doing", "did", "failure", "detail", "state", "was", "idleSeconds", "app", "bundle", "title", "trigger", "text",
        "key", "keyCode", "modifiers", "isRepeat", "x", "y", "button", "clicks", "dx", "dy", "t", "tracks", "watcher", "who", "seconds",
        "why", "id", "at", "files",
    ]

    static func group(_ type: String) -> LogLine.Group {
        switch type {
        case DeviceFact.actStartedType, DeviceFact.actEndedType: .acts
        case DeviceFact.presenceChangedType: .presence
        case "device/app-focused": .app
        case "device/window-read": .window
        case "device/input-submitted": .inputs
        case "device/key-pressed", "device/mouse-pressed", "device/mouse-moved", "device/scrolled": .keys
        default: type.hasPrefix("record/") ? .record : type.hasPrefix("device/live-watch") ? .live : .other
        }
    }

    /// A line of the bridge's log, `{ type, payload, offset, createdAt }`; nil for one without them.
    static func line(_ json: [String: Any]) -> LogLine? {
        guard let type = json["type"] as? String, let offset = json["offset"] as? Int else { return nil }
        let payload = json["payload"] as? [String: Any] ?? [:]
        let at = (json["createdAt"] as? String).flatMap(time) ?? Date(timeIntervalSince1970: 0)
        return line(type: type, payload: payload, offset: offset, at: at)
    }

    static func line(type: String, payload: [String: Any], offset: Int, at: Date) -> LogLine {
        let text = { (key: String) in (payload[key] as? String).flatMap { $0.isEmpty ? nil : $0 } }
        let number = { (key: String) in (payload[key] as? NSNumber)?.intValue }
        var title = type
        var detail: String?
        var detailIsCode = false
        var symbol = "circle.dotted"
        var isRed = false
        var thing: String?
        var block: String?
        var blockKey: String?
        switch type {
        case DeviceFact.actStartedType:
            title = text("doing") ?? "An act started"
            detail = text("detail")
            detailIsCode = true
            thing = text("thing")
            symbol = thing.map { ActivityLine.symbol($0) } ?? "circle"
            (block, blockKey) = (detail, "detail")
        case DeviceFact.actEndedType:
            let did = text("did") ?? "An act ended"
            title = text("failure").map { "\(did): \($0)" } ?? did
            isRed = text("failure") != nil
            symbol = "circle"
        case DeviceFact.presenceChangedType:
            let state = text("state") ?? "unknown"
            title = state.prefix(1).uppercased() + state.dropFirst()
            if state == "idle", let idle = number("idleSeconds") {
                detail = "\(idle) s with no input"
            } else {
                detail = text("was").map { "was \($0)" }
            }
            symbol = "person"
        case "device/app-focused":
            title = "\(text("app") ?? "An app") is in front"
            detail = text("title").map { "“\($0)”" }
            symbol = "cursorarrow"
        case "device/window-read":
            title = "Read the window in front"
            let trigger: String? =
                switch text("trigger") {
                case "click": "after a click"
                case "typing-pause": "after typing"
                case "scroll-end": "after a scroll"
                case "app": "a new app"
                case "window": "a new window"
                default: nil
                }
            let window = [text("app"), text("title").map { "“\($0)”" }].compactMap { $0 }.joined(separator: " ")
            detail = [window.isEmpty ? nil : window, trigger].compactMap { $0 }.joined(separator: " · ")
            thing = Shareable.accessibility.id
            symbol = Shareable.accessibility.symbol
            (block, blockKey) = (text("text"), "text")
        case "device/input-submitted":
            title = "You sent an input"
            let files = (payload["files"] as? [Any])?.count ?? 0
            let words = text("text").map { "“\(oneLine($0, limit: 80))”" }
            detail = [words, files > 0 ? (files == 1 ? "1 file" : "\(files) files") : nil].compactMap { $0 }.joined(separator: " · ")
            symbol = "text.bubble"
            (block, blockKey) = (text("text"), "text")
        case "device/live-watch-started":
            title = "\(text("who") ?? "Somebody") began to watch live"
            detail = LiveSection.words(payload["tracks"] as? [String] ?? [])
            symbol = "eye"
            isRed = true
        case "device/live-watch-ended":
            title = "\(text("who") ?? "Somebody") stopped watching"
            detail = [number("seconds").map { "\($0) s" }, text("why")].compactMap { $0 }.joined(separator: " · ")
            symbol = "eye"
        case "device/key-pressed":
            let key = text("text") ?? text("key") ?? number("keyCode").map { "key \($0)" } ?? "a key"
            title = "Pressed “\(key)”" + (text("app").map { " in \($0)" } ?? "")
            detail = (payload["modifiers"] as? [String]).map { $0.joined(separator: " + ") }
            symbol = "keyboard"
        case "device/mouse-pressed":
            title = "Clicked at \(number("x") ?? 0), \(number("y") ?? 0)" + (text("app").map { " in \($0)" } ?? "")
            symbol = "cursorarrow.click"
        case "device/mouse-moved":
            title = "The pointer moved to \(number("x") ?? 0), \(number("y") ?? 0)"
            symbol = "cursorarrow.motionlines"
        case "device/scrolled":
            title = "Scrolled by \(number("dx") ?? 0), \(number("dy") ?? 0)"
            symbol = "scroll"
        default:
            if type.hasPrefix("record/") {
                let tracks = (payload["tracks"] as? [String: Any]).map { Array($0.keys) } ?? []
                let names = tracks.sorted { (rank($0), $0) < (rank($1), $1) }
                let slot = (payload["t"] as? NSNumber).map { Lend.clock(Date(timeIntervalSince1970: $0.doubleValue)) }
                title = type == "record/slot-stored" ? "Slot \(slot ?? "") is in the mind" : type
                detail = names.isEmpty ? nil : "\(names.count) \(names.count == 1 ? "track" : "tracks"): \(names.joined(separator: ", "))"
                symbol = "record.circle"
                isRed = true
            } else {
                detail = oneLine(compact(payload), limit: 120)
                detailIsCode = true
            }
        }
        let fields = payload.keys.filter { $0 != blockKey }
            .sorted { (order.firstIndex(of: $0) ?? order.count, $0) < (order.firstIndex(of: $1) ?? order.count, $1) }
            .map { LogLine.Field(key: $0, value: value(payload[$0])) }
        let group = group(type)
        let event: [String: Any] = ["type": type, "offset": offset, "createdAt": at.ISO8601Format(), "payload": payload]
        return LogLine(
            id: "e\(offset)", offset: offset, type: type, at: at, time: Lend.clock(at), symbol: symbol, isRed: isRed, title: title,
            detail: detail.flatMap { $0.isEmpty ? nil : $0 }, detailIsCode: detailIsCode, took: nil, notInMind: false, thing: thing,
            act: text("act"), fields: fields, block: block, group: group, json: pretty(event),
            search: [title, detail ?? "", type].joined(separator: " ").lowercased())
    }

    /// An act of the panel's list as a row: the window's "Acts".
    static func line(_ row: ActivityLog.Row) -> LogLine {
        let fact = DeviceFact.actStarted(act: row.act, thing: row.thing, doing: row.doing, detail: row.detail)
        var payload = fact.payload
        if let did = row.did { payload["did"] = did }
        if let failure = row.failure { payload["failure"] = failure }
        let type = row.did == nil ? DeviceFact.actStartedType : DeviceFact.actEndedType
        let title = ActivityLine.title(of: row)
        return LogLine(
            id: "a\(row.act)", offset: 0, type: type, at: row.startedAt, time: Lend.clock(row.startedAt),
            symbol: ActivityLine.symbol(row.thing), isRed: row.isRunning || row.failure != nil, title: title, detail: row.detail,
            detailIsCode: true, took: ActivityLine.took(row), notInMind: !row.isInMind, thing: row.thing, act: row.act,
            fields: ["act", "thing", "doing", "did", "failure"].compactMap { key in payload[key].map { LogLine.Field(key: key, value: value($0)) } },
            block: row.detail, group: .acts, json: nil,
            search: [title, row.detail ?? "", type].joined(separator: " ").lowercased())
    }

    /// A row's event as JSON, for Copy Event: its type, offset and fields (the detail among them).
    static func json(of line: LogLine) -> String {
        if let json = line.json { return json }
        var payload = Dictionary(line.fields.map { ($0.key, $0.value) }, uniquingKeysWith: { first, _ in first })
        if let block = line.block { payload["detail"] = block }
        return pretty(["type": line.type, "createdAt": line.at.ISO8601Format(), "payload": payload])
    }

    /// An end's row gets its start's thing, detail and time: the end says only what was done.
    static func complete(_ end: inout LogLine, start: (thing: String, detail: String?, at: Date)) {
        end.thing = start.thing
        end.symbol = ActivityLine.symbol(start.thing)
        if end.detail == nil, let detail = start.detail {
            end.detail = detail
            end.detailIsCode = true
            end.block = detail
            end.search += " " + detail.lowercased()
        }
        let seconds = end.at.timeIntervalSince(start.at)
        end.took = seconds < 1 ? nil : seconds < 60 ? "\(Int(seconds.rounded())) s" : "\(Int(seconds / 60)) min"
    }

    /// A screen first, then the camera, the microphone and the speakers.
    private static func rank(_ track: String) -> Int {
        ["screen", "camera", "mic", "speaker"].firstIndex { track.hasPrefix($0) } ?? 4
    }

    private static func value(_ any: Any?) -> String {
        switch any {
        case let text as String: return text
        case let number as NSNumber: return CFGetTypeID(number) == CFBooleanGetTypeID() ? (number.boolValue ? "true" : "false") : number.stringValue
        case nil, is NSNull: return ""
        case let other?: return oneLine(compact(other), limit: 200)
        }
    }

    private static func compact(_ any: Any) -> String {
        guard JSONSerialization.isValidJSONObject(any), let data = try? JSONSerialization.data(withJSONObject: any, options: [.sortedKeys]) else {
            return String(describing: any)
        }
        return String(decoding: data, as: UTF8.self)
    }

    private static func pretty(_ any: [String: Any]) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: any, options: [.sortedKeys, .prettyPrinted, .withoutEscapingSlashes]) else { return "" }
        return String(decoding: data, as: UTF8.self)
    }

    private static func oneLine(_ words: String, limit: Int) -> String {
        let line = words.split(whereSeparator: \.isNewline).joined(separator: " ")
        return line.count > limit ? line.prefix(limit) + "…" : line
    }

    private static func time(_ text: String) -> Date? {
        let withFraction = ISO8601DateFormatter()
        withFraction.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return withFraction.date(from: text) ?? ISO8601DateFormatter().date(from: text)
    }
}

/// "Every event": what the window holds of the context, the filters and the search, and the rows
/// they leave (`shown`), made again only when one of them changes.
@MainActor
final class ContextLog: ObservableObject {
    @Published private(set) var window = EventWindow<LogLine>()
    @Published private(set) var shown: [LogLine] = []
    @Published private(set) var failure: String?
    /// The groups the list shows. Keys and mouse are many: off until the person turns them on.
    @Published var groups: Set<LogLine.Group> = Set(LogLine.Group.allCases).subtracting([.keys]) { didSet { refilter() } }
    @Published var search = "" { didSet { refilter() } }
    /// The bridge reads the next page below this offset.
    var readOlder: (Int) -> Void = { _ in }
    /// An act's start that the window does not hold: the panel's fold may.
    var startOf: (String) -> (thing: String, detail: String?, at: Date)? = { _ in nil }
    /// Each act's start of the events held, for its end.
    private var starts: [String: (thing: String, detail: String?, at: Date)] = [:]

    /// A line of the bridge: `{ reset }`, `{ page, before, more }`, `{ event }` or `{ failed }`.
    func heard(_ line: [String: Any]) {
        if line["reset"] != nil {
            window.reset()
            starts = [:]
            failure = nil
        }
        if let page = line["page"] as? [[String: Any]] {
            let lines = page.compactMap { LogWords.line($0) }
            remember(lines)
            window.take(page: lines.map(completed), before: line["before"] as? Int ?? 0, more: line["more"] as? Bool ?? false)
            completeEnds(of: lines)
            failure = nil
        }
        if let event = (line["event"] as? [String: Any]).flatMap({ LogWords.line($0) }) {
            remember([event])
            window.take(completed(event))
        }
        if let failed = line["failed"] as? String {
            window.failed()
            failure = failed
        }
        refilter()
    }

    /// The list came to its end: the next page, when there is one and none is on its way.
    func reachedEnd() {
        if let before = window.askOlder() { readOlder(before) }
    }

    /// The rows of the groups shown that have the search's words.
    private func refilter() {
        let words = search.lowercased().split(separator: " ").map(String.init)
        let all = groups.count == LogLine.Group.allCases.count
        shown = window.events.filter { line in
            (all || groups.contains(line.group)) && words.allSatisfy { line.search.contains($0) }
        }
    }

    private func remember(_ lines: [LogLine]) {
        if starts.count > 2 * EventWindow<LogLine>.most { starts = [:] }
        for line in lines where line.type == DeviceFact.actStartedType {
            if let act = line.act, let thing = line.thing { starts[act] = (thing, line.block, line.at) }
        }
    }

    private func completed(_ line: LogLine) -> LogLine {
        guard line.type == DeviceFact.actEndedType, let act = line.act, let start = starts[act] ?? startOf(act) else { return line }
        var line = line
        LogWords.complete(&line, start: start)
        return line
    }

    /// A page of starts older than their ends: the ends held get their thing and time now.
    private func completeEnds(of lines: [LogLine]) {
        let acts = Set(lines.filter { $0.type == DeviceFact.actStartedType }.compactMap(\.act))
        guard !acts.isEmpty else { return }
        window.update { line in
            if line.type == DeviceFact.actEndedType, line.thing == nil, let act = line.act, acts.contains(act), let start = starts[act] {
                LogWords.complete(&line, start: start)
            }
        }
    }

    /// For a drawing: these events, as a page of the context.
    func fixForDrawing(_ events: [[String: Any]]) {
        heard(["reset": true])
        heard(["page": events, "before": 1, "more": false])
    }
}

/// The window, made when it opens and let go of when it closes: no view, task or read of it runs
/// while it is closed.
@MainActor
final class ActivityWindow: NSObject, NSWindowDelegate {
    static let size = NSSize(width: 960, height: 614)
    private var window: NSWindow?
    private let makeView: () -> AnyView
    /// The window opened (true) or closed (false): the log's read starts or ends.
    var opened: (Bool) -> Void = { _ in }

    init(view: @escaping () -> AnyView) {
        makeView = view
    }

    var isVisible: Bool { window?.isVisible ?? false }

    func show() {
        if window == nil {
            let host = NSHostingController(rootView: makeView())
            host.sizingOptions = []
            // the content goes under the see-through title bar, and the view sets the title there
            host.safeAreaRegions = []
            let window = SettingsNSWindow(
                contentRect: NSRect(origin: .zero, size: Self.size), styleMask: [.titled, .closable, .miniaturizable, .resizable],
                backing: .buffered, defer: false)
            window.contentViewController = host
            window.title = "Activity"
            window.tallTitleBar()
            window.isReleasedWhenClosed = false
            window.contentMinSize = NSSize(width: 760, height: 420)
            window.setContentSize(Self.size)
            window.delegate = self
            window.center()
            // for a test with no hand: `ui.press {"id":"log.close"}` closes it as a click does
            window.standardWindowButton(.closeButton)?.cell?.setAccessibilityIdentifier("log.close")
            window.standardWindowButton(.closeButton)?.setAccessibilityIdentifier("log.close")
            self.window = window
            opened(true)
        }
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }

    func windowWillClose(_ notification: Notification) {
        window?.contentViewController = nil
        window = nil
        opened(false)
    }
}

/// What the window's thing control does.
struct ActivityWindowActions {
    var choose: (Shareable, Sharing) -> Void = { _, _ in }
    var endApproval: (Shareable) -> Void = { _ in }
    var copy: (String) -> Void = { _ in }
}

struct ActivityWindowView: View {
    enum Mode: String { case acts, every }

    @ObservedObject var acts: ActivityLog
    @ObservedObject var log: ContextLog
    /// The things, their choices and approvals, as the panel has them.
    @ObservedObject var state: PanelState
    var actions = ActivityWindowActions()
    @State var mode: Mode = .every
    @State var selected: LogLine?
    /// A drawing's: it shows "Following" as an open window does.
    var isDrawing = false

    var body: some View {
        VStack(spacing: 0) {
            VStack(spacing: 0) {
                // the title bar's band: the window's buttons at the left, the title in the middle
                Text("Activity")
                    .font(.system(size: 13, weight: .semibold))
                    .frame(maxWidth: .infinity)
                    .frame(height: 38)
                    .accessibilityAddTraits(.isHeader)
                toolbar
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
            }
            .background(Theme.titlebar)
            Theme.line.frame(height: 1)
            HStack(spacing: 0) {
                VStack(alignment: .leading, spacing: 0) {
                    header
                    list
                }
                .frame(maxWidth: .infinity)
                Theme.line.frame(width: 1)
                details
                    .frame(width: 285)
            }
            Theme.line.frame(height: 1)
            footer
                .padding(.leading, 22)
                .padding(.trailing, 14)
                .padding(.top, 8)
                .padding(.bottom, 9)
        }
        .foregroundStyle(Theme.t1)
        .background(Theme.win)
    }

    // MARK: - The top: the switch, the filters, the search

    private var toolbar: some View {
        HStack(spacing: 8) {
            HStack(spacing: 2) {
                modeButton(.acts, "Acts")
                modeButton(.every, "Every event")
            }
            .padding(2)
            .background(Theme.track, in: RoundedRectangle(cornerRadius: Theme.Radius.segmentTrack, style: .continuous))
            .accessibilityElement(children: .contain)
            .accessibilityLabel("Show")
            .accessibilityIdentifier("log.mode")
            if mode == .every {
                HStack(spacing: 5) {
                    ForEach(LogLine.Group.allCases.filter { $0 != .other }) { group in chip(group) }
                }
            }
            Spacer(minLength: 8)
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass").font(.system(size: 11, weight: .regular)).foregroundStyle(Theme.t3)
                TextField("Search", text: mode == .every ? $log.search : .constant(""))
                    .textFieldStyle(.plain)
                    .font(.system(size: 12))
                    .disabled(mode != .every)
                    .accessibilityIdentifier("log.search")
            }
            .padding(.horizontal, 9)
            .frame(width: 150, height: 24)
            .background(Theme.field, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous).strokeBorder(Theme.edge))
        }
        .font(.system(size: 12))
    }

    private func modeButton(_ value: Mode, _ title: String) -> some View {
        let isSelected = mode == value
        return Button {
            mode = value
            selected = nil
        } label: {
            Text(title)
                .font(.system(size: 12, weight: isSelected ? .semibold : .regular))
                .foregroundStyle(isSelected ? Theme.t1 : Theme.segIdle)
                .padding(.horizontal, 12)
                .frame(height: 22)
                .background(isSelected ? Theme.knob : Color.clear, in: RoundedRectangle(cornerRadius: Theme.Radius.segment, style: .continuous))
                .shadow(color: isSelected ? Theme.knobShadow : .clear, radius: 1, y: 0.5)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    private func chip(_ group: LogLine.Group) -> some View {
        let isOn = log.groups.contains(group)
        return Button {
            if isOn { log.groups.remove(group) } else { log.groups.insert(group) }
        } label: {
            Text(group.title)
                .font(.system(size: 11.5))
                .foregroundStyle(isOn ? Theme.accentTintText : Theme.t3)
                .padding(.horizontal, 9)
                .frame(height: 22)
                .background(isOn ? Theme.accentTint : Color.clear, in: Capsule())
                .overlay(Capsule().strokeBorder(isOn ? Color.clear : Theme.edge))
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .lineLimit(1)
        .fixedSize()
        .accessibilityLabel(group.title)
        .accessibilityValue(isOn ? "shown" : "hidden")
        .accessibilityIdentifier("log.filter.\(group.rawValue)")
    }

    // MARK: - The list

    private var header: some View {
        HStack(spacing: 8) {
            Text(acts.contextLine)
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(Theme.t2)
                .lineLimit(1)
                .truncationMode(.middle)
                .textSelection(.enabled)
                .accessibilityIdentifier("log.context")
            Spacer(minLength: 10)
            if isFollowing {
                HStack(spacing: 6) {
                    Circle().fill(Theme.ok).frame(width: 7, height: 7)
                    Text("Following")
                }
                .font(.system(size: 11))
                .foregroundStyle(Theme.okText)
                .help("New events of this context come into the list as they happen")
            }
        }
        .padding(.leading, 22)
        .padding(.trailing, 14)
        .padding(.top, 9)
        .padding(.bottom, 5)
    }

    private var isFollowing: Bool {
        acts.path != nil && (mode == .acts || isDrawing || (log.window.isRead && log.failure == nil))
    }

    /// The rows of the mode: the acts, or every event with the acts of this app not yet in the
    /// mind at the top.
    private var lines: [LogLine] {
        switch mode {
        case .acts:
            return acts.rows.map { LogWords.line($0) }
        case .every:
            guard log.groups.contains(.acts) else { return log.shown }
            let search = log.search.lowercased().split(separator: " ").map(String.init)
            let waiting = acts.rows.filter { !$0.startIsInMind }.map { LogWords.line($0) }.filter { line in search.allSatisfy { line.search.contains($0) } }
            return waiting + log.shown
        }
    }

    private var list: some View {
        let lines = self.lines
        return ScrollView(.vertical) {
            LazyVStack(alignment: .leading, spacing: 1) {
                ForEach(lines) { line in
                    LogRow(line: line, isSelected: line.id == selected?.id)
                        .onTapGesture { selected = line }
                }
                end(count: lines.count)
                    .onAppear { if mode == .every { log.reachedEnd() } }
            }
            .padding(.horizontal, 14)
            .padding(.bottom, 12)
        }
        .accessibilityIdentifier("log.list")
    }

    @ViewBuilder
    private func end(count: Int) -> some View {
        let words: String? =
            switch mode {
            case .acts: count == 0 ? (acts.path == nil ? "No mind has used this Mac since the app started." : "No act on this context yet.") : nil
            case .every:
                acts.path == nil ? "This Mac is lent to no mind: there is no context to read."
                    : log.failure.map { "The log could not be read: \($0)" }
                    ?? (!log.window.isRead ? "Reading the context…"
                        : log.window.isFull && log.window.hasOlder ? "The window holds the newest \(EventWindow<LogLine>.most) events. The mind keeps every one."
                        : log.window.hasOlder ? "Reading older events…" : count == 0 ? "No event on this context yet." : nil)
            }
        if let words {
            Text(words).font(.system(size: 11)).foregroundStyle(Theme.t3).padding(.horizontal, 8).padding(.vertical, 8)
        } else {
            Color.clear.frame(height: 1)
        }
    }

    // MARK: - The chosen event

    @ViewBuilder
    private var details: some View {
        if let line = selected {
            ScrollView(.vertical) {
                VStack(alignment: .leading, spacing: 12) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(line.title).font(.system(size: 14, weight: .semibold)).lineHeight(1.3, size: 14).fixedSize(horizontal: false, vertical: true)
                        Text("\(line.type) · \(line.time)").font(.system(size: 11, design: .monospaced)).foregroundStyle(Theme.t3)
                            .lineLimit(1).truncationMode(.middle)
                    }
                    Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 10, verticalSpacing: 4) {
                        ForEach(line.fields, id: \.self) { field in
                            GridRow {
                                Text(field.key).font(.system(size: 12)).lineHeight(1.45, size: 12).foregroundStyle(Theme.t3).frame(width: 52, alignment: .leading)
                                Text(field.value).font(.system(size: 11.5, design: .monospaced)).lineLimit(2).truncationMode(.middle)
                                    .textSelection(.enabled)
                            }
                        }
                        if line.block != nil {
                            GridRow {
                                Text(line.type == DeviceFact.actStartedType || line.type == DeviceFact.actEndedType ? "detail" : "text").font(.system(size: 12))
                                    .lineHeight(1.45, size: 12).foregroundStyle(Theme.t3)
                            }
                        }
                    }
                    if let block = line.block {
                        Text(block)
                            .font(.system(size: 11, design: .monospaced))
                            .lineHeight(1.5, size: 11)
                            .lineLimit(12)
                            .textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                            // the mock's padding (9, 11) inside its edge of 1 point
                            .padding(.horizontal, 12)
                            .padding(.vertical, 10)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(Theme.code, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                            .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(Theme.line))
                    }
                    if line.notInMind {
                        HStack(alignment: .top, spacing: 8) {
                            Image(systemName: "icloud.slash").font(.system(size: 12, weight: .regular)).foregroundStyle(Theme.warnText).padding(.top, 2)
                            Text("Not yet in the mind. It waits in the bridge’s queue and goes when the connection is back.")
                                .lineHeight(1.45, size: 12)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        .font(.system(size: 12))
                        .padding(.horizontal, 11)
                        .padding(.vertical, 10)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Theme.warnWash, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(Theme.warnEdge))
                    }
                    let thing = line.thing.flatMap { id in state.things.first { $0.id == id } }
                    if let thing {
                        thingControl(thing)
                    }
                    HStack(spacing: 6) {
                        if let thing, state.approvals[thing.id] != nil {
                            Button("End the Approval") { actions.endApproval(thing) }
                                .buttonStyle(SettingsLook.button)
                                .accessibilityIdentifier("log.endApproval")
                        }
                        Button("Copy Event") { actions.copy(LogWords.json(of: line)) }
                            .buttonStyle(SettingsLook.button)
                            .accessibilityIdentifier("log.copy")
                    }
                }
                .padding(14)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        } else {
            VStack {
                Text("Choose an event to see its fields.").font(.system(size: 12)).foregroundStyle(Theme.t3)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func thingControl(_ thing: Shareable) -> some View {
        let sharing = state.sharing[thing.id, default: .off]
        return VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 8) {
                Text(thing.title).font(.system(size: 12)).lineLimit(1).truncationMode(.tail)
                Spacer(minLength: 0)
                SharingControl(
                    id: thing.id, title: thing.title, selection: sharing, choose: { actions.choose(thing, $0) }, identifier: "log.sharing", segmentWidth: 42)
            }
            if let until = state.approvals[thing.id] {
                Text("Approved until \(Lend.shortClock(until))").font(.system(size: 11.5)).foregroundStyle(Theme.accentText)
            }
        }
        .padding(.top, 2)
    }

    // MARK: - The foot

    private var footer: some View {
        HStack(spacing: 10) {
            Text("Keys and moves are in no log unless you keep them. A refused use is no act and is not listed.")
                .font(.system(size: 11))
                .foregroundStyle(Theme.t3)
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: 8)
            Toggle("Show each act on the screen", isOn: $acts.showsPill)
                .toggleStyle(.checkbox)
                .font(.system(size: 12))
                .fixedSize()
                .accessibilityIdentifier("log.showsPill")
        }
    }
}

/// One row: the time, the thing's icon (red while an act runs, when it failed, for a watch and
/// the record), the title and the detail, the orange cloud while it is not yet in the mind, the
/// type, and how long an act took.
private struct LogRow: View {
    let line: LogLine
    let isSelected: Bool

    var body: some View {
        HStack(alignment: .center, spacing: 9) {
            Text(line.time).font(.system(size: 11).monospacedDigit()).foregroundStyle(Theme.t3).frame(width: 52, alignment: .leading)
            Image(systemName: line.symbol)
                .font(.system(size: 12, weight: .regular))
                .frame(width: 14)
                .foregroundStyle(line.isRed ? Theme.liveText : Theme.t2)
            VStack(alignment: .leading, spacing: 0) {
                Text(line.title).font(.system(size: 12.5)).lineHeight(1.3, size: 12.5).lineLimit(1).truncationMode(.tail)
                if let detail = line.detail {
                    Text(detail)
                        .font(line.detailIsCode ? .system(size: 10.5, design: .monospaced) : .system(size: 11.5))
                        .lineHeight(1.3, size: line.detailIsCode ? 10.5 : 11.5)
                        .foregroundStyle(Theme.t3)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
            }
            .layoutPriority(1)
            Spacer(minLength: 0)
            if line.notInMind {
                Image(systemName: "icloud.slash").font(.system(size: 11, weight: .regular)).foregroundStyle(Theme.warnText)
                    .help("Not yet in the mind: it goes when the connection is back")
            }
            Text(line.type).font(.system(size: 10.5, design: .monospaced)).foregroundStyle(Theme.t3).lineLimit(1)
            Text(line.took ?? "").font(.system(size: 11).monospacedDigit()).foregroundStyle(Theme.t3).frame(width: 30, alignment: .trailing)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .frame(minHeight: 36)
        .background(isSelected ? Theme.block : .clear, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
        .accessibilityIdentifier("log.row")
    }
}

// MARK: - The drawing

extension ActivityWindowView {
    /// The drawings' context: the panel's sample acts, a command that runs and is not yet in the
    /// mind, and the events of the last ten minutes around them.
    static func sampleEvents() -> [[String: Any]] {
        let now = Rendering.now
        let iso = { (seconds: TimeInterval) in now.addingTimeInterval(seconds).ISO8601Format() }
        let slot = (now.timeIntervalSince1970 / 30).rounded(.down) * 30 - 30
        let events: [(String, [String: Any], TimeInterval)] = [
            ("device/app-focused", ["app": "Ghostty", "bundle": "com.mitchellh.ghostty", "title": "my project"], -2),
            ("record/slot-stored", ["t": slot, "tracks": ["screen-1": ["kind": "video"], "camera-0": ["kind": "video"], "mic-0": ["kind": "audio"], "speaker-0": ["kind": "audio"]]], -11),
            ("device/input-submitted", ["id": "20261124T140141Z-3fa9", "text": "Open the roadmap on Misha’s computer", "at": iso(-30), "files": [["name": "Roadmap.pdf"], ["name": "Notes.md"]]], -30),
            ("device/act-ended", ["act": "sample-7", "did": "Took a picture of the display “Built-in Retina Display”"], -42),
            ("device/window-read", ["app": "Ghostty", "title": "my project", "trigger": "click", "text": "~/src/app main\n$ git status --short"], -59),
            ("device/act-ended", ["act": "sample-6", "did": "Listened to the microphone for 5 s"], -90),
            ("device/live-watch-ended", ["watcher": "w1", "who": "Misha", "seconds": 184, "why": "the owner ended it"], -189),
            ("device/presence-changed", ["state": "active", "idleSeconds": 0, "was": "idle"], -211),
            ("device/act-ended", ["act": "sample-5", "did": "Ran a command", "failure": "it ended with status 1"], -299),
            ("device/live-watch-started", ["watcher": "w1", "who": "Misha", "tracks": ["screen-1", "mic-0"]], -373),
            ("device/presence-changed", ["state": "idle", "idleSeconds": 120, "was": "active"], -531),
        ]
        return events.enumerated().map { index, event in
            ["type": event.0, "payload": event.1, "offset": 400 - index, "createdAt": iso(event.2)]
        }
    }

    /// The window's content, light and dark, into `folder` (`--render-log <folder>`): every event,
    /// the command that runs chosen, Commands on Ask with an approval.
    @MainActor
    static func render(to folder: URL) -> Bool {
        _ = NSApplication.shared
        Rendering.fixFaces()
        let acts = ActivityLog()
        ActivityLog.fillSample(acts, running: true)
        let log = ContextLog()
        log.startOf = { act in acts.rows.first { $0.act == act }.map { ($0.thing, $0.detail, $0.startedAt) } }
        log.fixForDrawing(sampleEvents())
        let state = PanelState()
        state.things = Rendering.things(["commands": .ask, "screen.1": .ask, "accessibility": .shared])
        state.sharing = Dictionary(uniqueKeysWithValues: state.things.map { ($0.id, $0.sharing) })
        state.approvals = ["commands": Rendering.now.addingTimeInterval(30 * 60)]
        let selected = acts.rows.first.map { LogWords.line($0) }
        var drawn = true
        for (dark, tone) in [(false, "light"), (true, "dark")] {
            let view = ActivityWindowView(acts: acts, log: log, state: state, selected: selected, isDrawing: true)
                .frame(width: ActivityWindow.size.width, height: ActivityWindow.size.height)
            drawn = Rendering.png(of: view, dark: dark, to: folder.appendingPathComponent("log-\(tone).png"), titled: true) && drawn
        }
        return drawn
    }
}
