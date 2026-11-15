//
//  TerminalVoiceModeHostTests.swift
//  ZenCODECoreTests
//
//  The terminal's voice host with fake panel-loop bindings: a dictation the
//  loop refuses goes to the prompt history, as a refused typed line stays
//  there; one it handles or that ends the loop does not. No chat is bound,
//  so no message is written.
//

import Foundation
import Testing
@testable import ZenCODECore

@ChatSessionActor
@Suite("Terminal voice mode host")
struct TerminalVoiceModeHostTests {
    /// A host whose loop answers every dictated line and prompt with
    /// `outcome`.
    private func makeHost(outcome: TerminalSubmittedInputOutcome) -> TerminalVoiceModeHost {
        let host = TerminalVoiceModeHost(reader: TerminalInteractiveLineReader())
        host.loop = TerminalVoiceModeHost.LoopBindings(
            participants: { [] },
            isUnread: { _ in false },
            markRead: { _ in },
            submitLine: { _ in outcome },
            submitPrompt: { _ in outcome }
        )
        return host
    }

    @Test
    func refusedLineIsRecordedInTheHistory() async {
        let host = makeHost(outcome: .refused)
        let keepsLoop = await host.voiceModeSubmitDictation(.line("che ore sono?"))
        #expect(keepsLoop)
        #expect(host.reader.commandHistory == ["che ore sono?"])
    }

    @Test
    func refusedPlainPromptIsRecordedInTheHistory() async {
        let host = makeHost(outcome: .refused)
        let keepsLoop = await host.voiceModeSubmitDictation(.plainPrompt("/exit now"))
        #expect(keepsLoop)
        #expect(host.reader.commandHistory == ["/exit now"])
    }

    @Test
    func handledDictationIsNotRecorded() async {
        let host = makeHost(outcome: .handled)
        #expect(await host.voiceModeSubmitDictation(.line("dictated line")))
        #expect(await host.voiceModeSubmitDictation(.plainPrompt("/plain")))
        #expect(host.reader.commandHistory.isEmpty)
    }

    @Test
    func dictationThatEndsTheLoopIsNotRecorded() async {
        let host = makeHost(outcome: .endsLoop)
        let keepsLoop = await host.voiceModeSubmitDictation(.line("goodbye"))
        #expect(!keepsLoop)
        #expect(host.reader.commandHistory.isEmpty)
    }

    @Test
    func dictationWithoutALoopIsNotRecorded() async {
        let host = TerminalVoiceModeHost(reader: TerminalInteractiveLineReader())
        let keepsLoop = await host.voiceModeSubmitDictation(.line("nobody listens"))
        #expect(keepsLoop)
        #expect(host.reader.commandHistory.isEmpty)
    }
}
