//
//  TelegramTUITests.swift
//  ZenCODE
//
//  Created by Gerardo Grisolini on 07/06/26.
//

import Foundation
import Testing
import ToolCore
@testable import ZenCODECore

@TerminalChatActor
@Suite
struct TelegramTUITests {
    @Test
    func telegramSettingsRequireEnabledToken() {
        let tokenOnlySettings = AgentTelegramSettingsManifest(
            enabled: true,
            botToken: " 123456:ABCDEF "
        )
        let pairedSettings = AgentTelegramSettingsManifest(
            enabled: true,
            botToken: " 123456:ABCDEF ",
            linkedChatID: 42,
            linkedChatTitle: "Gerardo"
        )
        let missingTokenSettings = AgentTelegramSettingsManifest(
            enabled: true,
            botToken: " "
        )
        let disabledSettings = AgentTelegramSettingsManifest(
            enabled: false,
            botToken: "123456:ABCDEF"
        )

        #expect(tokenOnlySettings.isConfigured)
        #expect(!tokenOnlySettings.isEnabled)
        #expect(tokenOnlySettings.botToken == "123456:ABCDEF")
        #expect(pairedSettings.isConfigured)
        #expect(pairedSettings.isEnabled)
        #expect(pairedSettings.linkedChatID == 42)
        #expect(pairedSettings.linkedChatTitle == "Gerardo")
        #expect(!missingTokenSettings.isEnabled)
        #expect(missingTokenSettings.botToken == nil)
        #expect(!disabledSettings.isEnabled)
        #expect(disabledSettings.botToken == nil)
    }

    @Test
    func settingsManifestRoundTripsEnabledTelegramConfiguration() throws {
        let manifest = AgentSettingsManifest(
            models: [],
            telegram: AgentTelegramSettingsManifest(
                enabled: true,
                botToken: "123456:ABCDEF",
                linkedChatID: 42,
                linkedChatTitle: "Gerardo"
            )
        )

        let data = try JSONEncoder().encode(manifest)
        let decoded = try JSONDecoder().decode(AgentSettingsManifest.self, from: data)
        let json = try #require(String(data: data, encoding: .utf8))

        #expect(decoded.telegram?.isEnabled == true)
        #expect(decoded.telegram?.botToken == "123456:ABCDEF")
        #expect(decoded.telegram?.linkedChatID == 42)
        #expect(decoded.telegram?.linkedChatTitle == "Gerardo")
        #expect(json.contains(#""telegram""#))
        #expect(json.contains(#""botToken":"123456:ABCDEF""#))
        #expect(json.contains(#""linkedChatID":42"#))
    }

    @Test
    func settingsManifestPreservesTokenOnlyTelegramConfigurationWithoutEnablingCommand() throws {
        let manifest = AgentSettingsManifest(
            models: [],
            telegram: AgentTelegramSettingsManifest(
                enabled: true,
                botToken: "123456:ABCDEF"
            )
        )

        let data = try JSONEncoder().encode(manifest)
        let decoded = try JSONDecoder().decode(AgentSettingsManifest.self, from: data)

        #expect(decoded.telegram?.isConfigured == true)
        #expect(decoded.telegram?.isEnabled == false)
        #expect(decoded.telegram?.botToken == "123456:ABCDEF")
        #expect(decoded.telegram?.linkedChatID == nil)
    }

    @Test
    func settingsManifestOmitsDisabledTelegramConfiguration() throws {
        let manifest = AgentSettingsManifest(
            models: [],
            telegram: AgentTelegramSettingsManifest(
                enabled: false,
                botToken: "123456:ABCDEF"
            )
        )

        let data = try JSONEncoder().encode(manifest)
        let decoded = try JSONDecoder().decode(AgentSettingsManifest.self, from: data)
        let json = try #require(String(data: data, encoding: .utf8))

        #expect(decoded.telegram == nil)
        #expect(!json.contains(#""telegram""#))
    }

    @Test
    func telegramCommandIsVisibleOnlyWhenConfigured() {
        let disabledCommands = TerminalChat.visibleCommandDescriptors(
            builderAgentEnabled: false,
            telegramEnabled: false
        ).map(\.command)
        let enabledCommands = TerminalChat.visibleCommandDescriptors(
            builderAgentEnabled: false,
            telegramEnabled: true
        ).map(\.command)

        #expect(!disabledCommands.contains("/agents-md"))
        #expect(!disabledCommands.contains("/make-agents"))
        #expect(!enabledCommands.contains("/agents-md"))
        #expect(!enabledCommands.contains("/make-agents"))
        #expect(!disabledCommands.contains("/telegram"))
        #expect(enabledCommands.contains("/telegram"))
    }

    @Test
    func builderCommandVisibilityRemainsIndependentFromTelegram() {
        let commands = TerminalChat.visibleCommandDescriptors(
            builderAgentEnabled: true,
            telegramEnabled: false
        ).map(\.command)

        #expect(commands.contains("/feature"))
        #expect(!commands.contains("/telegram"))
    }

