//
//  ZenComposerKeyHintTests.swift
//  ZenApp
//
//  The key hint under the composer's field
//  (`ZenComposerLogic.keyHint(isBusy:isSpeaking:hasSuggestions:)`): the
//  terminal input panel's help in its words, listing only the keys that do
//  something now.
//

import Foundation
import Testing

@testable import ZenAppControls

@Suite("Composer key hint")
struct ZenComposerKeyHintTests {
    @Test("idle: Enter sends, Ctrl+G and Ctrl+Y are named, Esc has nothing to stop")
    func idle() {
        let hint = ZenComposerLogic.keyHint(isBusy: false, isSpeaking: false, hasSuggestions: false)
        #expect(hint.full == "Enter send · Ctrl+G access · Ctrl+Y chat")
        #expect(hint.compact == nil)
        #expect(!hint.full.contains("Esc"))
    }

    @Test("busy: Enter queues and Esc stops, ahead of Ctrl+G and Ctrl+Y in the compact form")
    func busy() {
        let hint = ZenComposerLogic.keyHint(isBusy: true, isSpeaking: false, hasSuggestions: false)
        #expect(hint.full == "Enter queue · Ctrl+G access · Ctrl+Y chat · Esc stop")
        #expect(hint.compact == "Enter queue · Esc stop · Ctrl+G access · Ctrl+Y chat")
    }

    @Test("reading aloud: Enter sends and Esc stops the reading, ahead of Ctrl+G and Ctrl+Y in the compact form")
    func readingAloud() {
        let hint = ZenComposerLogic.keyHint(isBusy: false, isSpeaking: true, hasSuggestions: false)
        #expect(hint.full == "Enter send · Ctrl+G access · Ctrl+Y chat · Esc stop reading")
        #expect(hint.compact == "Enter send · Esc stop reading · Ctrl+G access · Ctrl+Y chat")
    }

    @Test("busy while reading aloud: the turn's hint wins, as in the terminal")
    func busyWhileReadingAloud() {
        let hint = ZenComposerLogic.keyHint(isBusy: true, isSpeaking: true, hasSuggestions: false)
        #expect(hint == ZenComposerLogic.keyHint(isBusy: true, isSpeaking: false, hasSuggestions: false))
        #expect(!hint.full.contains("stop reading"))
    }

    @Test(
        "suggestions on screen: their keys, Esc hides them, busy, reading aloud, or not",
        arguments: [(false, false), (true, false), (false, true), (true, true)]
    )
    func suggestions(isBusy: Bool, isSpeaking: Bool) {
        let hint = ZenComposerLogic.keyHint(isBusy: isBusy, isSpeaking: isSpeaking, hasSuggestions: true)
        #expect(hint.full == "↑/↓ select · Tab complete · Enter choose · Esc dismiss")
        #expect(hint.compact == nil)
    }
}
