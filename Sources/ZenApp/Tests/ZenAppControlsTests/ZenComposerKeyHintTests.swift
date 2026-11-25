//
//  ZenComposerKeyHintTests.swift
//  ZenApp
//
//  The key hint under the composer's field
//  (`ZenComposerLogic.keyHint(isBusy:isSpeaking:hasSuggestions:)`): the
//  terminal input panel's mode line in its words (`Prompt · …`, `Next prompt
//  · …` while busy), listing only the keys that do something now.
//

import Foundation
import Testing

@testable import ZenAppControls

@Suite("Composer key hint")
struct ZenComposerKeyHintTests {
    @Test("idle: Prompt, Enter sends, Ctrl+G and Ctrl+Y are named, Esc has nothing to stop")
    func idle() {
        let hint = ZenComposerLogic.keyHint(isBusy: false, isSpeaking: false, hasSuggestions: false)
        #expect(hint.full == "Prompt · Enter send · Ctrl+G access · Ctrl+Y chat")
        #expect(hint.compact == nil)
        #expect(!hint.full.contains("Esc"))
    }

    @Test("busy: Next prompt, Enter queues and Esc stops, ahead of Ctrl+G and Ctrl+Y in the compact form")
    func busy() {
        let hint = ZenComposerLogic.keyHint(isBusy: true, isSpeaking: false, hasSuggestions: false)
        #expect(hint.full == "Next prompt · Enter queue · Ctrl+G access · Ctrl+Y chat · Esc stop")
        #expect(hint.compact == "Next prompt · Enter queue · Esc stop · Ctrl+G access · Ctrl+Y chat")
    }

    @Test("reading aloud: Prompt, Enter sends and Esc stops the reading, ahead of Ctrl+G and Ctrl+Y in the compact form")
    func readingAloud() {
        let hint = ZenComposerLogic.keyHint(isBusy: false, isSpeaking: true, hasSuggestions: false)
        #expect(hint.full == "Prompt · Enter send · Ctrl+G access · Ctrl+Y chat · Esc stop reading")
        #expect(hint.compact == "Prompt · Enter send · Esc stop reading · Ctrl+G access · Ctrl+Y chat")
    }

    @Test("busy while reading aloud: the turn's hint wins, as in the terminal")
    func busyWhileReadingAloud() {
        let hint = ZenComposerLogic.keyHint(isBusy: true, isSpeaking: true, hasSuggestions: false)
        #expect(hint == ZenComposerLogic.keyHint(isBusy: true, isSpeaking: false, hasSuggestions: false))
        #expect(!hint.full.contains("stop reading"))
    }

    @Test(
        "suggestions on screen: the mode and their keys, Esc hides them, busy, reading aloud, or not",
        arguments: [(false, false), (true, false), (false, true), (true, true)]
    )
    func suggestions(isBusy: Bool, isSpeaking: Bool) {
        let hint = ZenComposerLogic.keyHint(isBusy: isBusy, isSpeaking: isSpeaking, hasSuggestions: true)
        let mode = isBusy ? "Next prompt · " : "Prompt · "
        #expect(hint.full.hasPrefix(mode))
        #expect(hint.full == mode + "↑/↓ select · Tab complete · Enter choose · Esc dismiss")
        #expect(hint.compact == nil)
    }
}
