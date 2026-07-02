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
            bearerToken: nil,
            workingDirectory: URL(fileURLWithPath: "/tmp/project"),
            maxToolRounds: 4,
            verboseLogging: false,
            toolAuthorizationHandler: nil
        )
        let client = RemoteGenerationClient(
            configuration: configuration,
            provider: AgentRemoteProvider(
                name: "Remote mlx-server",
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
    func remoteToolWireCatalogSanitizesXcodeNamesForResponses() throws {
        let catalog = RemoteToolWireCatalog(
            descriptors: [
                DirectToolDescriptor(
                    name: "xcode.BuildProject",
                    description: "Xcode: build project.",
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
                id: "call_xcode",
                name: "tool_xcode_BuildProject",
                argumentsObject: [:],
                argumentsJSON: "{}"
            )
        )

        #expect(toolPayloadNames == ["tool_xcode_BuildProject"])
        #expect(chatToolPayloadNames == ["tool_xcode_BuildProject"])
        #expect(localToolCall.name == "xcode.BuildProject")
    }

    @Test
    func responsesRequestSendsWireSafeToolNamesAndRestoresLocalXcodeToolCall() async throws {
        let response = """
        data: {"type":"response.output_item.done","output_index":0,"item":{"id":"item_xcode","type":"function_call","call_id":"call_xcode","name":"tool_xcode_BuildProject","arguments":"{\\"scheme\\":\\"App\\"}"}}

        data: {"type":"response.completed","response":{"output":[]}}

        """
        let urlSession = RemoteRequestCapturingURLProtocol.urlSession(
            responseBody: Data(response.utf8)
        )
        let client = RemoteGenerationClient(
            configuration: remoteStreamingConfiguration(),
            provider: AgentRemoteProvider(
                name: "Unit Test",
                baseURL: "https://unit.test/v1",
                modelID: "unit-model",
                chatEndpoint: .responses
            ),
            apiKey: nil,
            urlSession: urlSession,
            mcpRuntime: await borrowedXcodeMCPRuntime()
        )

        let result = try await client.streamResponses(
            messages: remoteXcodeHistoryMessages(),
            sessionID: "session-responses",
            allowedToolNames: ["local.exec", "xcode."],
            thinkingSelection: nil,
            onEvent: { _ in }
        )
        let request = try #require(RemoteRequestCapturingURLProtocol.capturedRequests().first)
        let body = try request.jsonObject()
        let toolNames = Set(
            ((body["tools"] as? [[String: Any]]) ?? []).compactMap {
                $0["name"] as? String
            }
        )
        let input = try #require(body["input"] as? [[String: Any]])
        let historyFunctionCall = try #require(input.first {
            $0["type"] as? String == "function_call"
                && $0["call_id"] as? String == "call_previous_xcode"
        })

        #expect(toolNames == ["tool_local_exec", "tool_xcode_BuildProject"])
        #expect(!toolNames.contains("local.exec"))
        #expect(!toolNames.contains("xcode.BuildProject"))
        #expect(historyFunctionCall["name"] as? String == "tool_xcode_BuildProject")
        #expect(JSONValue(jsonObject: body).prettyPrinted().contains("xcode.BuildProject") == false)
        #expect(result.toolCalls.map(\.name) == ["xcode.BuildProject"])
        #expect(result.toolCalls.first?.argumentsObject["scheme"] as? String == "App")
    }

    @Test
    func chatCompletionsRequestSendsWireSafeToolNamesAndRestoresLocalXcodeToolCall() async throws {
        let response = """
        data: {"choices":[{"delta":{"tool_calls":[{"index":0,"id":"call_xcode","type":"function","function":{"name":"tool_xcode_BuildProject","arguments":"{\\"scheme\\":\\"App\\"}"}}]},"finish_reason":"tool_calls"}]}

        data: [DONE]

        """
        let urlSession = RemoteRequestCapturingURLProtocol.urlSession(
            responseBody: Data(response.utf8)
        )
        let client = RemoteGenerationClient(
            configuration: remoteStreamingConfiguration(),
            provider: AgentRemoteProvider(
                name: "Unit Test",
                baseURL: "https://unit.test/v1",
                modelID: "unit-model",
                chatEndpoint: .chatCompletions
            ),
            apiKey: nil,
            urlSession: urlSession,
            mcpRuntime: await borrowedXcodeMCPRuntime()
        )

        let result = try await client.streamChatCompletions(
            messages: remoteXcodeHistoryMessages(),
            sessionID: "session-chat",
            allowedToolNames: ["local.exec", "xcode."],
            thinkingSelection: nil,
            onEvent: { _ in }
        )
        let request = try #require(RemoteRequestCapturingURLProtocol.capturedRequests().first)
        let body = try request.jsonObject()
        let toolNames = Set(
            ((body["tools"] as? [[String: Any]]) ?? []).compactMap {
                ($0["function"] as? [String: Any])?["name"] as? String
            }
        )
        let messages = try #require(body["messages"] as? [[String: Any]])
        let assistant = try #require(messages.first {
            ($0["tool_calls"] as? [[String: Any]])?.contains {
                $0["id"] as? String == "call_previous_xcode"
            } == true
        })
        let historyToolCall = try #require((assistant["tool_calls"] as? [[String: Any]])?.first)
        let historyFunction = try #require(historyToolCall["function"] as? [String: Any])
        let toolMessage = try #require(messages.first {
            $0["role"] as? String == "tool"
                && $0["tool_call_id"] as? String == "call_previous_xcode"
        })

        #expect(toolNames == ["tool_local_exec", "tool_xcode_BuildProject"])
        #expect(!toolNames.contains("local.exec"))
        #expect(!toolNames.contains("xcode.BuildProject"))
        #expect(historyFunction["name"] as? String == "tool_xcode_BuildProject")
        #expect(toolMessage["name"] as? String == "tool_xcode_BuildProject")
        #expect(JSONValue(jsonObject: body).prettyPrinted().contains("xcode.BuildProject") == false)
        #expect(result.toolCalls.map(\.name) == ["xcode.BuildProject"])
        #expect(result.toolCalls.first?.argumentsObject["scheme"] as? String == "App")
    }
}
