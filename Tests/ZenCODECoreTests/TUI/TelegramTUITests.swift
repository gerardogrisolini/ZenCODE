//
//  TelegramTUITests.swift
//  ZenCODE
//
//  Created by Gerardo Grisolini on 07/06/26.
//

import Foundation
import Synchronization
import Testing
import ToolCore
@testable import ZenCODECore

@ChatSessionActor
@Suite
struct TelegramTUITests {
    @Test
    func telegramSettingsFailClosedUnlessSchema2OwnerAndRoutesAreComplete() throws {
        let fixtures: [(String, Bool)] = [
            (#"{"enabled":true,"botToken":"123456:ABCDEF","linkedChatID":42,"ownerUserID":7,"routingVersion":1,"routes":[{"roomID":"default","lifecycle":"active","generation":1}]}"#, false),
            (#"{"enabled":true,"botToken":"123456:ABCDEF","linkedChatID":42,"ownerUserID":7,"routingVersion":3,"routes":[{"roomID":"default","lifecycle":"active","generation":1}]}"#, false),
            (#"{"enabled":true,"botToken":"123456:ABCDEF","linkedChatID":42,"routingVersion":2,"routes":[{"roomID":"default","lifecycle":"active","generation":1}]}"#, false),
            (#"{"enabled":true,"botToken":"123456:ABCDEF","linkedChatID":42,"ownerUserID":7,"routingVersion":2,"routes":[{"roomID":"one","lifecycle":"active","generation":1},{"roomID":"two","lifecycle":"active","generation":1}]}"#, false),
            (#"{"enabled":true,"botToken":"123456:ABCDEF","linkedChatID":42,"ownerUserID":7,"routingVersion":2,"routes":[{"roomID":"default","lifecycle":"active","generation":1}]}"#, true)
        ]

        for (json, expectedEnabled) in fixtures {
            let settings = try JSONDecoder().decode(
                AgentTelegramSettingsManifest.self, from: Data(json.utf8)
            )
            #expect(settings.isEnabled == expectedEnabled)
        }
    }

    /// Round trip through the real settings store, isolated in a temporary
    /// support directory: the `default` route plus more than 32 closed topic
    /// routes is pruned to the 32 newest inactive topics, a session topic is
    /// rebound, the JSON keeps the same route keys and schema, the
    /// configuration stays enabled and a router rebuilt from disk honours the
    /// new lease while rejecting the previous one.
    @Test
    nonisolated func telegramRoutesPrunedAndReboundRoundTripThroughTheSettingsStore() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "zencode-telegram-prune-\(UUID().uuidString)", isDirectory: true
        )
        defer { try? FileManager.default.removeItem(at: directory) }
        let topicless = AgentTelegramRouteManifest(roomID: "default")
        let closed = (1...40).map { (topic: Int) in
            AgentTelegramRouteManifest(topicID: topic, roomID: "closed-\(topic)", lifecycle: .closed, generation: 2)
        }
        let routes = [topicless] + closed + [AgentTelegramRouteManifest(topicID: 41, roomID: "session-a")]

        try await AppStorageDirectory.withSupportDirectoryURL(directory) {
            try AgentSettingsManifestStore.save(AgentSettingsManifest(
                models: [],
                telegram: AgentTelegramSettingsManifest(
                    enabled: true, botToken: "123456:ABCDEF",
                    linkedChatID: 42, ownerUserID: 7, routes: routes
                )
            ))
            let router = TerminalTelegramSessionRouter(
                linkedChatID: 42, ownerUserID: 7, routes: routes,
                persist: { ownerUserID, committed in
                    try AgentSettingsManifestStore.saveTelegramRoutes(committed, ownerUserID: ownerUserID)
                }
            )

            try await router.prune(keepingInactive: 32)
            let pruned = try #require(try AgentSettingsManifestStore.loadRequired().telegram)
            #expect(pruned.isEnabled)
            #expect(pruned.routes.count == 34)
            let previous = try await router.resolve(chatID: 42, userID: 7, topicID: 41)
            let rebound = try await router.rebind(previous, toRoomID: "session-b")

            let settings = try #require(try AgentSettingsManifestStore.loadRequired().telegram)
            let expected: [AgentTelegramRouteManifest] = [topicless] + closed.suffix(32) + [
                AgentTelegramRouteManifest(topicID: 41, roomID: "session-b", generation: 2),
            ]
            #expect(settings.isEnabled)
            #expect(settings.routes == expected)
            #expect(await router.snapshot() == expected)

            let data = try Data(contentsOf: AgentSettingsManifestStore.settingsURL())
            let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
            let telegram = try #require(object["telegram"] as? [String: Any])
            let storedRoutes = try #require(telegram["routes"] as? [[String: Any]])
            #expect(telegram["routingVersion"] as? Int == 2)
            #expect(storedRoutes.count == 34)
            #expect(storedRoutes.allSatisfy {
                Set($0.keys).isSubset(of: ["topicID", "roomID", "lifecycle", "generation"])
            })
            let expectedTopics: [Int?] = [nil] + (9...41).map { $0 }
            #expect(storedRoutes.map { $0["topicID"] as? Int } == expectedTopics)

            let reloaded = TerminalTelegramSessionRouter(
                linkedChatID: settings.linkedChatID, ownerUserID: settings.ownerUserID,
                routes: settings.routes
            )
            try await reloaded.validate(rebound)
            await #expect(throws: TerminalTelegramRouteDenial.staleGeneration) {
                try await reloaded.validate(previous)
            }
            #expect(await reloaded.activeRoute(forRoomID: "session-b")?.topicID == 41)
            await #expect(throws: TerminalTelegramRouteDenial.routeClosed) {
                try await reloaded.resolve(chatID: 42, userID: 7, topicID: 9)
            }
            // A pruned topic is unknown again and falls back to `default`.
            let fallback = try await reloaded.resolve(chatID: 42, userID: 7, topicID: 8)
            #expect(fallback.key.roomID == "default")
            #expect(fallback.effectiveMessageThreadID == 8)
        }
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
    func telegramCommandIsVisibleOnlyWhenConfigured() {
        let disabledCommands = TerminalChat.commandRegistry.visibleDescriptors(
            in: TerminalChat.commandContext(
                builderAgentEnabled: false,
                telegramEnabled: false,
                ds4ModelEnabled: false
            )
        ).map(\.command)
        let enabledCommands = TerminalChat.commandRegistry.visibleDescriptors(
            in: TerminalChat.commandContext(
                builderAgentEnabled: false,
                telegramEnabled: true,
                ds4ModelEnabled: false
            )
        ).map(\.command)

        #expect(!disabledCommands.contains("/agents-md"))
        #expect(!disabledCommands.contains("/make-agents"))
        #expect(!enabledCommands.contains("/agents-md"))
        #expect(!enabledCommands.contains("/make-agents"))
        #expect(!disabledCommands.contains("/telegram"))
        #expect(enabledCommands.contains("/telegram"))
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
        #expect(TerminalTelegramRemoteCommand.invocation(text: "/start")?.command == .start)
        #expect(TerminalTelegramRemoteCommand.invocation(text: "/start 233B0EC4")?.command == .start)
        #expect(TerminalTelegramRemoteCommand.invocation(text: "/start@zencode_bot 233B0EC4")?.command == .start)
        #expect(TerminalTelegramRemoteCommand.invocation(text: "/help")?.command == .help)
        #expect(TerminalTelegramRemoteCommand.invocation(text: "ciao") == nil)
        #expect(TelegramChannel.commandWithoutBotMention("/review@zencode_bot routing") == "/review routing")
        #expect(TelegramChannel.commandWithoutBotMention("person@example.com") == "person@example.com")
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
        // Ingress is lossless after dispatcher admission; it no longer exposes
        // a dropping buffer bound.
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

        #expect((try? TerminalTelegramUpdateOffsetStore.loadRequired(botID: 100, from: url)) == 41)
        #expect((try? TerminalTelegramUpdateOffsetStore.loadRequired(botID: 200, from: url)) == 7)
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
        let lease = Self.telegramPermissionTestLease()
        let collector = TelegramTestMessageCollector()
        let command = "remote-telegram-permission-test-\(UUID().uuidString)"
        let request = Self.localExecAuthorizationRequest(command: "\(command) --flag")

        let authorization = Task {
            await broker.authorize(
                request,
                lease: lease,
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

        let reminder = await broker.handleMessage("queue another prompt", lease: lease)
        #expect(reminder != .notHandled)
        if case let .handled(reply) = reminder {
            #expect(reply?.contains("Permission request pending") == true)
        }

        let reply = await broker.handleMessage("/allow \(requestID)", lease: lease)
        #expect(reply != .notHandled)
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
        let lease = Self.telegramPermissionTestLease()
        let collector = TelegramTestMessageCollector()
        let request = Self.authorizationRequest(
            toolName: "local.delete",
            title: "Delete Sources/Old.swift",
            kind: "destructive",
            command: "delete Sources/Old.swift"
        )

        #expect(!(await broker.isAlreadyAuthorized(request, lease: lease)))

        let authorization = Task {
            await broker.authorize(
                request,
                lease: lease,
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

        _ = await broker.handleMessage("/deny \(requestID)", lease: lease)
        #expect(await authorization.value == .denied)
    }

    /// A request that never reached the chat must fail closed immediately
    /// instead of holding the turn until the timeout expires.
    @Test
    func telegramPermissionBrokerFailsClosedWhenRequestCannotBeDelivered() async {
        let broker = TerminalTelegramPermissionBroker()
        let lease = Self.telegramPermissionTestLease()
        let request = Self.localExecAuthorizationRequest(
            command: "undeliverable-\(UUID().uuidString) --flag"
        )

        let outcome = await broker.authorize(
            request,
            lease: lease,
            timeoutNanoseconds: 600_000_000_000
        ) { _ in
            false
        }

        #expect(outcome == .undeliverable)
    }

    /// A tool outside the gated set never raises a remote dialogue.
    @Test
    func telegramPermissionBrokerSkipsUngatedTools() async {
        let broker = TerminalTelegramPermissionBroker()
        let lease = Self.telegramPermissionTestLease()
        let request = Self.authorizationRequest(
            toolName: "local.readFile",
            title: "Read Sources/Main.swift",
            kind: "read",
            command: "read Sources/Main.swift"
        )

        #expect(await broker.isAlreadyAuthorized(request, lease: lease))
        let outcome = await broker.authorize(request, lease: lease) { _ in
            Issue.record("An ungated tool must not raise a permission request.")
            return true
        }
        #expect(outcome == .notRequired)
    }

    private static func telegramPermissionTestLease() -> TerminalTelegramRouteLease {
        TerminalTelegramRouteLease(
            key: .init(chatID: 42, userID: 7, roomID: "terminal-test"),
            generation: 1
        )
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

actor TelegramTestMessageCollector {
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

extension TerminalChat {
    /// The Telegram channel of the terminal's slot, created on first use
    /// without attaching it, so a test drives it as the terminal's loop
    /// never does.
    var telegramChannel: TelegramChannel {
        sessionHost.telegramChannelCreatingIfNeeded(in: terminalSlotID)!
    }
}

extension TelegramTUITests {
    /// A generating session can be blocked on remote tool consent, so the busy
    /// gate must let that correlated reply reach the permission broker.
    @Test
    func busyTelegramSessionStillAcceptsAuthorizationReply() async throws {
        let terminal = try await Self.activeTelegramTerminal()
        let lease = try #require(terminal.telegramChannel.activeRouteLease)
        let collector = TelegramTestMessageCollector()
        let request = Self.authorizationRequest(
            toolName: "local.delete",
            title: "Delete Sources/Busy.swift",
            kind: "destructive",
            command: "delete Sources/Busy.swift"
        )
        let authorization = Task {
            await terminal.telegramChannel.permissionBroker.authorize(
                request, lease: lease
            ) { message in
                await collector.append(message)
                return true
            }
        }
        let requestMessage = await collector.firstMessage()
        let requestID = try #require(Self.telegramPermissionRequestID(in: requestMessage))
        let busyNotices = Mutex<[String]>([])
        terminal.telegramChannel.onTelegramSystemMessage = { text, _ in
            busyNotices.withLock { $0.append(text) }
            return true
        }
        // The session generates: the host holds a prompt reservation.
        let reservation = try terminal.sessionHost.reservePrompt(in: terminal.terminalSlotID)
        defer { terminal.sessionHost.releasePrompt(reservation) }

        _ = await terminal.telegramChannel.handleIncomingMessage(
            TerminalTelegramIncomingMessage(
                chatID: 42, userID: 7, text: "unrelated prompt", voice: nil,
                messageID: 98, chatTitle: nil, username: nil
            )
        )

        let didQueue = await terminal.telegramChannel.handleIncomingMessage(
            TerminalTelegramIncomingMessage(
                chatID: 42, userID: 7, text: "/deny \(requestID)", voice: nil,
                messageID: 99, chatTitle: nil, username: nil
            )
        )

        #expect(!didQueue)
        #expect(terminal.telegramChannel.promptQueue.isEmpty)
        #expect(busyNotices.withLock { messages in
            messages.filter { $0.contains("was not queued") }.count
        } == 1)
        #expect(await authorization.value == .denied)
    }
}
