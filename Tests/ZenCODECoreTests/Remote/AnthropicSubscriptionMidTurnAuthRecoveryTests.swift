//
//  AnthropicSubscriptionMidTurnAuthRecoveryTests.swift
//  ZenCODECoreTests
//
//  Mid-turn credential reload and one-shot 401/403 refresh recovery for the
//  Anthropic subscription prompt loop.
//

import Foundation
import NIOCore
import NIOHTTP1
import NIOPosix
import Synchronization
import Testing
@testable import ZenCODECore

@Suite("Anthropic Subscription mid-turn auth recovery", .serialized)
struct AnthropicSubscriptionMidTurnAuthRecoveryTests {
    private static let textResponse = """
    data: {"type":"message_start","message":{"usage":{"input_tokens":3,"output_tokens":0}}}

    data: {"type":"content_block_start","index":0,"content_block":{"type":"text","text":"Recovered"}}

    data: {"type":"message_delta","delta":{"stop_reason":"end_turn"},"usage":{"output_tokens":1}}

    data: {"type":"message_stop"}


    """

    private static let toolResponse = #"""
    data: {"type":"content_block_start","index":0,"content_block":{"type":"tool_use","id":"tool_1","name":"zencode_test_missing_tool","input":{}}}

    data: {"type":"content_block_delta","index":0,"delta":{"type":"input_json_delta","partial_json":"{\"path\":\"/tmp/none\"}"}}

    data: {"type":"content_block_stop","index":0}

    data: {"type":"message_delta","delta":{"stop_reason":"tool_use"}}

    data: {"type":"message_stop"}


