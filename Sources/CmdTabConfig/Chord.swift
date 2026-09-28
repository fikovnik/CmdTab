import Carbon.HIToolbox
import Foundation

/// A key plus the modifiers held with it, one line of the config's `keys`
/// table, parsed.
///
/// The modifier encoding is deliberately the NSEvent-style mask rather than
/// `CGEventFlags`, because that is what both channels of a symbolic hotkey
/// install expect: the `com.apple.symbolichotkeys` plist stores it, and
/// `CGSSetSymbolicHotKeyValue` takes it. Converting to `CGEventFlags` happens
/// once, in the event tap, and only for the chords the tap owns.
public struct Chord: Hashable, Sendable {
    public struct Modifiers: OptionSet, Hashable, Sendable {
        public let rawValue: UInt32
        public init(rawValue: UInt32) { self.rawValue = rawValue }

        public static let shift = Modifiers(rawValue: 0x0002_0000)
        public static let control = Modifiers(rawValue: 0x0004_0000)
        public static let option = Modifiers(rawValue: 0x0008_0000)
        public static let command = Modifiers(rawValue: 0x0010_0000)
        public static let function = Modifiers(rawValue: 0x0080_0000)

        /// Everything an event tap can match on. `function` is absent on
        /// purpose: arrow and function keys set it implicitly, so a tap-side
        /// chord naming it could never match, and one not naming it would
        /// match when it should not. Only the WindowServer can honour `fn`.
        public static let tapMatchable: Modifiers = [.shift, .control, .option, .command]
    }

    public let keyCode: UInt16
    public let modifiers: Modifiers

    public init(keyCode: UInt16, modifiers: Modifiers) {
        self.keyCode = keyCode
        self.modifiers = modifiers
    }

    public enum ParseError: Error, Equatable, CustomStringConvertible {
        case empty
        case unknownModifier(String)
        case unknownKey(String)

        public var description: String {
            switch self {
            case .empty: "empty chord"
            case .unknownModifier(let m): "unknown modifier \"\(m)\""
            case .unknownKey(let k): "unknown key \"\(k)\""
            }
        }
    }

    /// Parse `"ctrl-alt-cmd-h"`. Modifiers may appear in any order.
    public init(parsing text: String) throws {
        let lower = text.lowercased()
        var tokens = lower.split(separator: "-").map(String.init)
        let keyName: String
        if lower.hasSuffix("-") {
            // A trailing separator names the minus key: "cmd--", or bare "-".
            keyName = "minus"
        } else {
            guard let last = tokens.popLast() else { throw ParseError.empty }
            keyName = last
        }

        var mods = Modifiers()
        for token in tokens {
            switch token {
            case "cmd", "command": mods.insert(.command)
            case "ctrl", "control": mods.insert(.control)
            case "alt", "opt", "option": mods.insert(.option)
            case "shift": mods.insert(.shift)
            case "fn", "function": mods.insert(.function)
            default: throw ParseError.unknownModifier(token)
            }
        }

        guard let key = Chord.keys[keyName] else { throw ParseError.unknownKey(keyName) }
        self.keyCode = key.code
        self.modifiers = mods
    }

    /// The character the symbolic hotkey plist and SPI record alongside the key
    /// code. `0xFFFF` for keys with no ASCII equivalent, which is what macOS
    /// itself stores for arrows and function keys.
    public var charCode: UInt16 {
        Chord.keys.values.first { $0.code == keyCode }?.char ?? 0xFFFF
    }

    public func removing(_ m: Modifiers) -> Chord {
        Chord(keyCode: keyCode, modifiers: modifiers.subtracting(m))
    }

    /// Just the modifier glyphs, in Apple's order. What the HUD footer needs
    /// to say which key to release.
    public var modifierDisplay: String {
        var s = ""
        if modifiers.contains(.function) { s += "fn" }
        if modifiers.contains(.control) { s += "\u{2303}" }
        if modifiers.contains(.option) { s += "\u{2325}" }
        if modifiers.contains(.shift) { s += "\u{21E7}" }
        if modifiers.contains(.command) { s += "\u{2318}" }
        return s
    }

    public var display: String { modifierDisplay + Chord.glyph(forKeyCode: keyCode) }

    static func glyph(forKeyCode code: UInt16) -> String {
        if let named = displayGlyphs[code] { return named }
        if let entry = keys.values.first(where: { $0.code == code }), entry.char != 0xFFFF,
           let scalar = UnicodeScalar(entry.char) {
            return String(scalar).uppercased()
        }
        return "?"
    }

    private static let displayGlyphs: [UInt16: String] = [
        UInt16(kVK_Tab): "\u{21E5}", UInt16(kVK_Space): "space",
        UInt16(kVK_Return): "\u{21A9}", UInt16(kVK_Escape): "esc",
        UInt16(kVK_Delete): "\u{232B}", UInt16(kVK_ForwardDelete): "\u{2326}",
        UInt16(kVK_LeftArrow): "\u{2190}", UInt16(kVK_RightArrow): "\u{2192}",
        UInt16(kVK_UpArrow): "\u{2191}", UInt16(kVK_DownArrow): "\u{2193}",
        UInt16(kVK_PageUp): "\u{21DE}", UInt16(kVK_PageDown): "\u{21DF}",
        UInt16(kVK_Home): "\u{2196}", UInt16(kVK_End): "\u{2198}",
    ]

