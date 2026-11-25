import AppKit
import VoiceMeetCore

/// THE CONTROL SOCKET: `control.sock` in the app's home, for a test on this Mac with no hand
/// (README, "Testing with no hand"). Only a copy with a home of its own opens it (`AppEnvironment`):
/// the installed app never has one, so nothing stands in for its Touch ID. It speaks as the local
/// endpoint does, one line of JSON a connection, but a mind never reaches it: the bridge lends none
/// of these calls.
///
/// - `capture.toggle`, `capture.mark {points}`, `input.toggle`: what ⌥⇧S, ink and ⌥⇧Space do.
/// - `dictation.start`, `dictation.stop`: a hold of fn (its release at least `DictationKey.hold`
///   after its press); `dictation.fn {down}`: fn down or up; `dictation.esc`: Esc.
/// - `listen.write`: what ⌥⇧W, "Paste the last transcript", does: the newest entry of the history
///   (a dictation, or a stretch of Always listen) is written (README, "Dictation").
/// - `approval.answer {allow, keep?}`: answers the Ask question that waits, as its panel's buttons
///   do, and no Touch ID is asked (`Approval.answersByControl`); `keep` approves for the chosen
///   time (`approval.minutes`), as "Approve for 30 Minutes" does.
/// - `ui.state`: the lend, the open windows and what each shows, the last acts, the record, the last
///   dictation's text.
/// - `ui.tree`: the accessibility tree of the app's own windows, read in this process (no
///   permission of macOS is needed for the app's own elements).
/// - `ui.press {id, label?}`, `ui.type {id, text, replace?}`: a press of a control, or text typed
///   into it (at its end, or in place of its text), by its accessibility identifier (and, for a
///   segmented control, the segment's label; for a pop-up button, the item's title).
/// - `ui.scroll {id}`: scrolls a list to its end, as a person does to read older rows.
/// - `ui.key {key, shift?, command?}`: a press of Tab, Return, Escape or a letter of the Edit
///   menu (`key`: "tab", "return", "escape", "a", "c", "v", "w", "x", "z") in the key window,
///   through the app as the keyboard's: so ⌘W reaches the main menu.
/// - `perf.reset {watchMain?}`: the counters and the main queue's longest delay start again from
///   zero; `watchMain` starts the watch of the main queue (it wakes the app 20 times a second, so
///   it is off until asked, and false stops it). `ui.state`'s `perf` has the figures (`Perf`).
/// - `perf.threads`: each thread of the app, its name and its time so far (`Perf.threads`), and the
///   description of the main run loop (its sources and timers).
@MainActor
final class ControlSocket {
    var state: () -> [String: Any] = { [:] }
    var toggleCapture: (() -> Void)?
    var markCapture: (([[Double]]) -> Void)?
    var toggleInput: () -> Void = {}
    var dictationPressed: () -> Void = {}
    var dictationReleased: () -> Void = {}
    var dictationFn: (Bool) -> Void = { _ in }
    var dictationEscape: () -> Void = {}
    var writeSaid: () -> Void = {}

    private let endpoint: LocalEndpoint
    private let approval: Approval
    private let mainWatch = MainStallWatch()

    init(socketURL: URL, approval: Approval) {
        endpoint = LocalEndpoint(socketURL: socketURL, log: "control")
        self.approval = approval
        approval.answersByControl = true
        Perf.isCounting = true
        endpoint.onRequest = { [weak self] method, parameters in try self?.answer(method, parameters) ?? [:] }
    }

    func start() {
        endpoint.start()
        countWakes()
    }

    /// The wakes of the main thread (`mainWakes`) and the events it is given (`events.<type>`), for
    /// `perf`: what wakes an idle copy.
    private func countWakes() {
        let observer = CFRunLoopObserverCreateWithHandler(nil, CFRunLoopActivity.afterWaiting.rawValue, true, 0) { _, _ in
            Perf.count("mainWakes")
        }
        CFRunLoopAddObserver(CFRunLoopGetMain(), observer, .commonModes)
        _ = NSEvent.addLocalMonitorForEvents(matching: .any) { event in
            Perf.count("events.\(event.type.rawValue)")
            return event
        }
    }

