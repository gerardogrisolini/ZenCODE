//
//  RemoteSessionSnapshotTests.swift
//  ZenCODE
//
//  Created by Gerardo Grisolini on 30/05/26.
//

import Foundation
import NIOCore
import NIOHTTP1
import NIOPosix
import Synchronization
@testable import ZenCODECore
import Testing

extension RemoteSessionSnapshotTests {
    func remoteHistory() -> [AgentRuntimeMessage] {
        [
            AgentRuntimeMessage(role: .user, content: "run pwd"),
            AgentRuntimeMessage(
                role: .assistant,
                content: "",
                toolCalls: [
                    AgentRuntimeToolCall(
                        id: "call_1",
                        name: "local.exec",
                        argumentsJSON: #"{"command":"pwd"}"#
                    )
                ]
            ),
            AgentRuntimeMessage(
                role: .tool,
                content: "/tmp/project",
                toolCallID: "call_1",
                toolName: "local.exec"
            ),
            AgentRuntimeMessage(role: .assistant, content: "Done.")
        ]
    }

    func remoteXcodeHistoryMessages() -> [[String: Any]] {
        RemoteGenerationClient.initialMessages(
            cwd: "/tmp/project",
            systemPrompt: "System prompt",
            history: [
                AgentRuntimeMessage(role: .user, content: "build the app"),
                AgentRuntimeMessage(
                    role: .assistant,
                    content: "",
                    toolCalls: [
                        AgentRuntimeToolCall(
                            id: "call_previous_xcode",
                            name: "xcode.BuildProject",
                            argumentsJSON: #"{"scheme":"Previous"}"#
                        )
                    ]
                ),
                AgentRuntimeMessage(
                    role: .tool,
                    content: "Previous build succeeded.",
                    toolCallID: "call_previous_xcode",
                    toolName: "xcode.BuildProject"
                )
            ],
            allowedToolNames: ["xcode."]
        )
    }

    func remoteStreamingConfiguration() -> AgentRuntimeConfiguration {
        AgentRuntimeConfiguration(
            modelID: "unit-model",
            bearerToken: nil,
            workingDirectory: URL(fileURLWithPath: "/tmp/project", isDirectory: true),
            maxToolRounds: 4,
            verboseLogging: false,
            toolAuthorizationHandler: nil
        )
    }

    func borrowedXcodeMCPRuntime() async -> DirectMCPToolRuntime {
        let mcpRuntime = DirectMCPToolRuntime()
        let xcodeExecutor = XcodeToolExecutor(
            configuration: MCPServerConfiguration(
                executablePath: "/usr/bin/false",
                arguments: [],
                environment: [:]
            )
        )
        await mcpRuntime.installBorrowedXcodeExecutor(
            xcodeExecutor,
            tools: [
                ToolDescriptor(
                    name: "BuildProject",
                    description: "Builds an Xcode project.",
                    inputSchema: #"{"type":"object","properties":{"scheme":{"type":"string"}}}"#
                )
            ]
        )
        return mcpRuntime
    }
#if os(macOS)
    func remoteXcodeToolCatalog() -> RemoteToolWireCatalog {
        RemoteToolWireCatalog(
            descriptors: [
                DirectToolDescriptor(
                    name: "local.exec",
                    description: "Run a shell command.",
                    inputSchema: #"{"type":"object","properties":{"command":{"type":"string"}},"required":["command"]}"#
                ),
                DirectToolDescriptor(
                    name: "xcode.BuildProject",
                    description: "Builds an Xcode project.",
                    inputSchema: #"{"type":"object","properties":{"scheme":{"type":"string"}}}"#
                )
            ]
        )
    }

    func chatGPTSubscriptionTestCredentials() -> CodexAgentCredentials {
        CodexAgentCredentials(
            accessToken: "test-access-token",
            refreshToken: "test-refresh-token",
            expiresAt: Date().addingTimeInterval(3600),
            accountID: "test-account"
        )
    }

