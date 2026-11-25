import AppKit
import SwiftUI
import VoiceMeetCore

// THE DICTATIONS VIEW: the Activity window's third mode (`ActivityWindowView.Mode.dictations`),
// the history of transcripts on this Mac (`History`), newest first. A row is its time, the app it
// went into, and its text in two lines (all of it when chosen), with Copy and Paste. At the right,
// the chosen entry's fields. The list is lazy: only the rows on the screen are made, of up to
// 2,000. It is a mode of the Activity window, not a window of its own: the window has the switch,
// the search and the pane at the right that this view needs, and the person finds it where the
// rest of what happened on this Mac is.

/// The middle of the Activity window in its Dictations mode: the list and the chosen entry.
struct DictationsView: View {
    @ObservedObject var history: History
    let search: String
    @Binding var selected: String?
    let actions: ActivityWindowActions
    /// The time the rows are told against: now, or a drawing's.
    var now = Date()

    var body: some View {
        let entries = history.history.shown(search: search)
        let chosen = selected.flatMap { id in entries.first { $0.id == id } }
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 0) {
                header(shown: entries.count, count: history.history.entries.count)
                list(entries)
            }
            .frame(maxWidth: .infinity)
            Theme.line.frame(width: 1)
            details(chosen)
                .frame(width: 285)
        }
    }

    private func header(shown: Int, count: Int) -> some View {
        let all = count == 1 ? "1 transcript on this Mac" : "\(count) transcripts on this Mac"
        return HStack(spacing: 8) {
            Text(shown == count ? all : "\(shown) of \(all)")
                .font(.system(size: 11))
                .foregroundStyle(Theme.t2)
                .accessibilityIdentifier("dictations.count")
            Spacer(minLength: 10)
            if !history.keeps {
                HStack(spacing: 6) {
                    Circle().fill(Theme.warn).frame(width: 7, height: 7)
                    Text("Not kept")
                }
                .font(.system(size: 11))
                .foregroundStyle(Theme.warnText)
                .help("Settings › Dictation keeps no history: new transcripts do not come here")
            }
        }
        .padding(.leading, 22)
        .padding(.trailing, 14)
        .padding(.top, 9)
        .padding(.bottom, 5)
    }

    private func list(_ entries: [TranscriptEntry]) -> some View {
        ScrollView(.vertical) {
            LazyVStack(alignment: .leading, spacing: 1) {
                ForEach(entries) { entry in
                    DictationRow(
                        entry: entry, time: Self.time(entry.at, now: now), icon: history.icon(entry.bundle), isSelected: entry.id == selected,
                        copy: { actions.copy(entry.text) }, paste: { actions.paste(entry.text) }
                    )
                    .onTapGesture { selected = entry.id == selected ? nil : entry.id }
                }
                if entries.isEmpty {
                    Text(emptyWords).font(.system(size: 11)).foregroundStyle(Theme.t3).padding(.horizontal, 8).padding(.vertical, 8)
                }
            }
            .padding(.horizontal, 14)
            .padding(.bottom, 12)
        }
        .accessibilityIdentifier("dictations.list")
    }

    private var emptyWords: String {
        if !search.trimmingCharacters(in: .whitespaces).isEmpty { return "No transcript has these words." }
        if !history.keeps { return "Settings › Dictation keeps no history." }
        return "No transcript yet. Each dictation comes here, and each stretch of Always listen."
    }

    @ViewBuilder
    private func details(_ entry: TranscriptEntry?) -> some View {
        if let entry {
            ScrollView(.vertical) {
                VStack(alignment: .leading, spacing: 12) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(entry.kind == .stretch ? "Always listen" : entry.app ?? "Dictation")
                            .font(.system(size: 14, weight: .semibold)).lineHeight(1.3, size: 14).fixedSize(horizontal: false, vertical: true)
                        Text(Self.longTime(entry.at)).font(.system(size: 11, design: .monospaced)).foregroundStyle(Theme.t3).lineLimit(1)
                    }
                    Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 10, verticalSpacing: 4) {
                        ForEach(Self.fields(of: entry), id: \.0) { key, value in
                            GridRow {
                                Text(key).font(.system(size: 12)).lineHeight(1.45, size: 12).foregroundStyle(Theme.t3).frame(width: 52, alignment: .leading)
                                Text(value).font(.system(size: 11.5, design: .monospaced)).lineLimit(2).truncationMode(.middle).textSelection(.enabled)
                            }
                        }
                    }
                    Text(entry.text.isEmpty ? "No words." : entry.text)
                        .font(.system(size: 12.5))
                        .lineHeight(1.45, size: 12.5)
                        .foregroundStyle(entry.text.isEmpty ? Theme.t3 : Theme.t1)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 10)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Theme.code, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(Theme.line))
                        .accessibilityIdentifier("dictations.text")
                    HStack(spacing: 6) {
                        Button("Copy") { actions.copy(entry.text) }
                            .buttonStyle(SettingsLook.button)
                            .accessibilityIdentifier("dictations.chosen.copy")
                        Button("Paste") { actions.paste(entry.text) }
                            .buttonStyle(SettingsLook.button)
                            .help("Writes it where the cursor is, in the app you were in before this window")
                            .accessibilityIdentifier("dictations.chosen.paste")
                    }
                    .disabled(entry.text.isEmpty)
                }
                .padding(14)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        } else {
            VStack {
                Text("Choose a transcript to see all of it.").font(.system(size: 12)).foregroundStyle(Theme.t3)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    static func fields(of entry: TranscriptEntry) -> [(String, String)] {
        var fields: [(String, String)] = []
        if let bundle = entry.bundle { fields.append(("bundle", bundle)) }
        if let window = entry.window { fields.append(("window", window)) }
        fields.append(("how", outcomeWords(entry)))
        if let model = entry.model { fields.append(("model", model)) }
        fields.append(("words", "\(entry.words) in \(String(format: "%.1f", entry.seconds)) s"))
        return fields
    }

    static func outcomeWords(_ entry: TranscriptEntry) -> String {
        switch entry.outcome {
        case .written: "written"
        case .heardNothing: "heard no words"
        case .cancelled: "cancelled with Esc"
        case .failed: "failed before it was written"
        case .heard: "heard with no key"
        }
    }

    // MARK: - Times

    /// A drawing's times are the same on every Mac: UTC.
    private static var zone: TimeZone { AppEnvironment.current.isRendering ? TimeZone(identifier: "UTC")! : .current }

    private static func formatter(_ format: String) -> DateFormatter {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_GB")
        formatter.timeZone = zone
        formatter.setLocalizedDateFormatFromTemplate(format)
        return formatter
    }

    private static let clock = formatter("HH:mm")
    private static let day = formatter("d MMM")
    private static let long = formatter("EEE d MMM HH:mm:ss")

    /// The row's time: the time of day today, else the day.
    static func time(_ at: Double, now: Date) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = zone
        let date = Date(timeIntervalSince1970: at)
        return calendar.isDate(date, inSameDayAs: now) ? clock.string(from: date) : day.string(from: date)
    }

    static func longTime(_ at: Double) -> String { long.string(from: Date(timeIntervalSince1970: at)) }
}

