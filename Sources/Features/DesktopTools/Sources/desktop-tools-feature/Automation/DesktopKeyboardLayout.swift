import Carbon
import CoreGraphics
import Foundation

/// Modifier layer used while searching which physical key produces a character.
enum DesktopKeyLayer: CaseIterable, Sendable {
    case none, shift, option, shiftOption

    /// Carbon modifier bits shifted right by 8, as expected by `UCKeyTranslate`.
    var ucModifierState: UInt32 {
        switch self {
        case .none: 0
        case .shift: 2
        case .option: 8
        case .shiftOption: 10
        }
    }

    var eventFlags: CGEventFlags {
        switch self {
        case .none: []
        case .shift: .maskShift
        case .option: .maskAlternate
        case .shiftOption: [.maskShift, .maskAlternate]
        }
    }
}

protocol DesktopKeyTranslating {
    func character(forKeyCode keyCode: CGKeyCode, layer: DesktopKeyLayer) -> String?
}

/// Translates key codes using the current keyboard layout. Main-actor only, not Sendable.
struct CarbonKeyTranslator: DesktopKeyTranslating {
    private let layoutData: CFData
    private let keyboardType: UInt32

    @MainActor
    init?() {
        guard let source = TISCopyCurrentKeyboardLayoutInputSource()?.takeRetainedValue(),
              let raw = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData) else { return nil }
        layoutData = Unmanaged<CFData>.fromOpaque(raw).takeUnretainedValue()
        keyboardType = UInt32(LMGetKbdType())
    }

    func character(forKeyCode keyCode: CGKeyCode, layer: DesktopKeyLayer) -> String? {
        guard let bytes = CFDataGetBytePtr(layoutData) else { return nil }
        let modifierState = layer.ucModifierState
        let keyboardType = self.keyboardType
        return bytes.withMemoryRebound(to: UCKeyboardLayout.self, capacity: 1) { layout in
            var deadKeyState: UInt32 = 0
            var length = 0
            var characters = [UniChar](repeating: 0, count: 4)
            let status = UCKeyTranslate(
                layout, keyCode, UInt16(kUCKeyActionDown), modifierState,
                keyboardType, OptionBits(kUCKeyTranslateNoDeadKeysMask),
                &deadKeyState, characters.count, &length, &characters
            )
            guard status == noErr, length > 0 else { return nil }
            return String(utf16CodeUnits: characters, count: length)
        }
    }
}

enum DesktopKeyResolver {

    static func resolve(_ name: String, translator: (any DesktopKeyTranslating)?) throws -> (keyCode: CGKeyCode, flags: CGEventFlags) {
        let normalized = name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if let code = namedKeyCodes[normalized] {
            return (code, [])
        }
        if normalized.count == 1 {
            if let translator {
                for layer in DesktopKeyLayer.allCases {
                    for code in typingKeyCodes where translator.character(forKeyCode: code, layer: layer) == normalized {
                        return (code, layer.eventFlags)
                    }
                }
            } else if let code = usCharacterKeyCodes[normalized] {
                return (code, [])
            }
            throw DesktopControlError.invalidArgument(
                "key",
                "'\(name)' cannot be typed with a single key on the current keyboard layout; use type_text for text."
            )
        }
        throw DesktopControlError.invalidArgument(
            "key",
            "unsupported key '\(name)'. Use a single character or a named key (return, tab, space, escape, delete, forward_delete, left, right, up, down, home, end, page_up, page_down, f1-f20, keypad_0-keypad_9, ...); use type_text for text."
        )
    }

    /// Typing keycodes searched in ascending order; return, tab and space are excluded, JIS keys come last.
    static let typingKeyCodes: [CGKeyCode] = (0...50).filter { $0 != 36 && $0 != 48 && $0 != 49 }.map { CGKeyCode($0) } + [93, 94]

    static let namedKeyCodes: [String: CGKeyCode] = [
        "return": 36, "enter": 36, "tab": 48, "space": 49,
        "delete": 51, "backspace": 51, "escape": 53, "esc": 53,
        "f17": 64, "keypad_decimal": 65, "keypad_multiply": 67, "keypad_plus": 69, "keypad_clear": 71,
        "volume_up": 72, "volume_down": 73, "mute": 74, "keypad_divide": 75, "keypad_enter": 76,
        "keypad_minus": 78, "f18": 79, "f19": 80, "keypad_equals": 81, "keypad_0": 82,
        "keypad_1": 83, "keypad_2": 84, "keypad_3": 85, "keypad_4": 86, "keypad_5": 87,
        "keypad_6": 88, "keypad_7": 89, "f20": 90, "keypad_8": 91, "keypad_9": 92,
        "f5": 96, "f6": 97, "f7": 98, "f3": 99, "f8": 100, "f9": 101, "f11": 103,
        "f13": 105, "f16": 106, "f14": 107, "f10": 109, "f12": 111, "f15": 113,
        "help": 114, "home": 115, "page_up": 116, "forward_delete": 117, "f4": 118, "end": 119,
        "f2": 120, "page_down": 121, "f1": 122, "left": 123, "right": 124, "down": 125, "up": 126
    ]

    static let usCharacterKeyCodes: [String: CGKeyCode] = [
        "a": 0, "s": 1, "d": 2, "f": 3, "h": 4, "g": 5, "z": 6, "x": 7, "c": 8, "v": 9,
        "b": 11, "q": 12, "w": 13, "e": 14, "r": 15, "y": 16, "t": 17,
        "1": 18, "2": 19, "3": 20, "4": 21, "6": 22, "5": 23, "=": 24, "9": 25, "7": 26,
        "-": 27, "8": 28, "0": 29, "]": 30, "o": 31, "u": 32, "[": 33, "i": 34, "p": 35,
        "l": 37, "j": 38, "'": 39, "k": 40, ";": 41, "\\": 42,
        ",": 43, "/": 44, "n": 45, "m": 46, ".": 47, "`": 50
    ]
}
