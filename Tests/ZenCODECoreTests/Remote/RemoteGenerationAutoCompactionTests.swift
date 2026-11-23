//
//  RemoteGenerationAutoCompactionTests.swift
//  ZenCODECoreTests
//
//  The HTTP (non-DS4) path of RemoteGenerationClient compacts the history by
//  itself: before a request that would reach the policy trigger, counting the
//  history by the prompt tokens the provider reported for the previous one,
//  and once after the provider refused a request for its context length.
//

import Foundation
import Testing
import ToolCore
@testable import ZenCODECore
@testable import ZenCODERuntime

/// The three HTTP protocols of the non-DS4 path, each with the provider that
/// selects it and the stream a scripted response is written in.
enum RemoteAutoCompactionWire: CaseIterable, CustomTestStringConvertible, Sendable {
    case chatCompletions
    case responses
    case anthropicMessages

    var testDescription: String {
        switch self {
        case .chatCompletions: "chat completions"
        case .responses: "responses"
        case .anthropicMessages: "anthropic messages"
        }
    }

    var provider: AgentRemoteProvider {
        switch self {
        case .chatCompletions:
            AgentRemoteProvider(
                name: "Auto compaction fixture",
                baseURL: "https://unit.test/v1",
                modelID: "unit-model",
                chatEndpoint: .chatCompletions,
                protocolProfileID: .openAIChatCompletions
            )
        case .responses:
            AgentRemoteProvider(
                name: "Auto compaction fixture",
                baseURL: "https://unit.test/v1",
                modelID: "unit-model",
                chatEndpoint: .responses,
                protocolProfileID: .openAIResponses
            )
        case .anthropicMessages:
            AgentRemoteProvider(
                name: "Auto compaction fixture",
                baseURL: "https://api.anthropic.com/v1",
                modelID: "unit-model",
                chatEndpoint: .chatCompletions,
                providerProfileID: .anthropic,
                protocolProfileID: .anthropicMessages,
                authPolicy: .apiKeyRequired
            )
        }
    }

    /// A successful stream answering `text`. `promptTokens` is the prompt size
    /// the provider reports (no usage at all when `nil`); `cachedTokens` the
    /// part of it served from the prompt cache.
    func completion(text: String, promptTokens: Int?, cachedTokens: Int? = nil) throws -> Data {
        let events: [[String: Any]]
        switch self {
        case .chatCompletions:
            var chunk: [String: Any] = [
                "choices": [["delta": ["content": text], "finish_reason": "stop"]]
            ]
            if let promptTokens {
                var usage: [String: Any] = [
                    "prompt_tokens": promptTokens,
                    "completion_tokens": 2,
                    "total_tokens": promptTokens + 2
                ]
                if let cachedTokens {
                    usage["prompt_tokens_details"] = ["cached_tokens": cachedTokens]
                }
                chunk["usage"] = usage
            }
            events = [chunk]
        case .responses:
            var response: [String: Any] = ["output": [[String: Any]]()]
            if let promptTokens {
                var usage: [String: Any] = [
                    "input_tokens": promptTokens,
                    "output_tokens": 2,
                    "total_tokens": promptTokens + 2
                ]
                if let cachedTokens {
                    usage["input_tokens_details"] = ["cached_tokens": cachedTokens]
                }
                response["usage"] = usage
            }
            events = [
                ["type": "response.output_text.delta", "delta": text],
                ["type": "response.completed", "response": response]
            ]
        case .anthropicMessages:
            var message: [String: Any] = [:]
            if let promptTokens {
                // Anthropic reports the cached part beside the fresh input.
                let cached = cachedTokens ?? 0
                var usage: [String: Any] = [
                    "input_tokens": promptTokens - cached,
                    "output_tokens": 0
                ]
                if cachedTokens != nil {
                    usage["cache_read_input_tokens"] = cached
                }
                message["usage"] = usage
            }
            events = [
                ["type": "message_start", "message": message],
                ["type": "content_block_start", "index": 0, "content_block": ["type": "text", "text": ""]],
                ["type": "content_block_delta", "index": 0, "delta": ["type": "text_delta", "text": text]],
                ["type": "content_block_stop", "index": 0],
                ["type": "message_delta", "delta": ["stop_reason": "end_turn"], "usage": ["output_tokens": 2]],
                ["type": "message_stop"]
            ]
        }
        return try events.reduce(into: Data()) { data, event in
            data.append(Data("data: ".utf8))
            data.append(try JSONSerialization.data(withJSONObject: event))
            data.append(Data("\n\n".utf8))
        }
    }

