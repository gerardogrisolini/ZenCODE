//
//  ChatCommandDispatchTests+Routing.swift
//  ZenCODE
//
//  The first half of the shared command dispatcher tests: unknown, hidden,
//  and channel-only commands, the routing of every shared command onto its
//  operation, and the order of the channel's command steps against the
//  runtime and the closing notices.
//  Tests of this serialized suite run in file-name order: keep the name.
//

import Foundation
import Synchronization
import Testing
import ToolCore
@testable import ZenCODECore
@testable import ZenCODERuntime

extension ChatCommandDispatchTests {
    // MARK: - Unknown, hidden, and channel commands

    @Test
    func aLineThatNamesNoCommandIsAnUnknownCommand() async throws {
        try await withChatHarness { harness in
            let controller = harness.controller

            #expect(await controller.handleCommandLine("/nope", context: [])
                == ChatCommandOutcome(notices: [.unknownCommand(line: "/nope")]))
            // The line is trimmed, and the text names the command token.
            #expect(await controller.handleCommandLine("  /nope with words  ", context: [])
                == ChatCommandOutcome(notices: [.unknownCommand(line: "/nope with words")]))
            // Commands that take no arguments name no command with some.
            for line in ["/help me", "/models alpha", "/undo now"] {
                #expect(await controller.handleCommandLine(line, context: [])
                    == ChatCommandOutcome(notices: [.unknownCommand(line: line)]))
            }
            #expect(ChatSessionNoticeText.text(for: .unknownCommand(line: "/nope with words"))
                == "ZenCODE: unknown command '/nope'.\n")
            #expect(await harness.presenter.events.isEmpty)
            #expect(await harness.runtime.calls.isEmpty)
        }
    }

    @Test
    func aHiddenCommandAnswersAsUnknownOrWithItsOwnMessage() async throws {
        try await withChatHarness { harness in
            let controller = harness.controller
            controller.commandRegistry = Self.registry

            #expect(await controller.handleCommandLine("/builder-only", context: [])
                == ChatCommandOutcome(notices: [.unknownCommand(line: "/builder-only")]))
            #expect(await controller.handleCommandLine("/builder-feature list", context: [])
                == ChatCommandOutcome(notices: [
                    .commandUnavailable(message: "ZenCODE: only with the Builder agent.\n"),
                ]))
            #expect(ChatSessionNoticeText.text(
                for: .commandUnavailable(message: "ZenCODE: only with the Builder agent.\n")
            ) == "ZenCODE: only with the Builder agent.\n")
            #expect(ChatSessionNotice.commandUnavailable(message: "x").channel == .failure)

            // Once the session has the fact, both are the channel's.
            #expect(await controller.handleCommandLine("/builder-only", context: .builderAgent)
                == ChatCommandOutcome(action: .channelCommand))
            #expect(await controller.handleCommandLine("/builder-feature list", context: .builderAgent)
                == ChatCommandOutcome(action: .channelCommand))
            #expect(await harness.presenter.events.isEmpty)
        }
    }

    @Test
    func channelCommandsAndToolLogsAreLeftToTheChannel() async throws {
        try await withChatHarness { harness in
            let controller = harness.controller
            controller.commandRegistry = TerminalChat.commandRegistry

            for line in [
                "/exit", "/voice on", "/cron list",
                "/tools logs", "  /tools LOGS  ",
            ] {
                #expect(await controller.handleCommandLine(line, context: [])
                    == ChatCommandOutcome(action: .channelCommand))
            }
            // The setup is no longer a command: it opens only with `zen --setup`.
            for line in ["/setup", "/setup now"] {
                #expect(await controller.handleCommandLine(line, context: [])
                    == ChatCommandOutcome(notices: [.unknownCommand(line: line)]))
            }
            #expect(ChatSessionNoticeText.text(for: .unknownCommand(line: "/setup now"))
                == "ZenCODE: unknown command '/setup'.\n")
            #expect(await harness.presenter.events.isEmpty)
            #expect(await harness.runtime.calls.isEmpty)
            #expect(await harness.host.interactions.isEmpty)
        }
    }

    // MARK: - Routing

    @Test
    func helpListsTheCommandsTheOperatorSees() async throws {
        try await withChatHarness { harness in
            let controller = harness.controller
            controller.commandRegistry = Self.registry

            #expect(await controller.handleCommandLine("/help", context: [])
                == ChatCommandOutcome(notices: [.help(commandHelp: Self.registry.helpLines(in: []))]))
            let builderHelp = await controller.handleCommandLine("/help", context: .builderAgent)
            #expect(builderHelp == ChatCommandOutcome(notices: [
                .help(commandHelp: Self.registry.helpLines(in: .builderAgent)),
            ]))
            #expect(!Self.registry.helpLines(in: []).contains("/builder-only is for the Builder."))
            #expect(Self.registry.helpLines(in: .builderAgent).contains("/builder-only is for the Builder."))
        }
    }

    @Test
    func theSelectionAndSessionCommandsRunTheirOperations() async throws {
        try await withChatHarness { harness in
            let controller = harness.controller
            try await harness.startSession()

            // Without menus every selection command answers without asking.
            #expect(await controller.handleCommandLine("/models", context: [])
                == ChatCommandOutcome(notices: try await controller.chooseModel().notices))
            #expect(await controller.handleCommandLine("/think", context: [])
                == ChatCommandOutcome(notices: try await controller.chooseThinking().notices))
            #expect(await controller.handleCommandLine("/tools", context: [])
                == ChatCommandOutcome(notices: await controller.chooseTools().notices))
            #expect(await controller.handleCommandLine("/skills", context: [])
                == ChatCommandOutcome(notices: await controller.chooseSkills().notices))
            #expect(await controller.handleCommandLine("/agents", context: [])
                == ChatCommandOutcome(notices: try await controller.chooseProjectAgents().notices))
            // `/think` refuses arguments: the level comes from the menu.
            #expect(await controller.handleCommandLine("/think high", context: [])
                == ChatCommandOutcome(notices: [.thinkingTakesNoArguments]))
            #expect(ChatSessionNoticeText.text(for: .thinkingTakesNoArguments)
                == "ZenCODE: /think does not accept arguments. Use /think to choose a level.\n")
            #expect(ChatSessionNotice.thinkingTakesNoArguments.channel == .failure)

            // `/agents list` prints the selected agent, then the list.
            let agents = try controller.availableAgents()
            #expect(await controller.handleCommandLine("/agents list", context: [])
                == ChatCommandOutcome(notices: [
                    .selectedAgent(controller.selection.agent),
                    .availableAgents(
                        agents: agents,
                        selected: controller.selection.agent,
                        manifestPath: AgentProfileStore.agentsManifestURL().path
                    ),
                ]))

            // A selection that cannot be read answers with the usage.
            let badTools = await controller.handleCommandLine("/tools bogus", context: [])
            #expect(badTools.notices.last == .toolSelectionUsage)
            #expect(badTools.notices.count == 2)

            // `/sessions` lists the saved sessions; `/session` is its alias,
            // and its arguments follow `/sessions`, so it always lists.
            let list = await controller.handleCommandLine("/sessions", context: [])
            #expect(list == ChatCommandOutcome(notices: try await controller.chooseSavedSession().notices))
            #expect(await controller.handleCommandLine("/session", context: []) == list)
            #expect(await controller.handleCommandLine("/session save", context: []) == list)
            #expect(ChatSessionController.savedSessionCommandAction(rawArguments: " Restore  abc ")
                == .restore(entryID: "abc"))
            #expect(ChatSessionController.savedSessionCommandAction(rawArguments: "my work")
                == .saveNamed("my work"))
        }
    }

    @Test
    func theWorkspaceAndTaskCommandsRunTheirOperations() async throws {
        try await withChatHarness { harness in
            let controller = harness.controller

            for line in ["/attach list", "/open", "/artifacts", "/artifacts now", "/changes", "/changes diff", "/undo", "/tasks"] {
                let expected: ChatCommandOutcome
                switch ChatCommandRegistry.commandToken(from: line) {
                case "/attach": expected = await controller.runAttachCommand(line: line)
                case "/open": expected = await controller.runOpenCommand(line: line)
                case "/artifacts": expected = await controller.runArtifactsCommand(line: line)
                case "/changes": expected = await controller.runChangesCommand(line: line)
                case "/undo": expected = await controller.runUndoCommand(line: line)
                default: expected = await controller.runTasksCommand(line: line)
                }
                #expect(await controller.handleCommandLine(line, context: []) == expected)
            }
            #expect(await controller.handleCommandLine("/attach list", context: [])
                == ChatCommandOutcome(notices: [.pendingAttachments([])]))
            #expect(await controller.handleCommandLine("/artifacts now", context: [])
                == ChatCommandOutcome(notices: [.artifactsTakeNoArguments]))
            #expect(await controller.handleCommandLine("/changes", context: [])
                == ChatCommandOutcome(notices: [.noTrackedFileChanges]))
        }
    }

    @Test
    func thePlanningCommandsRunTheirOperations() async throws {
        try await withChatHarness(catalog: Self.catalog) { harness in
            let controller = harness.controller

            #expect(await controller.handleCommandLine("/plan", context: [])
                == ChatCommandOutcome(notices: [.planMissingGoal]))
            #expect(await controller.handleCommandLine("/goal", context: [])
                == ChatCommandOutcome(notices: [.workflowMissingGoal]))
            controller.selection.toolKeys = ["files"]
            #expect(await controller.handleCommandLine("/review", context: [])
                == ChatCommandOutcome(notices: [.subAgentToolsRequired(command: "/review")]))
            #expect(await controller.handleCommandLine("/plan ship it", context: [])
                == ChatCommandOutcome(notices: [.subAgentToolsRequired(command: "/plan")]))
            #expect(await harness.presenter.events.isEmpty)

            #expect(await controller.handleCommandLine("/plan status", context: [])
                == ChatCommandOutcome(notices: [.noActivePlan]))
            #expect(await harness.presenter.events == [.submittedCommand("/plan status")])

            let goal = await controller.handleCommandLine("/goal ship it", context: [])
            let workflow = try #require(controller.activeWorkflow)
            #expect(goal == ChatCommandOutcome(action: .startTurn(
                prompt: PlanningCommandKernel.workflowPrompt(goal: "ship it", graphID: workflow.graphID),
                purpose: .workflow(originalGoal: "ship it", graphID: workflow.graphID),
                locksResponseLanguage: false
            )))
        }
    }

    // MARK: - Channel steps

    @Test
    func modelsRunsItsChannelStepAfterTheRuntimeAndBeforeTheClosingNotices() async throws {
        try await withChatHarness(hostCapabilities: [.singleChoice]) { harness in
            let controller = harness.controller
            let hooks = RecordingChannelHooks(runtime: harness.runtime)
            controller.channelHooks = hooks
            try await harness.startSession()

            // The same model updates the session in place.
            await harness.host.answerChooseOne(Fixtures.alpha.id)
            let sameModel = await controller.handleCommandLine("/models", context: [])
            #expect(sameModel == ChatCommandOutcome())
            #expect(hooks.steps == [
                "selectionDidApply(sessionUpdated, models) after [\"updateSessionOptions\"]",
            ])

            // Another model creates the session anew: the session steps run
            // inside the operation, the selection step closes it.
            await harness.clearRecords()
            await harness.host.answerChooseOne(Fixtures.beta.id)
            _ = await controller.handleCommandLine("/models", context: [])
            let calls = await harness.callNames()
            #expect(hooks.steps.dropFirst().map { $0.components(separatedBy: " after ").first ?? "" } == [
                "sessionWillCreate(modelChanged)",
                "sessionDidCreate(modelChanged)",
                "selectionDidApply(sessionRecreated, models)",
            ])
            #expect(hooks.steps.last == "selectionDidApply(sessionRecreated, models) after \(calls)")

            // A cancelled menu applies nothing: no step.
            await harness.host.answerChooseOne(nil)
            let stepCount = hooks.steps.count
            #expect(await controller.handleCommandLine("/models", context: [])
                == ChatCommandOutcome(notices: [.modelUnchanged]))
            #expect(hooks.steps.count == stepCount)
        }
    }

    @Test
    func aNewSessionRunsTheChannelStepsAroundTheRuntimeReset() async throws {
        try await withChatHarness { harness in
            let controller = harness.controller
            let hooks = RecordingChannelHooks(runtime: harness.runtime)
            controller.channelHooks = hooks
            try await harness.startSession()
            let previousSessionID = controller.sessionID

            let outcome = await controller.handleCommandLine("/sessions new", context: [])

            #expect(outcome == ChatCommandOutcome(notices: [.sessionStarted]))
            // Outside a host's slot the controller mints `chat-<uuid>`.
            #expect(controller.sessionID != previousSessionID)
            #expect(controller.sessionID.hasPrefix("chat-"))
            #expect(UUID(uuidString: String(controller.sessionID.dropFirst("chat-".count))) != nil)
            let calls = await harness.callNames()
            #expect(calls.first == "resetSession")
            #expect(await harness.runtime.calls.first == .resetSession(previousSessionID))
            #expect(hooks.steps == [
                "newSessionWillStart after []",
                "newSessionDidStart after \(calls)",
            ])
        }
    }

    @Test
    func compactionReadsTheChannelsWindowAndShowsTheCompactedOne() async throws {
        try await withChatHarness { harness in
            let controller = harness.controller
            let hooks = RecordingChannelHooks(runtime: harness.runtime)
            hooks.contextWindow = DirectAgentContextWindowStatus(
                usedTokens: 3_000,
                maxTokens: 4_096,
                modelID: "alpha-model",
                isApproximate: false
            )
            controller.channelHooks = hooks
            try await harness.startSession(conversation: Fixtures.longConversation)
            let sessionID = controller.sessionID
            await harness.runtime.setCompactionResult(
                AgentRuntimeSessionCompactionResult(
                    snapshot: AgentRuntimeSessionSnapshot(
                        sessionID: sessionID,
                        modelID: "alpha-model",
                        workingDirectoryPath: harness.workspace.path,
                        systemPrompt: nil,
                        dynamicContext: nil,
                        cacheKey: nil,
                        history: [Fixtures.message(.assistant, "Summary.")],
                        allowedToolNames: nil,
                        thinkingSelection: nil,
                        preserveThinking: false
                    ),
                    wasCompacted: true,
                    originalEstimatedTokenCount: 12_345,
                    estimatedTokenCount: 950,
                    maxTokens: 8_000,
                    keptRecentMessageCount: 2
                )
            )

            let outcome = await controller.handleCommandLine("/sessions compact", context: [])

            #expect(outcome == ChatCommandOutcome(notices: [
                .sessionCompacted(originalTokenCount: 12_345, tokenCount: 950, keptRecentMessageCount: 2),
            ]))
            // The channel's maximum bounds the compaction.
            #expect(await harness.runtime.calls == [
                .compactSession(sessionID: sessionID, force: true, maxTokensOverride: 4_096),
            ])
            #expect(hooks.steps == [
                "commandContextWindow after []",
                "sessionDidCompact(950/8000) after [\"compactSession\"]",
            ])

            // Without a positive maximum nothing bounds it; nothing compacted
            // shows no window.
            await harness.clearRecords()
            hooks.contextWindow = DirectAgentContextWindowStatus(
                usedTokens: nil,
                maxTokens: 0,
                modelID: "alpha-model",
                isApproximate: true
            )
            await harness.runtime.setCompactionResult(nil)
            #expect(await controller.handleCommandLine("/sessions compact", context: [])
                == ChatCommandOutcome(notices: [.nothingToCompact]))
            #expect(await harness.runtime.calls == [
                .compactSession(sessionID: sessionID, force: true, maxTokensOverride: nil),
            ])
            #expect(hooks.steps.count == 3)
        }
    }

    @Test
    func theSessionsMemoryCommandPrintsTheBlockTheLastPromptWasSentWith() async throws {
        let firstBlock = try #require(MemoryTurnCoordinator.formattedBlock("- [id: A] Summary: first"))
        let lastBlock = try #require(MemoryTurnCoordinator.formattedBlock("- [id: B] Summary: last"))
        try await withChatHarness { harness in
            let controller = harness.controller
            let line = "/sessions memory"

            // The runtime holds no snapshot of the session yet.
            #expect(await controller.handleCommandLine(line, context: [])
                == ChatCommandOutcome(notices: [.noTurnMemoryBlock]))

            try await harness.startSession()
            let sessionID = controller.sessionID

            // A session with no prompt yet has no block.
            await harness.runtime.setSessionHistory(
                [Fixtures.message(.assistant, "Hello.")],
                sessionID: sessionID
            )
            #expect(await controller.handleCommandLine(line, context: [])
                == ChatCommandOutcome(notices: [.noTurnMemoryBlock]))

            // Two prompts with different blocks: only the last prompt's block
            // is shown, without the instruction that follows it.
            await harness.runtime.setSessionHistory(
                [
                    AgentRuntimeMessage(
                        role: .user,
                        content: "First question",
                        turnAddition: AgentRuntimeMessage.turnAddition(
                            memoryBlock: firstBlock,
                            instruction: "First instruction."
                        )
                    ),
                    Fixtures.message(.assistant, "First answer."),
                    AgentRuntimeMessage(
                        role: .user,
                        content: "Last question",
                        turnAddition: AgentRuntimeMessage.turnAddition(
                            memoryBlock: lastBlock,
                            instruction: "Last instruction."
                        )
                    ),
                    Fixtures.message(.assistant, "Last answer."),
                ],
                sessionID: sessionID
            )
            #expect(await controller.handleCommandLine(line, context: [])
                == ChatCommandOutcome(notices: [.turnMemoryBlock(lastBlock)]))

            // The last prompt was sent without a turn addition while an earlier
            // one had a block.
            await harness.runtime.setSessionHistory(
                [
                    AgentRuntimeMessage(
                        role: .user,
                        content: "First question",
                        turnAddition: firstBlock
                    ),
                    Fixtures.message(.assistant, "First answer."),
                    Fixtures.message(.user, "Last question"),
                ],
                sessionID: sessionID
            )
            #expect(await controller.handleCommandLine(line, context: [])
                == ChatCommandOutcome(notices: [.noTurnMemoryBlock]))

            // The last prompt carries only the turn instruction.
            await harness.runtime.setSessionHistory(
                [
                    AgentRuntimeMessage(
                        role: .user,
                        content: "First question",
                        turnAddition: firstBlock
                    ),
                    AgentRuntimeMessage(
                        role: .user,
                        content: "Last question",
                        turnAddition: "Only an instruction."
                    ),
                ],
                sessionID: sessionID
            )
            #expect(await controller.handleCommandLine(line, context: [])
                == ChatCommandOutcome(notices: [.noTurnMemoryBlock]))
        }
    }

    @Test
    func memoryIsAKeywordOfTheSessionsCommandInAnyCase() {
        #expect(ChatSessionController.savedSessionCommandAction(rawArguments: " Memory ") == .memory)
        #expect(ChatSessionController.savedSessionCommandAction(rawArguments: "memory now") == .memory)
        #expect(ChatSessionController.savedSessionCommandAction(rawArguments: "memories")
            == .saveNamed("memories"))
    }

    @Test
    func theMemoryNoticesAreWrittenAsTheBlockWithItsSizeAndAsOneLine() {
        let block = "<project-memory>\n- Entry\n</project-memory>"
        let characters = block.count
        let tokens = characters / 4
        let sizeLine = "Memory block: \(characters) characters, ~\(tokens) tokens (estimated).\n"
        #expect(ChatSessionNoticeText.text(for: .turnMemoryBlock(block)) == block + "\n" + sizeLine)
        // A block that already ends with a newline gets no second one, and
        // its size still counts the block as given.
        let withNewline = block + "\n"
        #expect(ChatSessionNoticeText.text(for: .turnMemoryBlock(withNewline))
            == withNewline + "Memory block: \(withNewline.count) characters, ~\(withNewline.count / 4) tokens (estimated).\n")
        #expect(ChatSessionNoticeText.text(for: .noTurnMemoryBlock)
            == "No memory block was provided with the last prompt.\n")
        #expect(ChatSessionNoticeText.text(for: .sessionSelectionUsage)
            .contains("/sessions memory             Show the memory block of the last prompt"))
    }
}
