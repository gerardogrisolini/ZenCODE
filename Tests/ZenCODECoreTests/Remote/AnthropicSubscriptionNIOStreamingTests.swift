//
//  AnthropicSubscriptionNIOStreamingTests.swift
//  ZenCODECoreTests
//
//  Provider-level NIO fixtures for Anthropic messages streaming.
//

import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
@testable import ZenCODECore
import Testing
import Synchronization

@Suite("Anthropic Subscription NIO streaming", .serialized)
struct AnthropicSubscriptionNIOStreamingTests {
    @Test("messages preserves OAuth wire headers, SSE usage and subscription usage headers")
    func messagesStreamsThroughNIOAndPublishesUsage() async throws {
        let response = """
        event: message_start
        data: {"type":"message_start","message":{"usage":{"input_tokens":11,"output_tokens":0}}}

        data: {"type":"content_block_start","index":0,"content_block":{"type":"text","text":"Hello "}}

        data: {"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"NIO"}}

        data: {"type":"message_delta","delta":{"stop_reason":"end_turn"},"usage":{"output_tokens":7}}

        data: {"type":"message_stop"}

        """
        let fixture = try await RemoteNIOStreamingFixture.start(
            responseBody: Data(response.utf8),
            responseHeaders: [
                RemoteHTTPHeader(name: "content-type", value: "text/event-stream"),
                RemoteHTTPHeader(
                    name: "anthropic-ratelimit-unified-5h-utilization",
                    value: "0.25"
                ),
                RemoteHTTPHeader(
                    name: "anthropic-ratelimit-unified-7d-utilization",
                    value: "0.60"
                )
            ]
        )
        defer {
            fixture.beginShutdown()
        }
        let client = makeClient(fixture: fixture)
        let lease = try await installedLease(in: client)
        let events = CapturedDirectAgentEvents()

        let result = try await client.streamAnthropicMessages(
            lease: lease,
            modelID: "claude-haiku-4-5",
            modelLLMID: "claude-haiku-4-5",
            credentials: credentials(),
            applyTurnMemory: false,
            onEvent: { event in
                events.append(event)
            }
        )

        let request = try #require(fixture.capturedRequests().first)
        let payload = try request.jsonObject()
        let usage = try #require(events.subscriptionUsage().first)

        #expect(result.text == "Hello NIO")
        #expect(result.stopReason == "end_turn")
        #expect(result.stats.usage?.promptTokens == 11)
        #expect(result.stats.usage?.completionTokens == 7)
        #expect(events.contentText() == "Hello NIO")
        #expect(usage.dailyUsedPercent == 25.0)
        #expect(usage.weeklyUsedPercent == 60.0)
        #expect(request.request.httpMethod == "POST")
        #expect(request.request.url?.path == "/v1/messages")
        #expect(headerValue("content-type", in: request) == "application/json")
        #expect(headerValue("anthropic-version", in: request) == "2023-06-01")
        #expect(headerValue("anthropic-dangerous-direct-browser-access", in: request) == "true")
        #expect(headerValue("authorization", in: request) == "Bearer access-token")
        #expect(headerValue("x-app", in: request) == "cli")
        #expect(payload["model"] as? String == "claude-haiku-4-5")
        #expect(payload["stream"] as? Bool == true)
    }

