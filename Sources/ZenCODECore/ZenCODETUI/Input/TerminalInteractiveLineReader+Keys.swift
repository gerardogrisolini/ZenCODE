//
//  TerminalInteractiveLineReader+Keys.swift
//  ZenCODE
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
    func readKey(pollTimeoutMilliseconds: Int32? = nil) -> Key? {
        guard case let .key(key) = readKeyResult(
            pollTimeoutMilliseconds: pollTimeoutMilliseconds
        ) else {
            return nil
        }
        return key
    }

    func readKeyResult(pollTimeoutMilliseconds: Int32? = nil) -> KeyReadResult {
        let byte: UInt8
        switch rawInput.readByteResult(timeoutMilliseconds: pollTimeoutMilliseconds) {
        case let .byte(value):
            byte = value
        case .timedOut:
            return .timedOut
        case .endOfInput:
            return .endOfInput
        }

        if let key = Self.controlKey(for: byte) {
            return .key(key)
        }

        switch byte {
        case 0x1B:
            return .key(readEscapeKey())
        default:
            return .key(decodeCharacter(startingWith: byte).map(Key.character) ?? .unknown)
        }
    }

    /// Control codes are the only motion bindings that survive every terminal
    /// configuration. Laptop keyboards without Home/End (and macOS terminals,
    /// which never forward Command shortcuts) depend on the Emacs/readline set
    /// below, so `Ctrl+A`/`Ctrl+E` must mean line start/end. Access mode is on
    /// `Ctrl+G` for that reason.
    static func controlKey(for byte: UInt8) -> Key? {
        switch byte {
        case 0x04: return .endOfInput
        case 0x01: return .home
        case 0x05: return .end
        case 0x02: return .left
        case 0x06: return .right
        case 0x10: return .up
        case 0x0E: return .down
        case 0x07: return .toggleAccessMode
        case 0x0B: return .clearAfterCursor
        case 0x12: return .reverseSearch
        case 0x15: return .clearBeforeCursor
        case 0x14: return .toggleToolDetails
        case 0x17: return .deleteWordBefore
        case 0x0D: return .enter
        case 0x09: return .tab
        case 0x7F, 0x08: return .backspace
        default: return nil
        }
    }

    func readEscapeKey() -> Key {
        guard let secondByte = readByte(timeoutMilliseconds: Self.escapeSequenceInitialTimeout) else {
            return .cancel
        }

        switch secondByte {
        case 0x0A, 0x0D:
            // Legacy Option+Enter (ESC+CR) fallback for terminals without an
            // extended keyboard protocol, where Shift+Enter is not detectable.
            return .newline
        case 0x5B:
            return readCSIKey()
        case 0x4F:
            return readSS3Key()
        case 0x1B:
            // Meta-prefixed escape sequence (ESC ESC [ …): the encoding used by
            // macOS Terminal.app and iTerm2 when the Option key is configured
            // as Meta/"Esc+", where Option+← arrives as ESC before the plain
            // cursor sequence instead of as a CSI modifier parameter.
            return readMetaPrefixedEscapeKey()
        // Legacy Meta encodings: terminals that send Alt as an ESC prefix
        // rather than a CSI modifier, which is still the default on macOS
        // Terminal.app and many `xterm` configurations.
        case 0x62, 0x42:
            return .wordLeft
        case 0x66, 0x46:
            return .wordRight
        case 0x64, 0x44:
            return .deleteWordAfter
        // `ESC <` / `ESC >` are the readline draft-wide motions. They are the
        // only start/end-of-draft bindings reachable on keyboards without
        // Home/End keys, where Ctrl+Home/Ctrl+End cannot be typed.
        case 0x3C:
            return .bufferStart
        case 0x3E:
            return .bufferEnd
        case 0x7F, 0x08:
            // Alt+Backspace (macOS Option+Delete) clears the whole draft;
            // word-wise deletion stays on Ctrl+W.
            return .clearDraft
        default:
            drainPendingEscapeSequence()
            return .unknown
        }
    }

    /// Reads the sequence following a doubled `ESC` and reinterprets it as an
    /// Alt-modified key. A lone doubled `ESC` stays a cancel request.
    func readMetaPrefixedEscapeKey() -> Key {
        guard let byte = readByte(timeoutMilliseconds: Self.escapeSequenceContinuationTimeout) else {
            return .cancel
        }

        switch byte {
        case 0x5B:
            return Self.metaModified(readCSIKey())
        case 0x4F:
            return Self.metaModified(readSS3Key())
        default:
            drainPendingEscapeSequence()
            return .unknown
        }
    }

    /// Applies the Alt modifier to a key decoded from a meta-prefixed sequence.
    static func metaModified(_ key: Key) -> Key {
        switch key {
        case .left:
            return .wordLeft
        case .right:
            return .wordRight
        case .home:
            return .bufferStart
        case .end:
            return .bufferEnd
        case .delete:
            return .deleteWordAfter
        case .backspace:
            return .clearDraft
        default:
            return key
        }
    }

    func readCSIKey() -> Key {
        var bytes: [UInt8] = []
        while bytes.count < Self.escapeSequenceMaximumLength {
            guard let byte = readByte(timeoutMilliseconds: Self.escapeSequenceContinuationTimeout) else {
                return .unknown
            }
            bytes.append(byte)
            if byte >= 0x40 && byte <= 0x7E {
                return keyFromCSI(bytes)
            }
        }

        drainPendingEscapeSequence()
        return .unknown
    }

    func readSS3Key() -> Key {
        guard let byte = readByte(timeoutMilliseconds: Self.escapeSequenceContinuationTimeout) else {
            return .unknown
        }

        switch byte {
        case 0x41:
            return .up
        case 0x42:
            return .down
        case 0x43:
            return .right
        case 0x44:
            return .left
        case 0x46:
            return .end
        case 0x48:
            return .home
        default:
            drainPendingEscapeSequence()
            return .unknown
        }
    }

    func keyFromCSI(_ bytes: [UInt8]) -> Key {
        guard let finalByte = bytes.last else {
            return .unknown
        }

        switch finalByte {
        case 0x41, 0x42, 0x43, 0x44, 0x46, 0x48:
            let components = Self.csiComponents(bytes)
            return Self.cursorKey(
                finalByte: finalByte,
                modifierBits: Self.cursorModifierBits(components: components)
            )
        case 0x7E:
            return tildeTerminatedKey(bytes)
        case 0x75:
            return csiUKey(bytes)
        default:
            return .unknown
        }
    }

    static func csiComponents(_ bytes: [UInt8]) -> [String] {
        guard let sequence = String(validating: bytes.dropLast(), as: UTF8.self) else {
            return []
        }
        return sequence.split(separator: ";", omittingEmptySubsequences: false).map(String.init)
    }

    /// Modifier bitmask of a cursor sequence.
    ///
    /// The canonical form is `CSI 1;<modifier><final>`, but several terminals
    /// (rxvt derivatives, some tmux versions) drop the leading `1` and send the
    /// modifier alone. Reading a lone parameter as a modifier only when it is
    /// greater than one keeps the unmodified `CSI 1D` unaffected.
    static func cursorModifierBits(components: [String]) -> Int {
        if components.count >= 2, let modifier = integerPrefix(in: components[1]), modifier > 0 {
            return modifier - 1
        }
        if components.count == 1,
           let modifier = integerPrefix(in: components[0]),
           modifier > 1 {
            return modifier - 1
        }
        return 0
    }

    /// Ctrl and Alt are treated as equivalent "jump" modifiers because the two
    /// conventions are split across platforms: macOS terminals send Alt for
    /// word motion, Linux consoles and PuTTY send Ctrl.
    static func cursorKey(finalByte: UInt8, modifierBits: Int) -> Key {
        let isJumpModified = (modifierBits & 0b110) != 0
        let isControlModified = (modifierBits & 0b100) != 0

        switch finalByte {
        case 0x41:
            return .up
        case 0x42:
            return .down
        case 0x43:
            return isJumpModified ? .wordRight : .right
        case 0x44:
            return isJumpModified ? .wordLeft : .left
        case 0x46:
            return isControlModified ? .bufferEnd : .end
        case 0x48:
            return isControlModified ? .bufferStart : .home
        default:
            return .unknown
        }
    }

    func tildeTerminatedKey(_ bytes: [UInt8]) -> Key {
        guard let sequence = String(validating: bytes.dropLast(), as: UTF8.self) else {
            return .unknown
        }
        let components = sequence.split(separator: ";").map(String.init)
        if let key = Self.shiftReturnKey(components: components, keyCodeIndex: 0, modifierIndex: 1) {
            return key
        }
        if let key = Self.modifyOtherKeysKey(components: components) {
            return key
        }
        let numericPrefix = components.first
        let modifierBits = components.count >= 2
            ? max(0, (Self.integerPrefix(in: components[1]) ?? 1) - 1)
            : 0
        let isJumpModified = (modifierBits & 0b110) != 0
        let isControlModified = (modifierBits & 0b100) != 0

        switch numericPrefix {
        case "200":
            return .paste(readBracketedPaste())
        case "201":
            return .unknown
        case "1", "7":
            return isControlModified ? .bufferStart : .home
        case "3":
            return isJumpModified ? .deleteWordAfter : .delete
        case "4", "8":
            return isControlModified ? .bufferEnd : .end
        default:
            return .unknown
        }
    }

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
        // Shift (0b01) or Alt (0b10): both are newline shortcuts, matching
        // the legacy ESC+CR (Option+Enter) fallback path.
        return (modifierBits & 0b11) != 0 ? .newline : .enter
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
        case 16:
            return .up
        case 11:
            return .clearAfterCursor
        case 18:
            return .reverseSearch
        case 20:
            return .toggleToolDetails
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
    /// while Alt+B moves one word left, and accepting either modifier would
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
        case 98 where isControlModified:
            return .left
        case 102 where isControlModified:
            return .right
        case 112 where isControlModified:
            return .up
        case 110 where isControlModified:
            return .down
        case 100 where isControlModified:
            // Ctrl+D is end-of-input, never the Alt+D delete-word binding.
            return .endOfInput
        case 107 where isControlModified:
            return .clearAfterCursor
        case 116 where isControlModified:
            return .toggleToolDetails
        case 117 where isControlModified:
            return .clearBeforeCursor
        case 114 where isControlModified:
            return .reverseSearch
        case 101 where isControlModified:
            return .end
        case 119 where isControlModified:
            return .deleteWordBefore
        case 98 where isAltModified:
            return .wordLeft
        case 102 where isAltModified:
            return .wordRight
        case 100 where isAltModified:
            return .deleteWordAfter
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

    func decodeCharacter(startingWith firstByte: UInt8) -> String? {
        guard firstByte >= 0x20 else {
            return nil
        }

        let byteCount = utf8ByteCount(startingWith: firstByte)
        guard byteCount > 0 else {
            return nil
        }
        guard byteCount > 1 else {
            return String(validating: [firstByte], as: UTF8.self)
        }

        var bytes = [firstByte]
        while bytes.count < byteCount {
            guard let byte = readByte(timeoutMilliseconds: Self.escapeSequenceContinuationTimeout) else {
                return nil
            }
            bytes.append(byte)
        }
        return String(validating: bytes, as: UTF8.self)
    }

    func utf8ByteCount(startingWith byte: UInt8) -> Int {
        if byte & 0b1000_0000 == 0 {
            return 1
        }
        if byte & 0b1110_0000 == 0b1100_0000 {
            return 2
        }
        if byte & 0b1111_0000 == 0b1110_0000 {
            return 3
        }
        if byte & 0b1111_1000 == 0b1111_0000 {
            return 4
        }
        return 0
    }

    func drainPendingEscapeSequence() {
        while readByte(timeoutMilliseconds: Self.escapeSequenceContinuationTimeout) != nil {}
    }

    func readByte(timeoutMilliseconds: Int32? = nil) -> UInt8? {
        rawInput.readByte(timeoutMilliseconds: timeoutMilliseconds)
    }
}
