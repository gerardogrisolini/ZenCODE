//
//  VoiceModeSessionTests+Dictation.swift
//  ZenCODECoreTests
//
//  The voice mode session test that checks what the host does with a dictated
//  utterance, split out of the main suite file to keep it short.
//

import Foundation
import Synchronization
import Testing
@testable import ZenCODECore

extension VoiceModeSessionTests {
    @Test
    func anythingElseIsSentByTheHostAsADictation() async {
        let host = FakeVoiceModeHost()
        let session = await runningSession(host: host)

        #expect(await session.handleUtterance("Che ore sono?"))
        #expect(await session.handleUtterance("/exit"))
        #expect(await session.handleUtterance("  "))
        #expect(host.submitted == [.line("Che ore sono?"), .plainPrompt("/exit")])

        // The host ends the channel for a line that exits.
        host.submitResult = false
        #expect(await session.handleUtterance("esci") == false)
    }
}