    /// SwiftUI makes its accessibility elements only while an assistive app asks for them, and
    /// such an app says so with this attribute: `ui.tree` needs them too. Before the first view.
    static func makeAccessibilityElements() {
        let enhanced = NSSelectorFromString("accessibilitySetEnhancedUserInterfaceAttribute:")
        if NSApp.responds(to: enhanced) { NSApp.perform(enhanced, with: NSNumber(value: true)) }
    }
    func stop() { endpoint.stop() }

    private func answer(_ method: String, _ parameters: [String: Any]) throws -> [String: Any] {
        switch method {
        case "capture.toggle":
            guard let toggleCapture else { throw EndpointRefusal("A capture needs macOS 15.") }
            toggleCapture()
        case "capture.mark":
            guard let markCapture, let points = parameters["points"] as? [[Double]] else { throw EndpointRefusal("capture.mark needs points: [[x, y], …].") }
            markCapture(points)
        case "input.toggle":
            toggleInput()
        case "dictation.start":
            dictationPressed()
        case "dictation.stop":
            dictationReleased()
        case "dictation.fn":
            guard let down = parameters["down"] as? Bool else { throw EndpointRefusal("dictation.fn needs down: true or false.") }
            dictationFn(down)
        case "dictation.esc":
            dictationEscape()
        case "listen.write":
            writeSaid()
        case "approval.answer":
            guard let allow = parameters["allow"] as? Bool else { throw EndpointRefusal("approval.answer needs allow: true or false.") }
            guard approval.answer(allow: allow, keep: parameters["keep"] as? Bool ?? false) else { throw EndpointRefusal("No question waits for an answer.") }
        case "ui.state":
            var answer = state()
            answer["windows"] = NSApp.windows.filter(\.isVisible).map { window -> [String: Any] in
                // the app's key window: a banner's panel says it is key to draw as one, and is not
                ["kind": String(describing: type(of: window)), "title": window.title, "key": window === NSApp.keyWindow, "frame": Self.rect(window.frame)]
            }
            answer["approval"] = approval.waiting.map { ["question": $0.question.words, "mind": $0.question.mind ?? NSNull()] as [String: Any] } ?? NSNull()
            var perf = Perf.figures().dictionary
            perf["counters"] = Perf.counters
            perf["mainStallMaxMs"] = mainWatch.isRunning ? mainWatch.maxMilliseconds : NSNull()
            answer["perf"] = perf
            return answer
        case "perf.reset":
            Perf.resetCounters()
            if let watch = parameters["watchMain"] as? Bool {
                if watch { mainWatch.start() } else { mainWatch.stop() }
            }
            mainWatch.reset()
            return ["figures": Perf.figures().dictionary]
        case "perf.threads":
            // the main run loop's description names its timers, their intervals and callouts
            return [
                "threads": Perf.threads().map { ["id": $0.id, "name": $0.name, "cpuMs": $0.cpuMs] },
                "mainRunLoop": CFCopyDescription(CFRunLoopGetMain()) as String,
            ]
        case "ui.key":
            guard let name = parameters["key"] as? String, let code = Self.keyCodes[name.lowercased()] else {
                throw EndpointRefusal("ui.key needs key: one of \(Self.keyCodes.keys.sorted().joined(separator: ", ")).")
            }
            // the key window, else the frontmost that can be one: a test copy is often not the
            // app in front (and none is while the screen is locked), and the keys are its window's
            let front = NSApp.windows.filter { $0.isVisible && $0.canBecomeKey }.min { $0.orderedIndex < $1.orderedIndex }
            guard let window = NSApp.keyWindow ?? front else {
                throw EndpointRefusal("No window of the app can take a key now.")
            }
            var flags: NSEvent.ModifierFlags = []
            if parameters["shift"] as? Bool == true { flags.insert(.shift) }
            if parameters["command"] as? Bool == true { flags.insert(.command) }
            let event = { (type: NSEvent.EventType) in
                NSEvent.keyEvent(
                    with: type, location: .zero, modifierFlags: flags, timestamp: ProcessInfo.processInfo.systemUptime,
                    windowNumber: window.windowNumber, context: nil, characters: code.characters, charactersIgnoringModifiers: code.characters,
                    isARepeat: false, keyCode: code.keyCode)
            }
            guard let down = event(.keyDown), let up = event(.keyUp) else { throw EndpointRefusal("The key event could not be made.") }
            let answer: [String: Any] = ["window": String(describing: type(of: window)), "title": window.title]
            // as AppKit takes a key: the window's key equivalents (a default button, a shortcut),
            // then the main menu's, then the first responder's keyDown
            if window.performKeyEquivalent(with: down) { return answer.merging(["by": "window"]) { $1 } }
            if !flags.isEmpty, let item = Self.menuItem(for: down, in: NSApp.mainMenu), let action = item.action {
                var responder: NSResponder? = window.firstResponder ?? window
                while let next = responder, !next.responds(to: action) { responder = next.nextResponder }
                guard let target = responder ?? (window.responds(to: action) ? window : nil) else {
                    throw EndpointRefusal("Nothing in \(window.title) takes \(item.title).")
                }
                NSApp.sendAction(action, to: target, from: item)
                return answer.merging(["by": "menu", "item": item.title]) { $1 }
            }
            window.sendEvent(down)
            window.sendEvent(up)
            return answer.merging(["by": "keyDown"]) { $1 }
        case "ui.tree":
            var budget = parameters["maxNodes"] as? Int ?? 4_000
            return ["windows": NSApp.windows.filter(\.isVisible).map { Self.node($0, depth: 0, budget: &budget) }]
        case "ui.press":
            let element = try find(parameters)
            if let choice = element as? PopUpChoice {
                // as a pick in the open menu: the item's own action, then the button's
                choice.popUp.select(choice.item)
                if let menu = choice.popUp.menu { menu.performActionForItem(at: menu.index(of: choice.item)) }
                return [:]
            }
            guard Self.bool(element, "accessibilityEnabled") != false else { throw EndpointRefusal("\(Self.name(of: element)) is disabled.") }
            // what a press answers is not to be trusted: the menu bar's button answers no and opens
            if element.responds(to: NSSelectorFromString("accessibilityPerformPress")) {
                _ = element.perform(NSSelectorFromString("accessibilityPerformPress"))
            } else if let control = element as? NSControl {
                control.performClick(nil)
            } else {
                throw EndpointRefusal("\(Self.name(of: element)) takes no press.")
            }
        case "ui.scroll":
            // a scroll of a list to its end, as a person's: a lazy list makes its last rows then
            let element = try find(parameters)
            guard let scroll = Self.scrollView(under: element) else { throw EndpointRefusal("\(Self.name(of: element)) does not scroll.") }
            guard let document = scroll.documentView else { return [:] }
            let clip = scroll.contentView
            let end = document.isFlipped ? max(0, document.bounds.height - clip.bounds.height) : 0
            clip.scroll(to: NSPoint(x: clip.bounds.minX, y: end))
            scroll.reflectScrolledClipView(clip)
            return ["height": Double(document.bounds.height)]
        case "ui.type":
            guard let text = parameters["text"] as? String else { throw EndpointRefusal("ui.type needs text.") }
            let element = try find(parameters)
            let replace = parameters["replace"] as? Bool ?? false
            if let field = element as? NSTextView {
                field.window?.makeFirstResponder(field)
                field.insertText(text, replacementRange: replace ? NSRange(location: 0, length: field.string.utf16.count) : field.selectedRange())
            } else if let field = (element as? NSTextField) ?? Self.textField(under: element) {
                // as typing does: through the field editor, so that a SwiftUI binding hears it; a
                // window that is not key has none, and its field's delegate hears the change instead
                if field.window?.makeFirstResponder(field) == true, let editor = field.currentEditor() as? NSTextView {
                    let length = editor.string.utf16.count
                    editor.insertText(text, replacementRange: replace ? NSRange(location: 0, length: length) : NSRange(location: length, length: 0))
                } else {
                    field.stringValue = replace ? text : field.stringValue + text
                    field.delegate?.controlTextDidChange?(Notification(name: NSControl.textDidChangeNotification, object: field))
                }
            } else if element.responds(to: NSSelectorFromString("setAccessibilityValue:")) {
                _ = element.perform(NSSelectorFromString("setAccessibilityValue:"), with: text)
            } else {
                throw EndpointRefusal("\(Self.name(of: element)) takes no text.")
            }
        default:
            throw EndpointRefusal(
                "No method \"\(method)\". The methods are: ui.state, ui.tree, ui.press, ui.type, ui.scroll, ui.key, perf.reset, input.toggle, capture.toggle, capture.mark, dictation.start, dictation.stop, dictation.fn, dictation.esc, listen.write, approval.answer.")
        }
        return [:]
    }

