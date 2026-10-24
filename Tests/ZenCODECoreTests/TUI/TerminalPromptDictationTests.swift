//
//  TerminalPromptDictationTests.swift
//  ZenCODECoreTests
//
//  The voice dictation previewed at the end of the prompt draft: the pure
//  model, and how the panel reader ends it on edits.
//

import Foundation
import Synchronization
import Testing
@testable import ZenCODECore

@Suite("Terminal prompt dictation")
struct TerminalPromptDictationTests {
    private static func editor(_ text: String) -> TerminalPromptEditor {
        var editor = TerminalPromptEditor()
        editor.buffer = Array(text)
        editor.cursorIndex = editor.buffer.count
        return editor
    }

    @Test
    func aDictationIsAppendedAfterTheTypedTextWithOneSeparatingSpace() {
        var dictation = TerminalPromptDictation()
        var editor = Self.editor("Cerca")
        #expect(dictation.show(id: 1, text: "il file", in: &editor))
        #expect(String(editor.buffer) == "Cerca il file")
        #expect(editor.cursorIndex == editor.buffer.count)
        #expect(dictation.active == .init(id: 1, start: 6, insertedSeparator: true))

        // A draft that is empty or already ends in whitespace gets no space.
        for typed in ["", "Cerca ", "Riga\n"] {
            var dictation = TerminalPromptDictation()
            var editor = Self.editor(typed)
            #expect(dictation.show(id: 1, text: "il file", in: &editor))
            #expect(String(editor.buffer) == typed + "il file")
            #expect(dictation.active == .init(id: 1, start: typed.count, insertedSeparator: false))
        }
    }

    @Test
    func updatesReplaceThePreviewAndEmptyTextRemovesItWithItsSeparator() {
        var dictation = TerminalPromptDictation()
        var editor = Self.editor("Cerca")
        #expect(dictation.show(id: 1, text: "il", in: &editor))
        #expect(dictation.show(id: 1, text: "il file", in: &editor))
        #expect(String(editor.buffer) == "Cerca il file")
        // The same text changes nothing.
        #expect(!dictation.show(id: 1, text: "il file", in: &editor))

        #expect(dictation.show(id: 1, text: "", in: &editor))
        #expect(String(editor.buffer) == "Cerca")
        #expect(editor.cursorIndex == 5)
        #expect(!dictation.isActive)
        #expect(!dictation.show(id: 1, text: "", in: &editor))
        // Removing a preview does not end the dictation: it shows again.
        #expect(dictation.show(id: 1, text: "di nuovo", in: &editor))
        #expect(String(editor.buffer) == "Cerca di nuovo")
    }

    @Test
    func aSendTakesTheTypedTextAndTheFinalWordsAndClearsTheDraft() {
        var dictation = TerminalPromptDictation()
        var editor = Self.editor("Cerca")
        _ = dictation.show(id: 1, text: "il file, vai", in: &editor)
        // The final words come from voice, without the keyword.
        #expect(dictation.take(id: 1, text: "il file", from: &editor) == "Cerca il file")
        #expect(editor.buffer.isEmpty)
        #expect(editor.cursorIndex == 0)
        #expect(!dictation.isActive)
        #expect(dictation.endedThrough == 1)
        // Late previews and sends of a sent dictation are ignored.
        #expect(!dictation.show(id: 1, text: "il file", in: &editor))
        #expect(dictation.take(id: 1, text: "il file", from: &editor) == nil)
        #expect(editor.buffer.isEmpty)

        // Without a preview (Linux pause mode) the whole draft goes first.
        var typed = Self.editor("Nota:")
        #expect(dictation.take(id: 2, text: "rivedi il test", from: &typed) == "Nota: rivedi il test")
        #expect(typed.buffer.isEmpty)
        var spaced = Self.editor("Nota: ")
        #expect(dictation.take(id: 3, text: "rivedi", from: &spaced) == "Nota: rivedi")
    }

