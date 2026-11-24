import AppKit
import Carbon.HIToolbox

/// The app's keys that work in any app: Carbon hot keys, which need no permission of macOS.
/// One handler hears them all and calls the one that was pressed, by its id.
@MainActor
enum HotKey {
    struct Combo {
        let id: UInt32
        let key: Int
        let modifiers: Int
        /// The key in words, for the log and the panel.
        let words: String
    }

    /// Starts the person's capture and ends it (`Capture`).
    static let capture = Combo(id: 1, key: kVK_ANSI_S, modifiers: optionKey | shiftKey, words: "⌥⇧S")
    /// Opens the input to a mind (`MindInput`).
    static let input = Combo(id: 2, key: kVK_Space, modifiers: optionKey | shiftKey, words: "⌥⇧Space")

    private static var pressed: [UInt32: () -> Void] = [:]
    private static var isInstalled = false

    /// False when macOS refuses the key.
    static func register(_ combo: Combo, pressed: @escaping () -> Void) -> Bool {
        if !isInstalled {
            isInstalled = true
            var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
            InstallEventHandler(
                GetApplicationEventTarget(),
                { _, event, _ in
                    var hotKey = EventHotKeyID()
                    let status = GetEventParameter(
                        event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID), nil,
                        MemoryLayout<EventHotKeyID>.size, nil, &hotKey)
                    guard status == noErr else { return status }
                    let id = hotKey.id
                    DispatchQueue.main.async { MainActor.assumeIsolated { HotKey.pressed[id]?() } }
                    return noErr
                }, 1, &spec, nil, nil)
        }
        self.pressed[combo.id] = pressed
        var key: EventHotKeyRef?
        // the signature is "itxc"
        let id = EventHotKeyID(signature: 0x6974_7863, id: combo.id)
        return RegisterEventHotKey(UInt32(combo.key), UInt32(combo.modifiers), id, GetApplicationEventTarget(), 0, &key) == noErr
    }
}