    @Test("messages preserves bounded 429 body and reset/request-id diagnostics")
    func messagesSurfacesNIOHTTP429Details() async throws {
        let fixture = try await RemoteNIOStreamingFixture.start(
            responseBody: Data(#"{"error":{"type":"rate_limit_error","message":"Slow down"}}"#.utf8),
            responseStatus: 429,
            responseHeaders: [
                RemoteHTTPHeader(name: "content-type", value: "application/json"),
                RemoteHTTPHeader(name: "retry-after", value: "60"),
                RemoteHTTPHeader(name: "request-id", value: "req_nio_429"),
                RemoteHTTPHeader(
                    name: "anthropic-ratelimit-unified-5h-reset",
                    value: "60"
                )
            ]
        )
        defer {
            fixture.beginShutdown()
        }
        let client = makeClient(fixture: fixture)
        let lease = try await installedLease(in: client)

        do {
            _ = try await client.streamAnthropicMessages(
                lease: lease,
                modelID: "claude-haiku-4-5",
                modelLLMID: "claude-haiku-4-5",
                credentials: credentials(),
                applyTurnMemory: false,
                onEvent: { _ in }
            )
            Issue.record("Expected the Anthropic 429 response to fail.")
        } catch let error as RemoteGenerationClientError {
            guard case let .remoteFailure(message) = error else {
                Issue.record("Unexpected provider error: \(error)")
                return
            }
            #expect(message.contains("HTTP 429"))
            #expect(message.contains("Slow down"))
            #expect(message.contains("retry-after=60"))
            #expect(message.contains("request-id=req_nio_429"))
            #expect(message.contains("Anthropic"))
        }

        #expect(fixture.capturedRequests().count == 1)
    }

    @Test("messages never replay an Anthropic POST after a pre-head opening failure")
    func messagesDoesNotRetryPreHeadFailure() async throws {
        let fixture = try await RemoteNIOStreamingFixture.start(
            responseBody: Data(),
            failuresBeforeHead: 1
        )
        defer {
            fixture.beginShutdown()
        }
        let client = makeClient(fixture: fixture)
        let lease = try await installedLease(in: client)

        do {
            _ = try await client.streamAnthropicMessages(
                lease: lease,
                modelID: "claude-haiku-4-5",
                modelLLMID: "claude-haiku-4-5",
                credentials: credentials(),
                applyTurnMemory: false,
                onEvent: { _ in }
            )
            Issue.record("Expected the pre-head close to propagate without replay.")
        } catch {
            #expect(error is RemoteTransportError)
        }

        #expect(fixture.capturedRequests().count == 1)
    }

    @Test("unsatisfiable preflight budget is diagnosed once across rebuilt streams")
    func unsatisfiablePreflightBudgetDiagnosticIsEmittedOnce() async throws {
        let response = """
        data: {"type":"message_start","message":{"usage":{"input_tokens":1,"output_tokens":0}}}

        data: {"type":"content_block_start","index":0,"content_block":{"type":"text","text":"ok"}}

        data: {"type":"message_delta","delta":{"stop_reason":"end_turn"},"usage":{"output_tokens":1}}

        data: {"type":"message_stop"}

        """
        let fixture = try await RemoteNIOStreamingFixture.start(responseBody: Data(response.utf8))
        defer {
            fixture.beginShutdown()
        }
        let client = makeClient(
            fixture: fixture,
            configuredContextWindowLimit: 128,
            maxOutputTokens: 128
        )
        let lease = try await installedLease(in: client)
        let events = CapturedDirectAgentEvents()

        // A real context-limit retry re-enters `streamAnthropicMessages` on the
        // same lease. Calling the stream twice exercises that lifecycle without
        // relying on credentials or a live provider response.
        for _ in 0..<2 {
            _ = try await client.streamAnthropicMessages(
                lease: lease,
                modelID: "claude-haiku-4-5",
                modelLLMID: "claude-haiku-4-5",
                credentials: credentials(),
                applyTurnMemory: false,
                onEvent: { event in
                    events.append(event)
                }
            )
        }

        let diagnostics = events.diagnostics().filter {
            $0.contains("request cannot fit") && $0.contains("Skipping compaction")
        }
        #expect(diagnostics.count == 1)
        #expect(fixture.capturedRequests().count == 2)
    }

    @Test("cached Anthropic overhead is dropped by conversation appends and lifecycle changes")
    func cachedRequestOverheadIsInvalidatedAcrossConversationAndLifecycle() async throws {
        let fixture = try await RemoteNIOStreamingFixture.start(responseBody: Data())
        defer {
            fixture.beginShutdown()
        }
        let client = makeClient(fixture: fixture)
        let sessionID = "anthropic-overhead-lifecycle"
        let messages = (0..<120).map { index in
            RemoteGenerationClient.remoteMessage(
                role: index.isMultiple(of: 2) ? "user" : "assistant",
                content: "turn \(index) " + String(repeating: "payload ", count: 80),
                attachments: []
            )
        }
        await client.createSession(
            id: sessionID,
            cwd: "/tmp/project",
            history: RemoteGenerationClient.agentRuntimeMessages(from: messages),
            allowedToolNames: []
        )
        guard let lease = await client.sessionLease(for: sessionID) else {
            Issue.record("Expected the lifecycle test session to have a lease.")
            return
        }
        let runtimeTokens = AgentConversationCompactionSupport.estimatedTokenCount(
            for: RemoteGenerationClient.agentRuntimeMessages(from: messages)
        )
        let measuredEstimate = SubscriptionCompactionSupport.RequestEstimate(
            totalTokens: runtimeTokens + 16_000,
            staticOverheadTokens: 16_000
        )

        await client.recordRequestOverhead(
            estimate: measuredEstimate,
            runtimeConversationTokens: runtimeTokens,
            for: lease
        )
        let staleOverhead = await client.requestOverhead(forSessionID: sessionID)
        let staleResult = AnthropicSubscriptionGenerationClient.compactedMessagesIfNeeded(
            messages,
            maxTokens: 30_000,
            maxOutputTokens: 1_000,
            overhead: staleOverhead
        )
        let freshResult = AnthropicSubscriptionGenerationClient.compactedMessagesIfNeeded(
            messages,
            maxTokens: 30_000,
            maxOutputTokens: 1_000
        )

        // This proves why invalidation matters: carrying the old reservation
        // into a changed session would compact a history that otherwise fits.
        #expect(staleOverhead.staticOverheadTokens == 16_000)
        #expect(staleResult.wasCompacted)
        #expect(freshResult.wasCompacted == false)

        // Each wire role can carry a radically different UTF-8/JSON ratio.
        // The actor-level mutation boundary is shared by assistant and tool
        // commits, so every append must drop the cached conversation rate.
        for role in ["user", "assistant", "tool"] {
            await client.recordRequestOverhead(
                estimate: measuredEstimate,
                runtimeConversationTokens: runtimeTokens,
                for: lease
            )
            _ = await client.mutateSession(for: lease) { session in
                session.messages.append(
                    RemoteGenerationClient.remoteMessage(
                        role: role,
                        content: "changed \(role) 👩🏽‍💻\u{301}\\\"",
                        attachments: []
                    )
                )
            }
            #expect(await client.requestOverhead(forSessionID: sessionID) == .none)
        }

        await client.updateSessionOptions(
            id: sessionID,
            systemPrompt: "changed system prompt",
            allowedToolNames: [],
            thinkingSelection: nil,
            preserveThinking: false
        )
        #expect(await client.requestOverhead(forSessionID: sessionID) == .none)

        await client.recordRequestOverhead(
            estimate: measuredEstimate,
            runtimeConversationTokens: runtimeTokens,
            for: lease
        )
        await client.updateToolProviders([], sessionID: sessionID)
        #expect(await client.requestOverhead(forSessionID: sessionID) == .none)

        await client.recordRequestOverhead(
            estimate: measuredEstimate,
            runtimeConversationTokens: runtimeTokens,
            for: lease
        )
        await client.updateToolProviders([])
        #expect(await client.requestOverhead(forSessionID: sessionID) == .none)

        await client.recordRequestOverhead(
            estimate: measuredEstimate,
            runtimeConversationTokens: runtimeTokens,
            for: lease
        )
        await client.shutdown()
        #expect(await client.requestOverhead(forSessionID: sessionID) == .none)
    }

    @Test("manual Anthropic compaction drops the cached conversation inflation factor")
    func manualCompactionInvalidatesCachedConversationInflationFactor() async throws {
        let fixture = try await RemoteNIOStreamingFixture.start(responseBody: Data())
        defer {
            fixture.beginShutdown()
        }
        let client = makeClient(
            fixture: fixture,
            configuredContextWindowLimit: 100_000
        )
        let sessionID = "anthropic-manual-compaction-overhead"
        let history = (0..<120).map { index in
            AgentRuntimeMessage(
                role: index.isMultiple(of: 2) ? .user : .assistant,
                content: "turn \(index) " + String(repeating: "payload ", count: 80)
            )
        }
        await client.createSession(
            id: sessionID,
            cwd: "/tmp/project",
            history: history,
            allowedToolNames: []
        )
        let lease = try #require(await client.sessionLease(for: sessionID))
        let runtimeTokens = AgentConversationCompactionSupport.estimatedTokenCount(for: history)
        await client.recordRequestOverhead(
            estimate: SubscriptionCompactionSupport.RequestEstimate(
                totalTokens: runtimeTokens * 2,
                staticOverheadTokens: 0
            ),
            runtimeConversationTokens: runtimeTokens,
            for: lease
        )

        let cachedOverhead = await client.requestOverhead(forSessionID: sessionID)
        let result = try #require(await client.compactSession(id: sessionID, force: true))

        #expect(cachedOverhead.conversationInflationFactor == 2.0)
        #expect(result.wasCompacted)
        #expect(result.estimatedTokenCount < result.originalEstimatedTokenCount)
        // The persisted session no longer contains the conversation from which
        // this factor was measured, so retaining it would poison the next
        // compaction budget.
        #expect(await client.requestOverhead(forSessionID: sessionID) == .none)
    }

    @Test("messages reject regular EOF without message_stop and never replay", arguments: ["", Self.partialTextResponse, Self.toolResponse, "data: [DONE]\n\n"])
    func messagesRejectIncompleteEOF(response: String) async throws {
        let fixture = try await RemoteNIOStreamingFixture.start(responseBody: Data(response.utf8))
        defer { fixture.beginShutdown() }
        let client = makeClient(fixture: fixture)
        let lease = try await installedLease(in: client)

        do {
            _ = try await client.streamAnthropicMessages(
                lease: lease,
                modelID: "claude-haiku-4-5",
                modelLLMID: "claude-haiku-4-5",
                credentials: credentials(),
                applyTurnMemory: false,
                onEvent: { _ in }
            )
            Issue.record("Expected missing message_stop to fail.")
        } catch let error as RemoteGenerationClientError {
            guard case let .remoteFailure(message) = error else {
                Issue.record("Unexpected provider error: \(error)")
                return
            }
            #expect(message == "Anthropic streaming response ended before message_stop.")
        }
        #expect(fixture.capturedRequests().count == 1)
    }

    @Test("messages finalize tool calls only with message_stop")
    func messagesCompleteToolStream() async throws {
        let response = Self.toolResponse + "data: {\"type\":\"message_stop\"}\n\n"
        let fixture = try await RemoteNIOStreamingFixture.start(responseBody: Data(response.utf8))
        defer { fixture.beginShutdown() }
        let client = makeClient(fixture: fixture)
        let lease = try await installedLease(in: client)
        let result = try await client.streamAnthropicMessages(
            lease: lease,
            modelID: "claude-haiku-4-5",
            modelLLMID: "claude-haiku-4-5",
            credentials: credentials(),
            applyTurnMemory: false,
            onEvent: { _ in }
        )
        #expect(result.toolCalls.count == 1)
        #expect(result.toolCalls.first?.id == "tool_incomplete")
        #expect(result.stopReason == "tool_calls")
        #expect(fixture.capturedRequests().count == 1)
    }

    @Test("SSE errors are not replaced by the missing terminal error", arguments: [false, true])
    func messagesPreserveSSEError(afterStop: Bool) async throws {
        let response = (afterStop ? "data: {\"type\":\"message_stop\"}\n\n" : "")
            + "data: {\"type\":\"error\",\"error\":{\"type\":\"overloaded_error\",\"message\":\"Fixture overloaded\"}}\n\n"
        let fixture = try await RemoteNIOStreamingFixture.start(responseBody: Data(response.utf8))
        defer { fixture.beginShutdown() }
        let client = makeClient(fixture: fixture)
        let lease = try await installedLease(in: client)
        do {
            _ = try await client.streamAnthropicMessages(
                lease: lease,
                modelID: "claude-haiku-4-5",
                modelLLMID: "claude-haiku-4-5",
                credentials: credentials(),
                applyTurnMemory: false,
                onEvent: { _ in }
            )
            Issue.record("Expected SSE error to propagate.")
        } catch let error as RemoteGenerationClientError {
            guard case let .remoteFailure(message) = error else {
                Issue.record("Unexpected provider error: \(error)")
                return
            }
            #expect(message.contains("Fixture overloaded"))
            #expect(!message.contains("ended before message_stop"))
        }
        #expect(fixture.capturedRequests().count == 1)
    }

    @Test("prompt does not commit incomplete assistant messages or execute tools", arguments: ["", Self.partialTextResponse, Self.toolResponse])
    func promptRejectsIncompleteStreamWithoutSideEffects(response: String) async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("anthropic-incomplete-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        try await AppStorageDirectory.withSupportDirectoryURL(directory) {
            try AgentSettingsManifestStore.save(AgentSettingsManifest(
                models: [],
                anthropicSubscriptionCredentials: credentials()
            ))
            let fixture = try await RemoteNIOStreamingFixture.start(responseBody: Data(response.utf8))
            defer { fixture.beginShutdown() }
            let client = makeClient(fixture: fixture)
            let sessionID = "incomplete-prompt"
            await client.createSession(
                id: sessionID,
                cwd: directory.path,
                history: [
                    AgentRuntimeMessage(role: .user, content: "previous request"),
                    AgentRuntimeMessage(role: .assistant, content: "previous answer")
                ],
                allowedToolNames: []
            )
            let before = try #require(await client.snapshotSession(id: sessionID))
            let toolEvents = Mutex(0)
            let events = CapturedDirectAgentEvents()
            do {
                _ = try await client.sendPrompt(
                    sessionID: sessionID,
                    prompt: "new request",
                    attachments: [],
                    onEvent: { event in
                        events.append(event)
                        switch event {
                        case .toolCallStarted, .toolCallCompleted:
                            toolEvents.withLock { $0 += 1 }
                        default:
                            break
                        }
                    }
                )
                Issue.record("Expected the incomplete prompt response to fail.")
            } catch let error as RemoteGenerationClientError {
                guard case let .remoteFailure(message) = error else {
                    Issue.record("Unexpected provider error: \(error)")
                    return
                }
                #expect(message == "Anthropic streaming response ended before message_stop.")
            }
            let after = try #require(await client.snapshotSession(id: sessionID))
            #expect(after.history.count == before.history.count + 1)
            #expect(after.history.filter { $0.role == .assistant }.map(\.content) == ["previous answer"])
            #expect(after.history.last?.role == .user)
            #expect(after.history.last?.content == "new request")
            #expect(after.history.contains { $0.role == .tool } == false)
            #expect(toolEvents.withLock { $0 } == 0)
            #expect(fixture.capturedRequests().count == 1)
            if response == Self.partialTextResponse {
                // Live deltas may already be visible; only a complete message
                // is allowed into the reusable conversation history.
                #expect(events.contentText() == "Partial reply")
            }
            await client.shutdown()
        }
    }

