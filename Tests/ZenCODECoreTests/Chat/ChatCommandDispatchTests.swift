//
//  ChatCommandDispatchTests.swift
//  ZenCODE
//
//  The shared dispatcher of slash commands (`handleCommandLine(_:context:)`):
//  unknown, hidden, and channel-only commands, the routing of every shared
//  command onto its operation, the order of the channel's command steps
//  against the runtime and the closing notices, the ACP planning policy
//  (one case for each behavior ACP keeps), and the command fence that a
//  cancellation trips in the middle of `/goal` and of an approval.
//

import Foundation
import Synchronization
import Testing
import ToolCore
@testable import ZenCODECore

@Suite("Chat command dispatch", .serialized)
struct ChatCommandDispatchTests {
    private typealias Fixtures = ChatTestFixtures
    private typealias Roles = AgentProfileRoleTestSupport

    /// The system profiles a project without an agent association sees.
    private static let catalog = ChatTestCatalog.hosted(
        agents: [Roles.developer, Roles.systemPlanner, Roles.systemReviewer]
    )

    /// The shared commands with three channel commands: one always visible,
    /// one hidden as unknown without the Builder agent, and one hidden with
    /// its own message.
    private static let registry = ChatCommandRegistry(
        shared: ChatCommandRegistry.sharedDescriptors,
        channel: [
            (after: "/help", descriptors: [
                ChatCommandDescriptor(
                    command: "/quit",
                    summary: "close",
                    help: "/quit closes the session.",
                    scope: .channel
                ),
                ChatCommandDescriptor(
                    command: "/builder-only",
                    summary: "builder",
                    help: "/builder-only is for the Builder.",
                    scope: .channel,
                    availability: .builderAgent
                ),
                ChatCommandDescriptor(
                    command: "/builder-feature",
                    summary: "builder feature",
                    help: "/builder-feature is for the Builder.",
                    scope: .channel,
                    availability: .builderAgent,
                    hiddenMessage: "ZenCODE: only with the Builder agent.\n"
                ),
            ]),
        ]
    )

    /// An unapproved structured plan with two dependent points.
    private static func plan(id: String, goal: String = "Fix the parser") -> TerminalSessionPlan {
        TerminalSessionPlan(
            id: id,
            originalGoal: goal,
            consolidatedText: "1. Read the parser.\n2. Fix it.",
            createdAt: Date(timeIntervalSince1970: 1_000),
            points: [
                TerminalSessionPlanPoint(id: "\(id)-1", text: "Read the parser", hasExplicitDependencies: true),
                TerminalSessionPlanPoint(
                    id: "\(id)-2",
                    text: "Fix it",
                    dependsOn: ["\(id)-1"],
                    hasExplicitDependencies: true
                ),
            ]
        )
    }

    /// The ACP policy, with a `/review` prompt that names its inputs.
    private static func acpPolicy(
        savingAgent: AgentProfile? = nil,
        fallbackHistory: [AgentRuntimeMessage] = []
    ) -> ChatPlanningCommandPolicy {
        .acp(
            savingAgent: savingAgent,
            fallbackHistory: fallbackHistory,
            reviewPrompt: { request in
                "ACP REVIEW scope=\(request.scope) plan=\(request.approvedPlan?.id ?? "none") "
                    + "graph=\(request.taskGraph?.id ?? "none") reviewers=\(request.reviewers.count)"
            }
        )
    }

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

    // MARK: - ACP policy

