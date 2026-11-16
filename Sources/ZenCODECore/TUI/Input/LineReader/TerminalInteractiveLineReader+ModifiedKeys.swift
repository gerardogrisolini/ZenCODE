//
//  TerminalInteractiveLineReader+ModifiedKeys.swift
//  ZenCODE
//
//  Decoding of the modified keys reported through Kitty's CSI-u protocol and
//  xterm's modifyOtherKeys, and of bracketed paste.
//

#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif
import Dispatch
import Foundation
#if canImport(os)
import os
#endif

extension TerminalInteractiveLineReader {
    func csiUKey(_ bytes: [UInt8]) -> Key {
        guard let sequence = String(validating: bytes.dropLast(), as: UTF8.self) else {
            return .unknown
        }
        let components = sequence.split(separator: ";").map(String.init)
        guard Self.isKittyPressEvent(components: components, modifierIndex: 1) else {
            return .unknown
        }
        if let key = Self.shiftReturnKey(components: components, keyCodeIndex: 0, modifierIndex: 1) {
            return key
        }
        if let key = Self.fundamentalControlKey(
            components: components,
            keyCodeIndex: 0,
            modifierIndex: 1
        ) {
            return key
        }
        if let key = Self.shiftReturnKey(components: components, keyCodeIndex: 2, modifierIndex: 1) {
            return key
        }
        if let key = Self.fundamentalControlKey(
            components: components,
            keyCodeIndex: 2,
            modifierIndex: 1
        ) {
            return key
        }
        if let key = Self.controlShortcutKey(components: components, keyCodeIndex: 0, modifierIndex: 1) {
            return key
        }
        return .unknown
    }

    func readBracketedPaste() -> String {
        let endSequence: [UInt8] = [0x1B, 0x5B, 0x32, 0x30, 0x31, 0x7E]
        var bytes: [UInt8] = []

        while true {
            guard let byte = readByte(timeoutMilliseconds: Self.bracketedPasteByteTimeout) else {
                return Self.normalizedPastedText(bytes: bytes)
            }
            bytes.append(byte)
            if bytes.suffix(endSequence.count) == endSequence {
                bytes.removeLast(endSequence.count)
                return Self.normalizedPastedText(bytes: bytes)
            }
        }
    }

    static func normalizedPastedText(bytes: [UInt8]) -> String {
        let text = String(decoding: bytes, as: UTF8.self)
        return text
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
    }

    static func shiftReturnKey(
        components: [String],
        keyCodeIndex: Int,
        modifierIndex: Int
    ) -> Key? {
        guard components.indices.contains(keyCodeIndex),
              Self.isReturnKeyCode(Self.integerPrefix(in: components[keyCodeIndex])) else {
            return nil
        }
        guard components.indices.contains(modifierIndex),
              let modifier = Self.integerPrefix(in: components[modifierIndex]) else {
            return .enter
        }
        let modifierBits = modifier - 1
        // Only Shift (0b01) inserts a newline; Alt+Enter submits like Enter.
        return (modifierBits & 0b01) != 0 ? .newline : .enter
    }

    static func isReturnKeyCode(_ keyCode: Int?) -> Bool {
        keyCode == 10 || keyCode == 13
    }

    static func isKittyPressEvent(
        components: [String],
        modifierIndex: Int
    ) -> Bool {
        guard components.indices.contains(modifierIndex) else {
            return true
        }
        let fields = components[modifierIndex].split(
            separator: ":",
            omittingEmptySubsequences: false
        )
        guard fields.count <= 2,
              let modifier = fields.first.flatMap({ Int($0) }),
              modifier > 0 else {
            return false
        }
        guard fields.count == 2 else {
            return true
        }
        return Int(fields[1]) == 1
    }

    static func modifyOtherKeysKey(components: [String]) -> Key? {
        guard components.count == 3,
              components[0] == "27",
              Int(components[1]) != nil,
              Int(components[2]) != nil else {
            return nil
        }
        return shiftReturnKey(components: components, keyCodeIndex: 2, modifierIndex: 1)
        ?? fundamentalControlKey(components: components, keyCodeIndex: 2, modifierIndex: 1)
        ?? controlShortcutKey(components: components, keyCodeIndex: 2, modifierIndex: 1)
    }

