//
//  ACPResumeTaskGraphOfferTests.swift
//  ZenCODE
//
//  Session-scoped form elicitation for recovering incomplete task graphs.
//  Tests cover capability negotiation, explicit choices, and teardown.
//

import Foundation
import Testing
import ToolCore
@testable import ZenCODECore
@testable import ZenCODERuntime

@Suite(.serialized, .timeLimit(.minutes(2)))
struct ACPResumeTaskGraphOfferTests {
    /// The title of the offer's menu.
    private static let menuTitle = "Open tasks from previous sessions"
    /// The update time of the seeded graph.
    private static let seededDate = Date(timeIntervalSince1970: 1_000)

    /// A bridge on ``ACPTelegramScriptedBackend`` whose sessions run in
    /// `workspace`, and the store of the support directory the test runs in.
    private struct Fixture {
        let bridge: ZenCODEACPBridge
        let backend: ACPTelegramScriptedBackend
        let wire: ACPTelegramWire
        let workspace: URL
        let store: SessionTaskGraphStore

        init(root: URL) throws {
            workspace = root.appendingPathComponent("workspace", isDirectory: true)
            try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
            backend = ACPTelegramScriptedBackend()
            wire = ACPTelegramWire()
            store = SessionTaskGraphStore(supportDirectoryURL: root)
            let configuration = try AgentConfiguration(
                hostedModelID: "test-model",
                availableAgents: AgentProfileStore.defaultProfiles(),
                availableModels: [
                    AgentSettingsModelManifest(id: "test-model", kind: .remoteAPI, modelID: "local/test-model"),
                ],
                runMode: .acp,
                workingDirectory: workspace
            )
            bridge = ZenCODEACPBridge(
                configuration: configuration,
                writer: ACPWriter(sink: wire.sink),
                backendFactory: backend.factory
            )
        }

        /// Writes the checkpoint of an earlier session (`old-session` unless
        /// `sessionID` names another) that left the graph `old-work` with 2 of
        /// its 3 tasks pending, as that process would have persisted it.
        func seedEarlierSessionCheckpoint(sessionID: String = "old-session") throws {
            let tasks = (0 ..< 3).map { index in
                TaskRecord(
                    id: "old-work-task-\(index)",
                    title: "Task \(index)",
                    order: index + 1,
                    status: index == 0 ? .completed : .pending,
                    execution: TaskExecutionSpec(executor: .coordinator)
                )
            }
            try store.compareAndSwap(
                SessionTaskGraphCheckpoint(
                    sessionID: sessionID,
                    currentGraphID: "old-work",
                    graphs: [TaskGraphSnapshot(
                        id: "old-work", source: .manual, state: .active, tasks: tasks,
                        createdAt: ACPResumeTaskGraphOfferTests.seededDate,
                        updatedAt: ACPResumeTaskGraphOfferTests.seededDate
                    )]
                ),
                replacing: nil,
                workingDirectory: workspace
            )
        }

        /// The graph IDs of the earlier session's checkpoint; `nil` once it is gone.
        func earlierSessionGraphIDs() throws -> [String]? {
            try store.load(sessionID: "old-session", workingDirectory: workspace)?.graphs.map(\.id)
        }

        /// Sends `session/new` in ``workspace`` as request `id` and returns
        /// the new session's id once the bridge answered it.
        func newSession(id: Int, capabilities: sending [String: Any] = ["elicitation": ["form": [:]]]) async throws -> String {
            await bridge.handleMessage([
                "jsonrpc": "2.0", "id": -100, "method": "initialize",
                "params": ["protocolVersion": 1, "clientCapabilities": capabilities],
            ])
            await bridge.handleMessage([
                "jsonrpc": "2.0",
                "id": id,
                "method": "session/new",
                "params": ["cwd": workspace.path] as [String: Any],
            ])
            return try #require(wire.response(id: id)?["result"]?.objectValue?["sessionId"]?.acpStringValue)
        }

