import AppKit
import Carbon.HIToolbox

/// The app's keys that work in any app: Carbon hot keys, which need no permission of macOS.
/// One handler hears them all and calls the one that was pressed, by its id.
@MainActor
enum HotKey {
    struct Combo: Equatable {
        let id: UInt32
        let key: Int
        let modifiers: Int

        /// Starts the person's capture and ends it (`Capture`), unless Settings set another key.
        static let capture = Combo(id: 1, key: kVK_ANSI_S, modifiers: optionKey | shiftKey)
        /// Opens the input to a mind (`MindInput`), unless Settings set another key.
        static let input = Combo(id: 2, key: kVK_Space, modifiers: optionKey | shiftKey)
        /// Dictates into the app in front (`Dictation`).
        static let dictation = Combo(id: 3, key: kVK_ANSI_D, modifiers: optionKey | shiftKey)

        /// The key in words, as macOS's menus write it: ⌥⇧S, ⌃⌘Space.
        @MainActor var words: String {
            var text = ""
            if modifiers & controlKey != 0 { text += "⌃" }
            if modifiers & optionKey != 0 { text += "⌥" }
            if modifiers & shiftKey != 0 { text += "⇧" }
            if modifiers & cmdKey != 0 { text += "⌘" }
            return text + HotKey.name(of: key)
        }
    }

    /// A key's name: the special keys by a table, the others as the keyboard's layout prints them.
    static func name(of key: Int) -> String {
        let named: [Int: String] = [
            kVK_Space: "Space", kVK_Return: "Return", kVK_Tab: "Tab", kVK_Delete: "Delete", kVK_ForwardDelete: "⌦", kVK_Escape: "Esc",
            kVK_LeftArrow: "←", kVK_RightArrow: "→", kVK_UpArrow: "↑", kVK_DownArrow: "↓", kVK_Home: "Home", kVK_End: "End",
            kVK_PageUp: "Page Up", kVK_PageDown: "Page Down", kVK_F1: "F1", kVK_F2: "F2", kVK_F3: "F3", kVK_F4: "F4", kVK_F5: "F5",
            kVK_F6: "F6", kVK_F7: "F7", kVK_F8: "F8", kVK_F9: "F9", kVK_F10: "F10", kVK_F11: "F11", kVK_F12: "F12",
            kVK_ANSI_KeypadEnter: "Enter",
        ]
        if let name = named[key] { return name }
        // a drawing, and a layout that gives nothing, fall back to the US keyboard's letters
        let us: [Int: String] = [
            kVK_ANSI_A: "A", kVK_ANSI_B: "B", kVK_ANSI_C: "C", kVK_ANSI_D: "D", kVK_ANSI_E: "E", kVK_ANSI_F: "F", kVK_ANSI_G: "G",
            kVK_ANSI_H: "H", kVK_ANSI_I: "I", kVK_ANSI_J: "J", kVK_ANSI_K: "K", kVK_ANSI_L: "L", kVK_ANSI_M: "M", kVK_ANSI_N: "N",
            kVK_ANSI_O: "O", kVK_ANSI_P: "P", kVK_ANSI_Q: "Q", kVK_ANSI_R: "R", kVK_ANSI_S: "S", kVK_ANSI_T: "T", kVK_ANSI_U: "U",
            kVK_ANSI_V: "V", kVK_ANSI_W: "W", kVK_ANSI_X: "X", kVK_ANSI_Y: "Y", kVK_ANSI_Z: "Z", kVK_ANSI_0: "0", kVK_ANSI_1: "1",
            kVK_ANSI_2: "2", kVK_ANSI_3: "3", kVK_ANSI_4: "4", kVK_ANSI_5: "5", kVK_ANSI_6: "6", kVK_ANSI_7: "7", kVK_ANSI_8: "8",
            kVK_ANSI_9: "9",
        ]
        if !AppEnvironment.current.isRendering, let typed = typed(key), !typed.isEmpty { return typed.uppercased() }
        return us[key] ?? "Key \(key)"
    }

    /// What the current keyboard layout types for the key with no modifier.
    private static func typed(_ key: Int) -> String? {
        guard let source = TISCopyCurrentKeyboardLayoutInputSource()?.takeRetainedValue(),
            let pointer = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData)
        else { return nil }
        let data = Unmanaged<CFData>.fromOpaque(pointer).takeUnretainedValue() as Data
        var deadKeys: UInt32 = 0
        var characters = [UniChar](repeating: 0, count: 4)
        var length = 0
        let status = data.withUnsafeBytes { bytes -> OSStatus in
            guard let layout = bytes.baseAddress?.assumingMemoryBound(to: UCKeyboardLayout.self) else { return -1 }
            return UCKeyTranslate(
                layout, UInt16(key), UInt16(kUCKeyActionDisplay), 0, UInt32(LMGetKbdType()), OptionBits(kUCKeyTranslateNoDeadKeysBit),
                &deadKeys, characters.count, &length, &characters)
        }
        guard status == noErr, length > 0 else { return nil }
        return String(utf16CodeUnits: characters, count: length).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static var pressed: [UInt32: () -> Void] = [:]
    private static var released: [UInt32: () -> Void] = [:]
    private static var isInstalled = false
    private static var refs: [UInt32: EventHotKeyRef] = [:]

    /// False when macOS refuses the key.
    static func register(_ combo: Combo, pressed: @escaping () -> Void, released: (() -> Void)? = nil) -> Bool {
        if !isInstalled {
            isInstalled = true
            let specs = [
                EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed)),
                EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyReleased)),
            ]
            InstallEventHandler(
                GetApplicationEventTarget(),
                { _, event, _ in
                    var hotKey = EventHotKeyID()
                    let status = GetEventParameter(
                        event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID), nil,
                        MemoryLayout<EventHotKeyID>.size, nil, &hotKey)
                    guard status == noErr else { return status }
                    let id = hotKey.id
                    let isRelease = GetEventKind(event) == UInt32(kEventHotKeyReleased)
                    DispatchQueue.main.async { MainActor.assumeIsolated { (isRelease ? HotKey.released[id] : HotKey.pressed[id])?() } }
                    return noErr
                }, specs.count, specs, nil, nil)
        }
        self.pressed[combo.id] = pressed
        self.released[combo.id] = released
        unregister(combo.id)
        var key: EventHotKeyRef?
        // the signature is "itxc"
        let id = EventHotKeyID(signature: 0x6974_7863, id: combo.id)
        guard RegisterEventHotKey(UInt32(combo.key), UInt32(combo.modifiers), id, GetApplicationEventTarget(), 0, &key) == noErr, let key else {
            return false
        }
        refs[combo.id] = key
        return true
    }

    /// The key with this id no longer works (a new one is recorded, or the person removed it).
    static func unregister(_ id: UInt32) {
        guard let key = refs.removeValue(forKey: id) else { return }
        UnregisterEventHotKey(key)
    }
}
