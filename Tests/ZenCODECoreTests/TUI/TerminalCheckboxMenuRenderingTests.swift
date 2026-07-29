//
//  TerminalCheckboxMenuRenderingTests.swift
//  ZenCODE
//

import Foundation
import Testing
@testable import ZenCODECore

@Suite
struct TerminalCheckboxMenuRenderingTests {
    @Test
    func resumableTaskGraphSelectionRequiresInteractiveChatMode() throws {
        let workingDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let chatConfiguration = try AgentConfiguration(
            hostedModelID: "remote-community/test",
            runMode: .chat,
            workingDirectory: workingDirectory
        )
        let acpConfiguration = try AgentConfiguration(
            hostedModelID: "remote-community/test",
            runMode: .acp,
            workingDirectory: workingDirectory
        )

        #expect(TerminalChat.shouldOfferResumableTaskGraphSelection(
            configuration: chatConfiguration,
            stdinIsTerminal: true
        ))
        #expect(!TerminalChat.shouldOfferResumableTaskGraphSelection(
            configuration: chatConfiguration,
            stdinIsTerminal: false
        ))
        #expect(!TerminalChat.shouldOfferResumableTaskGraphSelection(
            configuration: acpConfiguration,
            stdinIsTerminal: true
        ))
    }

    @Test
    func clearFrameSequenceClearsOnlyMenuRowsAndKeepsCursorInsideFrame() {
        let frame = TerminalCheckboxMenu.RenderedFrame(row: 10, height: 3)

        let sequence = TerminalCheckboxMenu.clearFrameSequence(
            frame: frame,
            terminalRows: 24
        )

        #expect(
            sequence == "\u{1B}[10;1H\u{1B}[2K"
                + "\u{1B}[11;1H\u{1B}[2K"
                + "\u{1B}[12;1H\u{1B}[2K"
                + "\u{1B}[12;1H"
        )
        #expect(!sequence.contains("\u{1B}[J"))
        #expect(!sequence.contains("\u{1B}[13;1H"))
    }

    @Test
    func resumableTaskGraphMenusExposeResumeAndCheckboxDeletionChoices() {
        let graph = ResumableTaskGraph(
            sessionID: "session",
            graphID: "unfinished",
            state: .active,
            source: .workflow,
            totalTaskCount: 3,
            pendingTaskCount: 2,
            updatedAt: Date(timeIntervalSince1970: 0)
        )

        let choices = TerminalChat.resumableTaskGraphChoiceItems([graph])
        #expect(choices.count == 3)
        #expect(choices[0].value == .resume(graph.id))
        #expect(choices[0].groupTitle == "Resume")
        #expect(choices[1].value == .deleteOld)
        #expect(choices[2].value == .startFresh)

        let deletionItems = TerminalChat.resumableTaskGraphDeletionItems([graph])
        #expect(deletionItems.map(\.value) == [graph.id])
        #expect(deletionItems.map(\.title) == ["unfinished"])
    }
}