    """#

    private static let unauthorizedBody = #"{"type":"error","error":{"type":"authentication_error","message":"OAuth token has expired."}}"#

    @Test("a 401 on the first round refreshes once and replays the same round", arguments: [401, 403])
    func authFailureRefreshesAndReplaysRound(status: Int) async throws {
        let server = try await StatusSequenceServer.start(responses: [
            (status, Self.unauthorizedBody),
            (200, Self.textResponse)
        ])
        defer { server.shutdown() }
        let refreshes = Mutex(0)
        let client = makeClient(server: server)
        await client.setCredentialProviders(
            load: { Self.credentials("stale-access") },
            refresh: { credentials in
                #expect(credentials.accessToken == "stale-access")
                refreshes.withLock { $0 += 1 }
                return Self.credentials("fresh-access")
            }
        )
        let events = CapturedDirectAgentEvents()

        let result = try await client.sendPrompt(
            sessionID: "auth-recovery",
            prompt: "hello",
            attachments: [],
            onEvent: { events.append($0) }
        )

        #expect(result.text == "Recovered")
        #expect(refreshes.withLock { $0 } == 1)
        #expect(server.authorizations() == ["Bearer stale-access", "Bearer fresh-access"])
        #expect(events.diagnostics().contains(
            AnthropicSubscriptionGenerationClient.authRefreshDiagnostic()
        ))
        let snapshot = try #require(await client.snapshotSession(id: "auth-recovery"))
        // Exactly one user prompt and one assistant reply: the failed attempt
        // committed nothing, so the replay does not duplicate history.
        #expect(snapshot.history.map(\.role) == [.user, .assistant])
        #expect(snapshot.history.filter { $0.role == .user }.map(\.content) == ["hello"])
        #expect(snapshot.history.last?.content == "Recovered")
        await client.shutdown()
    }

    @Test("a second 401 after the refresh fails without further retries")
    func secondAuthFailureIsNotRetried() async throws {
        let server = try await StatusSequenceServer.start(responses: [
            (401, Self.unauthorizedBody),
            (401, Self.unauthorizedBody),
            (200, Self.textResponse)
        ])
        defer { server.shutdown() }
        let refreshes = Mutex(0)
        let client = makeClient(server: server)
        await client.setCredentialProviders(
            load: { Self.credentials("stale-access") },
            refresh: { _ in
                refreshes.withLock { $0 += 1 }
                return Self.credentials("fresh-access")
            }
        )

        do {
            _ = try await client.sendPrompt(
                sessionID: "auth-recovery-twice",
                prompt: "hello",
                attachments: [],
                onEvent: { _ in }
            )
            Issue.record("Expected the second 401 to fail the turn.")
        } catch let error as RemoteGenerationClientError {
            guard case let .remoteFailure(message) = error else {
                Issue.record("Unexpected provider error: \(error)")
                return
            }
            #expect(message.contains("HTTP 401"))
            #expect(message.contains("Sign in to Anthropic Subscription again"))
        }

        #expect(refreshes.withLock { $0 } == 1)
        #expect(server.authorizations() == ["Bearer stale-access", "Bearer fresh-access"])
        let snapshot = try #require(await client.snapshotSession(id: "auth-recovery-twice"))
        #expect(snapshot.history.map(\.role) == [.user])
        await client.shutdown()
    }

    @Test("a failed refresh surfaces a sign-in error without replaying the request")
    func failedRefreshIsSurfacedOnce() async throws {
        let server = try await StatusSequenceServer.start(responses: [
            (401, Self.unauthorizedBody),
            (200, Self.textResponse)
        ])
        defer { server.shutdown() }
        let refreshes = Mutex(0)
        let client = makeClient(server: server)
        await client.setCredentialProviders(
            load: { Self.credentials("stale-access") },
            refresh: { _ in
                refreshes.withLock { $0 += 1 }
                throw URLError(.notConnectedToInternet)
            }
        )

        do {
            _ = try await client.sendPrompt(
                sessionID: "auth-refresh-failure",
                prompt: "hello",
                attachments: [],
                onEvent: { _ in }
            )
            Issue.record("Expected the refresh failure to fail the turn.")
        } catch let error as RemoteGenerationClientError {
            guard case let .remoteFailure(message) = error else {
                Issue.record("Unexpected provider error: \(error)")
                return
            }
            #expect(message.contains("HTTP 401"))
            #expect(message.contains("Refreshing the access token failed"))
            #expect(message.contains("Sign in to Anthropic Subscription again"))
        }

        #expect(refreshes.withLock { $0 } == 1)
        #expect(server.authorizations() == ["Bearer stale-access"])
        await client.shutdown()
    }

    @Test("a rejected refresh token propagates the typed sign-in error")
    func rejectedRefreshTokenPropagatesTypedError() async throws {
        let server = try await StatusSequenceServer.start(responses: [
            (401, Self.unauthorizedBody)
        ])
        defer { server.shutdown() }
        let client = makeClient(server: server)
        await client.setCredentialProviders(
            load: { Self.credentials("stale-access") },
            refresh: { _ in throw AnthropicSubscriptionAuthError.refreshTokenRejected }
        )

        await #expect(throws: AnthropicSubscriptionAuthError.self) {
            _ = try await client.sendPrompt(
                sessionID: "auth-refresh-rejected",
                prompt: "hello",
                attachments: [],
                onEvent: { _ in }
            )
        }
        #expect(server.authorizations().count == 1)
        await client.shutdown()
    }

    @Test("credentials are reloaded at the start of every tool round")
    func credentialsAreReloadedEveryRound() async throws {
        let server = try await StatusSequenceServer.start(responses: [
            (200, Self.toolResponse),
            (200, Self.textResponse)
        ])
        defer { server.shutdown() }
        let loads = Mutex(0)
        let client = makeClient(server: server)
        await client.setCredentialProviders(
            load: {
                let count = loads.withLock { value in
                    value += 1
                    return value
                }
                return Self.credentials("access-\(count)")
            },
            refresh: { _ in
                Issue.record("No forced refresh expected without an auth failure.")
                return Self.credentials("unexpected")
            }
        )

        let result = try await client.sendPrompt(
            sessionID: "auth-reload",
            prompt: "hello",
            attachments: [],
            onEvent: { _ in }
        )

        #expect(result.text == "Recovered")
        #expect(loads.withLock { $0 } == 2)
        #expect(server.authorizations() == ["Bearer access-1", "Bearer access-2"])
        await client.shutdown()
    }

    @Test("only 401 and 403 provider failures are authentication failures")
    func authenticationFailureClassification() {
        let prefix = AnthropicSubscriptionGenerationClient.httpFailureMessagePrefix
        func failure(_ text: String) -> Error {
            RemoteGenerationClientError.remoteFailure(text)
        }
        #expect(AnthropicSubscriptionGenerationClient.isAuthenticationFailure(failure("\(prefix)401: expired")))
        #expect(AnthropicSubscriptionGenerationClient.isAuthenticationFailure(failure("\(prefix)403")))
        #expect(!AnthropicSubscriptionGenerationClient.isAuthenticationFailure(failure("\(prefix)429: slow down")))
        #expect(!AnthropicSubscriptionGenerationClient.isAuthenticationFailure(failure("\(prefix)500")))
        #expect(!AnthropicSubscriptionGenerationClient.isAuthenticationFailure(failure("tool said HTTP 401")))
        #expect(!AnthropicSubscriptionGenerationClient.isAuthenticationFailure(URLError(.userAuthenticationRequired)))
    }

    @Test
    func anthropicClientCarriesTheProfileRoleIntoToolExecutionContext() async {
        let client = AnthropicSubscriptionGenerationClient(
            configuration: AgentRuntimeConfiguration(
                modelID: "claude-haiku-4-5",
                workingDirectory: URL(fileURLWithPath: "/tmp/project", isDirectory: true),
                maxToolRounds: 4,
                toolAuthorizationHandler: nil,
                profileRole: .organizer
            ),
            provider: AgentRemoteProvider(
                name: "Anthropic Subscription",
                baseURL: AgentRemoteProvider.anthropicSubscriptionBaseURL,
                modelID: "claude-haiku-4-5",
                chatEndpoint: .responses
            )
        )

        #expect(await client.toolExecutor.toolExecutionContext.profileRole == .organizer)
        await client.shutdown()
    }

    private static func credentials(_ accessToken: String) -> AnthropicSubscriptionCredentials {
        AnthropicSubscriptionCredentials(
            accessToken: accessToken,
            refreshToken: "refresh-token",
            expiresAt: Date().addingTimeInterval(3_600)
        )
    }

    private func makeClient(server: StatusSequenceServer) -> AnthropicSubscriptionGenerationClient {
        AnthropicSubscriptionGenerationClient(
            configuration: AgentRuntimeConfiguration(
                modelID: "claude-haiku-4-5",
                workingDirectory: URL(fileURLWithPath: "/tmp/project", isDirectory: true),
                maxToolRounds: 4,
                toolAuthorizationHandler: nil
            ),
            provider: AgentRemoteProvider(
                name: "Anthropic Subscription",
                baseURL: AgentRemoteProvider.anthropicSubscriptionBaseURL,
                modelID: "claude-haiku-4-5",
                chatEndpoint: .responses
            ),
            transport: server.transport,
            messagesEndpointURLOverride: server.messagesURL
        )
    }
}

/// Minimal loopback HTTP server answering each request with the next scripted
/// (status, body) pair and recording the `Authorization` header it received.
private final class StatusSequenceServer: Sendable {
    let transport = RemoteTransportCore()
    private let group: MultiThreadedEventLoopGroup
    private let channel: any Channel
    private let script: Script

    private init(group: MultiThreadedEventLoopGroup, channel: any Channel, script: Script) {
        self.group = group
        self.channel = channel
        self.script = script
    }

    static func start(responses: [(Int, String)]) async throws -> StatusSequenceServer {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        let script = Script(responses: responses)
        do {
            let channel = try await ServerBootstrap(group: group)
                .serverChannelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
                .childChannelInitializer { channel in
                    channel.eventLoop.makeCompletedFuture {
                        try channel.pipeline.syncOperations.configureHTTPServerPipeline(
                            withPipeliningAssistance: false
                        )
                        try channel.pipeline.syncOperations.addHandler(Handler(script: script))
                    }
                }
                .bind(host: "127.0.0.1", port: 0)
                .get()
            return StatusSequenceServer(group: group, channel: channel, script: script)
        } catch {
            try? await group.shutdownGracefully()
            throw error
        }
    }

    var messagesURL: URL {
        URL(string: "http://127.0.0.1:\(channel.localAddress!.port!)/v1/messages")!
    }

    func authorizations() -> [String] {
        script.authorizations.withLock { $0 }
    }

    func shutdown() {
        channel.close(promise: nil)
        group.shutdownGracefully(queue: .global()) { _ in }
    }

    final class Script: Sendable {
        let responses: Mutex<[(Int, String)]>
        let authorizations = Mutex<[String]>([])

        init(responses: [(Int, String)]) {
            self.responses = Mutex(responses)
        }

        func next(authorization: String) -> (Int, String) {
            authorizations.withLock { $0.append(authorization) }
            return responses.withLock { queue in
                queue.isEmpty ? (500, "unexpected request") : queue.removeFirst()
            }
        }
    }

    final class Handler: ChannelInboundHandler, @unchecked Sendable {
        typealias InboundIn = HTTPServerRequestPart
        typealias OutboundOut = HTTPServerResponsePart

        private let script: Script
        private var head: HTTPRequestHead?

        init(script: Script) {
            self.script = script
        }

        func channelRead(context: ChannelHandlerContext, data: NIOAny) {
            switch Self.unwrapInboundIn(data) {
            case let .head(head):
                self.head = head
            case .body:
                break
            case .end:
                let authorization = head?.headers["authorization"].first ?? ""
                let (status, body) = script.next(authorization: authorization)
                var headers = HTTPHeaders()
                headers.add(
                    name: "content-type",
                    value: status == 200 ? "text/event-stream" : "application/json"
                )
                headers.add(name: "content-length", value: String(body.utf8.count))
                context.write(
                    Self.wrapOutboundOut(.head(HTTPResponseHead(
                        version: .http1_1,
                        status: HTTPResponseStatus(statusCode: status),
                        headers: headers
                    ))),
                    promise: nil
                )
                var buffer = context.channel.allocator.buffer(capacity: body.utf8.count)
                buffer.writeString(body)
                context.write(Self.wrapOutboundOut(.body(.byteBuffer(buffer))), promise: nil)
                context.writeAndFlush(Self.wrapOutboundOut(.end(nil)), promise: nil)
            }
        }
    }
}
