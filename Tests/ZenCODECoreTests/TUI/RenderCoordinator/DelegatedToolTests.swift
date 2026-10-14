import Foundation
import Testing
import ToolCore
@testable import ZenCODECore

extension TerminalChatRenderCoordinatorTests {
    @Test
    func agentMessageDoesNotBecomeSubAgentActivityOrFallbackRow() async {
        let toolCall = presentedToolCall(
            id: "hidden-delegated-message",
            name: "agent.message",
            argumentsObject: [
                "name": "worker",
                "message": "please review the diff"
            ],
            argumentsJSON: "{}"
        )
        let renderer = makeRenderer(standardErrorIsTerminal: true)
        let event = DirectSubAgentToolEvent(
            agentID: "agent-worker",
            agentName: "worker",
            toolCall: toolCall,
            lifecycle: .started
        )

        await renderer.recordSubAgentToolEvent(event)
        let presentationSnapshot = await renderer.subAgentToolPresentationSnapshot()
        #expect(presentationSnapshot.revision == 0)
        #expect(presentationSnapshot.presentationsByAgentID.isEmpty)

        let snapshot = DirectSubAgentRuntime.AgentSnapshot(
            id: "agent-worker",
            name: "worker",
            role: "",
            status: .running,
            pending: true,
            currentToolName: toolCall.name,
            currentToolTarget: "worker: please review the diff",
            latestOutput: nil,
            latestError: nil,
            createdAt: Date(),
            updatedAt: Date()
        )
        let rows = TerminalChat.renderSubAgentOverviewRowsForTesting(
            [snapshot],
            rowBudget: nil,
            toolPresentationsByAgentID: presentationSnapshot.presentationsByAgentID
        ).map { TerminalANSIText.stripANSI($0) }

        #expect(!rows.contains { $0.contains("agent.message") })
        #expect(!rows.contains { $0.contains("please review the diff") })
        #expect(rows.contains { $0.contains("worker") })
    }

    @Test
    func delegatedToolEventsUseCanonicalRowsInsideTheIndentedOverview() async {
        let toolCall = exampleEditFileCall(id: "shared-render-edit")
        let result = DirectAgentToolResult(output: "Updated", summary: "Updated")
        let delegatedClock = StreamingClock()
        let delegatedRenderer = makeRenderer(
            standardErrorIsTerminal: true,
            toolNow: { delegatedClock.now },
            columnWidthProvider: { 120 }
        )

        await delegatedRenderer.recordSubAgentToolEvent(
            DirectSubAgentToolEvent(
                agentID: "agent-worker",
                agentName: "worker",
                toolCall: toolCall,
                lifecycle: .started
            )
        )
        delegatedClock.advance(by: .milliseconds(1_200))
        await delegatedRenderer.recordSubAgentToolEvent(
            DirectSubAgentToolEvent(
                agentID: "agent-worker",
                agentName: "worker",
                toolCall: toolCall,
                lifecycle: .completed(result)
            )
        )
        let presentationSnapshot = await delegatedRenderer
            .subAgentToolPresentationSnapshot()
        let agentSnapshot = DirectSubAgentRuntime.AgentSnapshot(
            id: "agent-worker",
            name: "worker",
            role: "",
            status: .running,
            pending: true,
            currentToolName: toolCall.name,
            currentToolTarget: "/tmp/Example.swift",
            latestOutput: nil,
            latestError: nil,
            createdAt: Date(),
            updatedAt: Date()
        )
        let rows = TerminalChat.renderSubAgentOverviewRowsForTesting(
            [agentSnapshot],
            rowBudget: nil,
            toolPresentationsByAgentID: presentationSnapshot.presentationsByAgentID
        ).map { TerminalANSIText.stripANSI($0) }
        let toolRows = rows.filter {
            $0.contains(toolCall.name)
                || $0.contains("/tmp/Example.swift")
                || $0.contains("oldValue")
                || $0.contains("newValue")
        }

        // Recording delegated tools updates only the live overview model. It
        // must never append a coordinator-looking block to the transcript.
        #expect(await delegatedRenderer.capturedWriteEvents().isEmpty)
        #expect(toolRows.count >= 2)
        #expect(toolRows.allSatisfy { $0.hasPrefix("   ") })
        #expect(rows.contains { $0.contains("✅ 1.20s") })
        #expect(!rows.contains { $0.contains("oldValue") })
        #expect(!rows.contains { $0.contains("newValue") })
    }

