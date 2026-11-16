//
//  RemoteSessionSnapshotTests.swift
//  ZenCODE
//
//  Created by Gerardo Grisolini on 30/05/26.
//

import FeatureMCPBridgeKit
import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import NIOCore
import NIOHTTP1
import NIOPosix
import Synchronization
@testable import ZenCODECore
import Testing
import ToolCore

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

    func remoteFeatureHistoryMessages() -> [[String: Any]] {
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
                            id: "call_previous_fixture",
                            name: "fixture.Build",
                            argumentsJSON: #"{"scheme":"Previous"}"#
                        )
                    ]
                ),
                AgentRuntimeMessage(
                    role: .tool,
                    content: "Previous build succeeded.",
                    toolCallID: "call_previous_fixture",
                    toolName: "fixture.Build"
                )
            ],
            allowedToolNames: ["fixture."]
        )
    }

    func remoteStreamingConfiguration() -> AgentRuntimeConfiguration {
        AgentRuntimeConfiguration(
            modelID: "unit-model",
            workingDirectory: URL(fileURLWithPath: "/tmp/project", isDirectory: true),
            maxToolRounds: 4,
            toolAuthorizationHandler: nil
        )
    }

    func borrowedFeatureMCPRuntime() async -> DirectMCPToolRuntime {
        let mcpRuntime = DirectMCPToolRuntime()
        let executor = RemoteMCPToolExecutor(
            configuration: MCPServerConfiguration(
                executablePath: "/usr/bin/false",
                arguments: [],
                environment: [:]
            ),
            toolNamePrefix: "fixture."
        )
        _ = await mcpRuntime.installBorrowedExternalExecutor(
            name: "fixture",
            executor: executor,
            tools: [
                ToolDescriptor(
                    name: "Build",
                    description: "Builds a fixture project.",
                    inputSchema: #"{"type":"object","properties":{"scheme":{"type":"string"}}}"#
                )
            ]
        )
        return mcpRuntime
    }
    func remoteFeatureToolCatalog() -> RemoteToolWireCatalog {
        RemoteToolWireCatalog(
            descriptors: [
                DirectToolDescriptor(
                    name: "local.exec",
                    description: "Run a shell command.",
                    inputSchema: #"{"type":"object","properties":{"command":{"type":"string"}},"required":["command"]}"#
                ),
                DirectToolDescriptor(
                    name: "fixture.Build",
                    description: "Builds a fixture project.",
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
                "content": "Saved memory entry to the project graph."
            ]
        ]
    }

    /// A conversation large enough that compacting it genuinely reclaims
    /// context, used together with an oversized tool catalogue to exercise the
    /// overhead-aware preflight.
    func preflightCompactionHistory() -> [AgentRuntimeMessage] {
        (0..<120).map { index in
            AgentRuntimeMessage(
                role: index.isMultiple(of: 2) ? .user : .assistant,
                content: "brief message \(index) " + String(repeating: "detail ", count: 30)
            )
        }
    }

    /// The same conversation in provider wire form, prefixed by the system
    /// message the client would install.
    func chatGPTPreflightCompactionMessages() -> [[String: Any]] {
        var messages: [[String: Any]] = [
            [
                "role": "system",
                "content": "System prompt"
            ]
        ]
        for message in preflightCompactionHistory() {
            messages.append(
                RemoteGenerationClient.remoteMessage(
                    role: message.role.rawValue,
                    content: message.content,
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

    func diagnostics() -> [String] {
        lockedEvents().compactMap { event in
            guard case let .diagnostic(message) = event else {
                return nil
            }
            return message
        }
    }

    private func lockedEvents() -> [DirectAgentEvent] {
        events.withLock { events in
            events
        }
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