        /// Sends `session/prompt` with `text` as request `id` in a task, which
        /// ends once the bridge answered it.
        func startPrompt(_ text: String, id: Int, sessionID: String) -> Task<Void, Never> {
            let bridge = bridge
            return Task(name: "ZenCODE.Tests.acp-resume-offer.prompt") {
                await bridge.handleMessage([
                    "jsonrpc": "2.0",
                    "id": id,
                    "method": "session/prompt",
                    "params": [
                        "sessionId": sessionID,
                        "prompt": [["type": "text", "text": text]] as [[String: Any]],
                    ] as [String: Any],
                ])
            }
        }

        /// Sends `method` (`session/cancel`, `session/close`) for `sessionID`
        /// as request `id`, and returns once the bridge answered it.
        func send(_ method: String, id: Int, sessionID: String) async {
            await bridge.handleMessage([
                "jsonrpc": "2.0",
                "id": id,
                "method": method,
                "params": ["sessionId": sessionID],
            ])
        }

        /// The first `elicitation/create` the bridge wrote, once it
        /// did, with its index on the wire.
        func elicitationRequest() async -> (index: Int, message: [String: JSONValue])? {
            await ACPTelegramTestSupport.waitUntil { wire.messages.contains { $0["method"]?.acpStringValue == "elicitation/create" } }
            guard let index = wire.messages.firstIndex(where: {
                $0["method"]?.acpStringValue == "elicitation/create"
            }) else {
                return nil
            }
            return (index, wire.messages[index])
        }

        /// Answers the client's side of the request `message` with `outcome`.
        func answer(_ message: [String: JSONValue], outcome: sending [String: Any]) async throws {
            guard case let .number(requestID)? = message["id"] else {
                Issue.record("The elicitation request has no numeric id: \(message)")
                return
            }
            await bridge.handleMessage([
                "jsonrpc": "2.0",
                "id": Int(requestID),
                "result": outcome,
            ])
        }

        /// Returns once the session's offer ended; `false` when it did not.
        func waitForTheOfferToEnd(sessionID: String) async -> Bool {
            await ACPTelegramTestSupport.waitUntil {
                await !bridge.hasResumableTaskGraphOfferForTesting(sessionID: sessionID)
            }
        }

        /// Returns once `count` prompts wait for their session's offer.
        func waitForPromptsAwaitingTheOffer(_ count: Int) async -> Bool {
            await ACPTelegramTestSupport.waitUntil {
                await bridge.promptsAwaitingResumableTaskGraphOfferCountForTesting() == count
            }
        }

        /// The index on the wire of the first `session/update` of `sessionID`
        /// that matches `predicate`.
        func updateIndex(
            sessionID: String,
            where predicate: ([String: JSONValue]) -> Bool
        ) -> Int? {
            wire.messages.firstIndex { message in
                guard message["method"]?.acpStringValue == "session/update",
                      let params = message["params"]?.objectValue,
                      params["sessionId"]?.acpStringValue == sessionID,
                      let update = params["update"]?.objectValue else {
                    return false
                }
                return predicate(update)
            }
        }

        /// The index on the wire of the response to request `id`.
        func responseIndex(id: Int) -> Int? {
            wire.messages.firstIndex { $0["id"] == .number(Double(id)) && $0["method"] == nil }
        }
    }

    private static func withFixture(_ body: (Fixture) async throws -> Void) async throws {
        try await ACPTelegramTestSupport.withSupportDirectory(telegram: nil) { root in
            try await body(Fixture(root: root))
        }
    }