    func subscriptionToolCalls(
        from objects: [[String: Any]]
    ) throws -> [DirectAgentToolCall] {
        var accumulator = RemoteToolCallAccumulator()
        for object in objects {
            for event in ResponsesStreamParser.parse(object) {
                switch event {
                case let .responseToolCallItem(item, outputIndex):
                    accumulator.ingestResponseToolCallItem(item, outputIndex: outputIndex)
                case let .responseToolCallArgumentsDelta(event):
                    accumulator.ingestResponseToolCallArgumentsDelta(event)
                case let .responseToolCallArgumentsDone(event):
                    accumulator.ingestResponseToolCallArgumentsDone(event)
                default:
                    continue
                }
            }
        }
        return try accumulator.finalize()
    }

    func chatGPTContinuationMessages() -> [[String: Any]] {
        [
            [
                "role": "system",
                "content": "System prompt"
            ],
            RemoteGenerationClient.remoteMessage(
                role: "user",
                content: "first prompt",
                attachments: []
            ),
            RemoteGenerationClient.remoteMessage(
                role: "assistant",
                content: "first answer",
                attachments: []
            ),
            RemoteGenerationClient.remoteMessage(
                role: "user",
                content: "second prompt",
                attachments: []
            )
        ]
    }

    func chatGPTContinuationMessagesWithToolOutput() -> [[String: Any]] {
        [
            [
                "role": "system",
                "content": "System prompt"
            ],
            RemoteGenerationClient.remoteMessage(
                role: "user",
                content: "update the journal",
                attachments: []
            ),
            [
                "role": "assistant",
                "content": "",
                "tool_calls": [
                    [
                        "id": "call_memory",
                        "type": "function",
                        "function": [
                            "name": "memory_write",
                            "arguments": #"{"entry":"Updated journal."}"#
                        ]
                    ]
                ]
            ],
            [
                "role": "tool",
                "tool_call_id": "call_memory",
                "name": "memory_write",
                "content": "Saved memory entry to project MEMORY.md."
            ]
        ]
    }

    func chatGPTPreflightCompactionMessages() -> [[String: Any]] {
        var messages: [[String: Any]] = [
            [
                "role": "system",
                "content": "System prompt"
            ]
        ]
        for index in 0..<6 {
            let role = index.isMultiple(of: 2) ? "user" : "assistant"
            messages.append(
                RemoteGenerationClient.remoteMessage(
                    role: role,
                    content: "brief message \(index) " + String(repeating: "detail ", count: 20),
                    attachments: []
                )
            )
        }
        return messages
    }

    func chatGPTCompactionMessages() -> [[String: Any]] {
        var messages: [[String: Any]] = [
            [
                "role": "system",
                "content": "System prompt"
            ]
        ]
        for index in 0..<18 {
            messages.append(
                RemoteGenerationClient.remoteMessage(
                    role: "user",
                    content: "request \(index) " + String(repeating: "u", count: 1_800),
                    attachments: []
                )
            )
            messages.append(
                RemoteGenerationClient.remoteMessage(
                    role: "assistant",
                    content: "answer \(index) " + String(repeating: "a", count: 1_800),
                    attachments: []
                )
            )
        }
        return messages
    }
#endif
}

final class CapturedDirectAgentEvents: Sendable {
    private let events = Mutex<[DirectAgentEvent]>([])

    func append(_ event: DirectAgentEvent) {
        events.withLock { events in
            events.append(event)
        }
    }

    func contentText() -> String {
        lockedEvents().reduce(into: "") { text, event in
            if case let .content(delta) = event {
                text += delta
            }
        }
    }

    func thoughtText() -> String {
        lockedEvents().reduce(into: "") { text, event in
            if case let .thought(delta) = event {
                text += delta
            }
        }
    }

    func subscriptionUsage() -> [DirectAgentSubscriptionUsageStatus] {
        lockedEvents().compactMap { event in
            guard case let .subscriptionUsage(status) = event else {
                return nil
            }
            return status
        }
    }

    private func lockedEvents() -> [DirectAgentEvent] {
        events.withLock { events in
            events
        }
    }
}

