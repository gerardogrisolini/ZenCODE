//
//  ZenReaderKeyTests.swift
//  ZenApp
//
//  The reader keys the composer hands to its owner
//  (`ZenComposerLogic.readerKey(for:modifiers:)`), mirroring the terminal's
//  reader: ← → Home End between messages, ↑ ↓ to scroll; only unmodified
//  keys, so the modified ones keep their text-editing meaning.
//

import Foundation
import SwiftUI
import Testing

@testable import ZenAppControls

@Suite("Composer reader keys")
struct ZenReaderKeyTests {
    @Test("the unmodified arrows, Home and End map to the terminal's reader actions")
    func mapping() {
        #expect(ZenComposerLogic.readerKey(for: .leftArrow, modifiers: []) == .previousMessage)
        #expect(ZenComposerLogic.readerKey(for: .rightArrow, modifiers: []) == .nextMessage)
        #expect(ZenComposerLogic.readerKey(for: .home, modifiers: []) == .firstMessage)
        #expect(ZenComposerLogic.readerKey(for: .end, modifiers: []) == .lastMessage)
        #expect(ZenComposerLogic.readerKey(for: .upArrow, modifiers: []) == .scrollUp)
        #expect(ZenComposerLogic.readerKey(for: .downArrow, modifiers: []) == .scrollDown)
    }

    @Test("Caps Lock and the numeric-pad and function flags the arrow keys carry do not count")
    func ignoredFlags() {
        let flags: [EventModifiers] = [.capsLock, .numericPad, .function, [.numericPad, .function], [.capsLock, .function]]
        for flag in flags {
            #expect(ZenComposerLogic.readerKey(for: .leftArrow, modifiers: flag) == .previousMessage)
            #expect(ZenComposerLogic.readerKey(for: .rightArrow, modifiers: flag) == .nextMessage)
            #expect(ZenComposerLogic.readerKey(for: .upArrow, modifiers: flag) == .scrollUp)
            #expect(ZenComposerLogic.readerKey(for: .downArrow, modifiers: flag) == .scrollDown)
            #expect(ZenComposerLogic.readerKey(for: .home, modifiers: flag) == .firstMessage)
            #expect(ZenComposerLogic.readerKey(for: .end, modifiers: flag) == .lastMessage)
        }
    }

    @Test("Shift, Option, Command and Control keep the key's text-editing meaning")
    func modifiedKeys() {
        let keys: [KeyEquivalent] = [.leftArrow, .rightArrow, .upArrow, .downArrow, .home, .end]
        let modifiers: [EventModifiers] = [
            .shift, .option, .command, .control,
            [.shift, .option], [.command, .shift],
            [.function, .shift], [.numericPad, .function, .option],
        ]
        for key in keys {
            for modifier in modifiers {
                #expect(ZenComposerLogic.readerKey(for: key, modifiers: modifier) == nil)
            }
        }
    }

    @Test("every other key is not a reader key")
    func otherKeys() {
        let keys: [KeyEquivalent] = [.return, .tab, .escape, .space, .pageUp, .pageDown, .delete, "a", "y"]
        for key in keys {
            #expect(ZenComposerLogic.readerKey(for: key, modifiers: []) == nil)
        }
    }
}
