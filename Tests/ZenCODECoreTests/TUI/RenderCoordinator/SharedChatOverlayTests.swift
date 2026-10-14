import Foundation
import Testing
import ToolCore
@testable import ZenCODECore

extension TerminalChatRenderCoordinatorTests {
    @Test
    func firstSharedChatMessageHeaderReanchorsActiveToolBlock() async {
        let renderer = makeRenderer(
            standardErrorIsTerminal: true,
            columnWidthProvider: { 80 }
        )
        let statusBar = await makeChatStatusBar(row: 14)
        await statusBar.setSharedChatReader(entries: [], unreadCount: 0, isExpanded: false)
        let toolCall = exampleReadFileCall(id: "tool-before-first-chat-message")
        let previousOutputCapacity = await statusBar.scrollableOutputRowCapacity()
        await renderer.writeToolCallStarted(
            toolCall,
            maximumInPlaceRows: previousOutputCapacity
        )
        let started = await renderer.snapshot()
        let eventsBeforeTransition = await renderer.capturedWriteEvents().count

        await renderer.beginBottomOverlayTransition(
            maximumInPlaceRows: previousOutputCapacity
        )
        #expect(await renderer.snapshot().activeToolCallID == nil)
        await statusBar.setSharedChatReader(
            entries: [
                TerminalSharedChatReaderEntry(
                    id: UUID(),
                    route: "worker",
                    text: "Ready"
                )
            ],
            unreadCount: 1,
            isExpanded: false
        )
        let currentOutputCapacity = await statusBar.scrollableOutputRowCapacity()
        await renderer.endBottomOverlayTransition(
            maximumInPlaceRows: currentOutputCapacity
        )

        let reanchored = await renderer.snapshot()
        let transitionEvents = Array(
            (await renderer.capturedWriteEvents()).dropFirst(eventsBeforeTransition)
        )
        let transitionText = transitionEvents.renderedText()
        #expect(started.activeToolCallID == toolCall.id)
        #expect(started.activeToolRenderedRowCount > 0)
        #expect(
            transitionEvents.first?.text.hasPrefix(
                "\u{1B}[\(started.activeToolRenderedRowCount)A\r"
            ) == true
        )
        #expect(TerminalANSIText.stripANSI(transitionText).contains("local.readFile"))
        #expect(reanchored.activeToolCallID == toolCall.id)
        #expect(reanchored.activeToolRenderedRowCount > 0)

