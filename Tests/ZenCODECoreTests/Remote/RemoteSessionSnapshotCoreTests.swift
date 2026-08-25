//
//  RemoteSessionSnapshotTests.swift
//  ZenCODE
//
//  Created by Gerardo Grisolini on 30/05/26.
//

import Foundation
#if canImport(CryptoKit)
import CryptoKit
#endif
@testable import ZenCODECore
import Testing
import ToolCore

extension RemoteSessionSnapshotTests {
    @Test
    func remoteToolCatalogRenderingIsByteStable() throws {
        let descriptors = [
            DirectToolDescriptor(
                name: "tool.beta",
                description: "Beta tool.",
                inputSchema: #"{"required":["path"],"properties":{"path":{"description":"Path","type":"string"}},"type":"object"}"#
            ),
            DirectToolDescriptor(
                name: "tool.alpha",
                description: "Alpha tool.",
                inputSchema: #"{"type":"object","properties":{"count":{"minimum":1,"type":"integer"},"query":{"type":"string"}},"required":["query"]}"#
            )
        ]
        let first = RemoteToolWireCatalog(descriptors: descriptors)
        let second = RemoteToolWireCatalog(descriptors: Array(descriptors.reversed()))
        let firstData = try JSONValue.acpValue(from: first.responsesToolPayloads).jsonData()
        let secondData = try JSONValue.acpValue(from: second.responsesToolPayloads).jsonData()

        #expect(firstData == secondData)
        #if canImport(CryptoKit)
        #expect(SHA256.hash(data: firstData) == SHA256.hash(data: secondData))
        #endif
    }

    @Test
    func remoteInitialMessagesRoundTripToolTranscript() {
        let history = remoteHistory()
        let messages = RemoteGenerationClient.initialMessages(
            cwd: "/tmp/project",
            systemPrompt: "System prompt",
            history: history,
            allowedToolNames: ["local.exec"]
        )
        let snapshot = RemoteGenerationClient.snapshotMessages(from: messages)

        #expect(snapshot.systemPrompt == "System prompt")
        #expect(snapshot.history == history)
    }

    @Test
    func remoteInitialMessagesPreserveRestoredLegacySystemHistoryWithoutMutatingStaticPrefix() {
        let taskTools: Set<String> = [
            "tasks.create",
            "tasks.list",
            "tasks.update",
            "agent.create",
        ]
        let messages = RemoteGenerationClient.initialMessages(
            cwd: "/tmp/project",
            systemPrompt: "Current resolved prompt.",
            history: [
                AgentRuntimeMessage(role: .system, content: "ACP client instructions."),
                AgentRuntimeMessage(role: .user, content: "Inspect the project.")
            ],
            allowedToolNames: taskTools
        )

        #expect(messages.count == 2)
        let systemContent = messages.first?["content"] as? String
        #expect(systemContent == "ACP client instructions.")
        #expect(systemContent?.contains("Task workflow policy:") == false)

        let restoredMessages = RemoteGenerationClient.initialMessages(
            cwd: "/tmp/project",
            systemPrompt: "Saved remote system prompt.",
            history: [],
            allowedToolNames: taskTools
        )
        let restoredSystemContent = restoredMessages.first?["content"] as? String
        #expect(restoredSystemContent == "Saved remote system prompt.")
        #expect(restoredSystemContent?.contains("Task workflow policy:") == false)
    }

    @Test
    func remoteInitialMessagesRoundTripProviderReplayMetadata() {
        let reasoningItemsJSON = #"[{"type":"reasoning","id":"rs_1","encrypted_content":"state","summary":[]}]"#
        let thinkingBlocksJSON = #"[{"type":"thinking","thinking":"step","signature":"sig"}]"#
        let history = [
            AgentRuntimeMessage(role: .user, content: "First prompt"),
            AgentRuntimeMessage(
                role: .assistant,
                content: "First answer",
                reasoningItemsJSON: reasoningItemsJSON,
                thinkingBlocksJSON: thinkingBlocksJSON,
                providerResponseID: "resp_first"
            )
        ]
        let messages = RemoteGenerationClient.initialMessages(
            cwd: "/tmp/project",
            systemPrompt: "System prompt",
            history: history,
            allowedToolNames: []
        )
        let snapshot = RemoteGenerationClient.snapshotMessages(from: messages)
        let restoredMessages = RemoteGenerationClient.initialMessages(
            cwd: "/tmp/project",
            systemPrompt: snapshot.systemPrompt,
            history: snapshot.history,
            allowedToolNames: []
        )
        let assistant = restoredMessages.first {
            ($0["role"] as? String) == "assistant"
        }

        #expect(snapshot.history == history)
        #expect(assistant?["reasoning_items"] as? String == reasoningItemsJSON)
        #expect(assistant?["thinking_blocks"] as? String == thinkingBlocksJSON)
        #expect(assistant?["response_id"] as? String == "resp_first")
    }