    /// C0 keys may be reported either as their control-code value or as the
    /// printable key plus a Ctrl modifier.  Kitty and xterm use both forms
    /// depending on terminal/version, so keep the raw C0 meanings before
    /// considering modified printable shortcuts.
    static func fundamentalControlKey(
        components: [String],
        keyCodeIndex: Int,
        modifierIndex: Int
    ) -> Key? {
        guard components.indices.contains(keyCodeIndex),
              let keyCode = Self.integerPrefix(in: components[keyCodeIndex]) else {
            return nil
        }

        // C0 values have meanings only in their plain form. Enhanced keyboard
        // protocols also report e.g. Shift+Tab and Alt+Tab as C0 9; treating
        // those as plain Tab would silently accept a completion. Printable
        // Ctrl/Alt shortcuts are handled below by `controlShortcutKey`.
        if components.indices.contains(modifierIndex) {
            guard Self.integerPrefix(in: components[modifierIndex]) == 1 else {
                return nil
            }
        }

        switch keyCode {
        case 27:
            return .cancel
        case 9:
            return .tab
        case 8, 127:
            return .backspace
        case 1:
            return .home
        case 2:
            return .left
        case 4:
            return .endOfInput
        case 5:
            return .end
        case 6:
            return .right
        case 7:
            return .toggleAccessMode
        case 14:
            return .down
        case 15, 25:
            return .toggleSharedChatReader
        case 16:
            return .up
        case 11:
            return .clearAfterCursor
        case 21:
            return .clearBeforeCursor
        case 23:
            return .deleteWordBefore
        default:
            return nil
        }
    }

    /// Maps a modified printable key reported through Kitty's CSI-u protocol or
    /// xterm's `modifyOtherKeys`.
    ///
    /// Each shortcut demands its own modifier: Ctrl+B moves one character left
    /// while Alt+B is not a shortcut, and accepting either modifier would
    /// swallow a key the operator meant for something else.
    static func controlShortcutKey(
        components: [String],
        keyCodeIndex: Int,
        modifierIndex: Int
    ) -> Key? {
        guard components.indices.contains(keyCodeIndex),
              let keyCode = Self.integerPrefix(in: components[keyCodeIndex]),
              components.indices.contains(modifierIndex),
              let modifier = Self.integerPrefix(in: components[modifierIndex]),
              modifier > 0 else {
            return nil
        }

        let modifierBits = modifier - 1
        let isControlModified = (modifierBits & 0b100) != 0
        let isAltModified = (modifierBits & 0b010) != 0

        switch keyCode {
        case 97 where isControlModified:
            return .home
        case 103 where isControlModified:
            return .toggleAccessMode
        case 111 where isControlModified, 121 where isControlModified:
            return .toggleSharedChatReader
        case 98 where isControlModified:
            return .left
        case 102 where isControlModified:
            return .right
        case 112 where isControlModified:
            return .up
        case 110 where isControlModified:
            return .down
        case 100 where isControlModified:
            return .endOfInput
        case 107 where isControlModified:
            return .clearAfterCursor
        case 117 where isControlModified:
            return .clearBeforeCursor
        case 101 where isControlModified:
            return .end
        case 119 where isControlModified:
            return .deleteWordBefore
        case 127 where isAltModified, 8 where isAltModified:
            return .clearDraft
        // `Alt+<` / `Alt+>`; the base key is reported unshifted by terminals
        // that separate the Shift modifier from the key code.
        case 60 where isAltModified, 44 where isAltModified:
            return .bufferStart
        case 62 where isAltModified, 46 where isAltModified:
            return .bufferEnd
        default:
            return nil
        }
    }

    static func integerPrefix(in component: String) -> Int? {
        let prefix = component.split(separator: ":", maxSplits: 1).first
        return prefix.flatMap { Int($0) }
    }
}