/// Captures loosely typed JSON dictionaries from subscription events; access is protected by `lock`.
final class CapturedSubscriptionEvents: @unchecked Sendable {
    private let lock = NSLock()
    private var objects: [[String: Any]] = []

    func append(_ object: [String: Any]) {
        lock.lock()
        objects.append(object)
        lock.unlock()
    }

    func all() -> [[String: Any]] {
        lock.lock()
        defer { lock.unlock() }
        return objects
    }
}

struct CapturedRemoteRequest: Sendable {
    let request: URLRequest
    let body: Data
    let headerEntries: [RemoteHTTPHeader]

    init(
        request: URLRequest,
        body: Data,
        headerEntries: [RemoteHTTPHeader]? = nil
    ) {
        self.request = request
        self.body = body
        self.headerEntries = headerEntries ?? (request.allHTTPHeaderFields ?? [:])
            .map { RemoteHTTPHeader(name: $0.key, value: $0.value) }
    }

    func jsonObject() throws -> [String: Any] {
        let value = try JSONDecoder().decode(JSONValue.self, from: body)
        return try #require(value.objectValue).mapValues(\.jsonObject)
    }
}

/// URLProtocol subclasses are invoked by URLSession across threads; static test state is protected by `lock`.
final class RemoteRequestCapturingURLProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) private static var responseBody = Data()
    nonisolated(unsafe) private static var failuresBeforeResponse: [URLError.Code] = []
    nonisolated(unsafe) private static var failureAfterResponse: URLError.Code?
    nonisolated(unsafe) private static var requests: [CapturedRemoteRequest] = []
    private static let lock = NSLock()

    static func urlSession(
        responseBody: Data,
        failuresBeforeResponse: [URLError.Code] = [],
        failureAfterResponse: URLError.Code? = nil
    ) -> URLSession {
        lock.lock()
        self.responseBody = responseBody
        self.failuresBeforeResponse = failuresBeforeResponse
        self.failureAfterResponse = failureAfterResponse
        requests = []
        lock.unlock()

        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [RemoteRequestCapturingURLProtocol.self]
        return URLSession(configuration: configuration)
    }

    static func capturedRequests() -> [CapturedRemoteRequest] {
        lock.lock()
        defer { lock.unlock() }
        return requests
    }

    override class func canInit(with request: URLRequest) -> Bool {
        true
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        let body = Self.bodyData(from: request) ?? Data()
        Self.lock.lock()
        Self.requests.append(CapturedRemoteRequest(request: request, body: body))
        let responseBody = Self.responseBody
        let failureCode = Self.failuresBeforeResponse.isEmpty
            ? nil
            : Self.failuresBeforeResponse.removeFirst()
        let failureAfterResponse = Self.failureAfterResponse
        Self.lock.unlock()

        if let failureCode {
            client?.urlProtocol(self, didFailWithError: URLError(failureCode))
            return
        }

        let response = HTTPURLResponse(
            url: request.url ?? URL(string: "https://unit.test")!,
            statusCode: 200,
            httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "text/event-stream"]
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: responseBody)
        if let failureAfterResponse {
            DispatchQueue.global().asyncAfter(deadline: .now() + .milliseconds(100)) { [self] in
                client?.urlProtocol(
                    self,
                    didFailWithError: URLError(failureAfterResponse)
                )
            }
        } else {
            client?.urlProtocolDidFinishLoading(self)
        }
    }

    override func stopLoading() {}

    private static func bodyData(from request: URLRequest) -> Data? {
        if let body = request.httpBody {
            return body
        }
        guard let stream = request.httpBodyStream else {
            return nil
        }

        stream.open()
        defer { stream.close() }

        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while stream.hasBytesAvailable {
            let read = stream.read(&buffer, maxLength: buffer.count)
            guard read > 0 else {
                break
            }
            data.append(buffer, count: read)
        }
        return data
    }
}


