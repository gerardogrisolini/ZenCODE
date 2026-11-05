//
//  TerminalModifierKeyStateTests.swift
//  ZenCODE
//
//  Created by Gerardo Grisolini on 05/11/26.
//

import Foundation
import Synchronization
import Testing
@testable import ZenCODECore

/// Shift+Enter, Option+Backspace and Option+</> in terminals that send them
/// as a plain `CR`/`DEL` or as a layout character (Terminal.app): the decoder
/// resolves them through the modifier state of the local keyboard.
@Suite
struct TerminalModifierKeyStateTests {
    private static func makeReader(
        pipe: Pipe,
        isShiftPressed: @escaping @Sendable () -> Bool = { false },
        isOptionPressed: @escaping @Sendable () -> Bool = { false }
    ) -> TerminalInteractiveLineReader {
        TerminalInteractiveLineReader(
            rawInput: TerminalRawInput(
                fileDescriptor: pipe.fileHandleForReading.fileDescriptor
            ),
            modifierKeyState: TerminalModifierKeyState(
                isShiftPressed: isShiftPressed,
                isOptionPressed: isOptionPressed
            )
        )
    }

    @Test
    func plainCarriageReturnWithShiftHeldDecodesAsNewline() {
        let pipe = Pipe()
        let reader = Self.makeReader(pipe: pipe, isShiftPressed: { true })

        pipe.fileHandleForWriting.write(Data([0x0D]))
        #expect(reader.readKey(pollTimeoutMilliseconds: 500) == .newline)

        pipe.fileHandleForWriting.closeFile()
    }

    @Test
    func plainCarriageReturnWithoutShiftDecodesAsEnter() {
        let pipe = Pipe()
        let reader = Self.makeReader(pipe: pipe, isShiftPressed: { false })

        pipe.fileHandleForWriting.write(Data([0x0D]))
        #expect(reader.readKey(pollTimeoutMilliseconds: 500) == .enter)

        pipe.fileHandleForWriting.closeFile()
    }

    /// Terminals with an extended keyboard protocol already report their
    /// modifiers, so the Shift state never overrides what they encode.
    @Test
    func extendedKeyboardSequencesIgnoreShiftState() {
        let pipe = Pipe()
        let reader = Self.makeReader(pipe: pipe, isShiftPressed: { true })

        // CSI-u Enter without modifiers: `ESC [ 13 u`.
        pipe.fileHandleForWriting.write(Data([0x1B, 0x5B, 0x31, 0x33, 0x75]))
        #expect(reader.readKey(pollTimeoutMilliseconds: 500) == .enter)

        pipe.fileHandleForWriting.closeFile()
    }

    /// Terminal.app sends Shift+Enter as `ESC CR`: it is a newline on its own,
    /// without asking macOS for the Shift state.
    @Test
    func escapeCarriageReturnDecodesAsNewlineWithoutProbingShift() {
        let pipe = Pipe()
        let probeCount = Mutex(0)
        let reader = Self.makeReader(pipe: pipe, isShiftPressed: {
            probeCount.withLock { $0 += 1 }
            return false
        })

        pipe.fileHandleForWriting.write(Data([0x1B, 0x0D]))
        #expect(reader.readKey(pollTimeoutMilliseconds: 500) == .newline)
        #expect(probeCount.withLock { $0 } == 0)

        pipe.fileHandleForWriting.closeFile()
    }

    @Test
    func shiftStateIsProbedOnlyForPlainCarriageReturn() {
        let pipe = Pipe()
        let probeCount = Mutex(0)
        let reader = Self.makeReader(pipe: pipe, isShiftPressed: {
            probeCount.withLock { $0 += 1 }
            return false
        })

        pipe.fileHandleForWriting.write(Data([0x61]))
        #expect(reader.readKey(pollTimeoutMilliseconds: 500) == .character("a"))
        #expect(probeCount.withLock { $0 } == 0)

        pipe.fileHandleForWriting.write(Data([0x0D]))
        #expect(reader.readKey(pollTimeoutMilliseconds: 500) == .enter)
        #expect(probeCount.withLock { $0 } == 1)

        pipe.fileHandleForWriting.closeFile()
    }

    @Test
    func plainDeleteWithOptionHeldDecodesAsClearDraft() {
        let pipe = Pipe()
        let reader = Self.makeReader(pipe: pipe, isOptionPressed: { true })

        pipe.fileHandleForWriting.write(Data([0x7F]))
        #expect(reader.readKey(pollTimeoutMilliseconds: 500) == .clearDraft)

        // "Delete sends Ctrl-H" turns the same key into BS.
        pipe.fileHandleForWriting.write(Data([0x08]))
        #expect(reader.readKey(pollTimeoutMilliseconds: 500) == .clearDraft)

        pipe.fileHandleForWriting.closeFile()
    }