/// One row: the time, the app's icon, the app and how it ended, the text, Copy and Paste.
private struct DictationRow: View {
    let entry: TranscriptEntry
    let time: String
    let icon: NSImage?
    let isSelected: Bool
    let copy: () -> Void
    let paste: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 9) {
            Text(time).font(.system(size: 11).monospacedDigit()).foregroundStyle(Theme.t3).frame(width: 52, alignment: .leading)
                .padding(.top, 1)
            Group {
                if let icon {
                    Image(nsImage: icon).resizable().interpolation(.high)
                } else {
                    Image(systemName: entry.kind == .stretch ? "ear" : "waveform").font(.system(size: 12, weight: .regular)).foregroundStyle(Theme.t2)
                }
            }
            .frame(width: 16, height: 16)
            VStack(alignment: .leading, spacing: 1) {
                Text(source).font(.system(size: 11)).foregroundStyle(entry.outcome == .cancelled || entry.outcome == .failed ? Theme.warnText : Theme.t3)
                    .lineLimit(1).truncationMode(.tail)
                Text(entry.text.isEmpty ? "No words" : entry.text)
                    .font(.system(size: 12.5))
                    .lineHeight(1.3, size: 12.5)
                    .foregroundStyle(entry.text.isEmpty ? Theme.t3 : Theme.t1)
                    .lineLimit(isSelected ? nil : 2)
                    .truncationMode(.tail)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            HStack(spacing: 2) {
                button("doc.on.doc", "Copy", id: "dictations.copy", action: copy)
                button("text.insert", "Paste", id: "dictations.paste", action: paste)
            }
            .disabled(entry.text.isEmpty)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(isSelected ? Theme.block : .clear, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
        .contentShape(Rectangle())
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("dictations.row")
    }

    /// "Notes · cancelled with Esc", "Always listen".
    private var source: String {
        let from = entry.kind == .stretch ? "Always listen" : entry.app ?? "Dictation"
        return entry.outcome == .written || entry.outcome == .heard ? from : "\(from) · \(DictationsView.outcomeWords(entry))"
    }

    private func button(_ symbol: String, _ label: String, id: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 11, weight: .regular)).foregroundStyle(Theme.t2).frame(width: 24, height: 22)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(label == "Paste" ? "Paste: where the cursor is, in the app you were in before this window" : "Copy")
        .accessibilityLabel(label)
        .accessibilityIdentifier(id)
    }
}

