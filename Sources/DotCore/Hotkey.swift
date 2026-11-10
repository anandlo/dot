import Carbon.HIToolbox
import Foundation

/// The Carbon modifier bits a hot key is made of.
public enum HotkeyModifiers: Int, Sendable, CaseIterable {
    case command = 256
    case shift = 512
    case option = 2048
    case control = 4096
    case capsLock = 65_536

    /// The bits of a set of modifiers.
    public static func mask(_ modifiers: HotkeyModifiers...) -> Int {
        modifiers.reduce(0) { $0 | $1.rawValue }
    }

    /// Whether the mask contains the modifier.
    public static func contains(_ mask: Int, _ modifier: HotkeyModifiers) -> Bool {
        mask & modifier.rawValue != 0
    }
}

/// A global shortcut: a key code plus Carbon modifiers.
public struct Hotkey: Codable, Sendable, Equatable, Hashable {
    /// The virtual key code (Carbon `kVK_*`).
    public var keyCode: Int
    /// The Carbon modifier mask.
    public var modifiers: Int
    /// A human label such as `⌥⌘D`.
    public var label: String
    /// The ANSI key code of the same character, when the keyboard layout
    /// puts the character somewhere else.
    ///
    /// The shortcut is registered on both codes, so it keeps working when
    /// the layout is changed.
    public var ansiKeyCode: Int?

    /// Creates a hot key.
    public init(keyCode: Int, modifiers: Int, label: String, ansiKeyCode: Int? = nil) {
        self.keyCode = keyCode
        self.modifiers = modifiers
        self.label = label
        self.ansiKeyCode = ansiKeyCode
    }

    private enum CodingKeys: String, CodingKey {
        case keyCode
        case modifiers
        case label
        case ansiKeyCode
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.keyCode = try container.decode(Int.self, forKey: .keyCode)
        self.modifiers = try container.decode(Int.self, forKey: .modifiers)
        self.label = try container.decode(String.self, forKey: .label)
        self.ansiKeyCode = try container.decodeIfPresent(Int.self, forKey: .ansiKeyCode)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(keyCode, forKey: .keyCode)
        try container.encode(modifiers, forKey: .modifiers)
        try container.encode(label, forKey: .label)
        try container.encodeIfPresent(ansiKeyCode, forKey: .ansiKeyCode)
    }

    /// Dot's default: `⌥⌘D`.
    ///
    /// It does not clash with Scrawl's `⌥⇧S`.
    public static let defaultRecord = Hotkey(
        keyCode: 2, // kVK_ANSI_D
        modifiers: HotkeyModifiers.mask(.option, .command),
        label: "⌥⌘D"
    )

    /// The default shortcut that pastes the last transcript: `⌥⌘V`.
    public static let defaultPaste = Hotkey(
        keyCode: 9, // kVK_ANSI_V
        modifiers: HotkeyModifiers.mask(.option, .command),
        label: "⌥⌘V"
    )

    /// Whether the combination has one of the "strong" modifiers.
    public var hasStrongModifier: Bool {
        HotkeyModifiers.contains(modifiers, .command)
            || HotkeyModifiers.contains(modifiers, .option)
            || HotkeyModifiers.contains(modifiers, .control)
    }

    /// Whether the key is a function key, which may stand on its own.
    public var isFunctionKey: Bool {
        HotkeyValidator.isFunctionKey(keyCode)
    }

    /// The combination ready to draw on a keycap.
    ///
    /// The glyphs are separated by a hair space: drawn tight in a monospaced
    /// face they collide into one unreadable mark, which is what the welcome
    /// window showed. It is derived from ``label`` so a rebind moves with it.
    public var keycapLabel: String {
        label.map(String.init).joined(separator: "\u{200A}")
    }