    /// The item of the main menu that a key with ⌘ is, as the menu's own key matching finds it.
    private static func menuItem(for event: NSEvent, in menu: NSMenu?) -> NSMenuItem? {
        guard let menu else { return nil }
        let wanted = event.modifierFlags.intersection([.command, .shift, .option, .control])
        for item in menu.items {
            if let found = menuItem(for: event, in: item.submenu) { return found }
            guard !item.keyEquivalent.isEmpty, item.isEnabled || item.action != nil else { continue }
            // an upper-case key equivalent is the key with ⇧
            let isShifted = item.keyEquivalent != item.keyEquivalent.lowercased()
            let modifiers = item.keyEquivalentModifierMask.union(isShifted ? .shift : [])
            if item.keyEquivalent.lowercased() == event.charactersIgnoringModifiers?.lowercased(), modifiers == wanted { return item }
        }
        return nil
    }

    /// The keys `ui.key` presses: their virtual key codes and characters.
    private static let keyCodes: [String: (keyCode: UInt16, characters: String)] = [
        "tab": (48, "\t"), "return": (36, "\r"), "escape": (53, "\u{1b}"),
        "a": (0, "a"), "c": (8, "c"), "v": (9, "v"), "w": (13, "w"), "x": (7, "x"), "z": (6, "z"),
    ]