    @Test("prompt commits assistant text when message_stop is present")
    func promptCommitsCompleteStream() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("anthropic-complete-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try await AppStorageDirectory.withSupportDirectoryURL(directory) {
            try AgentSettingsManifestStore.save(AgentSettingsManifest(
                models: [],
                anthropicSubscriptionCredentials: credentials()
            ))
            let response = Self.partialTextResponse + "data: {\"type\":\"message_stop\"}\n\n"
            let fixture = try await RemoteNIOStreamingFixture.start(responseBody: Data(response.utf8))
            defer { fixture.beginShutdown() }
            let client = makeClient(fixture: fixture)
            let result = try await client.sendPrompt(
                sessionID: "complete-prompt",
                prompt: "new request",
                attachments: [],
                onEvent: { _ in }
            )
            let snapshot = try #require(await client.snapshotSession(id: "complete-prompt"))
            #expect(result.text == "Partial reply")
            #expect(result.stopReason == "end_turn")
            #expect(snapshot.history.last?.role == .assistant)
            #expect(snapshot.history.last?.content == "Partial reply")
            #expect(fixture.capturedRequests().count == 1)
            await client.shutdown()
        }
    }

    private static let partialTextResponse = """
    data: {"type":"content_block_start","index":0,"content_block":{"type":"text","text":"Partial reply"}}

    data: {"type":"message_delta","delta":{"stop_reason":"end_turn"}}


    """

    private static let toolResponse = #"""
    data: {"type":"content_block_start","index":0,"content_block":{"type":"tool_use","id":"tool_incomplete","name":"local_writeFile","input":{}}}

    data: {"type":"content_block_delta","index":0,"delta":{"type":"input_json_delta","partial_json":"{\"path\":\"/tmp/should-not-be-written\",\"content\":\"incomplete\"}"}}

    data: {"type":"content_block_stop","index":0}

    data: {"type":"message_delta","delta":{"stop_reason":"tool_use"}}


    """#

    private func makeClient(
        fixture: RemoteNIOStreamingFixture,
        configuredContextWindowLimit: Int? = nil,
        maxOutputTokens: Int? = nil
    ) -> AnthropicSubscriptionGenerationClient {
        AnthropicSubscriptionGenerationClient(
            configuration: AgentRuntimeConfiguration(
                modelID: "claude-haiku-4-5",
                workingDirectory: URL(fileURLWithPath: "/tmp/project", isDirectory: true),
                configuredContextWindowLimit: configuredContextWindowLimit,
                maxToolRounds: 4,
                maxOutputTokens: maxOutputTokens,
                toolAuthorizationHandler: nil
            ),
            provider: AgentRemoteProvider(
                name: "Anthropic Subscription",
                baseURL: AgentRemoteProvider.anthropicSubscriptionBaseURL,
                modelID: "claude-haiku-4-5",
                chatEndpoint: .responses
            ),
            transport: fixture.transport,
            messagesEndpointURLOverride: fixture.messagesURL
        )
    }

    /// Creates the fixture session inside the actor and returns its lease.
    /// Streaming addresses the session through the actor, so a preflight
    /// compaction is persisted where the next round will read it.
    private func installedLease(
        in client: AnthropicSubscriptionGenerationClient
    ) async throws -> AnthropicSubscriptionGenerationClient.SessionLease {
        let sessionID = "anthropic-nio-session"
        await client.createSession(
            id: sessionID,
            cwd: "/tmp/project",
            history: [AgentRuntimeMessage(role: .user, content: "hello")],
            allowedToolNames: []
        )
        return try #require(await client.sessionLease(for: sessionID))
    }

    private func credentials() -> AnthropicSubscriptionCredentials {
        AnthropicSubscriptionCredentials(
            accessToken: "access-token",
            refreshToken: "refresh-token",
            expiresAt: Date().addingTimeInterval(3_600)
        )
    }

    private func headerValue(
        _ name: String,
        in request: CapturedRemoteRequest
    ) -> String? {
        request.headerEntries.first {
            $0.name.caseInsensitiveCompare(name) == .orderedSame
        }?.value
    }
}
