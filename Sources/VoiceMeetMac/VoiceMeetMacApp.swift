import AppKit

@main
enum VoiceMeetMacApp {
    @MainActor
    static func main() {
        // A write to a pipe whose reader is gone (a bridge's stdin, a command's) fails with EPIPE
        // and ends nothing: the default action of SIGPIPE would end the app with no report.
        signal(SIGPIPE, SIG_IGN)
        // A copy started only to answer one question (Permissions.swift): it opens nothing.
        if CommandLine.arguments.contains(Permission.checkScreenRecordingArgument) {
            exit(CGPreflightScreenCaptureAccess() ? 0 : 1)
        }
        if AppEnvironment.current.isRendering {
            Rendering.fixSystemSettings()
            // the drawing's own home in the temporary folder goes with it, at every exit
            atexit { try? FileManager.default.removeItem(at: AppEnvironment.current.folder) }
        }
        // Every view, light and dark, for the snapshot check: `--render-all <folder>` (Rendering.swift).
        if let flag = CommandLine.arguments.firstIndex(of: "--render-all"), CommandLine.arguments.indices.contains(flag + 1) {
            exit(Rendering.renderAll(to: URL(fileURLWithPath: CommandLine.arguments[flag + 1])) ? 0 : 1)
        }
        // A copy started only to draw the panel to a PNG file, for a look at it with no click.
        if let flag = CommandLine.arguments.firstIndex(of: "--render-panel"), CommandLine.arguments.indices.contains(flag + 1) {
            // an optional third word draws that phase (`Panel.renderPhases`): the lend's (live, reconnecting,
            // stopped, not-allowed, incompatible), or the panel's own (ringing, busy, blocked, activity, no-mind)
            let phase = CommandLine.arguments.indices.contains(flag + 2) ? CommandLine.arguments[flag + 2] : nil
            exit(Panel.render(to: URL(fileURLWithPath: CommandLine.arguments[flag + 1]), phase: phase) ? 0 : 1)
        }
        // The mind switcher, closed and open, light and dark: `--render-switcher <folder>`.
        if let flag = CommandLine.arguments.firstIndex(of: "--render-switcher"), CommandLine.arguments.indices.contains(flag + 1) {
            exit(MindSwitcher.render(to: URL(fileURLWithPath: CommandLine.arguments[flag + 1])) ? 0 : 1)
        }
        // The activity pill and the panel's activity list, with sample acts: `--render-activity <folder>`.
        if let flag = CommandLine.arguments.firstIndex(of: "--render-activity"), CommandLine.arguments.indices.contains(flag + 1) {
            exit(ActivityLog.render(to: URL(fileURLWithPath: CommandLine.arguments[flag + 1])) ? 0 : 1)
        }
        // The capture's pill while it records, light and dark: `--render-capture <folder>`.
        if let flag = CommandLine.arguments.firstIndex(of: "--render-capture"), CommandLine.arguments.indices.contains(flag + 1) {
            exit(CapturePillView.render(to: URL(fileURLWithPath: CommandLine.arguments[flag + 1])) ? 0 : 1)
        }
        // The same for the forms of the mind menu: Add a Mind, and Remove.
        if let flag = CommandLine.arguments.firstIndex(of: "--render-add-mind"), CommandLine.arguments.indices.contains(flag + 1) {
            // an optional third word is the name in the field, to see its check
            let name = CommandLine.arguments.indices.contains(flag + 2) ? CommandLine.arguments[flag + 2] : "jane.mac"
            let form = AddMindForm(profiles: ["example.com", "example.org"], name: name, add: { _, _ in }, cancel: {})
            exit(FormWindow.render(form, to: URL(fileURLWithPath: CommandLine.arguments[flag + 1])) ? 0 : 1)
        }
        if let flag = CommandLine.arguments.firstIndex(of: "--render-remove-mind"), CommandLine.arguments.indices.contains(flag + 1) {
            let form = RemoveMindForm(mind: "example.com", isActive: true, remove: {}, cancel: {})
            exit(FormWindow.render(form, to: URL(fileURLWithPath: CommandLine.arguments[flag + 1])) ? 0 : 1)
        }
        // The input bar (empty, listening, filled, sending, not sent) and the dictation pill, light
        // and dark: `--render-input <folder>`.
        if let flag = CommandLine.arguments.firstIndex(of: "--render-input"), CommandLine.arguments.indices.contains(flag + 1) {
            let folder = URL(fileURLWithPath: CommandLine.arguments[flag + 1])
            exit(MindInput.render(to: folder) && Dictation.render(to: folder) ? 0 : 1)
        }
        // The Settings window's pages (general, dictation, a mind lent, a mind whose own word list
        // fails), light and dark: `--render-settings <folder>`.
        if let flag = CommandLine.arguments.firstIndex(of: "--render-settings"), CommandLine.arguments.indices.contains(flag + 1) {
            exit(SettingsView.render(to: URL(fileURLWithPath: CommandLine.arguments[flag + 1])) ? 0 : 1)
        }
        // The Ask question, light and dark: `--render-approval <folder>`.
        if let flag = CommandLine.arguments.firstIndex(of: "--render-approval"), CommandLine.arguments.indices.contains(flag + 1) {
            exit(ApprovalWindow.render(to: URL(fileURLWithPath: CommandLine.arguments[flag + 1])) ? 0 : 1)
        }
        // The Activity window with every event, light and dark: `--render-log <folder>`.
        if let flag = CommandLine.arguments.firstIndex(of: "--render-log"), CommandLine.arguments.indices.contains(flag + 1) {
            exit(ActivityWindowView.render(to: URL(fileURLWithPath: CommandLine.arguments[flag + 1])) ? 0 : 1)
        }
        // The menu-bar mark and the mind's face in each state: `--render-icons <folder>`.
        if let flag = CommandLine.arguments.firstIndex(of: "--render-icons"), CommandLine.arguments.indices.contains(flag + 1) {
            exit(IterateIcon.render(to: URL(fileURLWithPath: CommandLine.arguments[flag + 1])) ? 0 : 1)
        }
        // A sample banner: `--render-banner <file> ring|request|notice [dark]`; `--render-ring <file> [dark]`
        // is the ring's.
        for flag in ["--render-banner", "--render-ring"] {
            guard let at = CommandLine.arguments.firstIndex(of: flag), CommandLine.arguments.indices.contains(at + 1) else { continue }
            let words = Array(CommandLine.arguments[(at + 2)...])
            let kind = flag == "--render-ring" ? "ring" : words.first ?? "notice"
            exit(BannerWindow.render(kind, to: URL(fileURLWithPath: CommandLine.arguments[at + 1]), dark: words.contains("dark")) ? 0 : 1)
        }
        // AVFoundation reports some mistakes as Objective-C exceptions. The log gets the reason.
        NSSetUncaughtExceptionHandler { exception in
            AppLog("app").error("uncaught exception \(exception.name.rawValue): \(exception.reason ?? "no reason")")
        }
        let application = NSApplication.shared
        let delegate = AppDelegate()
        application.delegate = delegate
        // A menu-bar-only app: no Dock icon and no window. Info.plist says the same (LSUIElement).
        application.setActivationPolicy(.accessory)
        withExtendedLifetime(delegate) {
            application.run()
        }
    }
}