    @Test
    func plainDeleteWithoutOptionDecodesAsBackspace() {
        let pipe = Pipe()
        let reader = Self.makeReader(pipe: pipe, isShiftPressed: { true })

        pipe.fileHandleForWriting.write(Data([0x7F]))
        #expect(reader.readKey(pollTimeoutMilliseconds: 500) == .backspace)

        pipe.fileHandleForWriting.closeFile()
    }

    /// Option is read only for Backspace and the Option+</> characters:
    /// Option+Enter keeps submitting and Option never changes another typed
    /// character or an escape sequence.
    @Test
    func optionStateIsProbedOnlyForBackspaceAndDraftMotionCharacters() {
        let pipe = Pipe()
        let probeCount = Mutex(0)
        let reader = Self.makeReader(pipe: pipe, isOptionPressed: {
            probeCount.withLock { $0 += 1 }
            return true
        })

        pipe.fileHandleForWriting.write(Data([0x61]))
        #expect(reader.readKey(pollTimeoutMilliseconds: 500) == .character("a"))

        pipe.fileHandleForWriting.write(Data([0x0D]))
        #expect(reader.readKey(pollTimeoutMilliseconds: 500) == .enter)

        // CSI 3~ is the forward Delete key, not Backspace.
        pipe.fileHandleForWriting.write(Data([0x1B, 0x5B, 0x33, 0x7E]))
        #expect(reader.readKey(pollTimeoutMilliseconds: 500) == .delete)
        #expect(probeCount.withLock { $0 } == 0)

        pipe.fileHandleForWriting.write(Data([0x7F]))
        #expect(reader.readKey(pollTimeoutMilliseconds: 500) == .clearDraft)
        #expect(probeCount.withLock { $0 } == 1)

        pipe.fileHandleForWriting.write(Data("\u{2264}".utf8))
        #expect(reader.readKey(pollTimeoutMilliseconds: 500) == .bufferStart)
        #expect(probeCount.withLock { $0 } == 2)

        pipe.fileHandleForWriting.closeFile()
    }

    /// U.S./British/ABC type `¯`/`˘` for Option+Shift+,/. (`<`/`>`), Italian,
    /// German and French type `≤`/`≥` for Option+</>.
    @Test
    func optionDraftMotionCharactersWithOptionHeldMoveToDraftEnds() {
        let pipe = Pipe()
        let reader = Self.makeReader(pipe: pipe, isOptionPressed: { true })

        for (character, key) in [
            ("\u{AF}", TerminalInteractiveLineReader.Key.bufferStart),
            ("\u{2264}", .bufferStart),
            ("\u{2D8}", .bufferEnd),
            ("\u{2265}", .bufferEnd),
        ] {
            pipe.fileHandleForWriting.write(Data(character.utf8))
            #expect(reader.readKey(pollTimeoutMilliseconds: 500) == key)
        }

        // Spanish Option+</> types `[`/`{`, which stay ordinary characters.
        pipe.fileHandleForWriting.write(Data("[".utf8))
        #expect(reader.readKey(pollTimeoutMilliseconds: 500) == .character("["))

        pipe.fileHandleForWriting.closeFile()
    }

    @Test
    func optionDraftMotionCharactersWithoutOptionAreTyped() {
        let pipe = Pipe()
        let reader = Self.makeReader(pipe: pipe)

        for character in ["\u{AF}", "\u{2264}", "\u{2D8}", "\u{2265}"] {
            pipe.fileHandleForWriting.write(Data(character.utf8))
            #expect(reader.readKey(pollTimeoutMilliseconds: 500) == .character(character))
        }

        pipe.fileHandleForWriting.closeFile()
    }

    @Test
    func sshVariablesMarkTheSessionAsRemote() {
        #expect(TerminalModifierKeyState.isLocalSession(environment: [:]))
        #expect(!TerminalModifierKeyState.isLocalSession(
            environment: ["SSH_CONNECTION": "10.0.0.2 50000 10.0.0.1 22"]
        ))
        #expect(!TerminalModifierKeyState.isLocalSession(
            environment: ["SSH_CLIENT": "10.0.0.2 50000 22"]
        ))
        #expect(!TerminalModifierKeyState.isLocalSession(
            environment: ["SSH_TTY": "/dev/ttys001"]
        ))
        #expect(TerminalModifierKeyState.isLocalSession(
            environment: ["SSH_CONNECTION": "", "SSH_CLIENT": "", "SSH_TTY": ""]
        ))
    }

    #if !os(macOS)
    @Test
    func systemProbeIsUnavailableOutsideMacOS() {
        let state = TerminalModifierKeyState.system(environment: [:])
        #expect(state.isShiftPressed() == false)
        #expect(state.isOptionPressed() == false)
    }
    #endif
}