    /// The body of an HTTP error, in the envelope every protocol shares.
    static func errorBody(_ message: String) throws -> Data {
        try JSONSerialization.data(withJSONObject: ["error": ["message": message]])
    }
}

@Suite("Remote generation auto compaction", .serialized)
struct RemoteGenerationAutoCompactionTests {
    /// Small enough for a few thousand characters to reach the trigger:
    /// 95% (3,800 estimated tokens) triggers, 30% (1,200) is the target.
    private static let contextWindow = 4_000
    private static let sessionID = "auto-compaction"
    private static let contextLimitMessage =
        "Your request exceeded model token limit: 4000 (requested: 4600)"

    /// 10 messages of about 258 estimated tokens each: 2,590 in all, 68% of the
    /// window, so the shared estimate alone never asks for a compaction.
    private static let belowTrigger = (messages: 10, characters: 1_000)
    /// 16 messages: 4,120 estimated tokens, above the 3,800 trigger.
    private static let aboveTrigger = (messages: 16, characters: 1_000)

    // MARK: Preflight

    @Test("a request above the estimated trigger is compacted first", arguments: RemoteAutoCompactionWire.allCases)
    func compactsAboveEstimatedTrigger(wire: RemoteAutoCompactionWire) async throws {
        let harness = try await Harness.start(
            wire: wire,
            history: Self.history(Self.aboveTrigger),
            responses: [try wire.completion(text: "done", promptTokens: nil)]
        )
        defer { harness.fixture.beginShutdown() }

        let response = try await harness.send("next question")

        #expect(response.text == "done")
        let bodies = harness.bodies()
        try #require(bodies.count == 1)
        #expect(bodies[0].contains(AgentConversationCompactionSupport.memorySummaryHeader))
        #expect(bodies[0].contains("next question"))
        // The history alone is 16,000 characters; the request carries a summary
        // of the earliest messages and the most recent ones.
        #expect(bodies[0].count < 12_000)
        #expect(harness.compactionDiagnostics().count == 1)
        let snapshot = try #require(await harness.client.snapshotSession(id: Self.sessionID))
        #expect(snapshot.history.count < Self.aboveTrigger.messages)
        #expect(snapshot.systemPrompt?.contains(AgentConversationCompactionSupport.memorySummaryHeader) == true)
    }

    @Test("a chat-completions request above the trigger carries fewer messages and a summary in the system prompt")
    func compactedChatRequestShape() async throws {
        let wire = RemoteAutoCompactionWire.chatCompletions
        let harness = try await Harness.start(
            wire: wire,
            history: Self.history(Self.aboveTrigger),
            responses: [try wire.completion(text: "done", promptTokens: nil)]
        )
        defer { harness.fixture.beginShutdown() }

        _ = try await harness.send("next question")

        let messages = try harness.chatMessages(at: 0)
        // System prompt, 16 history messages and the new prompt without it.
        #expect(messages.count < Self.aboveTrigger.messages + 2)
        #expect(messages.first?["role"] as? String == "system")
        let system = try #require(messages.first?["content"] as? String)
        #expect(system.hasPrefix("system prompt"))
        #expect(system.contains(AgentConversationCompactionSupport.memorySummaryHeader))
        #expect(messages.last?["role"] as? String == "user")
        #expect((messages.last?["content"] as? String) == "next question")
    }

    @Test("a history below the trigger is sent unchanged", arguments: RemoteAutoCompactionWire.allCases)
    func leavesHistoryBelowTriggerUntouched(wire: RemoteAutoCompactionWire) async throws {
        let harness = try await Harness.start(
            wire: wire,
            history: Self.history(Self.belowTrigger),
            responses: [try wire.completion(text: "done", promptTokens: nil)]
        )
        defer { harness.fixture.beginShutdown() }

        _ = try await harness.send("next question")

        let bodies = harness.bodies()
        try #require(bodies.count == 1)
        #expect(!bodies[0].contains(AgentConversationCompactionSupport.memorySummaryHeader))
        #expect(bodies[0].contains("message 0 "))
        #expect(harness.compactionDiagnostics().isEmpty)
    }