    /// The combination in words.
    ///
    /// Copy that cannot show modifier glyphs — a screen-reader hint, a spoken
    /// instruction — must still describe the *live* shortcut, so this is derived
    /// from the same fields as ``label`` rather than written out beside it.
    public var spelledOut: String {
        var parts: [String] = []
        if HotkeyModifiers.contains(modifiers, .control) { parts.append("Control") }
        if HotkeyModifiers.contains(modifiers, .option) { parts.append("Option") }
        if HotkeyModifiers.contains(modifiers, .shift) { parts.append("Shift") }
        if HotkeyModifiers.contains(modifiers, .command) { parts.append("Command") }
        let glyphs = CharacterSet(charactersIn: "\u{2303}\u{2325}\u{21E7}\u{2318}")
        let key = String(String.UnicodeScalarView(
            label.unicodeScalars.filter { !glyphs.contains($0) }
        ))
        parts.append(key)
        return parts.joined(separator: " ")
    }

    /// Builds the label of a combination from its parts.
    public static func makeLabel(keyCode: Int, modifiers: Int, typed: String? = nil) -> String {
        var label = ""
        if HotkeyModifiers.contains(modifiers, .control) { label += "⌃" }
        if HotkeyModifiers.contains(modifiers, .option) { label += "⌥" }
        if HotkeyModifiers.contains(modifiers, .shift) { label += "⇧" }
        if HotkeyModifiers.contains(modifiers, .command) { label += "⌘" }
        let key = HotkeyValidator.keyLabel(keyCode: keyCode, typed: typed)
        return label + key
    }
}

/// Why a shortcut was refused.
public enum HotkeyRejection: Error, Equatable, LocalizedError {
    /// The combination had no `⌘`, `⌥` or `⌃` (and was not a function key).
    case noModifier(String)
    /// macOS already uses the combination.
    case systemOwned(String)
    /// Dot already uses the combination for something else.
    case alreadyUsed(String)
    /// The key cannot be used at all.
    case unsupportedKey

    public var errorDescription: String? {
        switch self {
        case .noModifier(let label):
            "\(label) needs ⌘, ⌥ or ⌃ — a function key may stand on its own."
        case .systemOwned(let label):
            "macOS already uses \(label). Pick another combination."
        case .alreadyUsed(let label):
            "\(label) is already used by Dot. Pick another combination."
        case .unsupportedKey:
            "That key cannot be used as a shortcut."
        }
    }
}

/// Checks that a shortcut is usable before it is stored.
public enum HotkeyValidator {
    /// The function keys, which may be used without a modifier.
    static let functionKeyCodes: Set<Int> = [
        122, 120, 99, 118, 96, 97, 98, 100, 101, 109, 103, 105, 107, 113, 111, 106, 64, 79, 80, 90,
    ]

    /// Whether the key code is a function key.
    public static func isFunctionKey(_ keyCode: Int) -> Bool {
        functionKeyCodes.contains(keyCode)
    }

    /// The name of a key, as it should appear in a shortcut label.
    public static func keyLabel(keyCode: Int, typed: String? = nil) -> String {
        if let name = namedKeys[keyCode] { return name }
        if let typed, let character = typed.first,
           !character.isWhitespace, !CharacterSet.controlCharacters.contains(character.unicodeScalars.first ?? " ") {
            return String(character).uppercased()
        }
        return "key \(keyCode)"
    }

    /// The ANSI key code of a character, when there is one.
    ///
    /// The table is the US layout: the letter `A` is the key code `0`, the
    /// letter `S` is `1` and so on.
    public static func ansiKeyCode(forCharacter character: Character) -> Int? {
        let upper = String(character).uppercased()
        guard upper.count == 1, let only = upper.first else { return nil }
        return ansiKeyCodes[only]
    }

    /// The US layout's key code of every character a shortcut can use.
    static let ansiKeyCodes: [Character: Int] = [
        "A": 0, "S": 1, "D": 2, "F": 3, "H": 4, "G": 5, "Z": 6, "X": 7, "C": 8, "V": 9,
        "B": 11, "Q": 12, "W": 13, "E": 14, "R": 15, "T": 16, "Y": 17,
        "1": 18, "2": 19, "3": 20, "4": 21, "6": 22, "5": 23, "=": 24, "9": 25,
        "7": 26, "-": 27, "8": 28, "0": 29, "]": 30, "O": 31, "U": 32, "[": 33,
        "I": 34, "P": 35, "L": 36, "J": 37, "'": 38, "K": 39, ";": 40, "\\": 41,
        ",": 42, "/": 43, "N": 45, "M": 46, ".": 47, "`": 50,
    ]