    @Test(arguments: ["local.editFile", "local.multiEdit", "local.writeFile"], [false, true])
    func coordinatorAndDelegatedToolsOmitSourcePreviews(
        toolName: String,
        stdinIsTerminal: Bool
    ) async throws {
        let old = "    let oldValue = 1"
        let new = "    let newValue = 2"
        var arguments: [String: Any] = ["path": "/tmp/Example.swift"]
        switch toolName {
        case "local.writeFile":
            arguments["content"] = new
        case "local.multiEdit":
            arguments["edits"] = [["old": old, "new": new]]
        default:
            arguments["old"] = old
            arguments["new"] = new
        }
        let toolCall = presentedToolCall(
            id: "aligned-file-preview",
            name: toolName,
            argumentsObject: arguments,
            argumentsJSON: "{}"
        )
        let result = DirectAgentToolResult(output: "Updated", summary: "Updated")
        let renderer = makeRenderer(
            stdinIsTerminal: stdinIsTerminal,
            standardErrorIsTerminal: true,
            columnWidthProvider: { 100 }
        )
        await renderer.writeToolCallStarted(toolCall)
        let startEventCount = await renderer.capturedWriteEvents().count
        await renderer.writeToolCallCompleted(toolCall, result: result)
        let coordinatorRawRows = await renderer.capturedText(droppingFirst: startEventCount).components(separatedBy: "\n")
        let coordinatorRows = coordinatorRawRows.map {
            TerminalANSIText.stripANSI($0).replacingOccurrences(of: "\r", with: "")
        }
        let inset = stdinIsTerminal ? TerminalChatTextFormatting.chatLineInsetPrefix : ""
        #expect(!coordinatorRows.contains { $0.contains("newValue") || $0.contains("oldValue") })
        #expect(coordinatorRows.contains { $0.hasPrefix("\(inset)🛠️  \(toolName)") })
        let sourceRows = coordinatorRawRows.filter { $0.contains(TerminalChat.codeAreaBackgroundColor) }
        #expect(sourceRows.isEmpty)

        let delegatedRenderer = makeRenderer(standardErrorIsTerminal: true)
        let agentSnapshot = DirectSubAgentRuntime.AgentSnapshot(
            id: "agent-worker",
            name: "worker",
            role: "",
            status: .running,
            pending: true,
            currentToolName: toolCall.name,
            currentToolTarget: "/tmp/Example.swift",
            latestOutput: nil,
            latestError: nil,
            createdAt: Date(),
            updatedAt: Date()
        )
        // Delegated tool activity stays compact for both lifecycles as well.
        for lifecycle in [DirectSubAgentToolEvent.Lifecycle.started, .completed(result)] {
            await delegatedRenderer.recordSubAgentToolEvent(
                DirectSubAgentToolEvent(
                    agentID: agentSnapshot.id,
                    agentName: agentSnapshot.name,
                    toolCall: toolCall,
                    lifecycle: lifecycle
                )
            )
            let presentations = await delegatedRenderer.subAgentToolPresentationSnapshot()
            let delegatedRawRows = TerminalChat.renderSubAgentOverviewRowsForTesting(
                [agentSnapshot],
                rowBudget: nil,
                toolPresentationsByAgentID: presentations.presentationsByAgentID
            )
            let delegatedRows = delegatedRawRows.map { TerminalANSIText.stripANSI($0) }
            #expect(delegatedRows.contains { $0.hasPrefix("   🛠️  \(toolName)") })
            #expect(!delegatedRows.contains { $0.contains("newValue") || $0.contains("oldValue") })
            let ansiRows = TerminalChat.renderSubAgentToolRowsForTesting(
                try #require(presentations.presentationsByAgentID[agentSnapshot.id])
            )
            let sourceRows = ansiRows.filter { $0.contains(TerminalChat.codeAreaBackgroundColor) }
            #expect(sourceRows.isEmpty)
        }
        #expect(await delegatedRenderer.capturedWriteEvents().isEmpty)
    }

