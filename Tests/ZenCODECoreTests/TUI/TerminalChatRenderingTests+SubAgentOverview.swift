//
//  TerminalChatRenderingTests+SubAgentOverview.swift
//  ZenCODE
//
//  Tests for the sub-agent overview rendering: layout, model titles, activity
//  labels and response identity tracking.
//

import Foundation
import Markdown
import Testing
@testable import ZenCODECore
@testable import ZenCODERuntime

extension TerminalChatRenderingTests {
    @Test
    func subAgentOverviewRendersPlainWrappedStatusWithoutBoxDrawing() {
        let snapshot = DirectSubAgentRuntime.AgentSnapshot(
            id: "agent_1",
            name: "swift-scan",
            status: .closed,
            pending: false,
            latestOutput: "Trovati 3 file `.swift`: 1. `./Tests/ZenCODECoreTests/AgentCoreSessionRunnerTests.swift` 2. `./Tests/ZenCODECoreTests/MemoryServiceTests.swift` 3. `./Tests/ZenCODECoreTests/VeryLongFileNameThatShouldWrapInsideTheBox.swift`",
            latestError: nil,
            createdAt: Date(),
            updatedAt: Date()
        )

        let rendered = TerminalSubAgentOverviewLayout.render(
            [snapshot],
            modelTitleResolver: { $0 },
            toolPresentationsByAgentID: [:]
        )
        let visibleLines = rendered
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { ansiStripped(String($0)) }

        #expect(visibleLines[1] == "👥 Sub-Agents:")
        #expect(rendered.hasPrefix("\n"))
        #expect(rendered.hasSuffix("\n"))
        #expect(!rendered.contains("┌"))
        #expect(!rendered.contains("│"))
        #expect(!rendered.contains("└"))
        #expect(visibleLines.allSatisfy { $0.count <= 122 })
    }

    @Test
    func subAgentOverviewKeepsMultipleSnapshotsCompactAcrossBoundaries() {
        let now = Date(timeIntervalSince1970: 0)
        let snapshots = [
            DirectSubAgentRuntime.AgentSnapshot(
                id: "agent-first",
                name: "first-agent",
                status: .closed,
                pending: false,
                latestOutput: nil,
                latestError: nil,
                createdAt: now,
                updatedAt: now
            ),
            DirectSubAgentRuntime.AgentSnapshot(
                id: "agent-second",
                name: "second-agent",
                status: .closed,
                pending: false,
                latestOutput: nil,
                latestError: nil,
                createdAt: now,
                updatedAt: now
            ),
            DirectSubAgentRuntime.AgentSnapshot(
                id: "agent-third",
                name: "third-agent",
                status: .closed,
                pending: false,
                latestOutput: nil,
                latestError: nil,
                createdAt: now,
                updatedAt: now
            )
        ]

        let visibleLines = ansiStripped(TerminalSubAgentOverviewLayout.render(
            snapshots,
            modelTitleResolver: { $0 },
            toolPresentationsByAgentID: [:]
        ))
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map(String.init)
        let summaryIndex = visibleLines.firstIndex { $0.contains("3 total") }
        let firstHeaderIndex = visibleLines.firstIndex { $0.contains("first-agent") }
        let firstIDIndex = visibleLines.firstIndex { $0.contains("id: agent-first") }
        let secondHeaderIndex = visibleLines.firstIndex { $0.contains("second-agent") }
        let secondIDIndex = visibleLines.firstIndex { $0.contains("id: agent-second") }
        let thirdHeaderIndex = visibleLines.firstIndex { $0.contains("third-agent") }

        let contentLines = Array(visibleLines.dropFirst().dropLast())
        #expect(contentLines.allSatisfy { !$0.isEmpty })
        #expect(summaryIndex != nil)
        #expect(firstHeaderIndex != nil)
        #expect(firstIDIndex != nil)
        #expect(secondHeaderIndex != nil)
        #expect(secondIDIndex != nil)
        #expect(thirdHeaderIndex != nil)

        if let summaryIndex, let firstHeaderIndex,
           let firstIDIndex, let secondHeaderIndex,
           let secondIDIndex, let thirdHeaderIndex {
            // Each agent block is intentionally preceded by one visually blank
            // separator line.
            #expect(firstHeaderIndex == summaryIndex + 2)
            #expect(secondHeaderIndex == firstIDIndex + 2)
            #expect(thirdHeaderIndex == secondIDIndex + 2)
        }
    }

