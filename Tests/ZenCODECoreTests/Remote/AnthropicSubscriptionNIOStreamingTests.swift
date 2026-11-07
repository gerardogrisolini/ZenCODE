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
