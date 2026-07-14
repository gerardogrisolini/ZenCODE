//
//  TelegramTUITests.swift
//  ZenCODE
//
//  Created by Gerardo Grisolini on 07/06/26.
//

import Foundation
import Testing
@testable import ZenCODECore

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
            telegramEnabled: false,
            voiceEnabled: false
        ).map(\.command)
        let enabledCommands = TerminalChat.visibleCommandDescriptors(
            builderAgentEnabled: false,
            telegramEnabled: true,
            voiceEnabled: false
        ).map(\.command)

        #expect(!disabledCommands.contains("/telegram"))
        #expect(enabledCommands.contains("/telegram"))
    }

    @Test
    func builderCommandVisibilityRemainsIndependentFromTelegram() {
        let commands = TerminalChat.visibleCommandDescriptors(
            builderAgentEnabled: true,
            telegramEnabled: false,
            voiceEnabled: false
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
    func voiceCommandIsVisibleOnlyWhenConfigured() {
        let disabledCommands = TerminalChat.visibleCommandDescriptors(
            builderAgentEnabled: false,
            telegramEnabled: false,
            voiceEnabled: false
        ).map(\.command)
        let enabledCommands = TerminalChat.visibleCommandDescriptors(
            builderAgentEnabled: false,
            telegramEnabled: false,
            voiceEnabled: true
        ).map(\.command)

        #expect(!disabledCommands.contains("/voice"))
        #expect(enabledCommands.contains("/voice"))
    }

    @Test
    func voiceCommandTokenRendersAsUnknownWhenHidden() {
        #expect(
            TerminalChat.unknownCommandMessage(for: "/voice")
                == "ZenCODE: unknown command '/voice'.\n"
        )
    }

    @Test
    func submittedLineRoleSeparatesPromptsFromSlashCommands() {
        #expect(TerminalChat.submittedLineRole(for: "ciao") == .prompt)
        #expect(TerminalChat.submittedLineRole(for: "   ") == .empty)
        #expect(TerminalChat.submittedLineRole(for: "/voice") == .slashCommand(token: "/voice"))
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
            hostedModelID: "mlx-community/test",
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
        let command = "mlx-telegram-permission-test-\(UUID().uuidString)"
        let request = Self.localExecAuthorizationRequest(command: "\(command) --flag")

        let authorization = Task {
            await broker.authorize(
                request,
                chatID: 42,
                timeoutNanoseconds: 5_000_000_000
            ) { message in
                await collector.append(message)
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
        #expect(await authorization.value)
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
        AgentToolAuthorizationRequest(
            sessionID: "terminal-test",
            toolCallID: "tool-call-test",
            toolName: "local.exec",
            title: "Run \(command)",
            kind: "execute",
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

    // MARK: - TerminalTelegramToolCallFormatter

    private static let formatterWorkingDirectory = URL(
        fileURLWithPath: "/Users/dev/MyProject",
        isDirectory: true
    )

    private func toolCall(
        _ name: String,
        arguments: [String: Any] = [:]
    ) -> DirectAgentToolCall {
        DirectAgentToolCall(
            id: "test-\(UUID().uuidString)",
            name: name,
            argumentsObject: arguments,
            argumentsJSON: "{}"
        )
    }

    private func format(
        _ name: String,
        arguments: [String: Any] = [:],
        workingDirectory: URL = formatterWorkingDirectory
    ) -> String {
        TerminalTelegramToolCallFormatter.format(
            toolCall(name, arguments: arguments),
            workingDirectory: workingDirectory
        )
    }

    @Test
    func formatterAlwaysShowsConcreteToolNameAndKind() {
        // Empty arguments — header still identifies the tool.
        #expect(format("local.readFile") == "🔧 local.readFile · read")
        #expect(format("local.exec") == "🔧 local.exec · execute")

        // kind == "other" for unknown tools.
        #expect(format("custom.myTool") == "🔧 custom.myTool · other")

        // Tool with arguments but no recognized detail.
        #expect(format("custom.myTool", arguments: ["verbosity": 3]) == "🔧 custom.myTool · other")
    }

    @Test
    func formatterShowsWorkspaceRelativePathForReadAndWrite() {
        let readResult = format(
            "local.readFile",
            arguments: ["path": "/Users/dev/MyProject/Sources/Main.swift"]
        )
        #expect(readResult == "🔧 local.readFile · read\nSources/Main.swift")

        let writeResult = format(
            "local.writeFile",
            arguments: ["file_path": "/Users/dev/MyProject/Tests/Helper.swift"]
        )
        #expect(writeResult == "🔧 local.writeFile · edit\nTests/Helper.swift")
    }

    @Test
    func formatterShowsSourceAndDestinationForMove() {
        let result = format(
            "local.move",
            arguments: [
                "sourcePath": "/Users/dev/MyProject/Old.swift",
                "destinationPath": "/Users/dev/MyProject/New.swift"
            ]
        )
        #expect(result == "🔧 local.move · move\nOld.swift → New.swift")
    }

    @Test
    func formatterShowsMultipleFilesForReadFiles() {
        let result = format(
            "local.readFiles",
            arguments: [
                "paths": [
                    "/Users/dev/MyProject/Sources/A.swift",
                    "/Users/dev/MyProject/Sources/B.swift",
                    "/Users/dev/MyProject/Sources/C.swift"
                ]
            ]
        )
        #expect(result == "🔧 local.readFiles · read\nSources/A.swift (+2 more)")
    }

    @Test
    func formatterExtractsFileNamesFromApplyPatch() {
        let patch = """
        --- a/Sources/Old.swift
        +++ b/Sources/New.swift
        @@ -1,3 +1,3 @@
        -old line
        +new line
        """
        let result = format("local.applyPatch", arguments: ["patch": patch])
        #expect(result == "🔧 local.applyPatch · edit\nSources/Old.swift (+1 more)")
    }

    @Test
    func formatterShowsRelevantInfoForSearchTools() {
        // When path is the working directory root, the formatter falls back
        // to the pattern (the path "." is not informative).
        let grepResult = format(
            "search.grep",
            arguments: ["pattern": "TODO", "path": "/Users/dev/MyProject"]
        )
        #expect(grepResult == "🔧 search.grep · search\npattern: TODO")

        // When path is a subdirectory, the path is shown instead.
        let grepSubdirResult = format(
            "search.grep",
            arguments: ["pattern": "TODO", "path": "/Users/dev/MyProject/Sources"]
        )
        #expect(grepSubdirResult == "🔧 search.grep · search\nSources")

        let globResult = format(
            "search.glob",
            arguments: ["pattern": "**/*.swift", "path": "/Users/dev/MyProject/Sources"]
        )
        #expect(globResult == "🔧 search.glob · search\nSources")
    }

    @Test
    func formatterShowsRelevantInfoForLocalExec() {
        // Only the first token (executable/subcommand) is shown to limit
        // exposure of secrets that may appear in the full command string.
        let result = format(
            "local.exec",
            arguments: ["command": "swift test --filter MyTests"]
        )
        #expect(result == "🔧 local.exec · execute\ncommand: swift")
    }

    @Test
    func formatterShowsRelevantInfoForWebTools() {
        let searchResult = format(
            "web.search",
            arguments: ["query": "swift concurrency"]
        )
        #expect(searchResult == "🔧 web.search · search\nquery: swift concurrency")

        let fetchResult = format(
            "web.fetch",
            arguments: ["url": "https://example.com/api"]
        )
        #expect(fetchResult == "🔧 web.fetch · read\nurl: https://example.com/api")
    }

    @Test
    func formatterShowsRelevantInfoForGitTools() {
        let switchResult = format(
            "git.switch",
            arguments: ["branch": "feature/new-thing"]
        )
        #expect(switchResult == "🔧 git.switch · execute\nbranch: feature/new-thing")

        let showResult = format(
            "git.show",
            arguments: ["revision": "abc1234"]
        )
        #expect(showResult == "🔧 git.show · read\nrevision: abc1234")

        let commitResult = format(
            "git.commit",
            arguments: ["message": "Fix bug"]
        )
        // git.commit has no path, so it falls to contextual detail.
        #expect(commitResult == "🔧 git.commit · execute")
    }

    @Test
    func formatterShowsRelevantInfoForTaskTools() {
        let createResult = format(
            "tasks.create",
            arguments: ["title": "Implement feature X"]
        )
        #expect(createResult == "🔧 tasks.create · other\ntitle: Implement feature X")

        let updateResult = format(
            "tasks.update",
            arguments: ["id": "task-42", "status": "in_progress"]
        )
        #expect(updateResult == "🔧 tasks.update · edit\ntask: task-42")
    }

    @Test
    func formatterShowsRelevantInfoForFeatureTools() {
        let enableResult = format(
            "feature.enable",
            arguments: ["id": "MyFeature"]
        )
        #expect(enableResult == "🔧 feature.enable · execute\nfeature: MyFeature")
    }

    @Test
    func formatterShowsRelevantInfoForSubAgentTools() {
        let createResult = format(
            "agent.create",
            arguments: ["name": "plan-author", "role": "Planner"]
        )
        #expect(createResult == "🔧 agent.create · execute\nagent: plan-author")

        let messageResult = format(
            "agent.message",
            arguments: ["name": "plan-author", "message": "Continue work"]
        )
        #expect(messageResult == "🔧 agent.message · execute\nagent: plan-author")
    }

    @Test
    func formatterProvidesSafeFallbackForCustomTools() {
        let result = format(
            "custom.unknownTool",
            arguments: ["data": "whatever", "count": 42]
        )
        #expect(result == "🔧 custom.unknownTool · other")
    }

    @Test
    func formatterExcludesSensitiveContent() {
        // File contents must not appear.
        let writeResult = format(
            "local.writeFile",
            arguments: [
                "file_path": "/Users/dev/MyProject/secret.swift",
                "content": "API_KEY=sk-123456789"
            ]
        )
        #expect(!writeResult.contains("API_KEY"))
        #expect(!writeResult.contains("sk-123456789"))
        #expect(writeResult.contains("secret.swift"))

        // Full patch text must not appear, only the file names.
        let patchResult = format(
            "local.applyPatch",
            arguments: ["patch": "--- a/file.swift\n+++ b/file.swift\n@@ -1 +1 @@\n-secret code\n+new code"]
        )
        #expect(!patchResult.contains("secret code"))
        #expect(!patchResult.contains("new code"))
        #expect(patchResult.contains("file.swift"))

        // Prompts and messages must not appear.
        let agentResult = format(
            "agent.create",
            arguments: ["name": "worker", "prompt": "Do something sensitive"]
        )
        #expect(!agentResult.contains("Do something sensitive"))
        #expect(agentResult.contains("worker"))

        // Old/new text from editFile must not appear.
        let editResult = format(
            "local.editFile",
            arguments: [
                "path": "/Users/dev/MyProject/code.swift",
                "oldString": "password123",
                "newString": "password456"
            ]
        )
        #expect(!editResult.contains("password123"))
        #expect(!editResult.contains("password456"))
        #expect(editResult.contains("code.swift"))
    }

    @Test
    func formatterNormalizesAndTruncatesMultilineValues() {
        let result = format(
            "local.exec",
            arguments: ["command": "echo hello\necho world\n   echo test"]
        )
        // Newlines are collapsed, then only the first token is shown for local.exec.
        #expect(result == "🔧 local.exec · execute\ncommand: echo")
    }

    @Test
    func formatterTruncatesVeryLongValues() {
        let longCommand = String(repeating: "a", count: 200)
        let result = format("local.exec", arguments: ["command": longCommand])
        // The value is truncated to 80 chars (77 + "...").
        let lines = result.components(separatedBy: "\n")
        #expect(lines.count == 2)
        #expect(lines[1].hasPrefix("command: "))
        let valuePart = String(lines[1].dropFirst("command: ".count))
        #expect(valuePart.count == 80)
        #expect(valuePart.hasSuffix("..."))
    }

    @Test
    func formatterKeepsRelativePathsAsIs() {
        let result = format(
            "local.readFile",
            arguments: ["path": "Sources/Main.swift"]
        )
        #expect(result == "🔧 local.readFile · read\nSources/Main.swift")
    }

    @Test
    func formatterKeepsExternalAbsolutePaths() {
        let result = format(
            "local.readFile",
            arguments: ["path": "/tmp/other/file.swift"]
        )
        // Path outside working directory stays absolute, not reduced to basename.
        #expect(result == "🔧 local.readFile · read\n/tmp/other/file.swift")
    }

    @Test
    func formatterPrefersSpecificFilePathOverGenericPath() {
        // When both path (workspace root) and file_path (specific file) are present,
        // the specific file_path should be used, not the uninformative root.
        let result = format(
            "git.diff",
            arguments: [
                "path": "/Users/dev/MyProject",
                "file_path": "/Users/dev/MyProject/Sources/Main.swift"
            ]
        )
        #expect(result == "🔧 git.diff · read\nSources/Main.swift")
    }

    @Test
    func formatterSkipsPathExtractionForCustomTools() {
        // Custom/unknown tools should not have path-like arguments extracted,
        // since the key name may not represent a filesystem path.
        let result = format(
            "custom.upload",
            arguments: ["file": "API_KEY=secret"]
        )
        #expect(result == "🔧 custom.upload · other")
        #expect(!result.contains("API_KEY"))
        #expect(!result.contains("secret"))
    }

    @Test
    func formatterShowsOnlyFirstTokenForLocalExec() {
        let result = format(
            "local.exec",
            arguments: ["command": "API_TOKEN=secret deploy --force"]
        )
        #expect(result == "🔧 local.exec · execute\ncommand: API_TOKEN=secret")
    }

    @Test
    func formatterDeduplicatesAliasPathArrays() {
        // Supplying the same paths via both "paths" and "file_paths" should
        // not inflate the (+N more) count.
        let result = format(
            "local.readFiles",
            arguments: [
                "paths": ["/Users/dev/MyProject/A.swift"],
                "file_paths": ["/Users/dev/MyProject/A.swift"]
            ]
        )
        #expect(result == "🔧 local.readFiles · read\nA.swift")
    }

    @Test
    func formatterHandlesJsonArrayPaths() {
        // JSONValue.array should be decoded for path arrays.
        let result = format(
            "local.readFiles",
            arguments: [
                "paths": JSONValue.array([
                    .string("/Users/dev/MyProject/A.swift"),
                    .string("/Users/dev/MyProject/B.swift")
                ])
            ]
        )
        #expect(result == "🔧 local.readFiles · read\nA.swift (+1 more)")
    }

    @Test
    func formatterShowsRelevantInfoForMemorySearch() {
        let result = format(
            "memory.search",
            arguments: ["query": "telegram formatter"]
        )
        #expect(result == "🔧 memory.search · search\nquery: telegram formatter")
    }

    @Test
    func formatterShowsRelevantInfoForTodoWrite() {
        let result = format(
            "todo.write",
            arguments: ["title": "Fix bugs", "mode": "upsert"]
        )
        #expect(result == "🔧 todo.write · edit\ntitle: Fix bugs · mode: upsert")
    }

    @Test
    func formatterShowsRelevantInfoForGitGrep() {
        // git.grep now has a pattern contextual mapping.
        let result = format(
            "git.grep",
            arguments: ["pattern": "TODO", "path": "/Users/dev/MyProject"]
        )
        #expect(result == "🔧 git.grep · read\npattern: TODO")
    }

    @Test
    func formatterHandlesRootWorkingDirectory() {
        // When workingDirectory is "/", paths should be relativized correctly.
        let result = format(
            "local.readFile",
            arguments: ["path": "/tmp/file.swift"],
            workingDirectory: URL(fileURLWithPath: "/", isDirectory: true)
        )
        #expect(result == "🔧 local.readFile · read\ntmp/file.swift")
    }

    @Test
    func formatterSkipsUninformativeFirstPathInFileList() {
        // If the first path is the working directory root, it should be
        // skipped in favor of the first informative path.
        let result = format(
            "local.readFiles",
            arguments: [
                "paths": [
                    "/Users/dev/MyProject",
                    "/Users/dev/MyProject/Sources/A.swift",
                    "/Users/dev/MyProject/Sources/B.swift"
                ]
            ]
        )
        #expect(result == "🔧 local.readFiles · read\nSources/A.swift (+1 more)")
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
}