extension DictationsView {
    /// The drawings' history: dictations into three apps, a stretch of Always listen, one cancelled
    /// with Esc, one that heard nothing, and one of yesterday.
    static func sample(now: Date) -> [TranscriptEntry] {
        let at = { (seconds: Double) in now.timeIntervalSince1970 + seconds }
        return [
            TranscriptEntry(
                id: "s1", kind: .dictation, outcome: .written, at: at(-26 * 3600), text: "Book the train to Leeds for Thursday morning.", app: "Notes",
                bundle: "com.apple.Notes", model: "parakeet-v3", seconds: 3.1),
            TranscriptEntry(
                id: "s2", kind: .dictation, outcome: .heardNothing, at: at(-3 * 3600), text: "", app: "Ghostty", bundle: "com.mitchellh.ghostty",
                model: "parakeet-v3", seconds: 0.8),
            TranscriptEntry(
                id: "s3", kind: .stretch, outcome: .heard, at: at(-41 * 60), text: "so the panel opens on the mind and the lend first, then what I do myself",
                model: "parakeet-v3", seconds: 5.2),
            TranscriptEntry(
                id: "s4", kind: .dictation, outcome: .cancelled, at: at(-17 * 60), text: "Tell Misha the roadmap moved to Friday, and that the second file is the newer one.",
                app: "Slack", bundle: "com.tinyspeck.slackmacgap", window: "Misha (DM) - iterate", model: "gpt-live-transcribe", seconds: 6.4),
            TranscriptEntry(
                id: "s5", kind: .dictation, outcome: .written, at: at(-4 * 60),
                text:
                    "Restart the bridge on the Beelink box, then tell me when it is live. If Herdr still shows the old workspace, close it and open the worktree again from the main checkout, and check that Doppler has the new key before you run the harness.",
                app: "Ghostty", bundle: "com.mitchellh.ghostty", window: "~/src/mac-app", model: "parakeet-v3", seconds: 14.2),
            TranscriptEntry(
                id: "s6", kind: .dictation, outcome: .written, at: at(-50), text: "Open the roadmap on Misha’s computer and tell him why.", app: "Slack",
                bundle: "com.tinyspeck.slackmacgap", window: "#design - iterate", model: "gpt-live-transcribe", seconds: 3.6),
        ]
    }
}