    @Test
    func delegatedToolTimingScopesMatchingProviderCallIDsByAgent() async {
        let toolCall = presentedToolCall(
            id: "provider-reused-call-id",
            name: "search.grep",
            argumentsObject: ["pattern": "needle"],
            argumentsJSON: "{}"
        )
        let result = DirectAgentToolResult(output: "match", summary: "1 match")
        let clock = StreamingClock()
        let renderer = makeRenderer(
            standardErrorIsTerminal: true,
            toolNow: { clock.now },
            columnWidthProvider: { 120 }
        )
        let firstStarted = DirectSubAgentToolEvent(
            agentID: "agent-first",
            agentName: "first",
            toolCall: toolCall,
            lifecycle: .started
        )
        let secondStarted = DirectSubAgentToolEvent(
            agentID: "agent-second",
            agentName: "second",
            toolCall: toolCall,
            lifecycle: .started
        )

        await renderer.recordSubAgentToolEvent(firstStarted)
        clock.advance(by: .milliseconds(100))
        await renderer.recordSubAgentToolEvent(secondStarted)
        clock.advance(by: .milliseconds(200))
        await renderer.recordSubAgentToolEvent(
            DirectSubAgentToolEvent(
                agentID: "agent-second",
                agentName: "second",
                toolCall: toolCall,
                lifecycle: .completed(result)
            )
        )
        clock.advance(by: .milliseconds(300))
        await renderer.recordSubAgentToolEvent(
            DirectSubAgentToolEvent(
                agentID: "agent-first",
                agentName: "first",
                toolCall: toolCall,
                lifecycle: .completed(result)
            )
        )

        let presentations = await renderer
            .subAgentToolPresentationSnapshot()
            .presentationsByAgentID
        if case let .completed(_, secondDetail, _)? = presentations["agent-second"]?.lifecycle {
            #expect(secondDetail == "200ms")
        } else {
            Issue.record("Second delegated tool did not complete")
        }
        if case let .completed(_, firstDetail, _)? = presentations["agent-first"]?.lifecycle {
            #expect(firstDetail == "600ms")
        } else {
            Issue.record("First delegated tool did not complete")
        }
        #expect(await renderer.capturedWriteEvents().isEmpty)
    }

    @Test
    func delegatedAgentKeepsOnlyItsLatestToolPresentation() async {
        let renderer = makeRenderer(standardErrorIsTerminal: true)
        let first = presentedToolCall(
            id: "first-edit",
            name: "local.editFile",
            argumentsObject: [
                "path": "/tmp/Old.swift",
                "old": "let staleValue = 1",
                "new": "let staleValue = 2"
            ],
            argumentsJSON: "{}"
        )
        let second = presentedToolCall(
            id: "second-search",
            name: "search.grep",
            argumentsObject: ["pattern": "currentNeedle"],
            argumentsJSON: "{}"
        )

        for event in [
            DirectSubAgentToolEvent(
                agentID: "agent-worker",
                agentName: "worker",
                toolCall: first,
                lifecycle: .started
            ),
            DirectSubAgentToolEvent(
                agentID: "agent-worker",
                agentName: "worker",
                toolCall: first,
                lifecycle: .completed(
                    DirectAgentToolResult(output: "Updated", summary: "Updated")
                )
            ),
            DirectSubAgentToolEvent(
                agentID: "agent-worker",
                agentName: "worker",
                toolCall: second,
                lifecycle: .started
            )
        ] {
            await renderer.recordSubAgentToolEvent(event)
        }

        let presentations = await renderer
            .subAgentToolPresentationSnapshot()
            .presentationsByAgentID
        let current = presentations["agent-worker"]
        let snapshot = DirectSubAgentRuntime.AgentSnapshot(
            id: "agent-worker",
            name: "worker",
            role: "",
            status: .running,
            pending: true,
            currentToolName: second.name,
            currentToolTarget: "currentNeedle",
            latestOutput: nil,
            latestError: nil,
            createdAt: Date(),
            updatedAt: Date()
        )
        let rendered = TerminalChat.renderSubAgentOverviewRowsForTesting(
            [snapshot],
            rowBudget: nil,
            toolPresentationsByAgentID: presentations
        )
        .map { TerminalANSIText.stripANSI($0) }
        .joined(separator: "\n")

        #expect(presentations.count == 1)
        #expect(current?.toolCall.id == second.id)
        #expect(rendered.contains("search.grep"))
        #expect(rendered.contains("currentNeedle"))
        #expect(!rendered.contains("staleValue"))
        #expect(!rendered.contains("Old.swift"))
    }

