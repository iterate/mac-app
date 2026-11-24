import Foundation

/// The app's `config.json`, as `cli.mjs` writes it (`writeState`): `JSON.stringify(state, null, 2)`
/// and a newline, into `config.json.new`, then renamed onto `config.json`, so the app's watch of
/// the folder never reads half a file. The panel's `use` and `remove` change it here; `add` (a new
/// key, allowed by a member) stays the CLI's.
public enum ConfigFile {
    public enum Failure: Error, CustomStringConvertible, Equatable {
        case noMind(String, known: [String])

        public var description: String {
            switch self {
            case let .noMind(mind, known): "No mind \"\(mind)\" on this Mac. Its minds: \(known.isEmpty ? "none" : known.joined(separator: ", "))."
            }
        }
    }

    /// The config's object, with every key it has.
    public static func read(_ file: URL) throws -> [String: Any] {
        guard let object = try JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any] else {
            throw CocoaError(.fileReadCorruptFile)
        }
        return object
    }

    public static func write(_ state: [String: Any], to file: URL) throws {
        let new = file.appendingPathExtension("new")
        try Data((stringify(state) + "\n").utf8).write(to: new)
        guard rename(new.path, file.path) == 0 else { throw CocoaError(.fileWriteUnknown) }
    }

    private static func minds(of state: [String: Any]) -> [[String: Any]] {
        state["minds"] as? [[String: Any]] ?? []
    }

    /// `use <mind>`: it becomes the active one.
    public static func using(_ mind: String, in state: [String: Any]) throws -> [String: Any] {
        let mind = mind.lowercased()
        let known = minds(of: state).compactMap { $0["mind"] as? String }
        guard known.contains(mind) else { throw Failure.noMind(mind, known: known) }
        var state = state
        state["active"] = mind
        return state
    }

    /// `remove <mind>`: it leaves the list (and is no longer active); the answer names its key file,
    /// which the caller deletes.
    public static func removing(_ mind: String, from state: [String: Any]) throws -> (state: [String: Any], keyFile: String?) {
        let mind = mind.lowercased()
        let all = minds(of: state)
        guard let entry = all.first(where: { $0["mind"] as? String == mind }) else {
            throw Failure.noMind(mind, known: all.compactMap { $0["mind"] as? String })
        }
        var state = state
        state["minds"] = all.filter { $0["mind"] as? String != mind }
        if state["active"] as? String == mind { state["active"] = NSNull() }
        return (state, entry["keyFile"] as? String)
    }

    /// The minds of the iterate CLI's profiles (`iterate login`), in the file the CLI keeps them:
    /// `$XDG_CONFIG_HOME/iterate/minds.json`, else `~/.config/iterate/minds.json`.
    public static func profileMinds(environment: [String: String] = ProcessInfo.processInfo.environment, home: String = NSHomeDirectory()) -> [String] {
        let folder = environment["XDG_CONFIG_HOME"].flatMap { $0.isEmpty ? nil : $0 } ?? (home as NSString).appendingPathComponent(".config")
        let file = URL(fileURLWithPath: folder).appendingPathComponent("iterate/minds.json")
        guard let data = try? Data(contentsOf: file),
            let configs = ((try? JSONSerialization.jsonObject(with: data)) as? [String: Any])?["configs"] as? [String: Any]
        else { return [] }
        var minds: [String] = []
        for case let profile as [String: Any] in configs.values {
            if let mind = profile["mind"] as? String, !mind.isEmpty, !minds.contains(mind) { minds.append(mind) }
        }
        return minds
    }

    /// `JSON.stringify(value, null, 2)` of a value that `JSONSerialization` read. The keys of an
    /// object are sorted: `JSONSerialization` keeps no order.
    public static func stringify(_ value: Any, indent: String = "") -> String {
        let inner = indent + "  "
        switch value {
        case let object as [String: Any]:
            if object.isEmpty { return "{}" }
            let fields = object.keys.sorted().map { "\(inner)\(string($0)): \(stringify(object[$0]!, indent: inner))" }
            return "{\n\(fields.joined(separator: ",\n"))\n\(indent)}"
        case let array as [Any]:
            if array.isEmpty { return "[]" }
            return "[\n\(array.map { inner + stringify($0, indent: inner) }.joined(separator: ",\n"))\n\(indent)]"
        case let text as String:
            return string(text)
        case let number as NSNumber:
            #if canImport(Darwin)
            // a JSON boolean is an NSNumber too, and 1 `as? Bool` is true: CFBoolean tells them apart
            let isBoolean = CFGetTypeID(number) == CFBooleanGetTypeID()
            #else
            let isBoolean = value is Bool
            #endif
            if isBoolean { return number.boolValue ? "true" : "false" }
            return String(decoding: (try? JSONSerialization.data(withJSONObject: number, options: [.fragmentsAllowed])) ?? Data("null".utf8), as: UTF8.self)
        default:
            return "null"
        }
    }

    private static func string(_ text: String) -> String {
        String(decoding: (try? JSONSerialization.data(withJSONObject: text, options: [.fragmentsAllowed, .withoutEscapingSlashes])) ?? Data("\"\"".utf8), as: UTF8.self)
    }
}