    @Test
    func remoteClientSnapshotUsesLocalTranscript() async {
        let history = remoteHistory()
        let configuration = AgentRuntimeConfiguration(
            modelID: "remote-model",
            workingDirectory: URL(fileURLWithPath: "/tmp/project"),
            maxToolRounds: 4,
            toolAuthorizationHandler: nil
        )
        let client = RemoteGenerationClient(
            configuration: configuration,
            provider: AgentRemoteProvider(
                name: "Remote remote-server",
                baseURL: "http://127.0.0.1:8080/v1",
                modelID: "remote-model",
                chatEndpoint: .responses
            ),
            apiKey: nil
        )

        await client.createSession(
            id: "session-remote",
            cwd: "/tmp/project",
            systemPrompt: "System prompt",
            history: history,
            cacheKey: "cache-remote",
            allowedToolNames: ["local.exec"],
            thinkingSelection: nil,
            preserveThinking: false
        )

        let snapshot = await client.snapshotSession(id: "session-remote")

        #expect(snapshot?.sessionID == "session-remote")
        #expect(snapshot?.systemPrompt == "System prompt")
        #expect(snapshot?.cacheKey == "cache-remote")
        #expect(snapshot?.history == history)
    }

#if os(macOS)
    @Test
    func anthropicSubscriptionStreamingPreflightCompactsEstimatedPayloadBeforeRequest() async throws {
        let response = """
        data: {"type":"message_start","message":{"usage":{"input_tokens":1,"output_tokens":0}}}

        data: {"type":"content_block_start","index":0,"content_block":{"type":"text","text":"ok"}}

        data: {"type":"message_delta","delta":{"stop_reason":"end_turn"},"usage":{"output_tokens":1}}

        """
        let fixture = try await RemoteNIOStreamingFixture.start(
            responseBody: Data(response.utf8)
        )
        defer {
            fixture.beginShutdown()
        }
        let configuration = AgentRuntimeConfiguration(
            modelID: "claude-haiku-4-5",
            workingDirectory: URL(fileURLWithPath: "/tmp/project", isDirectory: true),
            configuredContextWindowLimit: 30_000,
            maxToolRounds: 4,
            maxOutputTokens: 4_000,
            toolAuthorizationHandler: nil
        )
        let client = AnthropicSubscriptionGenerationClient(
            configuration: configuration,
            provider: AgentRemoteProvider(
                name: "Anthropic Subscription",
                baseURL: AgentRemoteProvider.anthropicSubscriptionBaseURL,
                modelID: "claude-haiku-4-5",
                chatEndpoint: .responses
            ),
            transport: fixture.transport,
            messagesEndpointURLOverride: fixture.messagesURL
        )
        await client.updateToolProviders([
            AgentToolProvider(
                tools: [
                    ToolDescriptor(
                        name: "custom.large",
                        description: String(repeating: "large tool description ", count: 3_000),
                        inputSchema: #"{"type":"object","properties":{"query":{"type":"string"}}}"#
                    )
                ],
                executor: { _ in "" }
            )
        ])
        let sessionID = "session-anthropic-preflight"
        let history = preflightCompactionHistory()
        await client.createSession(
            id: sessionID,
            cwd: "/tmp/project",
            systemPrompt: "System prompt",
            history: history,
            allowedToolNames: ["custom.large"]
        )
        let lease = try #require(await client.sessionLease(for: sessionID))
        let originalHistoryCount = try #require(
            await client.snapshotSession(id: sessionID)
        ).history.count