    @Test
    func subAgentOverviewRendersModelAndCurrentActivity() {
        let snapshot = DirectSubAgentRuntime.AgentSnapshot(
            id: "agent_2",
            name: "planner",
            status: .running,
            pending: true,
            modelID: "gpt-5",
            currentActivity: "reading project files",
            currentToolName: "search.grep",
            currentToolTarget: "needle",
            latestOutput: nil,
            latestError: nil,
            createdAt: Date(),
            updatedAt: Date()
        )

        let rendered = ansiStripped(TerminalSubAgentOverviewLayout.render(
            [snapshot],
            modelTitleResolver: { $0 },
            toolPresentationsByAgentID: [:]
        ))

        #expect(rendered.contains("model: gpt-5"))
        #expect(rendered.contains("💬 reading project files"))
        #expect(rendered.contains("🛠️  search.grep needle"))
        #expect(!rendered.contains("activity:"))
        #expect(!rendered.contains("tool:"))
    }

    @Test
    func subAgentOverviewRendersAgentProfileLineWhenProfileNamePresent() {
        let snapshot = DirectSubAgentRuntime.AgentSnapshot(
            id: "agent_profile",
            name: "builder",
            profileID: "developer-profile",
            profileName: "Developer",
            status: .running,
            pending: true,
            modelID: "gpt-5",
            latestOutput: nil,
            latestError: nil,
            createdAt: Date(),
            updatedAt: Date()
        )

        let rendered = ansiStripped(TerminalSubAgentOverviewLayout.render(
            [snapshot],
            modelTitleResolver: { $0 },
            toolPresentationsByAgentID: [:]
        ))
        let lines = rendered.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)

        #expect(rendered.contains("agent: Developer"))
        #expect(!rendered.contains("role:"))