    /// The named keys a shortcut can use.
    ///
    /// The key codes are the Carbon virtual key codes. `Return` shares its
    /// code with the letter `L` (`0x24`), so `L` wins the name: a shortcut on
    /// that code is a shortcut on `L`.
    static let namedKeys: [Int: String] = [
        0: "A", 1: "S", 2: "D", 3: "F", 4: "H", 5: "G", 6: "Z", 7: "X", 8: "C", 9: "V",
        11: "B", 12: "Q", 13: "W", 14: "E", 15: "R", 16: "Y", 17: "T",
        18: "1", 19: "2", 20: "3", 21: "4", 22: "6", 23: "5", 24: "=", 25: "9",
        26: "7", 27: "-", 28: "8", 29: "0", 30: "]", 31: "O", 32: "U", 33: "[",
        34: "I", 35: "P", 36: "L", 37: "J", 38: "'", 39: "K", 40: ";", 41: "\\",
        42: ",", 43: "/", 44: "N", 45: "M", 46: ".", 47: "Tab", 48: "Space",
        49: "`", 50: "Return", 51: "Delete", 53: "Esc",
        65: "⌨.", 67: "⌨*", 69: "⌨+", 71: "⌨Clear", 75: "⌨/", 76: "⌨Enter", 78: "⌨-",
        81: "⌨=", 82: "⌨0", 83: "⌨1", 84: "⌨2", 85: "⌨3", 86: "⌨4", 87: "⌨5",
        88: "⌨6", 89: "⌨7", 91: "⌨8", 92: "⌨9",
        96: "F5", 97: "F6", 98: "F7", 99: "F3", 100: "F8", 101: "F9", 103: "F11",
        105: "F12", 106: "F16", 107: "F13", 109: "F10", 111: "F15", 113: "F14",
        64: "F17", 79: "F18", 80: "F19", 90: "F20",
        114: "Help",
        115: "Home", 116: "PageUp", 117: "Del", 119: "End", 121: "PageDown",
        123: "←", 124: "→", 125: "↓", 126: "↑",
    ]

    /// Combinations macOS keeps for itself.
    ///
    /// These are the ones that really are taken by the system; the list is
    /// deliberately short so a shortcut that only *looks* reserved is still
    /// allowed. `⌥⌘D` (show or hide the Dock) is not on it: Dot uses it by
    /// default and macOS lets a registered Carbon hot key take it over.
    static let systemShortcuts: Set<Hotkey> = {
        let command = HotkeyModifiers.mask(.command)
        let shift = HotkeyModifiers.mask(.shift)
        let option = HotkeyModifiers.mask(.option)
        let control = HotkeyModifiers.mask(.control)
        var shortcuts: Set<Hotkey> = []
        func add(_ keyCode: Int, _ modifiers: Int, _ label: String) {
            shortcuts.insert(Hotkey(keyCode: keyCode, modifiers: modifiers, label: label))
        }
        // The system shell.
        add(12, command, "⌘Q")          // Quit
        add(13, command, "⌘W")          // Close window
        add(4, command, "⌘H")           // Hide
        add(45, command, "⌘M")          // Minimise
        add(50, command, "⌘`")          // Cycle windows
        add(53, command, "⌘Esc")
        add(53, option, "⌥Esc")
        // The input source and Spotlight.
        add(49, command, "⌘Space")
        add(49, command | shift, "⌘⇧Space")
        add(49, command | control, "⌃⌘Space")
        add(49, control, "⌃Space")
        add(49, option | control, "⌃⌥Space")
        // The app switcher.
        add(48, command, "⌘Tab")
        add(48, command | shift, "⌘⇧Tab")
        // Mission Control.
        for code in [18, 19, 20, 21] {
            add(code, command, "⌘\(HotkeyValidator.keyLabel(keyCode: code))")
        }
        for code in [20, 21, 23, 26] {
            add(code, command | shift, "⌘⇧\(HotkeyValidator.keyLabel(keyCode: code))")
        }
        // Accessibility and the screen.
        add(3, command | control, "⌃⌘F")   // Full screen
        add(3, command | shift, "⌘⇧F")
        add(43, command | shift, "⌘⇧/")     // Help
        add(2, command | control, "⌃⌘D")    // Dictionary
        add(49, command | shift | control, "⌃⌘⇧Space")
        add(12, command | control | option | shift, "⌃⌥⌘⇧Q")
        return shortcuts
    }()

