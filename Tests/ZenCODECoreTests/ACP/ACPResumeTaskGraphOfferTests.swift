//
//  ACPResumeTaskGraphOfferTests.swift
//  ZenCODE
//
//  The startup offer of the task graphs earlier sessions left incomplete, in
//  a new ACP session: without any (or with only the graph of another live
//  session) nothing is registered or asked; otherwise, once `session/new`
//  answered, the client is asked with
//  one `session/request_permission` on a synthetic tool call (one option per
//  menu item, the kinds mapped from the offer's stable choice IDs), which is
//  completed once answered; Resume moves the graph into the new session and
//  the notice reaches the editor as an `agent_message_chunk`; a cancelled
//  answer or Start fresh leaves the checkpoint unchanged, Delete all removes
//  every listed graph; a `session/prompt` waits for the answer, and a
//  `session/cancel` meanwhile ends it as `cancelled`; `session/close` and the
//  shutdown withdraw the question. Nothing reaches the network; every test
//  runs in a UUID support directory.
//

import Foundation
import Testing
import ToolCore
@testable import ZenCODECore

@Suite(.serialized, .timeLimit(.minutes(2)))
struct ACPResumeTaskGraphOfferTests {
    /// The title of the offer's menu, the synthetic tool call's title.
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
            try store.save(
                SessionTaskGraphCheckpoint(
                    sessionID: sessionID,
                    currentGraphID: "old-work",
                    graphs: [TaskGraphSnapshot(
                        id: "old-work", source: .manual, state: .active, tasks: tasks,
                        createdAt: ACPResumeTaskGraphOfferTests.seededDate,
                        updatedAt: ACPResumeTaskGraphOfferTests.seededDate
                    )]
                ),
                workingDirectory: workspace
            )
        }

        /// The graph IDs of the earlier session's checkpoint; `nil` once it is gone.
        func earlierSessionGraphIDs() throws -> [String]? {
            try store.load(sessionID: "old-session", workingDirectory: workspace)?.graphs.map(\.id)
        }

        /// Sends `session/new` in ``workspace`` as request `id` and returns
        /// the new session's id once the bridge answered it.
        func newSession(id: Int) async throws -> String {
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

        /// The first `session/request_permission` the bridge wrote, once it
        /// did, with its index on the wire.
        func permissionRequest() async -> (index: Int, message: [String: JSONValue])? {
            await ACPTelegramTestSupport.waitUntil { !wire.permissionRequestIDs.isEmpty }
            guard let index = wire.messages.firstIndex(where: {
                $0["method"]?.acpStringValue == "session/request_permission"
            }) else {
                return nil
            }
            return (index, wire.messages[index])
        }

        /// Answers the client's side of the request `message` with `outcome`.
        func answer(_ message: [String: JSONValue], outcome: sending [String: Any]) async throws {
            guard case let .number(requestID)? = message["id"] else {
                Issue.record("The permission request has no numeric id: \(message)")
                return
            }
            await bridge.handleMessage([
                "jsonrpc": "2.0",
                "id": Int(requestID),
                "result": ["outcome": outcome],
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

        /// The `tool_call_update`s written for `toolCallID`.
        func toolCallUpdates(_ toolCallID: String) -> [[String: JSONValue]] {
            wire.sessionUpdates().filter {
                $0["sessionUpdate"]?.acpStringValue == "tool_call_update"
                    && $0["toolCallId"]?.acpStringValue == toolCallID
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

    private static var selectedFresh: [String: Any] {
        ["outcome": "selected", "optionId": "fresh"]
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

    /// The incomplete graph of another live ACP session of the workspace is
    /// not left over: a new session neither registers an offer for it nor
    /// asks.
    @Test
    func theGraphOfAnotherLiveSessionIsNotOffered() async throws {
        try await Self.withFixture { fixture in
            let liveSessionID = try await fixture.newSession(id: 1)
            try fixture.seedEarlierSessionCheckpoint(sessionID: liveSessionID)

            let sessionID = try await fixture.newSession(id: 2)
            #expect(await !fixture.bridge.hasResumableTaskGraphOfferForTesting(sessionID: sessionID))
            #expect(fixture.wire.permissionRequestIDs.isEmpty)
            #expect(try fixture.store.load(sessionID: liveSessionID, workingDirectory: fixture.workspace)?
                .graphs.map(\.id) == ["old-work"])
            await fixture.bridge.shutdown()
        }
    }

    // MARK: - The question

    /// After the `session/new` reply and its announcements, the client is
    /// asked with the expected options and synthetic tool call; Resume moves
    /// the graph into the new session, completes the tool call, and the
    /// notice reaches the editor.
    @Test
    func resumeMovesTheGraphIntoTheNewSessionAndPresentsTheNotice() async throws {
        try await Self.withFixture { fixture in
            try fixture.seedEarlierSessionCheckpoint()
            let sessionID = try await fixture.newSession(id: 1)
            let (requestIndex, request) = try #require(await fixture.permissionRequest())

            // Asked after the reply, the session info, and the commands.
            let replyIndex = try #require(fixture.responseIndex(id: 1))
            let infoIndex = try #require(fixture.updateIndex(sessionID: sessionID) {
                $0["sessionUpdate"]?.acpStringValue == "session_info_update"
            })
            let commandsIndex = try #require(fixture.updateIndex(sessionID: sessionID) {
                $0["sessionUpdate"]?.acpStringValue == "available_commands_update"
            })
            #expect(replyIndex < infoIndex && infoIndex < commandsIndex && commandsIndex < requestIndex)

            let params = try #require(request["params"]?.objectValue)
            #expect(params["sessionId"]?.acpStringValue == sessionID)
            let toolCall = try #require(params["toolCall"]?.objectValue)
            let toolCallID = try #require(toolCall["toolCallId"]?.acpStringValue)
            #expect(toolCallID.hasPrefix("zencode:resume-task-graphs:"))
            #expect(toolCall["status"]?.acpStringValue == "pending")
            #expect(toolCall["title"]?.acpStringValue == Self.menuTitle)
            #expect(toolCall["kind"]?.acpStringValue == "other")
            let detail = "2 of 3 tasks pending · updated \(ChatSessionNoticeText.timestampText(Self.seededDate))"
            let content = try #require(toolCall["content"]?.arrayValue)
            #expect(content.count == 1)
            let block = try #require(content.first?.objectValue)
            #expect(block["type"]?.acpStringValue == "content")
            #expect(block["content"]?.objectValue?["type"]?.acpStringValue == "text")
            #expect(block["content"]?.objectValue?["text"]?.acpStringValue == """
                Resume
                old-work — \(detail)

                Other actions
                Delete all old tasks — delete every task graph listed above
                Start fresh — leave saved tasks unchanged
                """)
            let options = try #require(params["options"]?.arrayValue).compactMap(\.objectValue)
            #expect(options.map { $0["optionId"]?.acpStringValue } == [
                "resume:old-session/old-work", "delete", "fresh",
            ])
            #expect(options.map { $0["name"]?.acpStringValue } == [
                "Resume old-work (\(detail))", "Delete all old tasks", "Start fresh",
            ])
            #expect(options.map { $0["kind"]?.acpStringValue } == [
                "allow_once", "reject_always", "reject_once",
            ])

            try await fixture.answer(request, outcome: [
                "outcome": "selected", "optionId": "resume:old-session/old-work",
            ])
            #expect(await fixture.waitForTheOfferToEnd(sessionID: sessionID))

            // Moved into the new ACP session, which keeps its id.
            #expect(try await fixture.bridge.sessionRunner.taskGraphSnapshot(sessionID: sessionID)?.id == "old-work")
            #expect(try fixture.store.load(sessionID: sessionID, workingDirectory: fixture.workspace)?
                .currentGraphID == "old-work")
            #expect(try fixture.earlierSessionGraphIDs() == nil)

            // The tool call is completed, then the notice follows.
            let completions = fixture.toolCallUpdates(toolCallID)
            #expect(completions.count == 1)
            #expect(completions.first?["status"]?.acpStringValue == "completed")
            let resumedText = Self.text(of: .taskGraphResumed(
                graphID: "old-work", pendingTaskCount: 2, isWorkflow: false
            ))
            #expect(fixture.wire.updateTexts(kind: "agent_message_chunk", from: requestIndex) == [resumedText])
            let completionIndex = try #require(fixture.updateIndex(sessionID: sessionID) {
                $0["sessionUpdate"]?.acpStringValue == "tool_call_update"
                    && $0["toolCallId"]?.acpStringValue == toolCallID
            })
            let noticeIndex = try #require(fixture.updateIndex(sessionID: sessionID) {
                $0["sessionUpdate"]?.acpStringValue == "agent_message_chunk"
            })
            #expect(completionIndex < noticeIndex)
            #expect(fixture.wire.permissionRequestIDs.count == 1)
            await fixture.bridge.shutdown()
        }
    }

    /// The answers that start fresh.
    enum FreshAnswer: String, CaseIterable, Sendable {
        case cancelled
        case startFresh
        case unknownOption

        var outcome: [String: Any] {
            switch self {
            case .cancelled:
                return ["outcome": "cancelled"]
            case .startFresh:
                return ACPResumeTaskGraphOfferTests.selectedFresh
            case .unknownOption:
                return ["outcome": "selected", "optionId": "resume:another/graph"]
            }
        }
    }

    /// A cancelled answer, Start fresh (`reject_once`), or an option the
    /// question never offered leave the checkpoint unchanged and present
    /// nothing; the tool call is completed all the same.
    @Test(arguments: FreshAnswer.allCases)
    func aCancelledOrFreshAnswerLeavesTheCheckpointUnchanged(_ answer: FreshAnswer) async throws {
        try await Self.withFixture { fixture in
            try fixture.seedEarlierSessionCheckpoint()
            let sessionID = try await fixture.newSession(id: 1)
            let (requestIndex, request) = try #require(await fixture.permissionRequest())
            let toolCallID = try #require(
                request["params"]?.objectValue?["toolCall"]?.objectValue?["toolCallId"]?.acpStringValue
            )

            try await fixture.answer(request, outcome: answer.outcome)
            #expect(await fixture.waitForTheOfferToEnd(sessionID: sessionID))

            #expect(try fixture.earlierSessionGraphIDs() == ["old-work"])
            #expect(try fixture.store.load(sessionID: sessionID, workingDirectory: fixture.workspace) == nil)
            #expect(fixture.toolCallUpdates(toolCallID).map { $0["status"]?.acpStringValue } == ["completed"])
            #expect(fixture.wire.updateTexts(kind: "agent_message_chunk", from: requestIndex).isEmpty)
            #expect(fixture.wire.permissionRequestIDs.count == 1)
            await fixture.bridge.shutdown()
        }
    }

    /// Delete all old tasks (`reject_always`) deletes every listed graph and
    /// presents the deletion; with nothing left, nothing more is asked.
    @Test
    func rejectAlwaysDeletesEveryListedGraphAndPresentsTheDeletion() async throws {
        try await Self.withFixture { fixture in
            try fixture.seedEarlierSessionCheckpoint()
            let sessionID = try await fixture.newSession(id: 1)
            let (requestIndex, request) = try #require(await fixture.permissionRequest())

            try await fixture.answer(request, outcome: ["outcome": "selected", "optionId": "delete"])
            #expect(await fixture.waitForTheOfferToEnd(sessionID: sessionID))

            #expect(try fixture.earlierSessionGraphIDs()?.contains("old-work") != true)
            #expect(try fixture.store.load(sessionID: sessionID, workingDirectory: fixture.workspace) == nil)
            #expect(fixture.wire.updateTexts(kind: "agent_message_chunk", from: requestIndex)
                == [Self.text(of: .oldTaskGraphsDeleted(count: 1))])
            #expect(fixture.wire.permissionRequestIDs.count == 1)
            await fixture.bridge.shutdown()
        }
    }

    // MARK: - Prompts while the question waits

    /// A `session/prompt` sent while the question waits does not start until
    /// it is answered, then runs normally.
    @Test
    func aPromptSentWhileTheQuestionWaitsStartsOnlyOnceItIsAnswered() async throws {
        try await Self.withFixture { fixture in
            try fixture.seedEarlierSessionCheckpoint()
            let sessionID = try await fixture.newSession(id: 1)
            let (_, request) = try #require(await fixture.permissionRequest())

            let prompt = fixture.startPrompt("Hello", id: 2, sessionID: sessionID)
            #expect(await fixture.waitForPromptsAwaitingTheOffer(1))
            #expect(await fixture.backend.prompts.isEmpty)
            #expect(fixture.wire.response(id: 2) == nil)
            #expect(fixture.wire.updateTexts(kind: "user_message_chunk").isEmpty)

            try await fixture.answer(request, outcome: Self.selectedFresh)
            await prompt.value
            #expect(fixture.wire.stopReason(id: 2) == "end_turn")
            #expect(await fixture.backend.prompts == ["Hello"])
            #expect(await fixture.bridge.promptsAwaitingResumableTaskGraphOfferCountForTesting() == 0)
            let completionIndex = try #require(fixture.updateIndex(sessionID: sessionID) {
                $0["sessionUpdate"]?.acpStringValue == "tool_call_update"
            })
            let userMessageIndex = try #require(fixture.updateIndex(sessionID: sessionID) {
                $0["sessionUpdate"]?.acpStringValue == "user_message_chunk"
            })
            #expect(completionIndex < userMessageIndex)
            await fixture.bridge.shutdown()
        }
    }

    /// A `session/cancel` of a prompt waiting for the question ends it as
    /// `cancelled` once the client answers the question with `cancelled`, as
    /// ACP has it: no turn runs and the checkpoint is unchanged.
    @Test
    func aSessionCancelWhileThePromptWaitsEndsItAsCancelledWithoutATurn() async throws {
        try await Self.withFixture { fixture in
            try fixture.seedEarlierSessionCheckpoint()
            let sessionID = try await fixture.newSession(id: 1)
            let (_, request) = try #require(await fixture.permissionRequest())
            let prompt = fixture.startPrompt("Hello", id: 2, sessionID: sessionID)
            #expect(await fixture.waitForPromptsAwaitingTheOffer(1))

            await fixture.send("session/cancel", id: 3, sessionID: sessionID)
            #expect(fixture.wire.response(id: 3)?["result"] == .object([:]))
            #expect(fixture.wire.response(id: 2) == nil)
            try await fixture.answer(request, outcome: ["outcome": "cancelled"])
            await prompt.value

            #expect(fixture.wire.stopReason(id: 2) == "cancelled")
            #expect(await fixture.backend.prompts.isEmpty)
            #expect(fixture.wire.updateTexts(kind: "user_message_chunk").isEmpty)
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
            let (requestIndex, request) = try #require(await fixture.permissionRequest())
            let toolCallID = try #require(
                request["params"]?.objectValue?["toolCall"]?.objectValue?["toolCallId"]?.acpStringValue
            )
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
            #expect(fixture.toolCallUpdates(toolCallID).isEmpty)
            #expect(fixture.wire.updateTexts(kind: "agent_message_chunk", from: requestIndex).isEmpty)
            #expect(try fixture.earlierSessionGraphIDs() == ["old-work"])

            // A late answer to the withdrawn question changes nothing.
            let countAfterClose = fixture.wire.count
            try await fixture.answer(request, outcome: [
                "outcome": "selected", "optionId": "resume:old-session/old-work",
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
            #expect(await fixture.permissionRequest() != nil)
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