        let result = try await client.streamAnthropicMessages(
            lease: lease,
            modelID: "claude-haiku-4-5",
            modelLLMID: "claude-haiku-4-5",
            credentials: AnthropicSubscriptionCredentials(
                accessToken: "test-access-token",
                refreshToken: "test-refresh-token",
                expiresAt: Date().addingTimeInterval(3600)
            ),
            applyTurnMemory: false,
            onEvent: { _ in }
        )

        let requests = fixture.capturedRequests()
        let request = try #require(requests.first)
        let body = try request.jsonObject()
        let systemBlocks = try #require(body["system"] as? [[String: Any]])
        let systemText = systemBlocks.compactMap { $0["text"] as? String }
            .joined(separator: "\n")
        let wireMessages = try #require(body["messages"] as? [[String: Any]])
        let snapshot = try #require(await client.snapshotSession(id: sessionID))

        #expect(result.text == "ok")
        #expect(requests.count == 1)
        #expect(systemText.contains(AgentConversationCompactionSupport.memorySummaryHeader))
        // The compaction that produced this request must live in the session
        // owned by the actor, not in a discarded copy: the wire payload and the
        // snapshot have to agree, and the next round must start from here.
        #expect(originalHistoryCount == history.count)
        #expect(snapshot.history.count < originalHistoryCount)
        #expect(snapshot.history.count == wireMessages.count)
        #expect(
            snapshot.systemPrompt?
                .contains(AgentConversationCompactionSupport.memorySummaryHeader) == true
        )
        #expect(
            snapshot.history.last?.content.hasPrefix("brief message 119 detail") == true
        )

        // Second round on the same lease: the persisted compaction is the new
        // starting point, so the preflight is a no-op and the wire payload does
        // not grow back to the uncompacted history.
        let secondResult = try await client.streamAnthropicMessages(
            lease: lease,
            modelID: "claude-haiku-4-5",
            modelLLMID: "claude-haiku-4-5",
            credentials: AnthropicSubscriptionCredentials(
                accessToken: "test-access-token",
                refreshToken: "test-refresh-token",
                expiresAt: Date().addingTimeInterval(3600)
            ),
            applyTurnMemory: false,
            onEvent: { _ in }
        )
        let secondRequests = fixture.capturedRequests()
        let secondBody = try #require(secondRequests.last).jsonObject()
        let secondWireMessages = try #require(secondBody["messages"] as? [[String: Any]])
        let secondSnapshot = try #require(await client.snapshotSession(id: sessionID))

        #expect(secondResult.text == "ok")
        #expect(secondRequests.count == 2)
        #expect(secondWireMessages.count == wireMessages.count)
        #expect(secondSnapshot.history.count == snapshot.history.count)
    }