    @Test("without a context window nothing is compacted")
    func unknownContextWindowNeverCompacts() async throws {
        let wire = RemoteAutoCompactionWire.chatCompletions
        let harness = try await Harness.start(
            wire: wire,
            history: Self.history(Self.aboveTrigger),
            responses: [try wire.completion(text: "done", promptTokens: 900_000)],
            contextWindow: nil
        )
        defer { harness.fixture.beginShutdown() }

        _ = try await harness.send("first")
        _ = try await harness.send("second")

        #expect(harness.bodies().allSatisfy { !$0.contains(AgentConversationCompactionSupport.memorySummaryHeader) })
        #expect(harness.compactionDiagnostics().isEmpty)
        #expect(await harness.client.contextCalibrationBySessionID.isEmpty)
    }

    // MARK: Calibration

    @Test(
        "the prompt size the provider reported triggers a compaction the estimate alone would not",
        arguments: RemoteAutoCompactionWire.allCases
    )
    func calibratedUsageTriggersCompaction(wire: RemoteAutoCompactionWire) async throws {
        let harness = try await Harness.start(
            wire: wire,
            history: Self.history(Self.belowTrigger),
            responses: [
                try wire.completion(text: "first answer", promptTokens: 3_950),
                try wire.completion(text: "second answer", promptTokens: nil)
            ]
        )
        defer { harness.fixture.beginShutdown() }

        _ = try await harness.send("first question")
        let calibration = try #require(
            await harness.client.contextCalibrationBySessionID[Self.sessionID]
        )
        #expect(calibration.reportedPromptTokens == 3_950)
        // The shared estimate saw far fewer tokens than the provider counted.
        #expect(calibration.estimatedTokens < 3_800)
        #expect(harness.compactionDiagnostics().isEmpty)

        _ = try await harness.send("second question")