    @Test
    func theKeywordAloneSendsTheTypedDraftOrNothing() {
        var dictation = TerminalPromptDictation()
        var editor = Self.editor("Compila il progetto")
        _ = dictation.show(id: 1, text: "vai", in: &editor)
        #expect(String(editor.buffer) == "Compila il progetto vai")
        #expect(dictation.take(id: 1, text: "", from: &editor) == "Compila il progetto")
        #expect(editor.buffer.isEmpty)

        var empty = Self.editor("")
        _ = dictation.show(id: 2, text: "vai", in: &empty)
        #expect(dictation.take(id: 2, text: "", from: &empty) == "")
        #expect(empty.buffer.isEmpty)
    }

    @Test
    func anEndedDictationIsOrdinaryTextAndANewerOneStartsAtTheEnd() {
        var dictation = TerminalPromptDictation()
        var editor = Self.editor("Cerca")
        _ = dictation.show(id: 1, text: "il file", in: &editor)
        #expect(dictation.end() == 1)
        #expect(dictation.end() == nil)
        #expect(!dictation.show(id: 1, text: "il file main", in: &editor))
        #expect(dictation.take(id: 1, text: "il file main", from: &editor) == nil)
        #expect(String(editor.buffer) == "Cerca il file")

        #expect(dictation.show(id: 2, text: "e aprilo", in: &editor))
        #expect(String(editor.buffer) == "Cerca il file e aprilo")
        #expect(dictation.active == .init(id: 2, start: 14, insertedSeparator: true))
        #expect(dictation.take(id: 2, text: "e aprilo", from: &editor) == "Cerca il file e aprilo")
    }

    @Test
    func previewUpdatesMoveTheCursorOnlyFromInsideTheDictation() {
        var dictation = TerminalPromptDictation()
        var editor = Self.editor("Cerca")
        _ = dictation.show(id: 1, text: "il", in: &editor)
        // Inside the dictation the cursor follows its end.
        editor.cursorIndex = 7
        _ = dictation.show(id: 1, text: "il file", in: &editor)
        #expect(editor.cursorIndex == 13)
        // In the typed text it stays where the operator put it.
        editor.cursorIndex = 2
        _ = dictation.show(id: 1, text: "il file main", in: &editor)
        #expect(String(editor.buffer) == "Cerca il file main")
        #expect(editor.cursorIndex == 2)
        _ = dictation.show(id: 1, text: "", in: &editor)
        #expect(editor.cursorIndex == 2)
    }

    @Test
    func aPreviewEndsHistoryNavigationLikeAnEdit() {
        var editor = Self.editor("Cerca")
        editor.preferredVisualColumn = 3
        editor.historyIndex = 0
        editor.suggestionIndex = 2
        editor.areSuggestionsDismissed = true
        var dictation = TerminalPromptDictation()
        _ = dictation.show(id: 1, text: "il file", in: &editor)
        #expect(editor.preferredVisualColumn == nil)
        #expect(editor.historyIndex == nil)
        #expect(editor.suggestionIndex == 0)
        #expect(!editor.areSuggestionsDismissed)
    }
}

@Suite("Terminal reader voice dictation")
struct TerminalReaderVoiceDictationTests {
    /// The dictation ids the reader reported as ended.
    private final class EndedDictations: Sendable {
        private let state = Mutex<[UInt64]>([])

        func append(_ id: UInt64) {
            state.withLock { $0.append(id) }
        }

        var ids: [UInt64] {
            state.withLock { $0 }
        }
    }

    private static func makeReader(
        typed: String = "",
        ended: EndedDictations
    ) -> TerminalInteractiveLineReader {
        let reader = TerminalInteractiveLineReader()
        reader.setVoiceDictationEndedHandler { id in
            ended.append(id)
        }
        reader.withPanelLock { state in
            state.panelBuffer = Array(typed)
            state.panelCursorIndex = typed.count
        }
        return reader
    }

    private static func draft(of reader: TerminalInteractiveLineReader) -> String {
        reader.withPanelLock { String($0.panelBuffer) }
    }