    /// Combinations that Dot is allowed to take over even though macOS
    /// lists them.
    ///
    /// `⌥⌘D` is macOS's "show or hide the Dock", but a Carbon hot key
    /// registered by an application takes precedence, and Dot's default
    /// shortcut has to work.
    static let overridableSystemShortcuts: Set<Hotkey> = [
        Hotkey(keyCode: 2, modifiers: HotkeyModifiers.mask(.option, .command), label: "⌥⌘D"),
    ]

    /// The enabled system shortcuts, read from the system.
    ///
    /// Returns an empty set when the system refuses to answer, in which case
    /// only the built-in list applies.
    public static func enabledSystemShortcuts() -> Set<Hotkey> {
        var shortcuts: Set<Hotkey> = []
        var unmanaged: Unmanaged<CFArray>?
        CopySymbolicHotKeys(&unmanaged)
        guard let unmanaged else { return shortcuts }
        let array = unmanaged.takeRetainedValue()
        let count = CFArrayGetCount(array)
        guard count > 0 else { return shortcuts }
        let entries = array as NSArray
        for index in 0..<count {
            guard let entry = entries[index] as? NSDictionary else { continue }
            guard let enabled = entry["kHISymbolicHotKeyEnabled"] as? NSNumber, enabled.boolValue else { continue }
            guard let code = entry["kHISymbolicHotKeyCode"] as? NSNumber else { continue }
            guard let modifiers = entry["kHISymbolicHotKeyModifiers"] as? NSNumber else { continue }
            let keyCode = code.intValue
            let mask = modifiers.intValue
            guard keyCode != 65_535 else { continue }
            let hotkey = Hotkey(
                keyCode: keyCode,
                modifiers: mask,
                label: Hotkey.makeLabel(keyCode: keyCode, modifiers: mask)
            )
            if overridableSystemShortcuts.contains(hotkey) { continue }
            shortcuts.insert(hotkey)
        }
        return shortcuts
    }

    /// Checks a shortcut.
    ///
    /// - Parameters:
    ///   - keyCode: the virtual key code.
    ///   - modifiers: the Carbon modifier mask.
    ///   - typed: the character the key produced, used for the label.
    ///   - inUse: the shortcuts Dot already uses.
    /// - Returns: the shortcut to store, or the reason it was refused.
    public static func validate(
        keyCode: Int,
        modifiers: Int,
        typed: String? = nil,
        ansiKeyCode: Int? = nil,
        inUse: [Hotkey] = []
    ) -> Result<Hotkey, HotkeyRejection> {
        let mask = modifiers
            & (HotkeyModifiers.mask(.command, .shift, .option, .control))
        let label = Hotkey.makeLabel(keyCode: keyCode, modifiers: mask, typed: typed)
        let candidate = Hotkey(
            keyCode: keyCode,
            modifiers: mask,
            label: label,
            ansiKeyCode: ansiKeyCode
        )

        let strong = HotkeyModifiers.contains(mask, .command)
            || HotkeyModifiers.contains(mask, .option)
            || HotkeyModifiers.contains(mask, .control)
        if !strong && !isFunctionKey(keyCode) {
            return .failure(.noModifier(label))
        }
        if systemShortcuts.contains(candidate) {
            return .failure(.systemOwned(label))
        }
        if enabledSystemShortcuts().contains(candidate) {
            return .failure(.systemOwned(label))
        }
        for used in inUse where used.keyCode == candidate.keyCode && used.modifiers == candidate.modifiers {
            return .failure(.alreadyUsed(label))
        }
        return .success(candidate)
    }
}