    @Test
    func acpReviewNeverRefusesForLackOfChangesAndBuildsItsOwnPrompt() async throws {
        try await withChatHarness(catalog: Self.catalog) { harness in
            let controller = harness.controller
            // ACP checks its own grant: the selection's tool groups do not count.
            controller.selection.toolKeys = []

            let outcome = await controller.runReviewCommand(
                line: "/review@zen focus on parsing",
                policy: Self.acpPolicy()
            )
            #expect(outcome == ChatCommandOutcome(action: .startTurn(
                prompt: "ACP REVIEW scope=focus on parsing plan=none graph=none reviewers=1",
                purpose: .review,
                locksResponseLanguage: false
            )))

            // A plan whose text is blank is no approved plan for ACP.
            controller.activePlan = TerminalSessionPlan(
                id: "blank-plan",
                originalGoal: "Fix it",
                consolidatedText: "   ",
                isApproved: true
            )
            let blank = await controller.runReviewCommand(line: "/review", policy: Self.acpPolicy())
            #expect(blank == ChatCommandOutcome(action: .startTurn(
                prompt: "ACP REVIEW scope= plan=none graph=none reviewers=1",
                purpose: .review,
                locksResponseLanguage: false
            )))

            // The terminal refuses the same `/review` without changes.
            controller.activePlan = nil
            controller.selection.toolKeys = ["sub-agents"]
            #expect(await controller.runReviewCommand(line: "/review")
                == ChatCommandOutcome(notices: [.noChangesToReview]))
        }
    }

    @Test
    func acpPlanSaveStoresTheActivePlanWithItsQueueAndRefusesASequenceWithABlankPlan() async throws {
        try await withChatHarness(catalog: Self.catalog, persistsTaskGraphs: true) { harness in
            let controller = harness.controller
            let first = Self.plan(id: "acp-first")
            let second = Self.plan(id: "acp-second", goal: "Validate the parser")

            // A blank plan anywhere in the sequence makes it unsaveable.
            controller.activePlan = first
            controller.queuedPlans = [
                TerminalSessionPlan(id: "acp-blank", originalGoal: "Goal", consolidatedText: " "),
            ]
            #expect(await controller.runPlanCommand(line: "/plan save", policy: Self.acpPolicy())
                == ChatCommandOutcome(notices: [.planUnavailableForSaving]))
            #expect(await harness.runtime.savedTaskPlans(workingDirectory: harness.workspace).isEmpty)

            controller.queuedPlans = [second]
            let outcome = await controller.runPlanCommand(
                line: "/plan save",
                policy: Self.acpPolicy(savingAgent: Roles.systemReviewer)
            )
            #expect(outcome == ChatCommandOutcome(notices: [
                .planSequenceSaved(planIDs: ["acp-first", "acp-second"]),
            ]))
            #expect(controller.activePlan == first)
            #expect(controller.queuedPlans == [second])
            let library = await harness.runtime.savedTaskPlans(workingDirectory: harness.workspace)
            #expect(library.map(\.graph.id) == ["acp-second", "acp-first"])
            #expect(library.allSatisfy { $0.snapshot.savingAgentName == Roles.systemReviewer.name })
        }
    }

    @Test
    func acpPlanSavePromotesEveryPlanOfTheLatestAnswerInTheFallbackHistory() async throws {
        try await withChatHarness(catalog: Self.catalog, persistsTaskGraphs: true) { harness in
            let controller = harness.controller
            let answer = """
            Piano 1/2: Parser

            Specifiche concordate
            - Keep the public API.

            Implementation plan
            1. Read the parser.
               Dependencies: none

            Piano 2/2: Validation

            Specifiche concordate
            - Cover the regression.

            Implementation plan
            1. Add the regression test.
               Dependencies: none
            """
            let outcome = await controller.runPlanCommand(
                line: "/plan save",
                policy: Self.acpPolicy(fallbackHistory: [
                    Fixtures.message(.user, "Ship the parser fix"),
                    Fixtures.message(.assistant, answer),
                ])
            )

            let active = try #require(controller.activePlan)
            let next = try #require(controller.queuedPlans.first)
            #expect(controller.queuedPlans.count == 1)
            #expect(outcome == ChatCommandOutcome(notices: [.planSequenceSaved(planIDs: [active.id, next.id])]))
            #expect(active.originalGoal == "Piano 1/2: Parser — Ship the parser fix")
            #expect(next.originalGoal == "Piano 2/2: Validation — Ship the parser fix")
            let library = await harness.runtime.savedTaskPlans(workingDirectory: harness.workspace)
            #expect(library.map(\.graph.id) == [next.id, active.id])
        }
    }

    @Test
    func acpPlanLoadExtendsTheRuntimeSessionsHistory() async throws {
        try await withChatHarness(catalog: Self.catalog, persistsTaskGraphs: true) { harness in
            let controller = harness.controller
            try await harness.startSession(conversation: [Fixtures.message(.user, "controller copy")])
            let runtimeHistory = [
                Fixtures.message(.user, "client history"),
                Fixtures.message(.assistant, "client answer"),
            ]
            await harness.runtime.setSessionHistory(runtimeHistory, sessionID: controller.sessionID)
            let plan = Self.plan(id: "library-plan")
            controller.activePlan = plan
            _ = await controller.runPlanCommand(line: "/plan save")
            controller.activePlan = nil

            let outcome = await controller.runPlanCommand(line: "/plan load", policy: Self.acpPolicy())

            guard case let .savedPlanLoaded(loaded)? = outcome.notices.first else {
                Issue.record("Expected the loaded plan, got \(outcome.notices)")
                return
            }
            #expect(loaded.id == plan.id)
            let replaced = try #require(await harness.runtime.replacedHistories.last)
            #expect(replaced.dropLast().map(\.content) == runtimeHistory.map(\.content))
            #expect(replaced.count == runtimeHistory.count + 1)
            // The controller's own copy is left alone.
            #expect(controller.history.map(\.content) == ["controller copy"])
            #expect(controller.activePlan == loaded)
        }
    }

    @Test
    func acpProjectsARestoredWorkflowBeforeTheSharedReply() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("chat-dispatch-acp-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try await AppStorageDirectory.withSupportDirectoryURL(root) {
            let fixture = try await Self.makeACPFixture(sessionID: "acp-dispatch-projection")
            let orchestrator = await fixture.bridge.sessionRunner.taskOrchestrator
            let graph = try await orchestrator.createGraph(
                sessionID: fixture.sessionID, id: "workflow-restored", source: .workflow, state: .active,
                tasks: [], originalGoal: "Keep the restored goal"
            )
            _ = try await orchestrator.updateWorkflow(
                sessionID: fixture.sessionID, graphID: graph.id, state: .awaitingUser,
                message: "Which file first?", expectedRevision: graph.revision
            )
            // The command state knows no workflow: the shared reply alone
            // would leave the message an ordinary prompt.
            let controller = try #require(
                await fixture.bridge.chatSessionControllerForTesting(sessionID: fixture.sessionID)
            )
            #expect(await fixture.bridge.workflowStateForTesting(sessionID: fixture.sessionID) == nil)
            #expect(await controller.workflowContinuationReplyAction(for: "Start with main.swift") == nil)

            try await fixture.bridge.prompt(id: .number(1), params: [
                "sessionId": fixture.sessionID, "prompt": "Start with main.swift",
            ])

            let prompts = await fixture.backend.recordedPrompts()
            let continuation = try #require(prompts.first { $0.contains("Continue the goal workflow") })
            #expect(continuation.contains("Goal: Keep the restored goal"))
            #expect(continuation.contains("Start with main.swift"))
            #expect(fixture.wire.stopReason(for: 1) == "end_turn")
        }
    }

    // MARK: - Fence

    @Test
    func aGoalSupersededAfterCreatingItsGraphRemovesTheGraph() async throws {
        try await withChatHarness(catalog: Self.catalog) { harness in
            let controller = harness.controller
            let fence = controller.beginCommandFence(sessionID: controller.sessionID)
            // The cancellation lands between the graph's creation and the
            // workflow's state.
            await harness.presenter.setSubmittedCommandHook { _ in
                controller.cancelActiveTurn()
            }

            let outcome = await controller.runGoalCommand(line: "/goal ship it", fence: fence)

            #expect(outcome == ChatCommandOutcome())
            #expect(!controller.isCurrent(fence))
            #expect(await harness.presenter.events == [.submittedCommand("/goal ship it")])
            #expect(controller.activeWorkflow == nil)
            let graph = try await harness.runtime.taskGraphSnapshot(sessionID: controller.sessionID, graphID: nil)
            #expect(graph == nil)
        }
    }

    @Test
    func anApprovalSupersededAfterActivatingTheGraphRollsItBack() async throws {
        try await withChatHarness(catalog: Self.catalog, persistsTaskGraphs: true) { harness in
            let controller = harness.controller
            let plan = Self.plan(id: "approved-plan")
            controller.activePlan = plan
            controller.pendingPlanApprovalPlanID = plan.id
            // A previous graph with the plan's ID, which the approval replaces.
            let previous = Fixtures.taskGraph(id: plan.id)
            try await harness.runtime.seedTaskGraph(previous, sessionID: controller.sessionID)
            let fence = controller.beginCommandFence(sessionID: controller.sessionID)
            await harness.runtime.setTaskGraphActivationHook { _ in
                controller.cancelActiveTurn()
            }

            let outcome = await controller.pendingReplyAction(
                for: "Ship the parser",
                fence: fence,
                policy: Self.acpPolicy()
            )

            #expect(outcome == ChatCommandOutcome())
            #expect(!controller.isCurrent(fence))
            // The plan stays unapproved; the Goal request was consumed before
            // the graph changed, as ACP always did.
            #expect(controller.activePlan == plan)
            #expect(controller.pendingPlanApprovalPlanID == nil)
            // The new graph is gone and the previous one is back.
            let restored = try #require(
                try await harness.runtime.taskGraphSnapshot(sessionID: controller.sessionID, graphID: plan.id)
            )
            #expect(restored.tasks.map(\.id) == previous.tasks.map(\.id))
            #expect(restored.source == previous.source)
            #expect(await harness.callNames() == ["activateTaskGraph", "restoreTaskGraph"])
        }
    }

    // MARK: - Support

    /// An ACP bridge over a scripted backend with one installed session.
    private static func makeACPFixture(sessionID: String) async throws -> (
        bridge: ZenCODEACPBridge,
        backend: ScriptedACPCommandBackend,
        wire: DispatchACPWire,
        sessionID: String
    ) {
        let workingDirectory = AppStorageDirectory.appSupportDirectoryURL()
            .appendingPathComponent(sessionID, isDirectory: true)
        let backend = ScriptedACPCommandBackend()
        let wire = DispatchACPWire()
        let configuration = try AgentConfiguration(
            hostedModelID: "test-model",
            availableAgents: AgentProfileStore.defaultProfiles(),
            availableModels: [
                AgentSettingsModelManifest(id: "test-model", kind: .remoteAPI, modelID: "local/test-model"),
            ],
            runMode: .acp,
            workingDirectory: workingDirectory
        )
        let bridge = ZenCODEACPBridge(
            configuration: configuration,
            writer: ACPWriter(sink: wire.sink),
            backendFactory: { _, _ in backend }
        )
        let sessionConfiguration = AgentCoreSessionConfiguration(
            sessionID: sessionID,
            modelID: "test-model",
            workingDirectory: workingDirectory,
            systemPrompt: "Chat command dispatch test",
            cacheKey: nil,
            history: [],
            allowedToolNames: nil
        )
        try await bridge.sessionRunner.createSession(configuration: sessionConfiguration)
        await bridge.installTestSession(sessionConfiguration)
        return (bridge, backend, wire, sessionID)
    }
}

/// The JSON-RPC messages an ACP bridge writes.
private final class DispatchACPWire: Sendable {
    private let storage = Mutex<[JSONValue]>([])

    var sink: ACPWriter.Sink {
        { [self] data in
            if let value = try? JSONDecoder().decode(JSONValue.self, from: data) {
                storage.withLock { $0.append(value) }
            }
        }
    }

    func stopReason(for requestID: Int) -> String? {
        storage.withLock { values in
            values.compactMap { value -> String? in
                guard let object = value.objectValue,
                      object["id"] == .number(Double(requestID)) else {
                    return nil
                }
                return object["result"]?.objectValue?["stopReason"]?.stringValue
            }.first
        }
    }
}
