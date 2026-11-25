// A start of AppKit with nothing of the app, for a failed idle check (harness/run.mjs): its
// wake-ups each second, as JSON lines. `plain`: no view; `status`: a status item with a title;
// `swiftui`: a status item with a SwiftUI view. Built with swiftc when needed.

import AppKit
import SwiftUI

let variant = CommandLine.arguments.dropFirst().first ?? "plain"
let app = NSApplication.shared
app.setActivationPolicy(.accessory)
var item: NSStatusItem?
var mainWakes = 0
let observer = CFRunLoopObserverCreateWithHandler(nil, CFRunLoopActivity.afterWaiting.rawValue, true, 0) { _, _ in mainWakes += 1 }
CFRunLoopAddObserver(CFRunLoopGetMain(), observer, .commonModes)
if variant != "plain" {
    item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    if variant == "swiftui" {
        let host = NSHostingView(rootView: Text("it").padding(2))
        host.frame = NSRect(x: 0, y: 0, width: 24, height: 22)
        item?.button?.addSubview(host)
        item?.length = 24
    } else {
        item?.button?.title = "it"
    }
}
func wakeups() -> UInt64 {
    var info = rusage_info_v4()
    _ = withUnsafeMutablePointer(to: &info) { $0.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { proc_pid_rusage(getpid(), RUSAGE_INFO_V4, $0) } }
    return info.ri_interrupt_wkups
}
let started = Date()
var last = wakeups(), lastMain = 0
let timer = DispatchSource.makeTimerSource(queue: .global())
timer.schedule(deadline: .now() + 1, repeating: 1)
timer.setEventHandler {
    let now = wakeups()
    DispatchQueue.main.async {
        print("{\"variant\":\"\(variant)\",\"s\":\(Int(Date().timeIntervalSince(started).rounded())),\"wakeups\":\(now - last),\"mainWakes\":\(mainWakes - lastMain)}")
        fflush(stdout)
        last = now; lastMain = mainWakes
        if Date().timeIntervalSince(started) > 14 { exit(0) }
    }
}
timer.resume()
app.run()