/// Deterministic loopback HTTP fixture for the NIO generation-provider tests.
///
/// This deliberately does not reuse `RemoteRequestCapturingURLProtocol`: the
/// provider clients must exercise `RemoteTransportCore` over a real NIO socket.
/// It retains full request-header order (including duplicates) alongside a
/// convenient `URLRequest` projection for existing payload assertions.
final class RemoteNIOStreamingFixture: @unchecked Sendable {
    let transport: RemoteTransportCore
    private let group: MultiThreadedEventLoopGroup
    private let channel: any Channel
    private let script: RemoteNIOStreamingScript

    private init(
        transport: RemoteTransportCore,
        group: MultiThreadedEventLoopGroup,
        channel: any Channel,
        script: RemoteNIOStreamingScript
    ) {
        self.transport = transport
        self.group = group
        self.channel = channel
        self.script = script
    }

    deinit {
        channel.close(promise: nil)
        group.shutdownGracefully(queue: .global()) { _ in }
    }

    static func start(
        responseBody: Data,
        responseStatus: Int = 200,
        responseHeaders: [RemoteHTTPHeader] = [
            RemoteHTTPHeader(name: "content-type", value: "text/event-stream")
        ],
        bodyChunks: [Data]? = nil,
        failuresBeforeHead: Int = 0,
        closeAfterHead: Bool = false
    ) async throws -> RemoteNIOStreamingFixture {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        let script = RemoteNIOStreamingScript(
            responseBody: responseBody,
            responseStatus: responseStatus,
            responseHeaders: responseHeaders,
            bodyChunks: bodyChunks,
            failuresBeforeHead: failuresBeforeHead,
            closeAfterHead: closeAfterHead
        )
        do {
            let channel = try await ServerBootstrap(group: group)
                .serverChannelOption(ChannelOptions.backlog, value: 16)
                .serverChannelOption(
                    ChannelOptions.socketOption(.so_reuseaddr),
                    value: 1
                )
                .childChannelOption(ChannelOptions.autoRead, value: true)
                .childChannelInitializer { channel in
                    channel.eventLoop.makeCompletedFuture {
                        try channel.pipeline.syncOperations.configureHTTPServerPipeline(
                            withPipeliningAssistance: false
                        )
                        try channel.pipeline.syncOperations.addHandler(
                            RemoteNIOStreamingRequestHandler(script: script)
                        )
                    }
                }
                .bind(host: "127.0.0.1", port: 0)
                .get()
            return RemoteNIOStreamingFixture(
                transport: RemoteTransportCore(),
                group: group,
                channel: channel,
                script: script
            )
        } catch {
            try? await group.shutdownGracefully()
            throw error
        }
    }

    var baseURL: URL {
        url(path: "/v1")
    }

    var messagesURL: URL {
        url(path: "/v1/messages")
    }

    func capturedRequests() -> [CapturedRemoteRequest] {
        script.capturedRequests()
    }

    func shutdown() async {
        _ = try? await channel.close().get()
        try? await group.shutdownGracefully()
    }

    private func url(path: String) -> URL {
        URL(string: "http://127.0.0.1:\(port)\(path)")!
    }

    private var port: Int {
        channel.localAddress!.port!
    }
}

private final class RemoteNIOStreamingScript: @unchecked Sendable {
    private let lock = NSLock()
    private let responseBody: Data
    private let responseStatus: Int
    private let responseHeaders: [RemoteHTTPHeader]
    private let bodyChunks: [Data]?
    private let closeAfterHead: Bool
    private var failuresBeforeHead: Int
    private var requests: [CapturedRemoteRequest] = []

    init(
        responseBody: Data,
        responseStatus: Int,
        responseHeaders: [RemoteHTTPHeader],
        bodyChunks: [Data]?,
        failuresBeforeHead: Int,
        closeAfterHead: Bool
    ) {
        self.responseBody = responseBody
        self.responseStatus = responseStatus
        self.responseHeaders = responseHeaders
        self.bodyChunks = bodyChunks
        self.failuresBeforeHead = max(0, failuresBeforeHead)
        self.closeAfterHead = closeAfterHead
    }

