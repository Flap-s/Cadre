import AppKit
import Carbon

struct KeyCombo: Codable, Equatable {
    var keyCode: UInt32
    var modifiers: UInt

    init(keyCode: UInt32, modifiers: NSEvent.ModifierFlags) {
        self.keyCode = keyCode
        self.modifiers = modifiers.intersection([.command, .option, .control, .shift]).rawValue
    }

    init(_ keyCode: Int, _ modifiers: NSEvent.ModifierFlags) {
        self.init(keyCode: UInt32(keyCode), modifiers: modifiers)
    }

    var modifierFlags: NSEvent.ModifierFlags { NSEvent.ModifierFlags(rawValue: modifiers) }

    var carbonModifiers: UInt32 {
        var m: UInt32 = 0
        if modifierFlags.contains(.command) { m |= UInt32(cmdKey) }
        if modifierFlags.contains(.option) { m |= UInt32(optionKey) }
        if modifierFlags.contains(.control) { m |= UInt32(controlKey) }
        if modifierFlags.contains(.shift) { m |= UInt32(shiftKey) }
        return m
    }

    var displayString: String { KeyNames.modifierSymbols(modifierFlags) + KeyNames.name(keyCode) }

    /// Used to show the shortcut next to menu items.
    var keyEquivalent: String {
        if let digit = KeyNames.digits[keyCode] { return digit }
        guard KeyNames.special[keyCode] == nil, let c = KeyNames.character(keyCode) else { return "" }
        return c.lowercased()
    }
}

enum KeyNames {
    static let special: [UInt32: String] = [
        36: "↩", 48: "⇥", 49: "Space", 51: "⌫", 53: "⎋", 117: "⌦",
        123: "←", 124: "→", 125: "↓", 126: "↑", 115: "↖", 119: "↘", 116: "⇞", 121: "⇟",
        122: "F1", 120: "F2", 99: "F3", 118: "F4", 96: "F5", 97: "F6",
        98: "F7", 100: "F8", 101: "F9", 109: "F10", 103: "F11", 111: "F12",
    ]

    /// Number-row keys, shown as digits whatever the layout (on AZERTY they type & é " ' … unshifted).
    static let digits: [UInt32: String] = [
        18: "1", 19: "2", 20: "3", 21: "4", 23: "5", 22: "6", 26: "7", 28: "8", 25: "9", 29: "0",
    ]

    static func modifierSymbols(_ flags: NSEvent.ModifierFlags) -> String {
        var s = ""
        if flags.contains(.control) { s += "⌃" }
        if flags.contains(.option) { s += "⌥" }
        if flags.contains(.shift) { s += "⇧" }
        if flags.contains(.command) { s += "⌘" }
        return s
    }

    /// Character produced by a key code on the current keyboard layout, ignoring modifiers.
    static func character(_ keyCode: UInt32) -> String? {
        guard let source = TISCopyCurrentKeyboardLayoutInputSource()?.takeRetainedValue(),
              let ptr = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData) else { return nil }
        let data = Unmanaged<CFData>.fromOpaque(ptr).takeUnretainedValue() as Data
        return data.withUnsafeBytes { raw -> String? in
            guard let layout = raw.baseAddress?.assumingMemoryBound(to: UCKeyboardLayout.self) else { return nil }
            var deadKeys: UInt32 = 0
            var chars = [UniChar](repeating: 0, count: 4)
            var length = 0
            let status = UCKeyTranslate(layout, UInt16(keyCode), UInt16(kUCKeyActionDisplay), 0,
                                        UInt32(LMGetKbdType()), OptionBits(kUCKeyTranslateNoDeadKeysBit),
                                        &deadKeys, chars.count, &length, &chars)
            guard status == noErr, length > 0 else { return nil }
            return String(utf16CodeUnits: chars, count: length)
        }
    }

    static func name(_ keyCode: UInt32) -> String {
        special[keyCode] ?? digits[keyCode] ?? character(keyCode)?.uppercased() ?? "#\(keyCode)"
    }
}

enum HotKeyStore {
    private static func key(_ action: CaptureAction) -> String { "hotkey.\(action.rawValue)" }

    static func combo(for action: CaptureAction) -> KeyCombo? {
        if let data = UserDefaults.standard.data(forKey: key(action)) {
            if data.isEmpty { return nil } // explicitly cleared
            return try? JSONDecoder().decode(KeyCombo.self, from: data)
        }
        return action.defaultCombo
    }

    @MainActor static func set(_ combo: KeyCombo?, for action: CaptureAction) {
        let data = combo.flatMap { try? JSONEncoder().encode($0) } ?? Data()
        UserDefaults.standard.set(data, forKey: key(action))
        HotKeyManager.shared.registerAll()
    }

    @MainActor static func resetAll() {
        for action in CaptureAction.allCases { UserDefaults.standard.removeObject(forKey: key(action)) }
        HotKeyManager.shared.registerAll()
    }
}

@MainActor
final class HotKeyManager {
    static let shared = HotKeyManager()

    private var refs: [EventHotKeyRef] = []
    private var actions: [UInt32: CaptureAction] = [:]
    private var installed = false
    /// Combos that failed to register (already taken by the system or another app).
    private(set) var failed: Set<CaptureAction> = []

    func install() {
        guard !installed else { return }
        installed = true
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, event, _ in
            var hotKeyID = EventHotKeyID()
            GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                              nil, MemoryLayout<EventHotKeyID>.size, nil, &hotKeyID)
            let id = hotKeyID.id
            DispatchQueue.main.async {
                MainActor.assumeIsolated { HotKeyManager.shared.fire(id) }
            }
            return noErr
        }, 1, &spec, nil, nil)
    }

    /// Temporarily disabled while the settings window records a new shortcut.
    var isSuspended = false {
        didSet { isSuspended ? unregisterAll() : registerAll() }
    }

    private func fire(_ id: UInt32) {
        guard !isSuspended, let action = actions[id] else { return }
        action.run()
    }

    private func unregisterAll() {
        refs.forEach { UnregisterEventHotKey($0) }
        refs.removeAll()
        actions.removeAll()
    }

    func registerAll() {
        unregisterAll()
        failed.removeAll()
        guard !isSuspended else { return }
        for (index, action) in CaptureAction.allCases.enumerated() {
            guard let combo = HotKeyStore.combo(for: action) else { continue }
            let id = UInt32(index + 1)
            var ref: EventHotKeyRef?
            let hotKeyID = EventHotKeyID(signature: OSType(0x4344_5245), id: id) // 'CDRE'
            let status = RegisterEventHotKey(combo.keyCode, combo.carbonModifiers, hotKeyID,
                                             GetApplicationEventTarget(), 0, &ref)
            if status == noErr, let ref {
                refs.append(ref)
                actions[id] = action
            } else {
                failed.insert(action)
            }
        }
    }
}
