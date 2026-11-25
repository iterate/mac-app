import AppKit

/// THE CONTROL SOCKET: `control.sock` in the app's home, for a test on this Mac with no hand
/// (README, "Testing with no hand"). Only a copy with a home of its own opens it (`AppEnvironment`):
/// the installed app never has one, so nothing stands in for its Touch ID. It speaks as the local
/// endpoint does, one line of JSON a connection, but a mind never reaches it: the bridge lends none
/// of these calls.
///
/// - `capture.toggle`, `capture.mark {points}`, `input.toggle`: what ⌥⇧S, ink and ⌥⇧Space do.
/// - `dictation.start`, `dictation.stop`: a hold of fn (its release at least `DictationKey.hold`
///   after its press); `dictation.fn {down}`: fn down or up; `dictation.esc`: Esc.
/// - `approval.answer {allow, keep?}`: answers the Ask question that waits, in place of the alert
///   and Touch ID (`Approval.answersByControl`); `keep` approves for 30 minutes, as "Approve for 30
///   Minutes" does.
/// - `ui.state`: the lend, the open windows and what each shows, the last acts, the record, the last
///   dictation's text.
/// - `ui.tree`: the accessibility tree of the app's own windows, read in this process (no
///   permission of macOS is needed for the app's own elements).
/// - `ui.press {id, label?}`, `ui.type {id, text}`: a press of a control, or text typed into it, by
///   its accessibility identifier (and, for a segmented control, the segment's label).
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

    private let endpoint: LocalEndpoint
    private let approval: Approval

    init(socketURL: URL, approval: Approval) {
        endpoint = LocalEndpoint(socketURL: socketURL, log: "control")
        self.approval = approval
        approval.answersByControl = true
        endpoint.onRequest = { [weak self] method, parameters in try self?.answer(method, parameters) ?? [:] }
    }

    func start() { endpoint.start() }

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
        case "approval.answer":
            guard let allow = parameters["allow"] as? Bool else { throw EndpointRefusal("approval.answer needs allow: true or false.") }
            guard approval.answer(allow: allow, keep: parameters["keep"] as? Bool ?? false) else { throw EndpointRefusal("No question waits for an answer.") }
        case "ui.state":
            var answer = state()
            answer["windows"] = NSApp.windows.filter(\.isVisible).map { window -> [String: Any] in
                ["kind": String(describing: type(of: window)), "title": window.title, "key": window.isKeyWindow, "frame": Self.rect(window.frame)]
            }
            answer["approval"] = approval.waiting.map { ["question": $0.question] } ?? NSNull()
            return answer
        case "ui.tree":
            var budget = parameters["maxNodes"] as? Int ?? 4_000
            return ["windows": NSApp.windows.filter(\.isVisible).map { Self.node($0, depth: 0, budget: &budget) }]
        case "ui.press":
            let element = try find(parameters)
            guard Self.bool(element, "accessibilityEnabled") != false else { throw EndpointRefusal("\(Self.name(of: element)) is disabled.") }
            // what a press answers is not to be trusted: the menu bar's button answers no and opens
            if element.responds(to: NSSelectorFromString("accessibilityPerformPress")) {
                _ = element.perform(NSSelectorFromString("accessibilityPerformPress"))
            } else if let control = element as? NSControl {
                control.performClick(nil)
            } else {
                throw EndpointRefusal("\(Self.name(of: element)) takes no press.")
            }
        case "ui.type":
            guard let text = parameters["text"] as? String else { throw EndpointRefusal("ui.type needs text.") }
            let element = try find(parameters)
            if let field = element as? NSTextView {
                field.window?.makeFirstResponder(field)
                field.insertText(text, replacementRange: field.selectedRange())
            } else if let field = element as? NSTextField {
                field.stringValue += text
            } else if element.responds(to: NSSelectorFromString("setAccessibilityValue:")) {
                _ = element.perform(NSSelectorFromString("setAccessibilityValue:"), with: text)
            } else {
                throw EndpointRefusal("\(Self.name(of: element)) takes no text.")
            }
        default:
            throw EndpointRefusal(
                "No method \"\(method)\". The methods are: ui.state, ui.tree, ui.press, ui.type, input.toggle, capture.toggle, capture.mark, dictation.start, dictation.stop, dictation.fn, dictation.esc, approval.answer.")
        }
        return [:]
    }

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
        guard let part = Self.first(in: Self.children(of: element), where: { Self.label(of: $0) == label }) else {
            throw EndpointRefusal("\"\(id)\" has nothing labelled \"\(label)\".")
        }
        return part
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
