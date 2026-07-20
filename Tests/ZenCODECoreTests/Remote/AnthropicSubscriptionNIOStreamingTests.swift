//
//  AnthropicSubscriptionNIOStreamingTests.swift
//  ZenCODECoreTests
//
//  Provider-level NIO fixtures for Anthropic messages streaming.
//

import Foundation
@testable import ZenCODECore
import Testing

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
        let client = makeClient(fixture: fixture)
        var session = makeSession()
        let events = CapturedDirectAgentEvents()

        let result = try await client.streamAnthropicMessages(
            session: &session,
            modelID: "claude-haiku-4-5",
            modelLLMID: "claude-haiku-4-5",
            credentials: credentials(),
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
        let client = makeClient(fixture: fixture)
        var session = makeSession()

        do {
            _ = try await client.streamAnthropicMessages(
                session: &session,
                modelID: "claude-haiku-4-5",
                modelLLMID: "claude-haiku-4-5",
                credentials: credentials(),
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
        let client = makeClient(fixture: fixture)
        var session = makeSession()

        do {
            _ = try await client.streamAnthropicMessages(
                session: &session,
                modelID: "claude-haiku-4-5",
                modelLLMID: "claude-haiku-4-5",
                credentials: credentials(),
                onEvent: { _ in }
            )
            Issue.record("Expected the pre-head close to propagate without replay.")
        } catch {
            #expect(error is RemoteTransportError)
        }

        #expect(fixture.capturedRequests().count == 1)
    }

    private func makeClient(
        fixture: RemoteNIOStreamingFixture
    ) -> AnthropicSubscriptionGenerationClient {
        AnthropicSubscriptionGenerationClient(
            configuration: AgentRuntimeConfiguration(
                modelID: "claude-haiku-4-5",
                bearerToken: nil,
                workingDirectory: URL(fileURLWithPath: "/tmp/project", isDirectory: true),
                maxToolRounds: 4,
                verboseLogging: false,
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

    private func makeSession() -> AnthropicSubscriptionGenerationClient.AgentSession {
        AnthropicSubscriptionGenerationClient.AgentSession(
            id: "anthropic-nio-session",
            cwd: URL(fileURLWithPath: "/tmp/project", isDirectory: true),
            systemPrompt: nil,
            cacheKey: nil,
            allowedToolNames: [],
            thinkingSelection: nil,
            preserveThinking: false,
            messages: [["role": "user", "content": "hello"]]
        )
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