    struct Key: Sendable {
        let code: UInt16
        /// ASCII equivalent, or `0xFFFF` when the key has none.
        let char: UInt16
    }

    /// Name → (key code, ASCII equivalent). The char values match what macOS
    /// stores in `com.apple.symbolichotkeys` for its own defaults, which is how
    /// they were checked: Fill is key 3 / char 102 (`f`), Minimize is key 46 /
    /// char 109 (`m`), Tile Left Half is key 123 / char 65535 (an arrow).
    static let keys: [String: Key] = {
        var t: [String: Key] = [:]
        func add(_ name: String, _ code: Int, _ char: UInt16, aliases: [String] = []) {
            let key = Key(code: UInt16(code), char: char)
            t[name] = key
            for a in aliases { t[a] = key }
        }
        func ascii(_ name: String, _ code: Int) {
            add(name, code, UInt16(name.unicodeScalars.first!.value))
        }

        ascii("a", kVK_ANSI_A); ascii("b", kVK_ANSI_B); ascii("c", kVK_ANSI_C)
        ascii("d", kVK_ANSI_D); ascii("e", kVK_ANSI_E); ascii("f", kVK_ANSI_F)
        ascii("g", kVK_ANSI_G); ascii("h", kVK_ANSI_H); ascii("i", kVK_ANSI_I)
        ascii("j", kVK_ANSI_J); ascii("k", kVK_ANSI_K); ascii("l", kVK_ANSI_L)
        ascii("m", kVK_ANSI_M); ascii("n", kVK_ANSI_N); ascii("o", kVK_ANSI_O)
        ascii("p", kVK_ANSI_P); ascii("q", kVK_ANSI_Q); ascii("r", kVK_ANSI_R)
        ascii("s", kVK_ANSI_S); ascii("t", kVK_ANSI_T); ascii("u", kVK_ANSI_U)
        ascii("v", kVK_ANSI_V); ascii("w", kVK_ANSI_W); ascii("x", kVK_ANSI_X)
        ascii("y", kVK_ANSI_Y); ascii("z", kVK_ANSI_Z)

        ascii("0", kVK_ANSI_0); ascii("1", kVK_ANSI_1); ascii("2", kVK_ANSI_2)
        ascii("3", kVK_ANSI_3); ascii("4", kVK_ANSI_4); ascii("5", kVK_ANSI_5)
        ascii("6", kVK_ANSI_6); ascii("7", kVK_ANSI_7); ascii("8", kVK_ANSI_8)
        ascii("9", kVK_ANSI_9)

        add("grave", kVK_ANSI_Grave, 96, aliases: ["`", "backtick"])
        add("minus", kVK_ANSI_Minus, 45)
        add("equal", kVK_ANSI_Equal, 61, aliases: ["="])
        add("leftbracket", kVK_ANSI_LeftBracket, 91, aliases: ["["])
        add("rightbracket", kVK_ANSI_RightBracket, 93, aliases: ["]"])
        add("backslash", kVK_ANSI_Backslash, 92)
        add("semicolon", kVK_ANSI_Semicolon, 59, aliases: [";"])
        add("quote", kVK_ANSI_Quote, 39, aliases: ["'"])
        add("comma", kVK_ANSI_Comma, 44, aliases: [","])
        add("period", kVK_ANSI_Period, 46, aliases: ["."])
        add("slash", kVK_ANSI_Slash, 47, aliases: ["/"])

        add("tab", kVK_Tab, 9)
        add("space", kVK_Space, 32)
        add("return", kVK_Return, 13, aliases: ["enter"])
        add("keypadenter", kVK_ANSI_KeypadEnter, 3)
        add("escape", kVK_Escape, 27, aliases: ["esc"])
        add("delete", kVK_Delete, 8, aliases: ["backspace"])
        add("forwarddelete", kVK_ForwardDelete, 0xFFFF)

        add("left", kVK_LeftArrow, 0xFFFF, aliases: ["leftarrow"])
        add("right", kVK_RightArrow, 0xFFFF, aliases: ["rightarrow"])
        add("up", kVK_UpArrow, 0xFFFF, aliases: ["uparrow"])
        add("down", kVK_DownArrow, 0xFFFF, aliases: ["downarrow"])
        add("pageup", kVK_PageUp, 0xFFFF)
        add("pagedown", kVK_PageDown, 0xFFFF)
        add("home", kVK_Home, 0xFFFF)
        add("end", kVK_End, 0xFFFF)

        let fkeys = [kVK_F1, kVK_F2, kVK_F3, kVK_F4, kVK_F5, kVK_F6, kVK_F7, kVK_F8,
                     kVK_F9, kVK_F10, kVK_F11, kVK_F12, kVK_F13, kVK_F14, kVK_F15,
                     kVK_F16, kVK_F17, kVK_F18, kVK_F19, kVK_F20]
        for (i, code) in fkeys.enumerated() { add("f\(i + 1)", code, 0xFFFF) }

        return t
    }()
}