    @Test
    func delegatedToolLifecycleRewritesTheSingleSubAgentOverviewSlot() async {
        let renderer = makeRenderer(
            standardErrorIsTerminal: true,
            columnWidthProvider: { 120 }
        )
        let toolCall = exampleEditFileCall(id: "overview-edit")
        let agentSnapshot = DirectSubAgentRuntime.AgentSnapshot(
            id: "agent-worker",
            name: "worker",
            role: "",
            overviewBatchID: UUID(),
            isInCurrentOverviewWave: true,
            status: .running,
            pending: true,
            currentToolName: toolCall.name,
            currentToolTarget: "/tmp/Example.swift",
            latestOutput: nil,
            latestError: nil,
            createdAt: Date(),
            updatedAt: Date()
        )

        func overviewText(
            _ presentations: [
                String: TerminalChatRenderCoordinator.SubAgentToolPresentation
            ]
        ) -> String {
            let rows = TerminalChat.renderSubAgentOverviewRowsForTesting(
                [agentSnapshot],
                rowBudget: nil,
                toolPresentationsByAgentID: presentations
            )
            return "\n\(rows.joined(separator: "\n"))\n\n"
        }

        await renderer.recordSubAgentToolEvent(
            DirectSubAgentToolEvent(
                agentID: agentSnapshot.id,
                agentName: agentSnapshot.name,
                toolCall: toolCall,
                lifecycle: .started
            )
        )
        let started = await renderer.subAgentToolPresentationSnapshot()
        _ = await renderer.renderRememberedSubAgentOverview(
            signature: "agents:tool-started:\(started.revision)",
            text: overviewText(started.presentationsByAgentID),
            overviewBatchID: "wave"
        )
        let ownedRows = await renderer.snapshot().activeSubAgentOverviewRowCount
        let eventCountBeforeCompletion = await renderer.capturedWriteEvents().count

        await renderer.recordSubAgentToolEvent(
            DirectSubAgentToolEvent(
                agentID: agentSnapshot.id,
                agentName: agentSnapshot.name,
                toolCall: toolCall,
                lifecycle: .completed(
                    DirectAgentToolResult(output: "Updated", summary: "Updated")
                )
            )
        )
        let completed = await renderer.subAgentToolPresentationSnapshot()
        _ = await renderer.renderRememberedSubAgentOverview(
            signature: "agents:tool-completed:\(completed.revision)",
            text: overviewText(completed.presentationsByAgentID),
            overviewBatchID: "wave"
        )
        let refresh = await renderer.capturedText(droppingFirst: eventCountBeforeCompletion)
        let visibleRefresh = TerminalANSIText.stripANSI(refresh)

        #expect(ownedRows > 0)
        #expect(refresh.hasPrefix("\u{1B}[\(ownedRows)A\r"))
        #expect(refresh.components(separatedBy: "\u{1B}[2K").count - 1 == ownedRows)
        #expect(visibleRefresh.contains("✅"))
        #expect(!visibleRefresh.contains("oldValue"))
        #expect(!visibleRefresh.contains("newValue"))
    }

