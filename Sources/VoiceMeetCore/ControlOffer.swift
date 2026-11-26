import Foundation

/// THE OFFER TO BE DRIVEN, as a fact on the Mac's own context `/devices/<name>`: whether a person
/// of the mind may drive this Mac now (README, "Drive: the offer in the mind"). A call page reads
/// the newest of these facts and lists the Mac in its Drive menu; there is no list of devices in a
/// config file.
///
/// - `device/control-configured { kind: "mac", lend, control: "ask" | "shared", displays }` when
///   Control this Mac is at Ask or Shared, macOS allows the posting, and one display at least may
///   be shown (its screen is not Off): the picture of a drive is that screen in the call.
/// - `device/control-configured { kind: "mac", lend, control: null, why }` when that ends: Off, no
///   Accessibility, every display Off, the app quits, the Mac is lent to another mind.
///
/// The app says the fact at each connection of its events job (a page that reads it after a gap
/// sees the state of now), and again only when it changes. A Mac that goes away with no word (a
/// crash, no network) leaves its last fact; the page also checks that the lend is live.
public enum ControlOffer: Equatable {
    case offered(control: String, displays: [Display])
    case withdrawn(why: String)

    public static let type = "device/control-configured"

    /// A display a driver may choose: its number (`control.start({ display })`, `call.publish`'s
    /// `screen:<n>`), its name, and its screen's choice ("ask" or "shared").
    public struct Display: Equatable {
        public let display: Int
        public let name: String
        public let screen: String

        public init(display: Int, name: String, screen: String) {
            self.display = display
            self.name = name
            self.screen = screen
        }
    }

    /// The offer of now. `control`: Control this Mac's choice ("off", "ask", "shared");
    /// `permitted`: macOS allows the posting; `displays`: each display with its screen's choice.
    public static func of(control: String, permitted: Bool, displays: [Display]) -> ControlOffer {
        guard control == "ask" || control == "shared" else { return .withdrawn(why: "Control this Mac is Off") }
        guard permitted else { return .withdrawn(why: "macOS has not given Accessibility") }
        let shown = displays.filter { $0.screen == "ask" || $0.screen == "shared" }
        guard !shown.isEmpty else { return .withdrawn(why: "every display is Off") }
        return .offered(control: control, displays: shown)
    }

    /// The fact's payload. `lend` is the Mac's name in the mind (`itx.<lend>`).
    public func payload(lend: String) -> [String: Any] {
        switch self {
        case .offered(let control, let displays):
            return [
                "kind": "mac", "lend": lend, "control": control,
                "displays": displays.map { ["display": $0.display, "name": $0.name, "screen": $0.screen] },
            ]
        case .withdrawn(let why):
            return ["kind": "mac", "lend": lend, "control": NSNull(), "why": why]
        }
    }

    public var isOffered: Bool {
        if case .offered = self { return true }
        return false
    }
}

/// WHEN THE OFFER IS SAID: at each connection (`again`), and otherwise only when it changed. A
/// withdrawal is said once; a first state that is no offer is said too, so that the newest fact on
/// the context is always the state of now.
public struct ControlOfferTeller: Equatable {
    public private(set) var said: ControlOffer?

    public init() {}

    /// The offer to say now, or nil when the context has it already.
    public mutating func tell(_ now: ControlOffer, again: Bool = false) -> ControlOffer? {
        if !again, now == said { return nil }
        // two withdrawals in a row are one, whatever their reasons: a page reads "not offered"
        if !again, case .withdrawn = now, case .withdrawn = said { return nil }
        said = now
        return now
    }

    /// The events job ended (another mind, none): the next one says the state again.
    public mutating func forget() { said = nil }
}