    // MARK: - The app's own accessibility elements

    // An element is an NSObject that answers the getters of NSAccessibility: a window, a view, a
    // cell, or SwiftUI's own kind, which Swift does not see as of that protocol. So each attribute
    // is read by its key, after a check that the element has it.

    /// The element whose identifier is `id`; with `label`, the one under it with that label.
    private func find(_ parameters: [String: Any]) throws -> NSObject {
        guard let id = parameters["id"] as? String else { throw EndpointRefusal("ui.press and ui.type need the id of a control.") }
        guard let element = Self.first(in: NSApp.windows.filter(\.isVisible), where: { Self.read($0, "accessibilityIdentifier") as? String == id }) else {
            throw EndpointRefusal("No control with the id \"\(id)\" is on the screen now.")
        }
        guard let label = parameters["label"] as? String else { return element }
        if let part = Self.first(in: Self.children(of: element), where: { Self.label(of: $0) == label }) { return part }
        // a pop-up button lists its items only while it is open: its item is chosen by its title
        if let popUp = Self.popUp(element), let item = popUp.itemArray.first(where: { $0.title.caseInsensitiveCompare(label) == .orderedSame }) {
            return PopUpChoice(popUp: popUp, item: item)
        }
        throw EndpointRefusal("\"\(id)\" has nothing labelled \"\(label)\".")
    }

    /// The AppKit text field that a SwiftUI element stands for: the one of its window at its frame.
    private static func textField(under element: NSObject) -> NSTextField? {
        guard let frame = (read(element, "accessibilityFrame") as? NSValue)?.rectValue else { return nil }
        func search(_ view: NSView) -> NSTextField? {
            if let field = view as? NSTextField, field.isEditable, let window = field.window {
                let onScreen = window.convertToScreen(field.convert(field.bounds, to: nil))
                if onScreen.intersects(frame), abs(onScreen.midY - frame.midY) < 8 { return field }
            }
            for child in view.subviews { if let found = search(child) { return found } }
            return nil
        }
        for window in NSApp.windows where window.isVisible {
            if let content = window.contentView, let found = search(content) { return found }
        }
        return nil
    }

    /// The scroll view that an element stands for: the element, or the one of its window at its frame.
    private static func scrollView(under element: NSObject) -> NSScrollView? {
        if let scroll = element as? NSScrollView { return scroll }
        guard let frame = (read(element, "accessibilityFrame") as? NSValue)?.rectValue else { return nil }
        func search(_ view: NSView) -> NSScrollView? {
            if let scroll = view as? NSScrollView, let window = scroll.window {
                let onScreen = window.convertToScreen(scroll.convert(scroll.bounds, to: nil))
                if abs(onScreen.midX - frame.midX) < 8, abs(onScreen.midY - frame.midY) < 8 { return scroll }
            }
            for child in view.subviews { if let found = search(child) { return found } }
            return nil
        }
        for window in NSApp.windows where window.isVisible {
            if let content = window.contentView, let found = search(content) { return found }
        }
        return nil
    }