    @Test
    func telegramCommandTokenRendersAsUnknownWhenHidden() {
        #expect(
            TerminalChat.unknownCommandMessage(for: "/telegram on")
                == "ZenCODE: unknown command '/telegram'.\n"
        )
    }

    @Test
    func submittedLineRoleSeparatesPromptsFromSlashCommands() {
        #expect(TerminalChat.submittedLineRole(for: "ciao") == .prompt)
        #expect(TerminalChat.submittedLineRole(for: "   ") == .empty)
        #expect(TerminalChat.submittedLineRole(for: "/telegram on") == .slashCommand(token: "/telegram"))
        #expect(TerminalChat.submittedLineRole(for: "/help extra") == .slashCommand(token: "/help"))
        #expect(TerminalChat.submittedLineRole(for: "/start 233B0EC4") == .slashCommand(token: "/start"))
    }

    @Test
    func slashCommandsDoNotUsePromptPanelRules() {
        #expect(!TerminalChat.shouldSuspendPanelInput(for: "ciao"))
        #expect(TerminalChat.shouldSuspendPanelInput(for: "/help"))
        #expect(TerminalChat.shouldSuspendPanelInput(for: "/unknown"))
        #expect(TerminalChat.isKnownSlashCommand("/think"))
        #expect(TerminalChat.isKnownSlashCommand("/session save"))
        #expect(!TerminalChat.isKnownSlashCommand("/agents-md"))
        #expect(!TerminalChat.isKnownSlashCommand("/make-agents"))
        #expect(!TerminalChat.isKnownSlashCommand("/start 233B0EC4"))
    }

    @Test
    func telegramOriginKeepsChatID() {
        let textOrigin = TerminalPromptOrigin.telegram(chatID: 42)

        #expect(textOrigin.telegramChatID == 42)
        #expect(TerminalPromptOrigin.local.telegramChatID == nil)
    }

    @Test
    func telegramCommandActionAcceptsOnlyOnOffAndBareStatus() {
        #expect(TerminalTelegramCommandAction(argument: "") == .status)
        #expect(TerminalTelegramCommandAction(argument: " on ") == .turnOn)
        #expect(TerminalTelegramCommandAction(argument: "off") == .turnOff)
        #expect(TerminalTelegramCommandAction(argument: "status") == .usage)
        #expect(TerminalTelegramCommandAction(argument: "start") == .usage)
        #expect(TerminalTelegramCommandAction(argument: "stop") == .usage)
    }

    @Test
    func telegramStartPayloadIsRemoteCommandNotPrompt() {
        #expect(TerminalTelegramRemoteCommand(text: "/start") == .start)
        #expect(TerminalTelegramRemoteCommand(text: "/start 233B0EC4") == .start)
        #expect(TerminalTelegramRemoteCommand(text: "/start@zencode_bot 233B0EC4") == .start)
        #expect(TerminalTelegramRemoteCommand(text: "/help") == .help)
        #expect(TerminalTelegramRemoteCommand(text: "ciao") == nil)
    }

    @Test
    func telegramProgressReporterRequiresActiveTelegramSession() throws {
        let configuration = try AgentConfiguration(
            hostedModelID: "remote-community/test",
            availableAgents: AgentProfileStore.defaultProfiles(),
            workingDirectory: URL(fileURLWithPath: "/tmp/project", isDirectory: true)
        )
        let terminal = TerminalChat(configuration: configuration, stdinIsTerminal: false)
        terminal.telegramLinkedChatID = 42

        terminal.telegramControlState = TerminalTelegramControlState(
            isConfigured: true,
            isActive: false,
            statusText: "Configured",
            botUsername: nil,
            lastError: nil,
            lastMessagePreview: nil
        )
        #expect(terminal.makeTelegramTurnProgressReporter(for: .telegram(chatID: 42)) == nil)

        terminal.telegramControlState.isActive = true
        // Local prompts forward to the linked chat once Telegram is active.
        #expect(terminal.makeTelegramTurnProgressReporter(for: .local) != nil)
        #expect(terminal.makeTelegramTurnProgressReporter(for: .telegram(chatID: 43)) == nil)
        #expect(terminal.makeTelegramTurnProgressReporter(for: .telegram(chatID: 42)) != nil)

        // Without a linked chat there is no destination, even for local prompts.
        terminal.telegramLinkedChatID = nil
        #expect(terminal.makeTelegramTurnProgressReporter(for: .local) == nil)
    }

    @Test
    func telegramTurnProgressReportingFollowsOnOffDuringLocalRequest() async throws {
        let configuration = try AgentConfiguration(
            hostedModelID: "remote-community/test",
            availableAgents: AgentProfileStore.defaultProfiles(),
            workingDirectory: URL(fileURLWithPath: "/tmp/project", isDirectory: true)
        )
        let terminal = TerminalChat(configuration: configuration, stdinIsTerminal: false)
        terminal.telegramLinkedChatID = 42
        terminal.telegramControlState = TerminalTelegramControlState(
            isConfigured: true,
            isActive: false,
            statusText: "Configured",
            botUsername: nil,
            lastError: nil,
            lastMessagePreview: nil
        )

        // A local turn begins while Telegram is off. Its origin is retained so
        // `/telegram on` can attach the in-flight request immediately.
        await terminal.beginTelegramTurnProgressReporting(for: .local)
        #expect(terminal.activeTelegramTurnOrigin == .local)
        #expect(terminal.activeTelegramProgressReporter == nil)

        terminal.telegramControlState.isActive = true
        terminal.synchronizeTelegramTurnProgressReporting()
        let firstReporter = try #require(terminal.activeTelegramProgressReporter)
        let firstChatID = await firstReporter.chatID
        #expect(firstChatID == 42)

        // `/telegram off` detaches the same in-flight turn, and turning it back
        // on does not require a Telegram-originated prompt.
        terminal.telegramControlState.isActive = false
        terminal.synchronizeTelegramTurnProgressReporting()
        #expect(terminal.activeTelegramProgressReporter == nil)

        terminal.telegramControlState.isActive = true
        terminal.synchronizeTelegramTurnProgressReporting()
        let secondReporter = try #require(terminal.activeTelegramProgressReporter)
        let secondChatID = await secondReporter.chatID
        #expect(secondChatID == 42)

        terminal.endTelegramTurnProgressReporting()
        #expect(terminal.activeTelegramTurnOrigin == nil)
        #expect(terminal.activeTelegramProgressReporter == nil)
    }

    /// While Telegram mirrors the session every turn owns an authorization
    /// handler, regardless of whether its prompt came from the terminal or the
    /// linked chat.
    @Test
    func telegramInstallsAuthorizationHandlerForMirroredTurns() throws {
        let terminal = try Self.activeTelegramTerminal()

        #expect(terminal.telegramToolAuthorizationHandler(for: .telegram(chatID: 42)) != nil)
        #expect(terminal.telegramToolAuthorizationHandler(for: .local) != nil)
        #expect(terminal.telegramToolAuthorizationHandler(for: .telegram(chatID: 43)) == nil)

        terminal.telegramControlState.isActive = false
        #expect(terminal.telegramToolAuthorizationHandler(for: .local) == nil)
        #expect(terminal.telegramToolAuthorizationHandler(for: .telegram(chatID: 42)) == nil)
    }

    /// Gated tools are the terminal authorizer's set, and a remote turn that
    /// cannot be asked is denied instead of silently approved.
    @Test
    func telegramTurnGatesDestructiveToolsAndFailsClosed() async throws {
        let terminal = try Self.activeTelegramTerminal()
        let deleteRequest = Self.authorizationRequest(
            toolName: "local.delete",
            title: "Delete Sources/Old.swift",
            kind: "destructive",
            command: "delete Sources/Old.swift"
        )

        #expect(DirectToolExecutor.destructiveGatedToolNames.allSatisfy(
            LocalExecPermissionAuthorizer.gatedToolNames.contains
        ))

        // Tools outside the gated set keep running without any dialogue.
        let readApproved = await terminal.authorizeTelegramToolRequest(
            Self.authorizationRequest(
                toolName: "local.readFile",
                title: "Read Sources/Main.swift",
                kind: "read",
                command: "read Sources/Main.swift"
            ),
            origin: .telegram(chatID: 42)
        )
        #expect(readApproved)

        // The chat that submitted the prompt can no longer be asked: refuse
        // rather than perform an unconfirmed destructive operation.
        terminal.telegramControlState.isActive = false
        let deleteApproved = await terminal.authorizeTelegramToolRequest(
            deleteRequest,
            origin: .telegram(chatID: 42)
        )
        #expect(!deleteApproved)
    }

    /// A locally submitted turn must send an actionable Telegram request too;
    /// answering the terminal dialog first cancels the remote wait and continues.
    @Test
    func mirroredLocalTurnCanBeAuthorizedFromTerminal() async throws {
        let authorizer = LocalExecPermissionAuthorizer()
        await authorizer.setConsentReader { _ in
            try? await Task.sleep(nanoseconds: 100_000_000)
            return Task.isCancelled ? nil : "r"
        }
        let terminal = try Self.activeTelegramTerminal(permissionAuthorizer: authorizer)
        let collector = TelegramTestMessageCollector()
        terminal.activeTelegramProgressReporter = TerminalTelegramTurnProgressReporter(
            chatID: 42
        ) { message, _ in
            await collector.append(message)
            return true
        }
        let request = Self.authorizationRequest(
            toolName: "local.delete",
            title: "Delete Sources/Terminal.swift",
            kind: "destructive",
            command: "delete Sources/Terminal.swift"
        )

        let authorization = Task {
            await terminal.authorizeTelegramToolRequest(request, origin: .local)
        }
        let telegramRequest = await collector.firstMessage()

        #expect(telegramRequest.contains("Permission required"))
        #expect(telegramRequest.contains("/allow"))
        #expect(await authorization.value)
    }

    /// The same coordinated request can be resolved from Telegram while the
    /// terminal dialog is pending; cancelling that dialog must not deny the tool.
    @Test
    func mirroredLocalTurnCanBeAuthorizedFromTelegram() async throws {
        let authorizer = LocalExecPermissionAuthorizer()
        await authorizer.setConsentReader { _ in
            do {
                try await Task.sleep(nanoseconds: 5_000_000_000)
                return "c"
            } catch {
                return nil
            }
        }
        let terminal = try Self.activeTelegramTerminal(permissionAuthorizer: authorizer)
        let collector = TelegramTestMessageCollector()
        terminal.activeTelegramProgressReporter = TerminalTelegramTurnProgressReporter(
            chatID: 42
        ) { message, _ in
            await collector.append(message)
            return true
        }
        let request = Self.authorizationRequest(
            toolName: "local.delete",
            title: "Delete Sources/Telegram.swift",
            kind: "destructive",
            command: "delete Sources/Telegram.swift"
        )

        let authorization = Task {
            await terminal.authorizeTelegramToolRequest(request, origin: .local)
        }
        let telegramRequest = await collector.firstMessage()
        let requestID = try #require(Self.telegramPermissionRequestID(in: telegramRequest))
        _ = await terminal.telegramPermissionBroker.handleMessage(
            "/allow \(requestID)",
            chatID: 42
        )

        #expect(await authorization.value)
    }

    private static func activeTelegramTerminal(
        permissionAuthorizer: LocalExecPermissionAuthorizer? = nil
    ) throws -> TerminalChat {
        let configuration = try AgentConfiguration(
            hostedModelID: "remote-community/test",
            availableAgents: AgentProfileStore.defaultProfiles(),
            workingDirectory: URL(fileURLWithPath: "/tmp/project", isDirectory: true)
        )
        let terminal = TerminalChat(
            configuration: configuration,
            stdinIsTerminal: false,
            permissionAuthorizer: permissionAuthorizer
        )
        terminal.telegramLinkedChatID = 42
        terminal.telegramControlState = TerminalTelegramControlState(
            isConfigured: true,
            isActive: true,
            statusText: "Active",
            botUsername: nil,
            lastError: nil,
            lastMessagePreview: nil
        )
        return terminal
    }

    @Test
    func telegramProgressReporterPublishesAllowedPayloadsInFIFOOrder() async {
        let collector = TelegramTestMessageCollector()
        let reporter = TerminalTelegramTurnProgressReporter(chatID: 42) { message, _ in
            await collector.append(message)
            return true
        }

        await reporter.enqueue(.tasks("📋 Task graph\n\n1 running"))
        #expect(await reporter.send(.authorization("🔐 Permission required\nRequest ID: A1")))
        await reporter.enqueue(.subAgentResponse("Reviewer completed."))
        await reporter.enqueue(.agentResponse("*ZenCODE completed*\n\nDone."))
        await reporter.enqueue(.summary("🪬 Summary: 1 file  +1 -0"))
        await reporter.flush()

        #expect(await collector.allMessages() == [
            "📋 Task graph\n\n1 running",
            "🔐 Permission required\nRequest ID: A1",
            "Reviewer completed.",
            "*ZenCODE completed*\n\nDone.",
            "🪬 Summary: 1 file  +1 -0"
        ])
    }

    @Test
    func telegramSubAgentOverviewRoutesToSubAgentResponsePayload() {
        let payload = TerminalChat.telegramSubAgentResponsePayload(
            heading: "\u{001B}[1mResponse from Reviewer:\u{001B}[0m",
            markdown: "Completed the review."
        )

        guard case let .some(.subAgentResponse(text)) = payload else {
            Issue.record("A sub-agent overview must retain the subAgentResponse discriminator.")
            return
        }
        #expect(text == "Response from Reviewer:\n\nCompleted the review.")
    }

    @Test
    func telegramProgressReporterTruncatesAllowedPayloads() async {
        let collector = TelegramTestMessageCollector()
        let reporter = TerminalTelegramTurnProgressReporter(chatID: 42) { message, _ in
            await collector.append(message)
            return true
        }

        await reporter.enqueue(.agentResponse(String(repeating: "x", count: 4_000)))
        await reporter.flush()

        let messages = await collector.allMessages()
        #expect(messages.count == 1)
        #expect(messages[0].count == TerminalTelegramTurnProgressReporter.maximumMessageLength)
    }

    @Test
    func telegramProgressReporterReturnsAuthorizationDeliveryResult() async {
        let reporter = TerminalTelegramTurnProgressReporter(chatID: 42) { _, _ in false }

        #expect(!(await reporter.send(.authorization("🔐 Permission required"))))
        await reporter.flush()
    }

    @Test
    func telegramFinalizationDeliversResponseBeforeSummary() async throws {
        let terminal = try Self.activeTelegramTerminal()
        let collector = TelegramTestMessageCollector()
        terminal.activeTelegramProgressReporter = TerminalTelegramTurnProgressReporter(
            chatID: 42
        ) { message, _ in
            await collector.append(message)
            return true
        }
        let summary = TurnFileChangeSummary(entries: [
            TurnFileChangeSummary.Entry(
                path: "Sources/App.swift",
                additions: 1,
                deletions: 0,
                status: .modified,
                isBinary: false,
                existedBefore: true,
                beforeDataBase64: nil,
                patch: nil
            )
        ])

        await terminal.activeTelegramProgressReporter?.enqueue(.tasks("📋 Task graph"))
        await terminal.finalizeTelegramTurnProgressReporting(
            outcome: .agentResponse("*ZenCODE completed*\n\nDone."),
            fileChangeSummary: summary
        )

        let messages = await collector.allMessages()
        #expect(messages.count == 3)
        #expect(messages[1] == "*ZenCODE completed*\n\nDone.")
        #expect(messages[2].hasPrefix("🪬 Summary:"))
        #expect(terminal.activeTelegramProgressReporter == nil)
    }

    @Test
    func telegramFinalizationDeliversOutcomeAndSummaryWithoutReporter() async throws {
        let terminal = try Self.activeTelegramTerminal()
        let collector = TelegramTestMessageCollector()
        terminal.activeTelegramTurnOrigin = .local
        terminal.onDirectTelegramTurnMessage = { payload, chatID in
            #expect(chatID == 42)
            await collector.append(payload.text)
            return true
        }
        let summary = TurnFileChangeSummary(entries: [
            TurnFileChangeSummary.Entry(
                path: "Sources/App.swift",
                additions: 1,
                deletions: 0,
                status: .modified,
                isBinary: false,
                existedBefore: true,
                beforeDataBase64: nil,
                patch: nil
            )
        ])

        await terminal.finalizeTelegramTurnProgressReporting(
            outcome: .agentResponse("*ZenCODE completed*\n\nDone."),
            fileChangeSummary: summary
        )

        let messages = await collector.allMessages()
        #expect(messages.count == 2)
        #expect(messages[0] == "*ZenCODE completed*\n\nDone.")
        #expect(messages[1].hasPrefix("🪬 Summary:"))
        #expect(terminal.activeTelegramProgressReporter == nil)
        #expect(terminal.activeTelegramTurnOrigin == nil)
    }

    @Test
    func telegramFinalizationDoesNotUseDirectFallbackWhenReporterExists() async throws {
        let terminal = try Self.activeTelegramTerminal()
        let reporterCollector = TelegramTestMessageCollector()
        let fallbackCollector = TelegramTestMessageCollector()
        terminal.activeTelegramTurnOrigin = .local
        terminal.activeTelegramProgressReporter = TerminalTelegramTurnProgressReporter(
            chatID: 42
        ) { message, _ in
            await reporterCollector.append(message)
            return true
        }
        terminal.onDirectTelegramTurnMessage = { payload, _ in
            await fallbackCollector.append(payload.text)
            return true
        }

        await terminal.finalizeTelegramTurnProgressReporting(
            outcome: .agentResponse("Done.")
        )

        #expect((await reporterCollector.allMessages()) == ["Done."])
        #expect((await fallbackCollector.allMessages()).isEmpty)
    }

    // MARK: - Root response mirroring

    @Test
    func telegramAggregatesRootResponseDeltasIntoOneMessageAtToolBoundary() async throws {
        let terminal = try Self.activeTelegramTerminal()
        let collector = TelegramTestMessageCollector()
        let reporter = Self.attachTestReporter(to: terminal, collector: collector)

        await terminal.appendTelegramRootResponseDelta("Inspecting ")
        await terminal.appendTelegramRootResponseDelta("the reporter")
        await terminal.appendTelegramRootResponseDelta(" first.\n")
        #expect((await collector.allMessages()).isEmpty)

        await terminal.publishTelegramRootResponseAtToolBoundary()
        await reporter.flush()

        #expect((await collector.allMessages()) == ["Inspecting the reporter first."])
    }

    @Test
    func telegramPublishesEveryIntermediateRootResponseSeparately() async throws {
        let terminal = try Self.activeTelegramTerminal()
        let collector = TelegramTestMessageCollector()
        let reporter = Self.attachTestReporter(to: terminal, collector: collector)

        await terminal.appendTelegramRootResponseDelta("First step.")
        await terminal.publishTelegramRootResponseAtToolBoundary()
        await terminal.appendTelegramRootResponseDelta("Second step.")
        await terminal.publishTelegramRootResponseAtToolBoundary()
        // A boundary without any content in between publishes nothing.
        await terminal.publishTelegramRootResponseAtToolBoundary()
        await reporter.flush()

        #expect((await collector.allMessages()) == ["First step.", "Second step."])
    }

    @Test
    func telegramDoesNotDuplicateTrailingRootResponseAsFinalOutcome() async throws {
        let terminal = try Self.activeTelegramTerminal()
        let collector = TelegramTestMessageCollector()
        terminal.activeTelegramTurnOrigin = .local
        _ = Self.attachTestReporter(to: terminal, collector: collector)

        await terminal.appendTelegramRootResponseDelta("Intermediate.")
        await terminal.publishTelegramRootResponseAtToolBoundary()
        // Trailing content that no tool call closes is the final response.
        await terminal.appendTelegramRootResponseDelta("All done, ")
        await terminal.appendTelegramRootResponseDelta("everything works.")

        await terminal.finalizeTelegramTurnProgressReporting(
            outcome: .agentResponse("All done, everything works.")
        )

        #expect(
            (await collector.allMessages()) == [
                "Intermediate.",
                "All done, everything works."
            ]
        )
        #expect(terminal.activeTelegramProgressReporter == nil)
    }

    @Test
    func telegramMirrorsOnlyResponsesAndNeverThinkingOrToolDetails() async throws {
        let terminal = try Self.activeTelegramTerminal()
        let collector = TelegramTestMessageCollector()
        terminal.activeTelegramTurnOrigin = .local
        let reporter = Self.attachTestReporter(to: terminal, collector: collector)

        // A turn that reasons, answers, calls a tool, and answers again: only
        // the visible responses have a mirroring hook, so reasoning and tool
        // identity have no path to the remote chat.
        await terminal.writeThought("Secret reasoning about local.delete.\n")
        await terminal.appendTelegramRootResponseDelta("Reading the manifest.")
        await terminal.publishTelegramRootResponseAtToolBoundary()
        await terminal.appendTelegramRootResponseDelta("Manifest looks fine.")
        await terminal.publishTelegramRootResponseAtToolBoundary()
        await reporter.flush()

        let messages = await collector.allMessages()
        #expect(messages == ["Reading the manifest.", "Manifest looks fine."])
        for message in messages {
            #expect(!message.contains("Secret reasoning"))
            #expect(!message.contains("thinking"))
            #expect(!message.contains("local.delete"))
            #expect(!message.contains("local.readFile"))
        }
    }

    @Test
    func telegramKeepsRootResponsesInOrderWithDelegatedAndAuthorizationPayloads() async throws {
        let terminal = try Self.activeTelegramTerminal()
        let collector = TelegramTestMessageCollector()
        terminal.activeTelegramTurnOrigin = .local
        let reporter = Self.attachTestReporter(to: terminal, collector: collector)

        await terminal.appendTelegramRootResponseDelta("Delegating the work.")
        await terminal.publishTelegramRootResponseAtToolBoundary()
        await reporter.enqueue(.tasks("📋 Task graph\n\nstep 1"))
        await reporter.enqueue(.subAgentResponse("🤖 worker\n\nDelegated answer."))
        await terminal.sendTelegramTurnMessage(.authorization("Permission required"), to: 42)
        await terminal.appendTelegramRootResponseDelta("Continuing after the tool.")
        await terminal.publishTelegramRootResponseAtToolBoundary()

        await terminal.finalizeTelegramTurnProgressReporting(
            outcome: .agentResponse("Final answer.")
        )

        #expect(
            (await collector.allMessages()) == [
                "Delegating the work.",
                "📋 Task graph\n\nstep 1",
                "🤖 worker\n\nDelegated answer.",
                "Permission required",
                "Continuing after the tool.",
                "Final answer."
            ]
        )
    }

    @Test
    func telegramSuppressesRootResponseStartedWhileTelegramWasOff() async throws {
        let terminal = try Self.activeTelegramTerminal()
        let firstCollector = TelegramTestMessageCollector()
        terminal.activeTelegramTurnOrigin = .local
        _ = Self.attachTestReporter(to: terminal, collector: firstCollector)

        await terminal.appendTelegramRootResponseDelta("Visible beginning ")

        // /telegram off in the middle of the response.
        terminal.telegramControlState.isActive = false
        terminal.synchronizeTelegramTurnProgressReporting()
        #expect(terminal.activeTelegramProgressReporter == nil)
        await terminal.appendTelegramRootResponseDelta("hidden middle ")

        // /telegram on again, still inside the same response block.
        terminal.telegramControlState.isActive = true
        terminal.synchronizeTelegramTurnProgressReporting()
        #expect(terminal.activeTelegramProgressReporter != nil)
        let secondCollector = TelegramTestMessageCollector()
        let secondReporter = Self.attachTestReporter(to: terminal, collector: secondCollector)
        await terminal.appendTelegramRootResponseDelta("and the tail.")
        await terminal.publishTelegramRootResponseAtToolBoundary()
        await secondReporter.flush()

        // Neither a replay of the hidden text nor a partial suffix is sent.
        #expect((await firstCollector.allMessages()).isEmpty)
        #expect((await secondCollector.allMessages()).isEmpty)

        // The next response block starts clean and is mirrored again.
        await terminal.appendTelegramRootResponseDelta("Next response.")
        await terminal.publishTelegramRootResponseAtToolBoundary()
        await secondReporter.flush()
        #expect((await secondCollector.allMessages()) == ["Next response."])
    }

    @Test
    func telegramReporterTruncatesAggregatedRootResponseToMessageLimit() async {
        let collector = TelegramTestMessageCollector()
        let reporter = TerminalTelegramTurnProgressReporter(chatID: 42) { message, _ in
            await collector.append(message)
            return true
        }
        let limit = TerminalTelegramTurnProgressReporter.maximumMessageLength

        for _ in 0..<10 {
            await reporter.appendAgentResponseDelta(String(repeating: "a", count: 1_000))
        }
        #expect(await reporter.hasPendingAgentResponse)
        await reporter.publishPendingAgentResponseAtBoundary()
        await reporter.flush()

        let messages = await collector.allMessages()
        #expect(messages.count == 1)
        #expect(messages.first?.count == limit)
    }

    @Test
    func telegramReporterDiscardsPendingRootResponseWithoutSending() async {
        let collector = TelegramTestMessageCollector()
        let reporter = TerminalTelegramTurnProgressReporter(chatID: 42) { message, _ in
            await collector.append(message)
            return true
        }

        await reporter.appendAgentResponseDelta("Trailing final text.")
        await reporter.discardPendingAgentResponse()
        #expect(await reporter.hasPendingAgentResponse == false)
        #expect(await reporter.publishPendingAgentResponseAtBoundary() == false)
        await reporter.flush()

        #expect((await collector.allMessages()).isEmpty)
    }

    @Test
    func telegramFinalResponseTextExcludesAlreadyMirroredIntermediateResponses() async throws {
        let terminal = try Self.activeTelegramTerminal()
        let collector = TelegramTestMessageCollector()
        terminal.activeTelegramTurnOrigin = .local
        _ = Self.attachTestReporter(to: terminal, collector: collector)

        await terminal.appendTelegramRootResponseDelta("Inspecting the manifest.")
        await terminal.publishTelegramRootResponseAtToolBoundary()
        await terminal.appendTelegramRootResponseDelta("All done, everything works.")

        // A turn's response text accumulates every block it produced.
        let accumulated = "Inspecting the manifest.All done, everything works."
        let mirrored = await terminal.telegramMirroredFinalResponseText(
            fallback: accumulated
        )
        #expect(mirrored == "All done, everything works.")

        await terminal.finalizeTelegramTurnProgressReporting(
            outcome: .agentResponse("*ZenCODE completed*\n\n\(mirrored)")
        )

        let messages = await collector.allMessages()
        #expect(
            messages == [
                "Inspecting the manifest.",
                "*ZenCODE completed*\n\nAll done, everything works."
            ]
        )
    }

    @Test
    func telegramFinalResponseTextKeepsFallbackWithoutMirroredIntermediateResponses() async throws {
        let terminal = try Self.activeTelegramTerminal()
        let collector = TelegramTestMessageCollector()
        terminal.activeTelegramTurnOrigin = .local
        _ = Self.attachTestReporter(to: terminal, collector: collector)

        await terminal.appendTelegramRootResponseDelta("Only one response.")

        #expect(
            (await terminal.telegramMirroredFinalResponseText(fallback: "Only one response."))
                == "Only one response."
        )
    }

    @discardableResult
    private static func attachTestReporter(
        to terminal: TerminalChat,
        collector: TelegramTestMessageCollector
    ) -> TerminalTelegramTurnProgressReporter {
        let reporter = TerminalTelegramTurnProgressReporter(chatID: 42) { message, _ in
            await collector.append(message)
            return true
        }
        terminal.activeTelegramProgressReporter = reporter
        return reporter
    }

    @Test
    func telegramPairingCodeAcceptsPlainCodeAndStartPayload() {
        #expect(TerminalTelegramPairingService.pairingCode(in: " abcd1234 ") == "ABCD1234")
        #expect(TerminalTelegramPairingService.pairingCode(in: "/start abcd1234") == "ABCD1234")
        #expect(
            TerminalTelegramPairingService.pairingCode(in: "/start@zencode_bot abcd1234")
                == "ABCD1234"
        )
        #expect(TerminalTelegramPairingService.pairingCode(in: "\n/start AbCd1234\n") == "ABCD1234")
        #expect(TerminalTelegramPairingService.pairingCode(in: "/start") == nil)
    }

    @Test
    func telegramPairingOnlyAllowsPrivateChats() {
        #expect(TerminalTelegramPairingService.allowsPairing(chatType: "private"))
        #expect(TerminalTelegramPairingService.allowsPairing(chatType: "PRIVATE"))
        #expect(!TerminalTelegramPairingService.allowsPairing(chatType: "group"))
        #expect(!TerminalTelegramPairingService.allowsPairing(chatType: "supergroup"))
        #expect(!TerminalTelegramPairingService.allowsPairing(chatType: "channel"))
        #expect(TerminalTelegramControlService.incomingMessageBufferLimit == 64)
    }

    @Test
    func telegramUpdateOffsetIsDurableMonotonicAndPerBot() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let url = directory.appendingPathComponent("telegram-updates.json")
        defer { try? FileManager.default.removeItem(at: directory) }

        try TerminalTelegramUpdateOffsetStore.save(updateID: 41, botID: 100, to: url)
        try TerminalTelegramUpdateOffsetStore.save(updateID: 40, botID: 100, to: url)
        try TerminalTelegramUpdateOffsetStore.save(updateID: 7, botID: 200, to: url)

        #expect(TerminalTelegramUpdateOffsetStore.load(botID: 100, from: url) == 41)
        #expect(TerminalTelegramUpdateOffsetStore.load(botID: 200, from: url) == 7)
        #if os(macOS) || os(Linux)
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        #expect((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o600)
        #endif

        try Data("corrupt".utf8).write(to: url)
        #expect(throws: (any Error).self) {
            _ = try TerminalTelegramUpdateOffsetStore.loadRequired(botID: 100, from: url)
        }
    }

    @Test
    func telegramPermissionCommandsParseRemoteApprovalReplies() {
        #expect(
            TerminalTelegramPermissionBroker.permissionCommand(from: "/allow ABC123")
                == TerminalTelegramPermissionCommand(decision: .allowOnce, requestID: "ABC123")
        )
        #expect(
            TerminalTelegramPermissionBroker.permissionCommand(from: "/always@zencode_bot f00")
                == TerminalTelegramPermissionCommand(decision: .allowAlways, requestID: "F00")
        )
        #expect(
            TerminalTelegramPermissionBroker.permissionCommand(from: "/deny ABC123")
                == TerminalTelegramPermissionCommand(decision: .deny, requestID: "ABC123")
        )
        #expect(TerminalTelegramPermissionBroker.permissionCommand(from: "sì abc-123") == nil)
        #expect(TerminalTelegramPermissionBroker.permissionCommand(from: "annulla") == nil)
        #expect(TerminalTelegramPermissionBroker.permissionCommand(from: "run the tests") == nil)
    }

    @Test
    func telegramPermissionBrokerWaitsForRemoteReply() async throws {
        let broker = TerminalTelegramPermissionBroker()
        let collector = TelegramTestMessageCollector()
        let command = "remote-telegram-permission-test-\(UUID().uuidString)"
        let request = Self.localExecAuthorizationRequest(command: "\(command) --flag")

        let authorization = Task {
            await broker.authorize(
                request,
                chatID: 42,
                timeoutNanoseconds: 5_000_000_000
            ) { message in
                await collector.append(message)
                return true
            }
        }

        let message = await collector.firstMessage()
        #expect(message.contains("Permission required"))
        #expect(message.contains(command))
        let requestID = try #require(Self.telegramPermissionRequestID(in: message))

        let reminder = await broker.handleMessage("queue another prompt", chatID: 42)
        #expect(reminder.isHandled)
        if case let .handled(reply) = reminder {
            #expect(reply?.contains("Permission request pending") == true)
        }

        let reply = await broker.handleMessage("/allow \(requestID)", chatID: 42)
        #expect(reply.isHandled)
        if case let .handled(replyText) = reply {
            #expect(replyText?.contains("allowed once") == true)
        }
        #expect(await authorization.value == .allowedOnce)
    }

    /// The destructive direct tools are gated exactly like `local.exec`, so a
    /// remote turn can no longer perform them without being asked.
    @Test
    func telegramPermissionBrokerAsksForDestructiveTools() async throws {
        let broker = TerminalTelegramPermissionBroker()
        let collector = TelegramTestMessageCollector()
        let request = Self.authorizationRequest(
            toolName: "local.delete",
            title: "Delete Sources/Old.swift",
            kind: "destructive",
            command: "delete Sources/Old.swift"
        )

        #expect(!(await broker.isAlreadyAuthorized(request)))

        let authorization = Task {
            await broker.authorize(
                request,
                chatID: 42,
                timeoutNanoseconds: 5_000_000_000
            ) { message in
                await collector.append(message)
                return true
            }
        }

        let message = await collector.firstMessage()
        #expect(message.contains("Permission required"))
        #expect(message.contains("local.delete"))
        #expect(message.contains("Delete Sources/Old.swift"))
        let requestID = try #require(Self.telegramPermissionRequestID(in: message))

        _ = await broker.handleMessage("/deny \(requestID)", chatID: 42)
        #expect(await authorization.value == .denied)
    }

    /// A request that never reached the chat must fail closed immediately
    /// instead of holding the turn until the timeout expires.
    @Test
    func telegramPermissionBrokerFailsClosedWhenRequestCannotBeDelivered() async {
        let broker = TerminalTelegramPermissionBroker()
        let request = Self.localExecAuthorizationRequest(
            command: "undeliverable-\(UUID().uuidString) --flag"
        )

        let outcome = await broker.authorize(
            request,
            chatID: 42,
            timeoutNanoseconds: 600_000_000_000
        ) { _ in
            false
        }

        #expect(outcome == .undeliverable)
        #expect(!outcome.isApproved)
    }

    /// A tool outside the gated set never raises a remote dialogue.
    @Test
    func telegramPermissionBrokerSkipsUngatedTools() async {
        let broker = TerminalTelegramPermissionBroker()
        let request = Self.authorizationRequest(
            toolName: "local.readFile",
            title: "Read Sources/Main.swift",
            kind: "read",
            command: "read Sources/Main.swift"
        )

        #expect(await broker.isAlreadyAuthorized(request))
        let outcome = await broker.authorize(request, chatID: 42) { _ in
            Issue.record("An ungated tool must not raise a permission request.")
            return true
        }
        #expect(outcome == .notRequired)
        #expect(outcome.isApproved)
    }

    @Test
    func telegramPermissionBrokerHandlesStrayPermissionRepliesWithoutPrompting() async {
        let broker = TerminalTelegramPermissionBroker()
        let permissionReply = await broker.handleMessage("/allow ABC123", chatID: 42)
        let regularPrompt = await broker.handleMessage("please continue", chatID: 42)

        #expect(permissionReply.isHandled)
        if case let .handled(reply) = permissionReply {
            #expect(reply == "No permission request is pending.")
        }
        #expect(regularPrompt == .notHandled)
    }

    private static func localExecAuthorizationRequest(command: String) -> AgentToolAuthorizationRequest {
        authorizationRequest(
            toolName: "local.exec",
            title: "Run \(command)",
            kind: "execute",
            command: command
        )
    }

    private static func authorizationRequest(
        toolName: String,
        title: String,
        kind: String,
        command: String
    ) -> AgentToolAuthorizationRequest {
        AgentToolAuthorizationRequest(
            sessionID: "terminal-test",
            toolCallID: "tool-call-test",
            toolName: toolName,
            title: title,
            kind: kind,
            command: command,
            workingDirectory: "/tmp/project"
        )
    }

    private static func telegramPermissionRequestID(in message: String) -> String? {
        message
            .split(separator: "\n")
            .first { line in
                line.trimmingCharacters(in: .whitespacesAndNewlines)
                    .hasPrefix("Request ID:")
            }
            .map {
                $0.replacingOccurrences(of: "Request ID:", with: "")
                    .trimmingCharacters(in: .whitespacesAndNewlines)
            }
    }


}

private actor TelegramTestMessageCollector {
    private var messages: [String] = []
    private var waiters: [CheckedContinuation<String, Never>] = []

    func append(_ message: String) {
        messages.append(message)
        let pendingWaiters = waiters
        waiters.removeAll()
        for waiter in pendingWaiters {
            waiter.resume(returning: message)
        }
    }

    func firstMessage() async -> String {
        if let message = messages.first {
            return message
        }
        return await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
    }

    func allMessages() -> [String] {
        messages
    }
}