    private static func text(of notice: ChatSessionNotice) -> String {
        ChatSessionNoticeText.text(for: notice).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - Nothing to offer

    /// Without an incomplete checkpoint in the workspace, `session/new`
    /// registers no offer and asks nothing, and a prompt runs at once.
    @Test
    func withoutAnIncompleteCheckpointSessionNewAsksNothing() async throws {
        try await Self.withFixture { fixture in
            let sessionID = try await fixture.newSession(id: 1)
            #expect(await !fixture.bridge.hasResumableTaskGraphOfferForTesting(sessionID: sessionID))
            #expect(fixture.wire.permissionRequestIDs.isEmpty)

            await fixture.startPrompt("Hello", id: 2, sessionID: sessionID).value
            #expect(fixture.wire.stopReason(id: 2) == "end_turn")
            #expect(await fixture.backend.prompts == ["Hello"])
            #expect(fixture.wire.permissionRequestIDs.isEmpty)
            await fixture.bridge.shutdown()
        }
    }

    // MARK: - The question

    /// The notices of one offer are one message: their chunks share a
    /// `messageId`, which is not the id of any other message of the session.
    @Test
    func theNoticesOfOneOfferAreOneMessageWithItsOwnID() async throws {
        try await Self.withFixture { fixture in
            let sessionID = try await fixture.newSession(id: 1)
            let epoch = await fixture.bridge.sessionEpochForTesting(sessionID: sessionID)
            let notices: [ChatSessionNotice] = [
                .taskGraphResumed(graphID: "old-work", pendingTaskCount: 2, isWorkflow: false),
                .oldTaskGraphsDeleted(count: 1),
            ]
            await fixture.bridge.presentResumableTaskGraphNotices(notices, sessionID: sessionID, epoch: epoch)
            await fixture.bridge.presentResumableTaskGraphNotices(notices, sessionID: sessionID, epoch: epoch)

            let chunks = fixture.wire.sessionUpdates().filter {
                $0["sessionUpdate"]?.acpStringValue == "agent_message_chunk"
            }
            #expect(chunks.count == 4)
            let ids = chunks.map { $0["messageId"]?.acpStringValue }
            #expect(ids.allSatisfy { $0?.isEmpty == false })
            // One offer, one message; another offer, another message.
            #expect(ids[0] == ids[1])
            #expect(ids[2] == ids[3])
            #expect(ids[0] != ids[2])
            // The text stays readable for a client that ignores the id.
            let texts = chunks.compactMap { $0["content"]?.objectValue?["text"]?.acpStringValue }
            #expect(texts[0] == Self.text(of: notices[0]))
            #expect(texts[1] == "\n\n" + Self.text(of: notices[1]))
            await fixture.bridge.shutdown()
        }
    }

    /// The form follows the session announcements and Resume moves the graph.
    @Test
    func resumeMovesTheGraphIntoTheNewSessionAndPresentsTheNotice() async throws {
        try await Self.withFixture { fixture in
            try fixture.seedEarlierSessionCheckpoint()
            let sessionID = try await fixture.newSession(id: 1)
            let (requestIndex, request) = try #require(await fixture.elicitationRequest())

            // Asked after the reply and the commands (the session has no
            // title yet: the first prompt names it).
            let replyIndex = try #require(fixture.responseIndex(id: 1))
            let commandsIndex = try #require(fixture.updateIndex(sessionID: sessionID) {
                $0["sessionUpdate"]?.acpStringValue == "available_commands_update"
            })
            #expect(fixture.updateIndex(sessionID: sessionID) {
                $0["sessionUpdate"]?.acpStringValue == "session_info_update"
            } == nil)
            #expect(replyIndex < commandsIndex && commandsIndex < requestIndex)

            let params = try #require(request["params"]?.objectValue)
            #expect(params["sessionId"]?.acpStringValue == sessionID)
            #expect(params["mode"]?.acpStringValue == "form")
            #expect(params["message"]?.acpStringValue == Self.menuTitle)
            #expect(params["toolCallId"] == nil && params["toolCall"] == nil)
            let schema = try #require(params["requestedSchema"]?.objectValue)
            #expect(schema["type"]?.acpStringValue == "object")
            #expect(schema["required"]?.arrayValue == [.string("choice")])
            let choice = try #require(schema["properties"]?.objectValue?["choice"]?.objectValue)
            #expect(choice["type"]?.acpStringValue == "string")
            let options = try #require(choice["oneOf"]?.arrayValue).compactMap(\.objectValue)
            let detail = "2 of 3 tasks pending · updated \(ChatSessionNoticeText.timestampText(Self.seededDate))"
            #expect(options.map { $0["const"]?.acpStringValue } == [
                "resume:old-session/old-work", "delete", "fresh",
            ])
            #expect(options.map { $0["title"]?.acpStringValue } == [
                "Resume old-work (\(detail))", "Delete all old tasks", "Start fresh",
            ])

            try await fixture.answer(request, outcome: [
                "action": "accept", "content": ["choice": "resume:old-session/old-work"],
            ])
            #expect(await fixture.waitForTheOfferToEnd(sessionID: sessionID))

            // Moved into the new ACP session, which keeps its id.
            #expect(try await fixture.bridge.sessionRunner.taskGraphSnapshot(sessionID: sessionID)?.id == "old-work")
            #expect(try fixture.store.load(sessionID: sessionID, workingDirectory: fixture.workspace)?
                .currentGraphID == "old-work")
            #expect(try fixture.earlierSessionGraphIDs() == nil)

            // The notice follows, without a synthetic tool call.
            let resumedText = Self.text(of: .taskGraphResumed(
                graphID: "old-work", pendingTaskCount: 2, isWorkflow: false
            ))
            #expect(fixture.wire.updateTexts(kind: "agent_message_chunk", from: requestIndex) == [resumedText])
            let noticeMessageID = fixture.wire.sessionUpdates().first {
                $0["sessionUpdate"]?.acpStringValue == "agent_message_chunk"
            }?["messageId"]?.acpStringValue
            #expect(noticeMessageID?.isEmpty == false)
            #expect(fixture.wire.permissionRequestIDs.isEmpty)
            #expect(fixture.wire.sessionUpdates().allSatisfy {
                $0["sessionUpdate"]?.acpStringValue != "tool_call"
                    && $0["sessionUpdate"]?.acpStringValue != "tool_call_update"
            })
            await fixture.bridge.shutdown()
        }
    }

    /// Explicitly choosing Delete all old tasks deletes every listed graph and
    /// presents the deletion; with nothing left, nothing more is asked.
    @Test
    func explicitDeleteRemovesEveryListedGraphAndPresentsTheDeletion() async throws {
        try await Self.withFixture { fixture in
            try fixture.seedEarlierSessionCheckpoint()
            let sessionID = try await fixture.newSession(id: 1)
            let (requestIndex, request) = try #require(await fixture.elicitationRequest())

            try await fixture.answer(request, outcome: ["action": "accept", "content": ["choice": "delete"]])
            #expect(await fixture.waitForTheOfferToEnd(sessionID: sessionID))

            #expect(try fixture.earlierSessionGraphIDs()?.contains("old-work") != true)
            #expect(try fixture.store.load(sessionID: sessionID, workingDirectory: fixture.workspace) == nil)
            #expect(fixture.wire.updateTexts(kind: "agent_message_chunk", from: requestIndex)
                == [Self.text(of: .oldTaskGraphsDeleted(count: 1))])
            #expect(fixture.wire.permissionRequestIDs.isEmpty)
            await fixture.bridge.shutdown()
        }
    }

    @Test(arguments: [
        [String: String](), ["form": "missing"], ["form": "null"], ["form": "boolean"],
    ])
    func withoutExplicitFormCapabilityNoOfferIsRegistered(_ variant: [String: String]) async throws {
        try await Self.withFixture { fixture in
            try fixture.seedEarlierSessionCheckpoint()
            let capabilities: [String: Any]
            switch variant["form"] {
            case "missing": capabilities = ["elicitation": [:]]
            case "null": capabilities = ["elicitation": ["form": NSNull()]]
            case "boolean": capabilities = ["elicitation": ["form": true]]
            default: capabilities = [:]
            }
            let sessionID = try await fixture.newSession(id: 1, capabilities: capabilities)
            #expect(await !fixture.bridge.hasResumableTaskGraphOfferForTesting(sessionID: sessionID))
            await fixture.startPrompt("Hello", id: 2, sessionID: sessionID).value
            #expect(fixture.wire.stopReason(id: 2) == "end_turn")
            #expect(!fixture.wire.messages.contains { $0["method"]?.acpStringValue == "elicitation/create" })
            #expect(fixture.wire.permissionRequestIDs.isEmpty)
            #expect(try fixture.earlierSessionGraphIDs() == ["old-work"])
            await fixture.bridge.shutdown()
        }
    }

    @Test(arguments: ["decline", "cancel", "invalid", "missing", "fresh"])
    func nonDestructiveAnswersLeaveCheckpointUntouched(_ answer: String) async throws {
        try await Self.withFixture { fixture in
            try fixture.seedEarlierSessionCheckpoint()
            let sessionID = try await fixture.newSession(id: 1)
            let (_, request) = try #require(await fixture.elicitationRequest())
            let response: [String: Any]
            switch answer {
            case "decline", "cancel": response = ["action": answer, "content": ["choice": "delete"]]
            case "invalid": response = ["action": "accept", "content": ["choice": "not-offered"]]
            case "missing": response = ["action": "accept"]
            default: response = ["action": "accept", "content": ["choice": "fresh"]]
            }
            try await fixture.answer(request, outcome: response)
            #expect(await fixture.waitForTheOfferToEnd(sessionID: sessionID))
            #expect(try fixture.earlierSessionGraphIDs() == ["old-work"])
            #expect(fixture.wire.permissionRequestIDs.isEmpty)
            #expect(fixture.wire.sessionUpdates().allSatisfy {
                $0["sessionUpdate"]?.acpStringValue != "tool_call"
                    && $0["sessionUpdate"]?.acpStringValue != "tool_call_update"
            })
            await fixture.bridge.shutdown()
        }
    }

    @Test
    func hostWithoutFormDoesNotAdvertiseSingleChoice() async throws {
        try await Self.withFixture { fixture in
            let host = ACPResumableTaskGraphChoiceHost(
                writer: ACPWriter(sink: fixture.wire.sink), sessionID: "test", supportsForm: false
            )
            #expect(!host.capabilities.contains(.singleChoice))
            #expect(await host.chooseOne(title: "test", items: [], selectedID: nil) == nil)
            #expect(fixture.wire.messages.isEmpty)
            await fixture.bridge.shutdown()
        }
    }

    @Test
    func elicitationErrorLeavesCheckpointUntouched() async throws {
        try await Self.withFixture { fixture in
            try fixture.seedEarlierSessionCheckpoint()
            let sessionID = try await fixture.newSession(id: 1)
            let (_, request) = try #require(await fixture.elicitationRequest())
            guard case let .number(requestID)? = request["id"] else {
                Issue.record("Missing elicitation request id")
                return
            }
            await fixture.bridge.handleMessage([
                "jsonrpc": "2.0", "id": Int(requestID),
                "error": ["code": -32603, "message": "client error"],
            ])
            #expect(await fixture.waitForTheOfferToEnd(sessionID: sessionID))
            #expect(try fixture.earlierSessionGraphIDs() == ["old-work"])
            await fixture.bridge.shutdown()
        }
    }

    @Test
    func cancelDuringOfferCancelsWaitingPromptWithoutDeleting() async throws {
        try await Self.withFixture { fixture in
            try fixture.seedEarlierSessionCheckpoint()
            let sessionID = try await fixture.newSession(id: 1)
            let (_, request) = try #require(await fixture.elicitationRequest())
            let prompt = fixture.startPrompt("Hello", id: 2, sessionID: sessionID)
            #expect(await fixture.waitForPromptsAwaitingTheOffer(1))
            await fixture.send("session/cancel", id: 3, sessionID: sessionID)
            try await fixture.answer(request, outcome: ["action": "cancel"])
            await prompt.value
            #expect(fixture.wire.stopReason(id: 2) == "cancelled")
            #expect(await fixture.backend.prompts.isEmpty)
            #expect(try fixture.earlierSessionGraphIDs() == ["old-work"])
            await fixture.bridge.shutdown()
        }
    }

    // MARK: - Close and shutdown

    /// `session/close` while the question waits withdraws it: the waiting
    /// prompt ends as `cancelled` before the close's reply, nothing of the
    /// offer reaches the wire, and the checkpoint is unchanged.
    @Test
    func sessionCloseWhileTheQuestionWaitsCancelsItAndClosesCleanly() async throws {
        try await Self.withFixture { fixture in
            try fixture.seedEarlierSessionCheckpoint()
            let sessionID = try await fixture.newSession(id: 1)
            let (requestIndex, request) = try #require(await fixture.elicitationRequest())
            let prompt = fixture.startPrompt("Hello", id: 2, sessionID: sessionID)
            #expect(await fixture.waitForPromptsAwaitingTheOffer(1))

            await fixture.send("session/close", id: 3, sessionID: sessionID)
            #expect(fixture.wire.response(id: 3)?["result"] == .object([:]))
            #expect(fixture.wire.errorMessage(id: 3) == nil)
            await prompt.value
            #expect(fixture.wire.stopReason(id: 2) == "cancelled")
            let promptReplyIndex = try #require(fixture.responseIndex(id: 2))
            let closeReplyIndex = try #require(fixture.responseIndex(id: 3))
            #expect(promptReplyIndex < closeReplyIndex)
            #expect(await !fixture.bridge.hasResumableTaskGraphOfferForTesting(sessionID: sessionID))
            #expect(await fixture.backend.prompts.isEmpty)
            #expect(fixture.wire.sessionUpdates().allSatisfy {
                $0["sessionUpdate"]?.acpStringValue != "tool_call_update"
            })
            #expect(fixture.wire.updateTexts(kind: "agent_message_chunk", from: requestIndex).isEmpty)
            #expect(try fixture.earlierSessionGraphIDs() == ["old-work"])

            // A late answer to the withdrawn question changes nothing.
            let countAfterClose = fixture.wire.count
            try await fixture.answer(request, outcome: [
                "action": "accept", "content": ["choice": "resume:old-session/old-work"],
            ])
            #expect(fixture.wire.count == countAfterClose)
            #expect(try fixture.earlierSessionGraphIDs() == ["old-work"])
            await fixture.bridge.shutdown()
        }
    }

    /// The shutdown withdraws a waiting question: the offer ends, the prompt
    /// waiting for it is abandoned silently, and the checkpoint is unchanged.
    @Test
    func shutdownWhileTheQuestionWaitsWithdrawsIt() async throws {
        try await Self.withFixture { fixture in
            try fixture.seedEarlierSessionCheckpoint()
            let sessionID = try await fixture.newSession(id: 1)
            #expect(await fixture.elicitationRequest() != nil)
            let prompt = fixture.startPrompt("Hello", id: 2, sessionID: sessionID)
            #expect(await fixture.waitForPromptsAwaitingTheOffer(1))
            let countBeforeShutdown = fixture.wire.count

            await fixture.bridge.shutdown()
            await prompt.value
            #expect(fixture.wire.count == countBeforeShutdown)
            #expect(await !fixture.bridge.hasResumableTaskGraphOfferForTesting(sessionID: sessionID))
            #expect(await fixture.bridge.promptsAwaitingResumableTaskGraphOfferCountForTesting() == 0)
            #expect(await fixture.backend.prompts.isEmpty)
            #expect(try fixture.earlierSessionGraphIDs() == ["old-work"])
        }
    }
}

extension ZenCODEACPBridge {
    /// Whether the startup offer of old task graphs of `sessionID` is still
    /// registered.
    func hasResumableTaskGraphOfferForTesting(sessionID: String) -> Bool {
        resumableTaskGraphOffers[sessionID] != nil
    }

    /// How many `session/prompt` handlers wait for their session's offer.
    func promptsAwaitingResumableTaskGraphOfferCountForTesting() -> Int {
        promptsAwaitingResumableTaskGraphOffer.count
    }
}