    @Test
    func agentToolAndOverviewTransferTheSingleRewriteAnchorWithoutStalePendingSections() async {
        let clock = StreamingClock()
        let renderer = makeRenderer(
            standardErrorIsTerminal: true,
            toolNow: { clock.now },
            columnWidthProvider: { 120 }
        )
        let toolCall = presentedToolCall(
            id: "wait-for-live-overview",
            name: "agent.wait",
            argumentsObject: [:],
            argumentsJSON: "{}"
        )

        await renderer.writeToolCallStarted(toolCall)
        let pendingToolRows = await renderer.snapshot().activeToolRenderedRowCount
        let eventsBeforeOverview = await renderer.capturedWriteEvents().count

        _ = await renderer.renderRememberedSubAgentOverview(
            signature: "agents:pending",
            text: "\n👥 Sub-Agents:\n   worker ⏳\n",
            overviewBatchID: "wave",
            maximumInPlaceRows: 20
        )
        let overviewEvents = Array(
            (await renderer.capturedWriteEvents()).dropFirst(eventsBeforeOverview)
        )
        let pendingOverviewRows = await renderer.snapshot().activeSubAgentOverviewRowCount

        #expect(pendingToolRows > 0)
        #expect(overviewEvents.first?.text.hasPrefix("\u{1B}[\(pendingToolRows)A\r") == true)
        #expect(await renderer.snapshot().activeToolCallID == nil)
        #expect(pendingOverviewRows > 0)

        clock.advance(by: .milliseconds(1_200))
        let eventsBeforeCompletion = await renderer.capturedWriteEvents().count
        await renderer.writeToolCallCompleted(
            toolCall,
            result: DirectAgentToolResult(output: "Done", summary: "Done"),
            maximumInPlaceRows: 20
        )
        let completionEvents = Array(
            (await renderer.capturedWriteEvents()).dropFirst(eventsBeforeCompletion)
        )
        let completionText = completionEvents.renderedText()

        #expect(completionEvents.first?.text.hasPrefix("\u{1B}[\(pendingOverviewRows)A\r") == true)
        #expect(completionText.contains("✅"))
        #expect(TerminalANSIText.stripANSI(completionText).contains("1.20s"))
        #expect(await renderer.snapshot().activeSubAgentOverviewRowCount == 0)

        let eventsBeforeCompletedOverview = await renderer.capturedWriteEvents().count
        _ = await renderer.renderRememberedSubAgentOverview(
            signature: "agents:completed",
            text: "\n👥 Sub-Agents:\n   worker ✅ 1.20s\n",
            overviewBatchID: "wave",
            maximumInPlaceRows: 20
        )
        let completedOverviewText = await renderer.capturedText(droppingFirst: eventsBeforeCompletedOverview)

        #expect(!containsCursorUpSequence(completedOverviewText))
        #expect(TerminalANSIText.stripANSI(completedOverviewText).contains("worker ✅ 1.20s"))
        #expect(await renderer.snapshot().activeSubAgentOverviewRowCount > 0)
    }