        let bodies = harness.bodies()
        try #require(bodies.count == 2)
        #expect(!bodies[0].contains(AgentConversationCompactionSupport.memorySummaryHeader))
        #expect(bodies[1].contains(AgentConversationCompactionSupport.memorySummaryHeader))
        #expect(bodies[1].count < bodies[0].count)
        #expect(harness.compactionDiagnostics().count == 1)
    }

    @Test(
        "a reported prompt size under the trigger, or none at all, leaves the next request alone",
        arguments: RemoteAutoCompactionWire.allCases,
        [Optional(1_200), nil]
    )
    func lowOrMissingUsageDoesNotCompact(
        wire: RemoteAutoCompactionWire,
        reportedPromptTokens: Int?
    ) async throws {
        let harness = try await Harness.start(
            wire: wire,
            history: Self.history(Self.belowTrigger),
            responses: [
                try wire.completion(text: "first answer", promptTokens: reportedPromptTokens),
                try wire.completion(text: "second answer", promptTokens: nil)
            ]
        )
        defer { harness.fixture.beginShutdown() }

        _ = try await harness.send("first question")
        _ = try await harness.send("second question")

        let bodies = harness.bodies()
        try #require(bodies.count == 2)
        #expect(bodies.allSatisfy { !$0.contains(AgentConversationCompactionSupport.memorySummaryHeader) })
        // The second request is the first one plus the answer and the new prompt.
        #expect(bodies[1].count > bodies[0].count)
        #expect(bodies[1].contains("first answer"))
        #expect(harness.compactionDiagnostics().isEmpty)
    }

    @Test("a compaction clears the calibration, so the compacted history is not compacted again")
    func compactionClearsCalibration() async throws {
        let wire = RemoteAutoCompactionWire.chatCompletions
        let harness = try await Harness.start(
            wire: wire,
            history: Self.history(Self.belowTrigger),
            responses: [
                try wire.completion(text: "first answer", promptTokens: 3_950),
                // No usage: nothing records a calibration again.
                try wire.completion(text: "second answer", promptTokens: nil),
                try wire.completion(text: "third answer", promptTokens: nil)
            ]
        )
        defer { harness.fixture.beginShutdown() }

        _ = try await harness.send("first question")
        #expect(await harness.client.contextCalibrationBySessionID[Self.sessionID] != nil)

        _ = try await harness.send("second question")
        #expect(harness.compactionDiagnostics().count == 1)
        #expect(await harness.client.contextCalibrationBySessionID[Self.sessionID] == nil)
        let compactedCount = try harness.chatMessages(at: 1).count

        _ = try await harness.send("third question")

        // One compaction in all: the third request only adds the second
        // answer and its own prompt to the compacted second one.
        #expect(harness.compactionDiagnostics().count == 1)
        let thirdMessages = try harness.chatMessages(at: 2)
        #expect(thirdMessages.count == compactedCount + 2)
    }

    @Test("every rewrite or replacement of the session history clears its calibration")
    func sessionChangesClearCalibration() async throws {
        let wire = RemoteAutoCompactionWire.chatCompletions
        let harness = try await Harness.start(
            wire: wire,
            history: Self.history(Self.belowTrigger),
            responses: [try wire.completion(text: "answer", promptTokens: 2_000)]
        )
        defer { harness.fixture.beginShutdown() }
        let client = harness.client
        let history = Self.history(Self.belowTrigger)
        func hasCalibration() async -> Bool {
            await client.contextCalibrationBySessionID[Self.sessionID] != nil
        }

        // updateSessionOptions
        _ = try await harness.send("question")
        #expect(await hasCalibration())
        await client.updateSessionOptions(
            id: Self.sessionID,
            systemPrompt: "another system prompt",
            allowedToolNames: [],
            thinkingSelection: nil,
            preserveThinking: false
        )
        #expect(!(await hasCalibration()))

        // A compaction asked for by `/sessions compact`.
        _ = try await harness.send("question")
        #expect(await hasCalibration())
        #expect(await client.compactSession(id: Self.sessionID, force: true) != nil)
        #expect(!(await hasCalibration()))

        // A session installed again under the same id.
        _ = try await harness.send("question")
        #expect(await hasCalibration())
        await client.createSession(
            id: Self.sessionID, cwd: "/tmp/project", systemPrompt: "system prompt",
            history: history, allowedToolNames: []
        )
        #expect(!(await hasCalibration()))

        // A session closed.
        _ = try await harness.send("question")
        #expect(await hasCalibration())
        await client.closeSession(id: Self.sessionID)
        #expect(!(await hasCalibration()))
    }

    @Test("stripping rejected images clears the calibration")
    func strippingImagesClearsCalibration() async throws {
        let wire = RemoteAutoCompactionWire.chatCompletions
        let harness = try await Harness.start(
            wire: wire,
            history: Self.history(Self.belowTrigger),
            responses: [
                try wire.completion(text: "first answer", promptTokens: 2_000),
                try RemoteAutoCompactionWire.errorBody("unknown variant `image_url`, expected `text`"),
                try wire.completion(text: "second answer", promptTokens: nil)
            ],
            statuses: [200, 400, 200]
        )
        defer { harness.fixture.beginShutdown() }

        _ = try await harness.send("first question")
        #expect(await harness.client.contextCalibrationBySessionID[Self.sessionID] != nil)

        let image = AgentRuntimeAttachment(
            kind: .image,
            data: Data([0x89, 0x50, 0x4E, 0x47]),
            contentType: "image/png",
            originalFilename: "screenshot.png"
        )
        _ = try await harness.client.sendPrompt(
            sessionID: Self.sessionID,
            prompt: "what is this?",
            attachments: [image],
            onEvent: { _ in }
        )

        #expect(harness.bodies().count == 3)
        #expect(await harness.client.contextCalibrationBySessionID[Self.sessionID] == nil)

        // The rejected request carried the image; the retry carries a text
        // notice in its place, so the model does not guess what it showed.
        let bodies = harness.bodies()
        #expect(bodies[1].contains("image_url"))
        #expect(!bodies[2].contains("image_url"))
        let retried = try #require(try harness.chatMessages(at: 2).last { $0["role"] as? String == "user" })
        #expect(retried["content"] as? String == "what is this?\n\n\(RemoteGenerationClient.omittedImageNotice)")
    }

    // MARK: Context-limit retry

    @Test(
        "a context-length rejection is retried once with the compacted history",
        arguments: RemoteAutoCompactionWire.allCases
    )
    func retriesOnceAfterContextLimit(wire: RemoteAutoCompactionWire) async throws {
        let harness = try await Harness.start(
            wire: wire,
            history: Self.history(Self.belowTrigger),
            responses: [
                try RemoteAutoCompactionWire.errorBody(Self.contextLimitMessage),
                try wire.completion(text: "recovered", promptTokens: nil)
            ],
            statuses: [400, 200]
        )
        defer { harness.fixture.beginShutdown() }

        let response = try await harness.send("next question")

        #expect(response.text == "recovered")
        let bodies = harness.bodies()
        try #require(bodies.count == 2)
        #expect(!bodies[0].contains(AgentConversationCompactionSupport.memorySummaryHeader))
        #expect(bodies[1].contains(AgentConversationCompactionSupport.memorySummaryHeader))
        #expect(bodies[1].count < bodies[0].count)
        #expect(bodies[1].contains("next question"))
        #expect(harness.compactionDiagnostics().isEmpty)
        let retries = harness.contextLimitDiagnostics()
        #expect(retries.count == 1)
        #expect(retries.first?.contains("Retrying once with compacted conversation history") == true)
        #expect(await harness.client.contextCalibrationBySessionID[Self.sessionID] == nil)
    }

    @Test("a second context-length rejection in the same turn is surfaced")
    func secondContextLimitRejectionIsThrown() async throws {
        let wire = RemoteAutoCompactionWire.chatCompletions
        let harness = try await Harness.start(
            wire: wire,
            history: Self.history(Self.belowTrigger),
            responses: [try RemoteAutoCompactionWire.errorBody(Self.contextLimitMessage)],
            statuses: [400, 400]
        )
        defer { harness.fixture.beginShutdown() }

        await expectRemoteFailure(Self.contextLimitMessage) {
            _ = try await harness.send("next question")
        }

        #expect(harness.bodies().count == 2)
        #expect(harness.contextLimitDiagnostics().count == 1)
    }

    @Test("a failure that is not about the context length is surfaced without compacting")
    func otherFailureIsThrownWithoutCompacting() async throws {
        let wire = RemoteAutoCompactionWire.chatCompletions
        let harness = try await Harness.start(
            wire: wire,
            history: Self.history(Self.belowTrigger),
            responses: [try RemoteAutoCompactionWire.errorBody("Invalid API key provided")],
            statuses: [400]
        )
        defer { harness.fixture.beginShutdown() }

        await expectRemoteFailure("Invalid API key provided") {
            _ = try await harness.send("next question")
        }

        #expect(harness.bodies().count == 1)
        #expect(harness.compactionDiagnostics().isEmpty)
        #expect(harness.contextLimitDiagnostics().isEmpty)
        let snapshot = try #require(await harness.client.snapshotSession(id: Self.sessionID))
        #expect(snapshot.systemPrompt?.contains(AgentConversationCompactionSupport.memorySummaryHeader) != true)
    }

    @Test("a context-length rejection of a history that cannot be compacted is surfaced")
    func uncompactableHistoryIsThrownWithDiagnostic() async throws {
        let wire = RemoteAutoCompactionWire.chatCompletions
        let harness = try await Harness.start(
            wire: wire,
            history: Self.history((messages: 2, characters: 200)),
            responses: [try RemoteAutoCompactionWire.errorBody(Self.contextLimitMessage)],
            statuses: [400]
        )
        defer { harness.fixture.beginShutdown() }

        await expectRemoteFailure(Self.contextLimitMessage) {
            _ = try await harness.send("next question")
        }

        #expect(harness.bodies().count == 1)
        let diagnostics = harness.contextLimitDiagnostics()
        #expect(diagnostics.count == 1)
        #expect(diagnostics.first?.contains("could not be compacted for retry") == true)
    }

    // MARK: Prompt cache warning

    @Test("a request that follows a compaction is not reported as a prompt-cache miss")
    func noCacheWarningAfterCompaction() async throws {
        let wire = RemoteAutoCompactionWire.chatCompletions
        // The provider reports a cold cache for a prompt past the warning floor.
        let coldCache = try wire.completion(text: "done", promptTokens: 1_500, cachedTokens: 0)

        let compacted = try await Harness.start(
            wire: wire,
            history: Self.history(Self.aboveTrigger),
            responses: [coldCache]
        )
        defer { compacted.fixture.beginShutdown() }
        _ = try await compacted.send("next question")
        #expect(compacted.compactionDiagnostics().count == 1)
        #expect(compacted.cacheWarnings().isEmpty)

        let retried = try await Harness.start(
            wire: wire,
            history: Self.history(Self.belowTrigger),
            responses: [try RemoteAutoCompactionWire.errorBody(Self.contextLimitMessage), coldCache],
            statuses: [400, 200]
        )
        defer { retried.fixture.beginShutdown() }
        _ = try await retried.send("next question")
        #expect(retried.contextLimitDiagnostics().count == 1)
        #expect(retried.cacheWarnings().isEmpty)

        // Control: the same cold cache without a compaction is still reported.
        let untouched = try await Harness.start(
            wire: wire,
            history: Self.history(Self.belowTrigger),
            responses: [coldCache]
        )
        defer { untouched.fixture.beginShutdown() }
        _ = try await untouched.send("next question")
        #expect(untouched.compactionDiagnostics().isEmpty)
        #expect(untouched.cacheWarnings().count == 1)
    }

    // MARK: Support

    /// A conversation of `messages` messages of about `characters` characters,
    /// alternating user and assistant.
    private static func history(
        _ size: (messages: Int, characters: Int)
    ) -> [AgentRuntimeMessage] {
        (0..<size.messages).map { index in
            AgentRuntimeMessage(
                role: index.isMultiple(of: 2) ? .user : .assistant,
                content: "message \(index) " + String(repeating: "x", count: size.characters)
            )
        }
    }

    /// Runs `body`, which must fail with the remote failure `message`.
    private func expectRemoteFailure(
        _ message: String,
        sourceLocation: SourceLocation = #_sourceLocation,
        _ body: () async throws -> Void
    ) async {
        do {
            try await body()
            Issue.record("Expected the provider failure to be surfaced.", sourceLocation: sourceLocation)
        } catch let RemoteGenerationClientError.remoteFailure(failure) {
            #expect(failure == message, sourceLocation: sourceLocation)
        } catch {
            Issue.record("Unexpected error: \(error)", sourceLocation: sourceLocation)
        }
    }

    /// A client over the loopback fixture, holding a session seeded with a
    /// history, and the events of every turn sent through it.
    private struct Harness {
        let fixture: RemoteNIOStreamingFixture
        let client: RemoteGenerationClient
        let events = CapturedDirectAgentEvents()

        static func start(
            wire: RemoteAutoCompactionWire,
            history: [AgentRuntimeMessage],
            responses: [Data],
            statuses: [Int] = [],
            contextWindow: Int? = RemoteGenerationAutoCompactionTests.contextWindow
        ) async throws -> Harness {
            let fixture = try await RemoteNIOStreamingFixture.start(
                responseBody: responses.last ?? Data(),
                responseSequence: responses,
                responseStatusSequence: statuses
            )
            let configuration = AgentRuntimeConfiguration(
                modelID: "unit-model",
                workingDirectory: URL(fileURLWithPath: "/tmp/project", isDirectory: true),
                maxToolRounds: 4,
                toolAuthorizationHandler: nil
            ).withModelSettings(
                configuredContextWindowLimit: contextWindow,
                generationParameterOverrides: nil
            )
            let client = RemoteGenerationClient(
                configuration: configuration,
                provider: wire.provider,
                apiKey: "test-key",
                transport: fixture.transport,
                streamEndpointBaseURLOverride: fixture.baseURL
            )
            await client.createSession(
                id: RemoteGenerationAutoCompactionTests.sessionID,
                cwd: "/tmp/project",
                systemPrompt: "system prompt",
                history: history,
                allowedToolNames: []
            )
            return Harness(fixture: fixture, client: client)
        }

        func send(_ prompt: String) async throws -> DirectAgentResponse {
            let events = events
            return try await client.sendPrompt(
                sessionID: RemoteGenerationAutoCompactionTests.sessionID,
                prompt: prompt,
                attachments: [],
                onEvent: { events.append($0) }
            )
        }

        /// The body of every request the fixture received, as text.
        func bodies() -> [String] {
            fixture.capturedRequests().map { String(decoding: $0.body, as: UTF8.self) }
        }

        /// The messages of the chat-completions request number `index`.
        func chatMessages(at index: Int) throws -> [[String: Any]] {
            let requests = fixture.capturedRequests()
            try #require(index < requests.count)
            return try #require(try requests[index].jsonObject()["messages"] as? [[String: Any]])
        }

        func compactionDiagnostics() -> [String] {
            events.diagnostics().filter { $0.hasPrefix("Compacted conversation history from ") }
        }

        func contextLimitDiagnostics() -> [String] {
            events.diagnostics().filter { $0.contains("context limit reached") }
        }

        func cacheWarnings() -> [String] {
            events.diagnostics().filter { $0.hasPrefix("Cache warning:") }
        }
    }
}