        let eventsBeforeCompletion = await renderer.capturedWriteEvents().count
        await renderer.writeToolCallCompleted(
            toolCall,
            result: DirectAgentToolResult(output: "Done", summary: "Done"),
            maximumInPlaceRows: currentOutputCapacity
        )
        let completionEvents = Array(
            (await renderer.capturedWriteEvents()).dropFirst(eventsBeforeCompletion)
        )
        #expect(
            completionEvents.first?.text.hasPrefix(
                "\u{1B}[\(reanchored.activeToolRenderedRowCount)A\r"
            ) == true
        )
        #expect(await renderer.snapshot().activeToolCallID == nil)
    }

    @Test
    func ordinaryToolStartRetiresSubAgentOverviewBeforeChatRepaintReplay() async {
        let renderer = makeRenderer(
            standardErrorIsTerminal: true,
            columnWidthProvider: { 80 }
        )
        let statusBar = await makeChatStatusBar(row: 14)
        await statusBar.setSharedChatReader(entries: [], unreadCount: 0, isExpanded: false)
        _ = await renderer.renderRememberedSubAgentOverview(
            signature: "agents:before-ordinary-tool",
            text: "\n👥 Sub-Agents:\n   running\n",
            overviewBatchID: "wave"
        )
        let toolCall = exampleReadFileCall(id: "ordinary-tool-before-chat-repaint")
        let previousOutputCapacity = await statusBar.scrollableOutputRowCapacity()
        let eventsBeforeTool = await renderer.capturedWriteEvents().count

        await renderer.writeToolCallStarted(
            toolCall,
            maximumInPlaceRows: previousOutputCapacity
        )

        let toolStartText = await renderer.capturedText(droppingFirst: eventsBeforeTool)
        #expect(toolStartText.hasPrefix("\u{1B}[3A\r"))
        #expect(toolStartText.components(separatedBy: "\u{1B}[2K").count - 1 >= 3)
        #expect(await renderer.snapshot().activeSubAgentOverviewRowCount == 0)

        await renderer.beginBottomOverlayTransition(
            maximumInPlaceRows: previousOutputCapacity
        )
        await statusBar.setSharedChatReader(
            entries: [
                TerminalSharedChatReaderEntry(
                    id: UUID(),
                    route: "worker",
                    text: "Ready"
                )
            ],
            unreadCount: 1,
            isExpanded: false
        )
        let currentOutputCapacity = await statusBar.scrollableOutputRowCapacity()
        await renderer.endBottomOverlayTransition(
            maximumInPlaceRows: currentOutputCapacity
        )
        await renderer.writeToolCallCompleted(
            toolCall,
            result: DirectAgentToolResult(output: "Done", summary: "Done"),
            maximumInPlaceRows: currentOutputCapacity
        )
        #expect(await renderer.snapshot().activeToolCallID == nil)
        let eventsBeforeOverviewRefresh = await renderer.capturedWriteEvents().count

        _ = await renderer.renderRememberedSubAgentOverview(
            signature: "agents:after-ordinary-tool-chat-repaint",
            text: "\n👥 Sub-Agents:\n   completed\n",
            overviewBatchID: "wave",
            maximumInPlaceRows: currentOutputCapacity
        )

        let refreshedOverviewText = await renderer.capturedText(droppingFirst: eventsBeforeOverviewRefresh)
        #expect(!containsCursorUpSequence(refreshedOverviewText))
        #expect(!TerminalANSIText.stripANSI(refreshedOverviewText).contains("running"))
        #expect(TerminalANSIText.stripANSI(refreshedOverviewText).contains("completed"))
        let refreshedSnapshot = await renderer.snapshot()
        #expect(refreshedSnapshot.activeSubAgentOverviewRowCount > 0)
    }

    @Test
    func ordinaryToolCompletionRetiresActiveSubAgentOverview() async {
        let renderer = makeRenderer(
            standardErrorIsTerminal: true,
            columnWidthProvider: { 80 }
        )
        _ = await renderer.renderRememberedSubAgentOverview(
            signature: "agents:before-ordinary-completion",
            text: "\n👥 Sub-Agents:\n   running\n",
            overviewBatchID: "wave"
        )
        let toolCall = exampleReadFileCall(id: "ordinary-completion-with-overview")
        let eventsBeforeCompletion = await renderer.capturedWriteEvents().count

        await renderer.writeToolCallCompleted(
            toolCall,
            result: DirectAgentToolResult(output: "Done", summary: "Done")
        )

        let completionText = await renderer.capturedText(droppingFirst: eventsBeforeCompletion)
        #expect(completionText.hasPrefix("\u{1B}[3A\r"))
        #expect(completionText.components(separatedBy: "\u{1B}[2K").count - 1 >= 3)
        #expect(TerminalANSIText.stripANSI(completionText).contains("local.readFile"))
        #expect(await renderer.snapshot().activeSubAgentOverviewRowCount == 0)
    }

    @Test
    func toolStartDuringBottomOverlayTransitionWaitsForTheNewAnchor() async {
        let renderer = makeRenderer(
            standardErrorIsTerminal: true,
            columnWidthProvider: { 80 }
        )
        let toolCall = exampleReadFileCall(id: "tool-started-during-chat-repaint")
        await renderer.beginBottomOverlayTransition(maximumInPlaceRows: 6)
        let eventsBeforeStart = await renderer.capturedWriteEvents().count

        await renderer.writeToolCallStarted(toolCall, maximumInPlaceRows: 6)

        #expect(await renderer.capturedWriteEvents().count == eventsBeforeStart)
        #expect(await renderer.snapshot().activeToolCallID == nil)

        await renderer.endBottomOverlayTransition(maximumInPlaceRows: 6)

        let reanchored = await renderer.snapshot()
        let replayText = await renderer.capturedText(droppingFirst: eventsBeforeStart)
        #expect(reanchored.activeToolCallID == toolCall.id)
        #expect(reanchored.activeToolRenderedRowCount > 0)
        #expect(TerminalANSIText.stripANSI(replayText).contains("local.readFile"))
    }

    @Test
    func toolCompletionDuringBottomOverlayTransitionReplaysAfterTheRepaint() async {
        let renderer = makeRenderer(
            standardErrorIsTerminal: true,
            columnWidthProvider: { 80 }
        )
        let toolCall = exampleReadFileCall(id: "tool-completed-during-chat-repaint")
        await renderer.writeToolCallStarted(toolCall, maximumInPlaceRows: 6)
        await renderer.beginBottomOverlayTransition(maximumInPlaceRows: 6)
        let eventsBeforeCompletion = await renderer.capturedWriteEvents().count

        await renderer.writeToolCallCompleted(
            toolCall,
            result: DirectAgentToolResult(output: "Done", summary: "Done"),
            maximumInPlaceRows: 6
        )

        #expect(await renderer.capturedWriteEvents().count == eventsBeforeCompletion)
        #expect(await renderer.snapshot().activeToolCallID == nil)

        await renderer.endBottomOverlayTransition(maximumInPlaceRows: 6)

        let replayText = await renderer.capturedText(droppingFirst: eventsBeforeCompletion)
        #expect(TerminalANSIText.stripANSI(replayText).contains("local.readFile"))
        #expect(TerminalANSIText.stripANSI(replayText).contains("✅"))
        #expect(containsCursorUpSequence(replayText))
        #expect(await renderer.snapshot().activeToolCallID == nil)
    }

    @Test
    func bottomOverlayTransitionAbandonsUnreachableToolRowsAppendSafely() async {
        let renderer = makeRenderer(
            standardErrorIsTerminal: true,
            columnWidthProvider: { 80 }
        )
        let toolCall = exampleReadFileCall(id: "tool-outside-reduced-chat-region")
        await renderer.writeToolCallStarted(toolCall, maximumInPlaceRows: 3)
        let started = await renderer.snapshot()
        let eventsBeforeTransition = await renderer.capturedWriteEvents().count

        await renderer.beginBottomOverlayTransition(maximumInPlaceRows: 3)
        await renderer.endBottomOverlayTransition(maximumInPlaceRows: 1)

        let transitionEvents = Array(
            (await renderer.capturedWriteEvents()).dropFirst(eventsBeforeTransition)
        )
        #expect(
            transitionEvents.first?.text.hasPrefix(
                "\u{1B}[\(started.activeToolRenderedRowCount)A\r"
            ) == true
        )
        #expect(!transitionEvents.plainText().contains(
            "local.readFile"
        ))
        #expect(await renderer.snapshot().activeToolCallID == nil)

        let eventsBeforeCompletion = await renderer.capturedWriteEvents().count
        await renderer.writeToolCallCompleted(
            toolCall,
            result: DirectAgentToolResult(output: "Done", summary: "Done"),
            maximumInPlaceRows: 1
        )
        let completionText = await renderer.capturedText(droppingFirst: eventsBeforeCompletion)
        #expect(!containsCursorUpSequence(completionText))
        #expect(TerminalANSIText.stripANSI(completionText).contains("local.readFile"))
    }

    @Test(arguments: [false, true], [false, true])
    func sharedChatCombinedSinkKeepsLiveBlockBesideTranscript(tool: Bool, full: Bool) async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        _ = FileManager.default.createFile(atPath: url.path, contents: nil)
        let sink = try FileHandle(forWritingTo: url)
        defer {
            try? sink.close()
            try? FileManager.default.removeItem(at: url)
        }
        let renderer = TerminalChatRenderCoordinator(
            stdinIsTerminal: false,
            standardOutput: sink,
            standardError: sink,
            standardOutputIsTerminal: true,
            standardErrorIsTerminal: true,
            cursorTopology: .shared,
            capturesWrites: true,
            streamingFlushDelay: nil,
            columnWidthProvider: { 80 }
        )
        let statusBar = TerminalStatusBar(isEnabled: true) { sink.write(Data($0.utf8)) }
        let height = 30
        await statusBar.configureForTesting(row: height, columns: 80)
        await statusBar.updateInputPanel(text: "draft", cursorIndex: 5, modeText: "Chat", helpText: "Enter")
        await statusBar.setSharedChatReader(entries: [], unreadCount: 0, isExpanded: false)
        let initialCapacity = try #require(await statusBar.scrollableOutputRowCapacity())
        #expect(initialCapacity == 24)
        let primaryScreen = await statusBar.primaryScreen
        await renderer.usePrimaryScreenForTesting(primaryScreen)
        primaryScreen.positionOutputForTesting(row: 1)
        // Keep the short transcript above the dock's maximum growth; a separate
        // cursor-edge fixture below exercises clamping at row one.
        let transcriptRows = full ? initialCapacity - 3 : 8
        for index in 0..<transcriptRows {
            primaryScreen.append("PERMANENT-\(index)\r\n")
        }
        let marker = tool ? "local.readFile" : "AGENT-ANCHOR"
        let call = presentedToolCall(
            id: "combined-chat", name: "local.readFile",
            argumentsObject: ["path": "/tmp/fixture"], argumentsJSON: #"{"path":"/tmp/fixture"}"#
        )
        if tool {
            await renderer.writeToolCallStarted(call, maximumInPlaceRows: initialCapacity)
        } else {
            _ = await renderer.renderRememberedSubAgentOverview(
                signature: "combined", text: "\nSub-Agents: AGENT-ANCHOR\n   running\n",
                overviewBatchID: "wave",
                maximumInPlaceRows: initialCapacity
            )
        }
        func screen() throws -> [String] {
            let text = String(decoding: try Data(contentsOf: url), as: UTF8.self)
            var terminal = PrimaryScreenTerminalModel(rows: height, columns: 80)
            terminal.write(text)
            return terminal.visibleText.components(separatedBy: "\n")
        }
        var entries: [TerminalSharedChatReaderEntry] = []
        // Empty -> first unread -> same-height arrivals -> open -> close -> last
        // unread consumed. Each assertion uses the actual reserved-row delta.
        for (unread, expanded) in [(1, false), (2, false), (3, false), (3, true), (1, false), (0, false)] {
            let before = try screen()
            let oldMarkerRow = try #require(before.firstIndex { $0.contains(marker) })
            let oldPermanentRow = try #require(before.firstIndex { $0.contains("PERMANENT-\(transcriptRows - 1)") })
            // The compositor moves only the rows actually displaced by growth;
            // a blank gap above the dock does not force transcript scrolling.
            let oldInsertionRow = primaryScreen.outputRowForTesting
            let oldCapacity = try #require(await statusBar.scrollableOutputRowCapacity())
            let eventOffset = try Data(contentsOf: url).count
            await renderer.beginBottomOverlayTransition(maximumInPlaceRows: oldCapacity)
            while entries.count < unread {
                entries.append(TerminalSharedChatReaderEntry(id: UUID(), route: "worker", text: "Ready"))
            }
            if expanded {
                #expect(await statusBar.expandSharedChatReader(entries: entries, unreadCount: unread))
                await statusBar.navigateSharedChatReader(.nextMessage)
                await statusBar.setSharedChatReader(entries: entries, unreadCount: 0, isExpanded: true)
            } else {
                await statusBar.setSharedChatReader(entries: entries, unreadCount: unread, isExpanded: false)
            }
            let newCapacity = try #require(await statusBar.scrollableOutputRowCapacity())
            await renderer.endBottomOverlayTransition(maximumInPlaceRows: newCapacity)
            if !tool {
                _ = await renderer.renderRememberedSubAgentOverview(
                    signature: "combined", text: "\nSub-Agents: AGENT-ANCHOR\n   running\n",
                    overviewBatchID: "wave",
                    maximumInPlaceRows: newCapacity
                )
            }
            let after = try screen()
            let scroll = max(0, oldInsertionRow - newCapacity)
            #expect(after.firstIndex { $0.contains(marker) } == max(0, oldMarkerRow - scroll))
            if oldPermanentRow >= scroll {
                #expect(after.firstIndex { $0.contains("PERMANENT-\(transcriptRows - 1)") } == oldPermanentRow - scroll)
            }
            #expect(after.filter { $0.contains(marker) }.count == 1)
            if oldCapacity == newCapacity {
                let repaint = String(decoding: try Data(contentsOf: url).dropFirst(eventOffset), as: UTF8.self)
                #expect(!repaint.contains("\u{1B}[1;\(newCapacity)r"))
            }
        }
    }

    @Test(arguments: [0, 1, 2], [false, true])
    func sharedChatCursorEdgesRespectEffectiveGeometry(scenario: Int, bottom: Bool) async throws {
        let height = [8, 14, 30][scenario]
        let draft = scenario == 1 ? String(repeating: "draft\n", count: 10) : "draft"
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        _ = FileManager.default.createFile(atPath: url.path, contents: nil)
        let sink = try FileHandle(forWritingTo: url)
        defer {
            try? sink.close()
            try? FileManager.default.removeItem(at: url)
        }
        let bar = TerminalStatusBar(isEnabled: true) { sink.write(Data($0.utf8)) }
        await bar.configureForTesting(row: height, columns: 80)
        await bar.updateInputPanel(text: draft, cursorIndex: draft.count, modeText: "Chat", helpText: "Enter")
        let primaryScreen = await bar.primaryScreen
        let entries = [TerminalSharedChatReaderEntry(id: UUID(), route: "worker", text: "Ready")]
        // At 8 rows the dock folds into the existing mode row; a tall draft
        // shares the same measured budget rather than an assumed dock height.
        for phase in 0..<7 {
            let oldCapacity = try #require(await bar.scrollableOutputRowCapacity())
            #expect(oldCapacity >= 2)
            if scenario == 0 { #expect(oldCapacity == 2) }
            let cursorRow = bottom ? oldCapacity : 1
            primaryScreen.positionOutputForTesting(row: cursorRow)
            switch phase {
            case 0, 1:
                await bar.setSharedChatReader(entries: entries, unreadCount: 1, isExpanded: false)
            case 2:
                _ = await bar.expandSharedChatReader(entries: entries, unreadCount: 1)
            case 3:
                await bar.navigateSharedChatReader(.lastMessage)
            case 4:
                await bar.setSharedChatReader(entries: entries, unreadCount: 0, isExpanded: false)
            case 5:
                await bar.setSharedChatReader(entries: entries, unreadCount: 1, isExpanded: false)
            default:
                await bar.removeSharedChatReader()
            }
            let capacity = try #require(await bar.scrollableOutputRowCapacity())
            let expectedRow = min(cursorRow, capacity)
            primaryScreen.append("CURSOR-\(phase)")
            let text = String(decoding: try Data(contentsOf: url), as: UTF8.self)
            var terminal = PrimaryScreenTerminalModel(rows: height, columns: 80)
            terminal.write(text)
            let rows = terminal.visibleText.components(separatedBy: "\n")
            #expect(rows[expectedRow - 1].hasPrefix("CURSOR-\(phase)"))
            #expect(expectedRow <= capacity)
            // Remove the probe without changing the cursor position used by the
            // next independently positioned phase.
            primaryScreen.clearOutputRowForTesting()
        }
    }

    @Test
    func ansiScreenModelsMarginsSaveRestoreAndDelayedWrap() {
        let text = "\u{1B}[1;3r\u{1B}[1;1HABCDX\r\nKEEP\r\n"
            + "\u{1B}7\u{1B}[5;1HDOCK\u{1B}8Z"
        let rows = terminalScreenText(text, height: 5, width: 4).components(separatedBy: "\n")
        #expect(rows == ["X", "KEEP", "Z", "", "DOCK"])
        // Save/restore has one slot, not a stack, and setting margins homes.
        #expect(terminalScreenText("\u{1B}[3;2H\u{1B}7\u{1B}[1;4rA\u{1B}8B", height: 5, width: 8)
            .components(separatedBy: "\n") == ["A", "", " B", "", ""])
    }

    @Test
    func firstSharedChatMessageHeaderPreservesSubAgentOverviewOwnership() async {
        let renderer = makeRenderer(
            standardErrorIsTerminal: true,
            columnWidthProvider: { 80 }
        )
        let statusBar = await makeChatStatusBar(row: 9)

        // An attached room has no compact dock until its first message arrives.
        await statusBar.setSharedChatReader(entries: [], unreadCount: 0, isExpanded: false)
        _ = await renderer.renderRememberedSubAgentOverview(
            signature: "agents:before-first-chat-message",
            text: "\n👥 Sub-Agents:\n   running\n",
            overviewBatchID: "wave"
        )
        #expect(await renderer.snapshot().activeSubAgentOverviewRowCount == 3)

        // This is the `.sharedChatMessages` transition. The status bar writes
        // outside the coordinator and moves the cursor while installing the
        // header, so first retire the old relative anchor.
        let previousOutputCapacity = await statusBar.scrollableOutputRowCapacity()
        let eventsBeforeTransition = await renderer.capturedWriteEvents().count
        await renderer.beginBottomOverlayTransition(
            maximumInPlaceRows: previousOutputCapacity
        )
        await statusBar.setSharedChatReader(
            entries: [
                TerminalSharedChatReaderEntry(
                    id: UUID(),
                    route: "worker",
                    text: "Ready"
                )
            ],
            unreadCount: 1,
            isExpanded: false
        )
        await renderer.endBottomOverlayTransition()
        #expect(await statusBar.state.sharedChatReaderDock?.entries.count == 1)
        #expect(await statusBar.reservedRowsForOverlay() == 7)
        #expect(await renderer.snapshot().activeSubAgentOverviewRowCount == 0)
        let eventsBeforeRefresh = await renderer.capturedWriteEvents().count

        _ = await renderer.renderRememberedSubAgentOverview(
            signature: "agents:after-first-chat-message",
            text: "\n👥 Sub-Agents:\n   completed\n",
            overviewBatchID: "wave"
        )
        let transitionText = (await renderer.capturedWriteEvents())
            .dropFirst(eventsBeforeTransition)
            .prefix(eventsBeforeRefresh - eventsBeforeTransition).renderedText()
        let refreshText = await renderer.capturedText(droppingFirst: eventsBeforeRefresh)

        #expect(transitionText.hasPrefix("\u{1B}[3A\r"))
        #expect(transitionText.contains("\u{1B}[2K"))
        #expect(!containsCursorUpSequence(refreshText))
        #expect(TerminalANSIText.stripANSI(refreshText).contains("completed"))
        #expect(await renderer.snapshot().activeSubAgentOverviewRowCount == 3)
    }

    @Test
    func sharedChatCollapsePreservesAndRewritesOverviewAnchoredWhileReaderWasOpen() async {
        let renderer = makeRenderer(
            standardErrorIsTerminal: true,
            columnWidthProvider: { 80 }
        )
        let statusBar = await makeChatStatusBar(row: 14)
        let entry = TerminalSharedChatReaderEntry(
            id: UUID(),
            route: "worker",
            text: "Ready"
        )
        await statusBar.setSharedChatReader(
            entries: [entry],
            unreadCount: 1,
            isExpanded: true
        )

        // A refresh can establish a new rewrite anchor after the reader opened.
        _ = await renderer.renderRememberedSubAgentOverview(
            signature: "agents:while-chat-open",
            text: "\n👥 Sub-Agents:\n   running\n",
            overviewBatchID: "wave"
        )
        #expect(await renderer.snapshot().activeSubAgentOverviewRowCount == 3)

        // This mirrors the input loop's close transaction. The old section is
        // erased while its anchor is still verified, before the status bar moves
        // the cursor to the enlarged transcript boundary.
        let previousOutputCapacity = await statusBar.scrollableOutputRowCapacity()
        await renderer.beginBottomOverlayTransition(
            maximumInPlaceRows: previousOutputCapacity
        )
        await statusBar.setSharedChatReader(
            entries: [entry],
            unreadCount: 1,
            isExpanded: false
        )
        await renderer.endBottomOverlayTransition()
        let currentOutputCapacity = await statusBar.scrollableOutputRowCapacity()
        let eventsBeforeRefresh = await renderer.capturedWriteEvents().count

        _ = await renderer.renderRememberedSubAgentOverview(
            signature: "agents:after-chat-close",
            text: "\n👥 Sub-Agents:\n   completed\n",
            overviewBatchID: "wave"
        )
        let refreshText = await renderer.capturedText(droppingFirst: eventsBeforeRefresh)

        #expect(previousOutputCapacity != nil)
        #expect(currentOutputCapacity != nil)
        #expect((currentOutputCapacity ?? 0) > (previousOutputCapacity ?? 0))
        #expect(!containsCursorUpSequence(refreshText))
        #expect(TerminalANSIText.stripANSI(refreshText).contains("completed"))
        #expect(await renderer.snapshot().activeSubAgentOverviewRowCount == 3)
    }

    @Test
    func hiddenSharedChatDockReanchorsOverviewEvenWhenCapacityDoesNotChange() async {
        let renderer = makeRenderer(
            standardErrorIsTerminal: true,
            columnWidthProvider: { 80 }
        )
        _ = await renderer.renderRememberedSubAgentOverview(
            signature: "agents:before-hidden-chat",
            text: "\n👥 Sub-Agents:\n   running\n",
            overviewBatchID: "wave"
        )
        let eventsBeforeTransition = await renderer.capturedWriteEvents().count

        // A compact Chat dock can be folded into existing chrome. Its capacity
        // delta is zero, but the status bar still emits an absolute cursor move.
        await renderer.beginBottomOverlayTransition(maximumInPlaceRows: 6)
        await renderer.endBottomOverlayTransition()
        let eventsBeforeRefresh = await renderer.capturedWriteEvents().count

        _ = await renderer.renderRememberedSubAgentOverview(
            signature: "agents:after-hidden-chat",
            text: "\n👥 Sub-Agents:\n   completed\n",
            overviewBatchID: "wave",
            maximumInPlaceRows: 6
        )
        let transitionText = (await renderer.capturedWriteEvents())
            .dropFirst(eventsBeforeTransition)
            .prefix(eventsBeforeRefresh - eventsBeforeTransition).renderedText()
        let refreshText = await renderer.capturedText(droppingFirst: eventsBeforeRefresh)

        #expect(transitionText.hasPrefix("\u{1B}[3A\r"))
        #expect(!containsCursorUpSequence(refreshText))
        #expect(TerminalANSIText.stripANSI(refreshText).contains("completed"))
        #expect(await renderer.snapshot().activeSubAgentOverviewRowCount == 3)
    }
}
