//
//  RemoteSessionSnapshotTests.swift
//  ZenCODE
//
//  Created by Gerardo Grisolini on 30/05/26.
//
import Foundation
import os
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
            for event in RemoteGenerationClient.parseResponsesStreamEvent(object) {
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
    private let events = OSAllocatedUnfairLock<[DirectAgentEvent]>(initialState: [])

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

    func jsonObject() throws -> [String: Any] {
        let value = try JSONDecoder().decode(JSONValue.self, from: body)
        return try #require(value.mlxObjectValue).mapValues(\.jsonObject)
    }
}

/// URLProtocol subclasses are invoked by URLSession across threads; static test state is protected by `lock`.
final class RemoteRequestCapturingURLProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) private static var responseBody = Data()
    nonisolated(unsafe) private static var requests: [CapturedRemoteRequest] = []
    private static let lock = NSLock()

    static func urlSession(responseBody: Data) -> URLSession {
        lock.lock()
        self.responseBody = responseBody
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
        Self.lock.unlock()

        let response = HTTPURLResponse(
            url: request.url ?? URL(string: "https://unit.test")!,
            statusCode: 200,
            httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "text/event-stream"]
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: responseBody)
        client?.urlProtocolDidFinishLoading(self)
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