    func receive(
        head: HTTPRequestHead,
        body: Data
    ) -> RemoteNIOStreamingFixtureAction {
        let headerEntries = head.headers.map {
            RemoteHTTPHeader(name: $0.name, value: $0.value)
        }
        var request = URLRequest(
            url: URL(string: "http://fixture.invalid\(head.uri)")!
        )
        request.httpMethod = head.method.rawValue
        for header in headerEntries {
            request.addValue(header.value, forHTTPHeaderField: header.name)
        }
        request.httpBody = body

        lock.lock()
        requests.append(
            CapturedRemoteRequest(
                request: request,
                body: body,
                headerEntries: headerEntries
            )
        )
        if failuresBeforeHead > 0 {
            failuresBeforeHead -= 1
            lock.unlock()
            return .closeBeforeHead
        }
        let response = RemoteNIOStreamingFixtureResponse(
            status: responseStatus,
            headers: responseHeaders,
            bodyChunks: bodyChunks ?? [responseBody],
            closeAfterHead: closeAfterHead
        )
        lock.unlock()
        return .respond(response)
    }

    func capturedRequests() -> [CapturedRemoteRequest] {
        lock.lock()
        defer { lock.unlock() }
        return requests
    }
}

private enum RemoteNIOStreamingFixtureAction {
    case closeBeforeHead
    case respond(RemoteNIOStreamingFixtureResponse)
}

private struct RemoteNIOStreamingFixtureResponse {
    let status: Int
    let headers: [RemoteHTTPHeader]
    let bodyChunks: [Data]
    let closeAfterHead: Bool
}

private final class RemoteNIOStreamingRequestHandler:
    ChannelInboundHandler,
    @unchecked Sendable
{
    typealias InboundIn = HTTPServerRequestPart
    typealias OutboundOut = HTTPServerResponsePart

    private let script: RemoteNIOStreamingScript
    private var requestHead: HTTPRequestHead?
    private var requestBody: ByteBuffer?

    init(script: RemoteNIOStreamingScript) {
        self.script = script
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        switch Self.unwrapInboundIn(data) {
        case let .head(head):
            requestHead = head
            requestBody = context.channel.allocator.buffer(capacity: 0)
        case var .body(buffer):
            if var requestBody {
                requestBody.writeBuffer(&buffer)
                self.requestBody = requestBody
            }
        case .end:
            guard let requestHead else {
                context.close(promise: nil)
                return
            }
            let body = requestBody.map { Data($0.readableBytesView) } ?? Data()
            switch script.receive(head: requestHead, body: body) {
            case .closeBeforeHead:
                context.close(promise: nil)
            case let .respond(response):
                write(response: response, context: context)
            }
        }
    }

    private func write(
        response: RemoteNIOStreamingFixtureResponse,
        context: ChannelHandlerContext
    ) {
        var headers = HTTPHeaders()
        for header in response.headers {
            headers.add(name: header.name, value: header.value)
        }
        if response.closeAfterHead, headers["content-length"].isEmpty {
            let advertisedLength = response.bodyChunks.reduce(0) { partial, chunk in
                partial + chunk.count
            } + 1
            headers.add(name: "content-length", value: String(advertisedLength))
        }
        context.write(
            Self.wrapOutboundOut(
                .head(
                    HTTPResponseHead(
                        version: .http1_1,
                        status: HTTPResponseStatus(statusCode: response.status),
                        headers: headers
                    )
                )
            ),
            promise: nil
        )
        for chunk in response.bodyChunks where !chunk.isEmpty {
            var buffer = context.channel.allocator.buffer(capacity: chunk.count)
            buffer.writeBytes(chunk)
            context.write(
                Self.wrapOutboundOut(.body(.byteBuffer(buffer))),
                promise: nil
            )
        }
        if response.closeAfterHead {
            context.flush()
            context.close(promise: nil)
        } else {
            context.writeAndFlush(Self.wrapOutboundOut(.end(nil)), promise: nil)
        }
    }
}
