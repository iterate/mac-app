import Foundation

/// WHERE THE RECORD WAITS: one spool for each device of each mind, `<root>/<mind>/itx.<device>/`.
/// A file's path in a spool is its path in the mind's files (`/devices/<device>/record/…`), and
/// the uploader of a device puts only its own spool into the mind, under its own name. So a slot
/// recorded as one device is never published as another one after a rename: it waits in its
/// spool until the Mac is that device again. (`itx.` keeps a device's folder apart from the
/// `slots` and `devices` folders of a spool of an earlier version, one for each mind.)
public enum Spool {
    public static func folder(in root: URL, mind: String, device: String) -> URL {
        root.appendingPathComponent(mind).appendingPathComponent("itx.\(device)")
    }

    /// The device a slot's event is of: the name in its files' paths, `/devices/<name>/…`.
    public static func device(ofSlot payload: [String: Any]) -> String? {
        let tracks = payload["tracks"] as? [String: [String: Any]] ?? [:]
        let names = Set(tracks.values.compactMap { track -> String? in
            guard let file = track["file"] as? String else { return nil }
            let parts = file.split(separator: "/")
            return parts.count > 2 && parts[0] == "devices" ? String(parts[1]) : nil
        })
        return names.count == 1 ? names.first : nil
    }

    /// A spool of an earlier version (`<root>/<mind>/`, every device in one): each of its slots,
    /// with the files it names, moves into the spool of the device the slot names, and the
    /// numbers of the capture devices and the newest sealed slot go along to each. A slot whose
    /// device cannot be read stays where it is. Answers the number of slots moved. Runs before
    /// a recorder or an uploader of that mind starts.
    @discardableResult
    public static func split(mindFolder: URL) -> Int {
        let files = FileManager.default
        let slots = mindFolder.appendingPathComponent("slots")
        guard let names = try? files.contentsOfDirectory(atPath: slots.path) else { return 0 }
        var moved = 0
        for name in names.sorted() where name.hasSuffix(".json") || name.hasSuffix(".open") {
            let slot = slots.appendingPathComponent(name)
            guard let data = try? Data(contentsOf: slot),
                let payload = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                let device = device(ofSlot: payload)
            else { continue }
            let target = mindFolder.appendingPathComponent("itx.\(device)")
            for kept in ["sealed", "devices.json"] where !files.fileExists(atPath: target.appendingPathComponent(kept).path) {
                try? files.createDirectory(at: target, withIntermediateDirectories: true)
                try? files.copyItem(at: mindFolder.appendingPathComponent(kept), to: target.appendingPathComponent(kept))
            }
            let tracks = payload["tracks"] as? [String: [String: Any]] ?? [:]
            for path in tracks.values.flatMap({ [$0["file"], $0["picture"]].compactMap { $0 as? String } }) {
                let from = mindFolder.appendingPathComponent(String(path.dropFirst()))
                let to = target.appendingPathComponent(String(path.dropFirst()))
                guard files.fileExists(atPath: from.path) else { continue }
                try? files.createDirectory(at: to.deletingLastPathComponent(), withIntermediateDirectories: true)
                try? files.moveItem(at: from, to: to)
            }
            // the event last: a slot in the new spool names only files that are there
            let to = target.appendingPathComponent("slots").appendingPathComponent(name)
            try? files.createDirectory(at: to.deletingLastPathComponent(), withIntermediateDirectories: true)
            if (try? files.moveItem(at: slot, to: to)) != nil { moved += 1 }
        }
        if moved > 0 { log("record: \(moved) slots of an earlier spool moved into the spool of their device") }
        return moved
    }

    /// The slots that wait in a spool.
    public static func waiting(in spool: URL) -> Int {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: spool.appendingPathComponent("slots").path)) ?? []
        return names.filter { $0.hasSuffix(".json") }.count
    }
}

/// The opens of a capture that more than one thing asks for: a start, a resume after a lock, a
/// display change, a restart after an error. Each open has a number; a new one makes every older
/// one stale, and a stale open stops the stream it made instead of keeping it. A resume asks only
/// when no open runs (`again` false): a resume during a slow open makes no second stream.
public struct Opens: Equatable, Sendable {
    public private(set) var current = 0
    public private(set) var running: Int?

    public init() {}

    /// The number of a new open; nil when one runs and `again` is false.
    public mutating func begin(again: Bool) -> Int? {
        guard again || running == nil else { return nil }
        current += 1
        running = current
        return current
    }

    /// The open `number` is done (well or not).
    public mutating func end(_ number: Int) {
        if running == number { running = nil }
    }

    /// Whether the stream of open `number` may be kept.
    public func keeps(_ number: Int) -> Bool { number == current }

    /// Every open is stale (the source stops).
    public mutating func stop() {
        current += 1
        running = nil
    }
}