    /// The pop-up button of an element: the element, its view or its cell's.
    private static func popUp(_ element: NSObject) -> NSPopUpButton? {
        if let popUp = element as? NSPopUpButton { return popUp }
        if let cell = element as? NSCell, let popUp = cell.controlView as? NSPopUpButton { return popUp }
        if let view = element as? NSView { return view.subviews.lazy.compactMap { $0 as? NSPopUpButton }.first }
        return nil
    }

    private static func first(in elements: [NSObject], where matches: (NSObject) -> Bool) -> NSObject? {
        for element in elements {
            if matches(element) { return element }
            if let found = first(in: children(of: element), where: matches) { return found }
        }
        return nil
    }

    /// One attribute, by its getter's name (`accessibilityRole`), or nil when the element has none.
    private static func read(_ element: NSObject, _ key: String) -> Any? {
        guard element.responds(to: NSSelectorFromString(key)) else { return nil }
        return element.value(forKey: key)
    }

    /// A yes-or-no attribute, by its key (`accessibilityEnabled` reads `isAccessibilityEnabled`).
    private static func bool(_ element: NSObject, _ key: String) -> Bool? {
        let getter = "is" + key.prefix(1).uppercased() + key.dropFirst()
        guard element.responds(to: NSSelectorFromString(getter)) else { return nil }
        return element.value(forKey: key) as? Bool
    }

    /// A window that shows no child, and a view with no role of its own (both the menu bar's),
    /// have their views as their children.
    private static func children(of element: NSObject) -> [NSObject] {
        let children = (read(element, "accessibilityChildren") as? [Any] ?? []).compactMap { $0 as? NSObject }
        guard children.isEmpty else { return children }
        if let window = element as? NSWindow { return window.contentView.map { [$0] } ?? [] }
        guard let view = element as? NSView, (read(view, "accessibilityRole") as? String ?? "AXUnknown") == "AXUnknown" else { return [] }
        return view.subviews
    }

    private static func label(of element: NSObject) -> String? {
        ["accessibilityLabel", "accessibilityTitle"].compactMap { read(element, $0) as? String }.first { !$0.isEmpty }
    }

    private static func name(of element: NSObject) -> String {
        "\(read(element, "accessibilityRole") as? String ?? "an element") \(read(element, "accessibilityIdentifier") as? String ?? "")"
    }

    private static func node(_ element: NSObject, depth: Int, budget: inout Int) -> [String: Any] {
        budget -= 1
        var node: [String: Any] = ["role": read(element, "accessibilityRole") as? String ?? ""]
        if let frame = read(element, "accessibilityFrame") as? NSValue { node["frame"] = rect(frame.rectValue) }
        if let id = read(element, "accessibilityIdentifier") as? String, !id.isEmpty { node["id"] = id }
        if let label = label(of: element) { node["label"] = label }
        if let value = read(element, "accessibilityValue") {
            if let text = value as? String { node["value"] = text } else if let number = value as? NSNumber { node["value"] = number }
        }
        if bool(element, "accessibilityEnabled") == false { node["enabled"] = false }
        let children = children(of: element)
        if !children.isEmpty, depth < 40, budget > 0 {
            var list: [[String: Any]] = []
            for child in children where budget > 0 { list.append(Self.node(child, depth: depth + 1, budget: &budget)) }
            node["children"] = list
        }
        return node
    }

    private static func rect(_ rect: NSRect) -> [Double] {
        [rect.minX, rect.minY, rect.width, rect.height].map { Double($0.rounded()) }
    }
}

/// An item of a pop-up button, for `ui.press {id, label}`: it is selected as a click on it would.
private final class PopUpChoice: NSObject {
    let popUp: NSPopUpButton
    let item: NSMenuItem

    init(popUp: NSPopUpButton, item: NSMenuItem) {
        self.popUp = popUp
        self.item = item
    }
}