#endif

    @Test
    func remoteToolWireCatalogRewritesResponsesHistoryNames() throws {
        let catalog = RemoteToolWireCatalog(
            descriptors: [
                DirectToolDescriptor(
                    name: "local.exec",
                    description: "Run a shell command.",
                    inputSchema: #"{"type":"object","properties":{"command":{"type":"string"}},"required":["command"]}"#
                ),
                DirectToolDescriptor(
                    name: "git.diff",
                    description: "Run git diff.",
                    inputSchema: #"{"type":"object","properties":{}}"#
                )
            ]
        )
        let messages = RemoteGenerationClient.initialMessages(
            cwd: "/tmp/project",
            systemPrompt: "System prompt",
            history: remoteHistory(),
            allowedToolNames: ["local.exec"]
        )

        let wireMessages = catalog.wireMessages(from: messages)
        let payload = RemoteGenerationClient.responsesInputPayload(from: wireMessages)
        let inputObjects = payload.input.compactMap { $0 as? [String: Any] }
        let functionCall = try #require(
            inputObjects.first { $0["type"] as? String == "function_call" }
        )
        let toolPayloadNames = catalog.responsesToolPayloads.compactMap {
            $0["name"] as? String
        }
        let localToolCall = catalog.localToolCall(
            from: DirectAgentToolCall(
                id: "call_2",
                name: "tool_git_diff",
                argumentsObject: [:],
                argumentsJSON: "{}"
            )
        )

        #expect(functionCall["name"] as? String == "tool_local_exec")
        #expect(toolPayloadNames.contains("tool_local_exec"))
        #expect(!toolPayloadNames.contains("local.exec"))
        #expect(localToolCall.name == "git.diff")
    }

    @Test
    func remoteToolWireCatalogKeepsCanonicalAndWireNamespacesDirectional() throws {
        let firstPresentation = ToolPresentationDefinition.standard(
            title: "First tool",
            action: "Run",
            kind: .execute
        )
        let secondPresentation = ToolPresentationDefinition.standard(
            title: "Second tool",
            action: "Run",
            kind: .execute
        )
        let catalog = RemoteToolWireCatalog(
            descriptors: [
                DirectToolDescriptor(
                    name: "local.exec",
                    description: "First descriptor.",
                    inputSchema: "{}",
                    presentation: firstPresentation
                ),
                DirectToolDescriptor(
                    name: "tool_local_exec",
                    description: "Second descriptor.",
                    inputSchema: "{}",
                    presentation: secondPresentation
                )
            ]
        )

        let firstIncoming = catalog.localToolCall(
            from: DirectAgentToolCall(
                id: "first",
                name: "tool_local_exec",
                argumentsObject: [:],
                argumentsJSON: "{}"
            )
        )
        let secondIncoming = catalog.localToolCall(
            from: DirectAgentToolCall(
                id: "second",
                name: "tool_tool_local_exec",
                argumentsObject: [:],
                argumentsJSON: "{}"
            )
        )

        #expect(catalog.wireName(forToolName: "local.exec") == "tool_local_exec")
        #expect(catalog.wireName(forToolName: "tool_local_exec") == "tool_tool_local_exec")
        #expect(firstIncoming.name == "local.exec")
        #expect(firstIncoming.presentation == firstPresentation)
        #expect(secondIncoming.name == "tool_local_exec")
        #expect(secondIncoming.presentation == secondPresentation)
    }

    @Test
    func remoteToolWireCatalogDoesNotMapSingularTaskNamespaceToTasks() {
        let catalog = RemoteToolWireCatalog(
            descriptors: [
                DirectToolDescriptor(
                    name: "tasks.list",
                    description: "List task graph records.",
                    inputSchema: #"{"type":"object","properties":{}}"#
                )
            ]
        )
        let singularToolCall = DirectAgentToolCall(
            id: "call_tasks",
            name: "task.list",
            argumentsObject: [:],
            argumentsJSON: "{}"
        )

        #expect(
            catalog.wireName(forToolName: "task.list")
                != catalog.wireName(forToolName: "tasks.list")
        )
        #expect(catalog.localToolCall(from: singularToolCall).name == "task.list")
    }

    @Test
    func remoteToolWireCatalogSanitizesFeatureNamesForResponses() throws {
        let catalog = RemoteToolWireCatalog(
            descriptors: [
                DirectToolDescriptor(
                    name: "fixture.Build",
                    description: "Feature: build project.",
                    inputSchema: #"{"type":"object","properties":{}}"#
                )
            ]
        )
        let toolPayloadNames = catalog.responsesToolPayloads.compactMap {
            $0["name"] as? String
        }
        let chatToolPayloadNames = catalog.chatCompletionToolPayloads.compactMap {
            (($0["function"] as? [String: Any])?["name"] as? String)
        }
        let localToolCall = catalog.localToolCall(
            from: DirectAgentToolCall(
                id: "call_feature",
                name: "tool_fixture_Build",
                argumentsObject: [:],
                argumentsJSON: "{}"
            )
        )

        #expect(toolPayloadNames == ["tool_fixture_Build"])
        #expect(chatToolPayloadNames == ["tool_fixture_Build"])
        #expect(localToolCall.name == "fixture.Build")
    }

    @Test
    func responsesRequestSendsWireSafeToolNamesAndRestoresLocalFeatureToolCall() async throws {
        let response = """
        data: {"type":"response.output_item.done","output_index":0,"item":{"id":"item_feature","type":"function_call","call_id":"call_feature","name":"tool_fixture_Build","arguments":"{\\"scheme\\":\\"App\\"}"}}

        data: {"type":"response.completed","response":{"output":[]}}

        """
        let fixture = try await RemoteNIOStreamingFixture.start(
            responseBody: Data(response.utf8)
        )
        defer {
            fixture.beginShutdown()
        }
        let client = RemoteGenerationClient(
            configuration: remoteStreamingConfiguration(),
            provider: AgentRemoteProvider(
                name: "Unit Test",
                baseURL: "https://unit.test/v1",
                modelID: "unit-model",
                chatEndpoint: .responses
            ),
            apiKey: nil,
            transport: fixture.transport,
            streamEndpointBaseURLOverride: fixture.baseURL,
            mcpRuntime: await borrowedFeatureMCPRuntime()
        )

        let result = try await client.streamResponses(
            messages: remoteFeatureHistoryMessages(),
            sessionID: "session-responses",
            allowedToolNames: ["local.exec", "fixture."],
            thinkingSelection: nil,
            onEvent: { _ in }
        )
        let request = try #require(fixture.capturedRequests().first)
        let body = try request.jsonObject()
        let toolNames = Set(
            ((body["tools"] as? [[String: Any]]) ?? []).compactMap {
                $0["name"] as? String
            }
        )
        let input = try #require(body["input"] as? [[String: Any]])
        let historyFunctionCall = try #require(input.first {
            $0["type"] as? String == "function_call"
                && $0["call_id"] as? String == "call_previous_fixture"
        })

        #expect(toolNames == ["tool_local_exec", "tool_fixture_Build"])
        #expect(!toolNames.contains("local.exec"))
        #expect(!toolNames.contains("fixture.Build"))
        #expect(historyFunctionCall["name"] as? String == "tool_fixture_Build")
        #expect(JSONValue(jsonObject: body).prettyPrinted().contains("fixture.Build") == false)
        #expect(result.toolCalls.map(\.name) == ["fixture.Build"])
        #expect(result.toolCalls.first?.argumentsObject["scheme"] as? String == "App")
    }

    @Test
    func chatCompletionsRequestSendsWireSafeToolNamesAndRestoresLocalFeatureToolCall() async throws {
        let response = """
        data: {"choices":[{"delta":{"tool_calls":[{"index":0,"id":"call_feature","type":"function","function":{"name":"tool_fixture_Build","arguments":"{\\"scheme\\":\\"App\\"}"}}]},"finish_reason":"tool_calls"}]}

        data: [DONE]

        """
        let fixture = try await RemoteNIOStreamingFixture.start(
            responseBody: Data(response.utf8)
        )
        defer {
            fixture.beginShutdown()
        }
        let client = RemoteGenerationClient(
            configuration: remoteStreamingConfiguration(),
            provider: AgentRemoteProvider(
                name: "Unit Test",
                baseURL: "https://unit.test/v1",
                modelID: "unit-model",
                chatEndpoint: .chatCompletions
            ),
            apiKey: nil,
            transport: fixture.transport,
            streamEndpointBaseURLOverride: fixture.baseURL,
            mcpRuntime: await borrowedFeatureMCPRuntime()
        )

        let result = try await client.streamChatCompletions(
            messages: remoteFeatureHistoryMessages(),
            sessionID: "session-chat",
            allowedToolNames: ["local.exec", "fixture."],
            thinkingSelection: nil,
            onEvent: { _ in }
        )
        let request = try #require(fixture.capturedRequests().first)
        let body = try request.jsonObject()
        let toolNames = Set(
            ((body["tools"] as? [[String: Any]]) ?? []).compactMap {
                ($0["function"] as? [String: Any])?["name"] as? String
            }
        )
        let messages = try #require(body["messages"] as? [[String: Any]])
        let assistant = try #require(messages.first {
            ($0["tool_calls"] as? [[String: Any]])?.contains {
                $0["id"] as? String == "call_previous_fixture"
            } == true
        })
        let historyToolCall = try #require((assistant["tool_calls"] as? [[String: Any]])?.first)
        let historyFunction = try #require(historyToolCall["function"] as? [String: Any])
        let toolMessage = try #require(messages.first {
            $0["role"] as? String == "tool"
                && $0["tool_call_id"] as? String == "call_previous_fixture"
        })

        #expect(toolNames == ["tool_local_exec", "tool_fixture_Build"])
        #expect(!toolNames.contains("local.exec"))
        #expect(!toolNames.contains("fixture.Build"))
        #expect(historyFunction["name"] as? String == "tool_fixture_Build")
        #expect(toolMessage["name"] as? String == "tool_fixture_Build")
        #expect(JSONValue(jsonObject: body).prettyPrinted().contains("fixture.Build") == false)
        #expect(result.toolCalls.map(\.name) == ["fixture.Build"])
        #expect(result.toolCalls.first?.argumentsObject["scheme"] as? String == "App")
    }
}