/// Registers global hot keys with Carbon.
///
/// `RegisterEventHotKey` works while any application is focused and needs no
/// permission at all — the same technique Scrawl uses (`src/capture.rs`).
public final class GlobalHotkeyManager: @unchecked Sendable {
    /// The identifier the manager gives the first hot key it registers.
    public static let recordIdentifier: UInt32 = 1
    /// The identifier the manager gives the paste hot key.
    public static let pasteIdentifier: UInt32 = 2
    /// The identifier the manager gives the ANSI alias of a hot key.
    public static let aliasIdentifier: UInt32 = 3

    /// Called with the identifier of the hot key that was pressed.
    public typealias Handler = @Sendable (UInt32) -> Void

    private let handler: Handler
    private let signature: OSType
    private let lock = NSLock()
    private var references: [EventHotKeyRef] = []
    private var handlerRef: EventHandlerRef?
    private var lastFired: (id: UInt32, at: Date) = (0, Date.distantPast)

    /// Creates a manager that calls `handler` when a hot key is pressed.
    public init(signature: OSType = 0x4D54_4B31, handler: @escaping Handler) {
        self.signature = signature
        self.handler = handler
    }

    /// Installs the Carbon event handler. Safe to call more than once.
    @discardableResult
    public func install() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if handlerRef != nil { return true }
        var spec = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )
        var reference: EventHandlerRef?
        let status = InstallEventHandler(
            GetApplicationEventTarget(),
            { _, event, userData in
                guard let event, let userData else { return noErr }
                var hotKeyID = EventHotKeyID()
                let result = GetEventParameter(
                    event,
                    EventParamName(kEventParamDirectObject),
                    EventParamType(typeEventHotKeyID),
                    nil,
                    MemoryLayout<EventHotKeyID>.size,
                    nil,
                    &hotKeyID
                )
                guard result == noErr else { return result }
                let manager = Unmanaged<GlobalHotkeyManager>.fromOpaque(userData).takeUnretainedValue()
                manager.fire(identifier: hotKeyID.id)
                return noErr
            },
            1,
            &spec,
            Unmanaged.passUnretained(self).toOpaque(),
            &reference
        )
        guard status == noErr else { return false }
        handlerRef = reference
        return true
    }

    /// Registers a hot key.
    ///
    /// - Returns: `true` when macOS accepted the combination. A refusal means
    ///   another application already owns it.
    @discardableResult
    public func register(_ hotkey: Hotkey, identifier: UInt32) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        var reference: EventHotKeyRef?
        let status = RegisterEventHotKey(
            UInt32(hotkey.keyCode),
            UInt32(hotkey.modifiers),
            EventHotKeyID(signature: signature, id: identifier),
            GetApplicationEventTarget(),
            0,
            &reference
        )
        guard status == noErr, let reference else { return false }
        references.append(reference)
        return true
    }

    /// Registers the ANSI alias of a hot key.
    ///
    /// The alias is the same shortcut on the US layout's key code. It is
    /// registered next to the real one so the shortcut keeps working when the
    /// keyboard layout is changed.
    ///
    /// - Returns: `true` when macOS accepted the combination.
    @discardableResult
    public func registerAlias(_ hotkey: Hotkey, identifier: UInt32) -> Bool {
        guard let alias = hotkey.ansiKeyCode, alias != hotkey.keyCode else { return false }
        var aliasHotkey = hotkey
        aliasHotkey.keyCode = alias
        return register(aliasHotkey, identifier: identifier)
    }

    /// Removes every hot key this manager registered.
    public func unregisterAll() {
        lock.lock()
        defer { lock.unlock() }
        for reference in references {
            UnregisterEventHotKey(reference)
        }
        references.removeAll()
    }

    /// Removes the Carbon event handler.
    public func uninstall() {
        unregisterAll()
        lock.lock()
        defer { lock.unlock() }
        if let handlerRef {
            RemoveEventHandler(handlerRef)
            self.handlerRef = nil
        }
    }

    private func fire(identifier: UInt32) {
        lock.lock()
        let now = Date()
        if identifier == lastFired.id && now.timeIntervalSince(lastFired.at) < 0.05 {
            lock.unlock()
            return
        }
        lastFired = (identifier, now)
        lock.unlock()
        handler(identifier)
    }
}