        // The "agent:" line comes right after the "id:" line and before the
        // "model:" line.
        let idIndex = lines.firstIndex { $0.contains("id: agent_profile") }
        let agentIndex = lines.firstIndex { $0.contains("agent: Developer") }
        let modelIndex = lines.firstIndex { $0.contains("model: gpt-5") }
        #expect(idIndex != nil)
        #expect(agentIndex != nil)
        #expect(modelIndex != nil)
        if let idIndex, let agentIndex, let modelIndex {
            #expect(agentIndex == idIndex + 1)
            #expect(modelIndex > agentIndex)
        }
    }

    @Test
    func subAgentOverviewSignatureTracksGenerationMetrics() {
        func snapshot(
            metrics: DirectAgentGenerationMetrics?
        ) -> DirectSubAgentRuntime.AgentSnapshot {
            DirectSubAgentRuntime.AgentSnapshot(
                id: "agent_signature",
                name: "planner",
                status: .running,
                pending: true,
                modelID: "gpt-5",
                latestMetrics: metrics,
                latestOutput: nil,
                latestError: nil,
                createdAt: Date(timeIntervalSince1970: 0),
                updatedAt: Date(timeIntervalSince1970: 0)
            )
        }

        let none = ChatSubAgentOverview.signature(for: [snapshot(metrics: nil)])
        let first = ChatSubAgentOverview.signature(for: [
            snapshot(
                metrics: DirectAgentGenerationMetrics(
                    promptTokenCount: 1_200,
                    cachedPromptTokenCount: 800,
                    completionTokenCount: nil,
                )
            )
        ])
        let second = ChatSubAgentOverview.signature(for: [
            snapshot(
                metrics: DirectAgentGenerationMetrics(
                    promptTokenCount: 1_200,
                    cachedPromptTokenCount: 800,
                    completionTokenCount: 42,
                )
            )
        ])
        // Rates are not rendered, so they must not force a republish.
        let sameCounts = ChatSubAgentOverview.signature(for: [
            snapshot(
                metrics: DirectAgentGenerationMetrics(
                    promptTokenCount: 1_200,
                    cachedPromptTokenCount: 800,
                    completionTokenCount: 42,
                )
            )
        ])

        #expect(none != first)
        #expect(first != second)
        #expect(second == sameCounts)
    }

    @Test
    func subAgentOverviewResolvesFriendlyModelTitleViaResolver() {
        let snapshot = DirectSubAgentRuntime.AgentSnapshot(
            id: "agent_resolved",
            name: "planner",
            status: .running,
            pending: true,
            modelID: "gpt-5",
            latestOutput: nil,
            latestError: nil,
            createdAt: Date(),
            updatedAt: Date()
        )

        let resolver: (String) -> String = { id in
            id == "gpt-5" ? "GPT-5 Turbo" : id
        }
        let rendered = ansiStripped(
            TerminalSubAgentOverviewLayout.render(
                [snapshot],
                modelTitleResolver: resolver,
                toolPresentationsByAgentID: [:]
            )
        )

        #expect(rendered.contains("model: GPT-5 Turbo"))
        #expect(!rendered.contains("model: gpt-5"))
    }

    @Test
    func subAgentOverviewKeepsConfiguredModelTitleAfterBackendReportsGenericID() {
        let snapshot = DirectSubAgentRuntime.AgentSnapshot(
            id: "agent_configured_model",
            name: "developer",
            status: .running,
            pending: true,
            configuredModelID: "binding:chatgpt:gpt-5.6-terra",
            modelID: "gpt-5.6",
            latestOutput: nil,
            latestError: nil,
            createdAt: Date(),
            updatedAt: Date()
        )

        let resolver: (String) -> String = { id in
            switch id {
            case "binding:chatgpt:gpt-5.6-terra": "GPT-5.6 Terra"
            case "gpt-5.6": "GPT-5.6"
            default: id
            }
        }
        let rendered = ansiStripped(
            TerminalSubAgentOverviewLayout.render(
                [snapshot],
                modelTitleResolver: resolver,
                toolPresentationsByAgentID: [:]
            )
        )

        #expect(rendered.contains("model: GPT-5.6 Terra"))
        #expect(!rendered.contains("model: GPT-5.6\n"))
    }

    @Test
    func subAgentOverviewStripsRemoteAPIProviderKeyForUnresolvableModel() {
        let rawModelID = "zai:glm-5.2"
        let snapshot = DirectSubAgentRuntime.AgentSnapshot(
            id: "agent_remote",
            name: "worker",
            status: .running,
            pending: true,
            modelID: rawModelID,
            latestOutput: nil,
            latestError: nil,
            createdAt: Date(),
            updatedAt: Date()
        )

        let resolver: (String) -> String = {
            TerminalChat.resolvedSubAgentModelTitle(for: $0)
        }
        let rendered = ansiStripped(
            TerminalSubAgentOverviewLayout.render(
                [snapshot],
                modelTitleResolver: resolver,
                toolPresentationsByAgentID: [:]
            )
        )

        #expect(rendered.contains("model: glm-5.2"))
        #expect(!rendered.contains("zai:"))
    }

    @Test
    func subAgentModelNameStrippingRemoteAPIPrefixHandlesEdgeCases() {
        #expect(ModelNamePresentation.subAgentModelNameStrippingRemoteAPIPrefix("zai:glm-5.2") == "glm-5.2")
        #expect(ModelNamePresentation.subAgentModelNameStrippingRemoteAPIPrefix("gpt-5") == nil)
        // An unknown provider key must not be stripped.
        #expect(
            ModelNamePresentation.subAgentModelNameStrippingRemoteAPIPrefix("remoteapi:openrouter:anthropic/claude")
                == nil
        )
        // Missing model name segment.
        #expect(ModelNamePresentation.subAgentModelNameStrippingRemoteAPIPrefix("openrouter:") == nil)
    }

    @Test
    func subAgentOverviewShowsOnlyOneStableThinkingLabel() {
        let snapshot = DirectSubAgentRuntime.AgentSnapshot(
            id: "agent_thinking",
            name: "researcher",
            status: .running,
            pending: true,
            currentActivity: nil,
            currentActivityKind: .thinking,
            latestContentPreview: "private reasoning delta that must stay hidden",
            latestOutput: nil,
            latestError: nil,
            createdAt: Date(),
            updatedAt: Date()
        )

        let rendered = ansiStripped(TerminalSubAgentOverviewLayout.render(
            [snapshot],
            modelTitleResolver: { $0 },
            toolPresentationsByAgentID: [:]
        ))

        #expect(rendered.components(separatedBy: "🤔 thinking…").count - 1 == 1)
        #expect(!rendered.contains("private reasoning delta"))
        #expect(!rendered.contains("💬"))
    }

    @Test
    func subAgentOverviewUsesTheCompactToolNameAndTarget() {
        let toolCall = presentedToolCall(
            id: "grep-call",
            name: "search.grep",
            argumentsObject: ["pattern": "needle"],
            argumentsJSON: #"{"pattern":"needle"}"#
        )
        let target = ToolCallPresentation.displayToolTarget(for: toolCall)
        let snapshot = DirectSubAgentRuntime.AgentSnapshot(
            id: "agent_tool",
            name: "researcher",
            status: .running,
            pending: true,
            currentToolName: toolCall.name,
            currentToolTarget: target,
            latestOutput: nil,
            latestError: nil,
            createdAt: Date(),
            updatedAt: Date()
        )

        let rendered = ansiStripped(TerminalSubAgentOverviewLayout.render(
            [snapshot],
            modelTitleResolver: { $0 },
            toolPresentationsByAgentID: [:]
        ))

        #expect(target == "needle")
        #expect(rendered.contains("🛠️  \(toolCall.name) needle"))
        #expect(!rendered.contains("🤔 thinking…"))
    }

    @Test
    func subAgentOverviewMultiRowDensitiesKeepBlankSeparatorsBetweenAgents() {
        let now = Date(timeIntervalSince1970: 0)
        let agentCount = 8
        let snapshots = (1...agentCount).map { index in
            DirectSubAgentRuntime.AgentSnapshot(
                id: "a\(index)",
                name: "scout-\(index)",
                profileID: "dev",
                profileName: "Dev",
                status: .running,
                pending: true,
                configuredModelID: "m1",
                currentToolName: "search.grep",
                currentToolTarget: "needle",
                latestOutput: nil,
                latestError: nil,
                createdAt: now,
                updatedAt: now
            )
        }

        // `render` frames the section with a leading and a trailing newline,
        // so the physical rows are the ones between them.
        func visibleRows(rowBudget: Int) -> [String] {
            ansiStripped(
                TerminalSubAgentOverviewLayout.render(
                    snapshots,
                    modelTitleResolver: { $0 },
                    toolPresentationsByAgentID: [:],
                    rowBudget: rowBudget
                )
            )
            .split(separator: "\n", omittingEmptySubsequences: false)
            .dropFirst()
            .dropLast()
            .map(String.init)
        }
        func isBlank(_ row: String) -> Bool {
            row.trimmingCharacters(in: .whitespaces).isEmpty
        }

        // Title and summary, then per agent: separator + header + agent/model
        // + tool (compact), separator + header + tool (dense), or one header
        // row with the inline activity fragment (inline).
        let sectionRows = 2
        let compactRows = sectionRows + agentCount * 4
        let denseRows = sectionRows + agentCount * 3
        let inlineRows = sectionRows + agentCount

        // The budget fits compact: separators and agent rows are kept.
        let compact = visibleRows(rowBudget: compactRows)
        #expect(compact.count == compactRows)
        #expect(compact.filter(isBlank).count == agentCount)
        #expect(compact.filter { $0.contains("agent: Dev") }.count == agentCount)

        // One row short of compact: dense drops the agent/model rows but keeps
        // the blank separator before each agent.
        let dense = visibleRows(rowBudget: compactRows - 1)
        #expect(dense.count == denseRows)
        #expect(dense.filter(isBlank).count == agentCount)
        #expect(dense.filter { $0.contains("agent:") }.isEmpty)
        for index in 0..<agentCount {
            let first = sectionRows + index * 3
            #expect(isBlank(dense[first]))
            #expect(dense[first + 1].contains("scout-\(index + 1)"))
            #expect(dense[first + 2].contains("search.grep needle"))
        }

        // One row short of dense: only inline fits, one row per agent.
        let inline = visibleRows(rowBudget: denseRows - 1)
        #expect(inline.count == inlineRows)
        #expect(inline.filter(isBlank).isEmpty)
        for index in 0..<agentCount {
            #expect(inline[sectionRows + index].contains("scout-\(index + 1)"))
        }
    }

    @Test
    func subAgentResponseIdentityTracksCompletionRatherThanMetadataUpdates() throws {
        let createdAt = Date(timeIntervalSince1970: 10)
        let firstCompletion = DirectSubAgentRuntime.AgentSnapshot(
            id: "agent-response-token",
            name: "reviewer",
            status: .idle,
            pending: false,
            latestOutput: "**Done**",
            latestOutputRevision: 1,
            latestError: nil,
            createdAt: createdAt,
            updatedAt: Date(timeIntervalSince1970: 20)
        )
        let closedAfterCompletion = DirectSubAgentRuntime.AgentSnapshot(
            id: "agent-response-token",
            name: "reviewer",
            status: .closed,
            pending: false,
            latestOutput: "**Done**",
            latestOutputRevision: 1,
            latestError: nil,
            createdAt: createdAt,
            updatedAt: Date(timeIntervalSince1970: 30)
        )
        let repeatedContentInNewCompletion = DirectSubAgentRuntime.AgentSnapshot(
            id: "agent-response-token",
            name: "reviewer",
            status: .idle,
            pending: false,
            latestOutput: "**Done**",
            latestOutputRevision: 2,
            latestError: nil,
            createdAt: createdAt,
            updatedAt: Date(timeIntervalSince1970: 40)
        )

        let first = try #require(
            TerminalSubAgentOverviewLayout.markdownResponses([firstCompletion]).first
        )
        let closed = try #require(
            TerminalSubAgentOverviewLayout.markdownResponses([closedAfterCompletion]).first
        )
        let repeated = try #require(
            TerminalSubAgentOverviewLayout.markdownResponses([repeatedContentInNewCompletion]).first
        )

        #expect(first.markdown == "**Done**")
        #expect(first.token == closed.token)
        #expect(first.token != repeated.token)
    }
}