    @Test
    func agentWaitRedrawsUnchangedOverviewAfterTakingItsRewriteAnchor() async {
        let renderer = makeRenderer(
            standardErrorIsTerminal: true,
            columnWidthProvider: { 120 }
        )
        let signature = "agents:unchanged"
        let overview = "\n👥 Sub-Agents:\n   worker ⏳\n"

        _ = await renderer.renderRememberedSubAgentOverview(
            signature: signature,
            text: overview,
            overviewBatchID: "wave",
            maximumInPlaceRows: 20
        )
        let initialOverviewRows = await renderer.snapshot().activeSubAgentOverviewRowCount
        let toolCall = presentedToolCall(
            id: "wait-for-unchanged-overview",
            name: "agent.wait",
            argumentsObject: [:],
            argumentsJSON: "{}"
        )

        await renderer.writeToolCallStarted(
            toolCall,
            maximumInPlaceRows: 20
        )
        let started = await renderer.snapshot()
        let eventsBeforeRefresh = await renderer.capturedWriteEvents().count

        let result = await renderer.renderRememberedSubAgentOverview(
            signature: signature,
            text: overview,
            overviewBatchID: "wave",
            maximumInPlaceRows: 20
        )
        let refreshEvents = Array(
            (await renderer.capturedWriteEvents()).dropFirst(eventsBeforeRefresh)
        )
        let refreshed = await renderer.snapshot()

        #expect(initialOverviewRows > 0)
        #expect(started.activeToolCallID == toolCall.id)
        #expect(result == .rendered)
        #expect(
            refreshEvents.first?.text.hasPrefix(
                "\u{1B}[\(started.activeToolRenderedRowCount)A\r"
            ) == true
        )
        #expect(
            refreshEvents.plainText()
                .contains("worker ⏳")
        )
        #expect(refreshed.activeToolCallID == nil)
        #expect(refreshed.activeSubAgentOverviewRowCount > 0)
        #expect(refreshed.lastRenderedSubAgentOverviewSignature == signature)
    }

    @Test
    func repeatedAgentToolCyclesTransferTheRewriteAnchorInBothDirections() async {
        let renderer = makeRenderer(
            standardErrorIsTerminal: true,
            columnWidthProvider: { 120 }
        )

        _ = await renderer.renderRememberedSubAgentOverview(
            signature: "agents:seed",
            text: "\n👥 Sub-Agents:\n   worker ready\n",
            overviewBatchID: "wave",
            maximumInPlaceRows: 20
        )
        var overviewRows = await renderer.snapshot().activeSubAgentOverviewRowCount
        #expect(overviewRows > 0)

        for cycle in 1...3 {
            let toolCall = presentedToolCall(
                id: "wait-cycle-\(cycle)",
                name: "agent.wait",
                argumentsObject: [:],
                argumentsJSON: "{}"
            )

            let eventsBeforeStart = await renderer.capturedWriteEvents().count
            await renderer.writeToolCallStarted(
                toolCall,
                maximumInPlaceRows: 20
            )
            let startEvents = Array(
                (await renderer.capturedWriteEvents()).dropFirst(eventsBeforeStart)
            )
            let started = await renderer.snapshot()

            // Starting the next coordinator call must replace the prior live
            // overview. Appending here loses the only rewrite anchor and makes
            // every subsequent refresh leave another Sub-Agents section behind.
            #expect(
                startEvents.first?.text.hasPrefix("\u{1B}[\(overviewRows)A\r") == true
            )
            #expect(started.activeSubAgentOverviewRowCount == 0)
            #expect(started.activeToolCallID == toolCall.id)
            #expect(started.activeToolRenderedRowCount > 0)

            let eventsBeforeRunningOverview = await renderer.capturedWriteEvents().count
            _ = await renderer.renderRememberedSubAgentOverview(
                signature: "agents:running:\(cycle)",
                text: "\n👥 Sub-Agents:\n   worker \(cycle) ⏳\n",
                overviewBatchID: "wave",
                maximumInPlaceRows: 20
            )
            let runningOverviewEvents = Array(
                (await renderer.capturedWriteEvents()).dropFirst(eventsBeforeRunningOverview)
            )
            let runningOverview = await renderer.snapshot()

            #expect(
                runningOverviewEvents.first?.text.hasPrefix(
                    "\u{1B}[\(started.activeToolRenderedRowCount)A\r"
                ) == true
            )
            #expect(runningOverview.activeToolCallID == nil)
            #expect(runningOverview.activeSubAgentOverviewRowCount > 0)

            let eventsBeforeCompletion = await renderer.capturedWriteEvents().count
            await renderer.writeToolCallCompleted(
                toolCall,
                result: DirectAgentToolResult(output: "Done", summary: "Done"),
                maximumInPlaceRows: 20
            )
            let completionEvents = Array(
                (await renderer.capturedWriteEvents()).dropFirst(eventsBeforeCompletion)
            )

            #expect(
                completionEvents.first?.text.hasPrefix(
                    "\u{1B}[\(runningOverview.activeSubAgentOverviewRowCount)A\r"
                ) == true
            )
            #expect(await renderer.snapshot().activeSubAgentOverviewRowCount == 0)

            _ = await renderer.renderRememberedSubAgentOverview(
                signature: "agents:completed:\(cycle)",
                text: "\n👥 Sub-Agents:\n   worker \(cycle) ✅\n",
                overviewBatchID: "wave",
                maximumInPlaceRows: 20
            )
            overviewRows = await renderer.snapshot().activeSubAgentOverviewRowCount
            #expect(overviewRows > 0)
        }
    }

}