    @Test
    func aKeyThatChangesTheDraftEndsTheDictationButACursorMoveDoesNot() async {
        let ended = EndedDictations()
        let reader = Self.makeReader(typed: "Cerca", ended: ended)
        reader.setVoiceDictation(id: 1, text: "il file")
        #expect(Self.draft(of: reader) == "Cerca il file")

        await reader.handlePanelKey(.left) { _ in }
        await reader.handlePanelKey(.home) { _ in }
        #expect(ended.ids.isEmpty)
        reader.setVoiceDictation(id: 1, text: "il file main")
        #expect(Self.draft(of: reader) == "Cerca il file main")
        // The operator moved into the typed text: the cursor stays there.
        #expect(reader.withPanelLock { $0.panelCursorIndex } == 0)

        await reader.handlePanelKey(.character(">")) { _ in }
        #expect(ended.ids == [1])
        // The dictated words are ordinary text now.
        reader.setVoiceDictation(id: 1, text: "il file main.swift")
        #expect(reader.takeVoiceDictation(id: 1, text: "il file main.swift") == nil)
        #expect(Self.draft(of: reader) == ">Cerca il file main")
        // The next dictation is appended at the end.
        reader.setVoiceDictation(id: 2, text: "e aprilo")
        #expect(Self.draft(of: reader) == ">Cerca il file main e aprilo")
        #expect(reader.withPanelLock { $0.panelCursorIndex } == 28)
    }

    @Test
    func enterSubmitsTheVisibleDraftAndEndsTheDictation() async {
        let ended = EndedDictations()
        let reader = Self.makeReader(typed: "Nota:", ended: ended)
        reader.setVoiceDictation(id: 3, text: "rivedi il test")
        let submitted = Mutex<[String]>([])

        await reader.handlePanelKey(.enter) { event in
            guard case let .submitted(line) = event else { return }
            submitted.withLock { $0.append(line) }
        }

        #expect(submitted.withLock { $0 } == ["Nota: rivedi il test"])
        #expect(reader.commandHistory == ["Nota: rivedi il test"])
        #expect(Self.draft(of: reader).isEmpty)
        #expect(ended.ids == [3])
    }

    @Test
    func aVoiceSendTakesTheWholeDraftWithoutHistory() {
        let ended = EndedDictations()
        let reader = Self.makeReader(typed: "Nota:", ended: ended)
        reader.setVoiceDictation(id: 1, text: "rivedi il test, vai")
        #expect(reader.takeVoiceDictation(id: 1, text: "rivedi il test") == "Nota: rivedi il test")
        #expect(Self.draft(of: reader).isEmpty)
        #expect(reader.commandHistory.isEmpty)
        // A send is not an edit: voice is not told to forget anything.
        #expect(ended.ids.isEmpty)
    }

    @Test
    func replacingTheDraftProgrammaticallyEndsTheDictation() async {
        let ended = EndedDictations()
        let reader = Self.makeReader(typed: "Cerca", ended: ended)
        reader.setVoiceDictation(id: 4, text: "il file")
        await reader.setPanelText("/plan rivedi")
        #expect(ended.ids == [4])
        #expect(Self.draft(of: reader) == "/plan rivedi")

        // Without a dictation shown there is nothing to end.
        await reader.setPanelText("altro")
        #expect(ended.ids == [4])
    }

    @Test
    func aNewVoiceSessionNumbersItsDictationsAgain() {
        let ended = EndedDictations()
        let reader = Self.makeReader(ended: ended)
        reader.setVoiceDictation(id: 5, text: "vecchio")
        #expect(reader.takeVoiceDictation(id: 5, text: "vecchio") == "vecchio")
        reader.setVoiceDictation(id: 1, text: "ignorato")
        #expect(Self.draft(of: reader).isEmpty)

        reader.setVoiceDictationEndedHandler { id in
            ended.append(id)
        }
        reader.setVoiceDictation(id: 1, text: "nuovo")
        #expect(Self.draft(of: reader) == "nuovo")
    }
}
