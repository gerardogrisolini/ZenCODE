//
//  ACPCompatibilityTests.swift
//  ZenCODE
//
//  Created by Gerardo Grisolini on 02/06/26.
//
import Foundation
@testable import ZenCODECore
import Testing

extension ACPCompatibilityTests {
    @Test
    func resumeSessionRebuildsStateFromClientHistory() async throws {
        let bridge = try makeBridge(
            models: [
                AgentSettingsModelManifest(
                    id: "test-model",
                    kind: .remoteAPI,
                    modelID: "local/test-model"
                )
            ]
        )

        try await bridge.resumeSession(id: nil, params: [
            "sessionId": "client-session-1",
            "cwd": "/tmp/acp-resume-workspace",
            "modelId": "test-model",
            "cacheKey": "client-cache-1",
            "history": [
                [
                    "role": "user",
                    "content": "Hello"
                ],
                [
                    "role": "assistant",
                    "content": "Hi"
                ]
            ] as [[String: Any]]
        ])

        let configuration = try #require(await bridge.sessionConfigurationsForTesting().first)

        #expect(configuration.sessionID == "client-session-1")
        #expect(configuration.workingDirectory.path == "/tmp/acp-resume-workspace")
        #expect(configuration.modelID == "test-model")
        #expect(configuration.cacheKey == "client-cache-1")
        #expect(configuration.history == [
            AgentRuntimeMessage(role: .user, content: "Hello"),
            AgentRuntimeMessage(role: .assistant, content: "Hi")
        ])
    }

    @Test
    func toolCallUpdatesUseACPv1WireKeys() throws {
        let toolCall = DirectAgentToolCall(
            id: "call_001",
            name: "local.exec",
            argumentsObject: [
                "command": "swift test",
                "workingDirectory": "/tmp/workspace"
            ],
            argumentsJSON: #"{"command":"swift test","workingDirectory":"/tmp/workspace"}"#
        )

        let create = ZenCODEACPBridge.toolCallCreateUpdate(for: toolCall)
        #expect(create["sessionUpdate"] as? String == "tool_call")
        #expect(create["toolCallId"] as? String == "call_001")
        #expect(create["title"] as? String == "Run swift test")
        #expect(create["kind"] as? String == "execute")
        #expect(create["status"] as? String == "pending")
        #expect(create["tool_call_id"] == nil)

        let progress = ZenCODEACPBridge.toolCallProgressUpdate(for: toolCall)
        #expect(progress["sessionUpdate"] as? String == "tool_call_update")
        #expect(progress["toolCallId"] as? String == "call_001")
        #expect(progress["title"] as? String == "Run swift test")
        #expect(progress["kind"] as? String == "execute")
        #expect(progress["status"] as? String == "in_progress")

        let completion = ZenCODEACPBridge.toolCallCompletionUpdate(
            for: toolCall,
            result: DirectAgentToolResult(
                output: "Build complete.",
                summary: "Build complete."
            )
        )
        #expect(completion["sessionUpdate"] as? String == "tool_call_update")
        #expect(completion["toolCallId"] as? String == "call_001")
        #expect(completion["title"] as? String == "Run swift test")
        #expect(completion["kind"] as? String == "execute")
        #expect(completion["status"] as? String == "completed")
    }

    @Test
    func toolKindsUseClientRecognizedACPCategories() {
        #expect(ZenCODEACPBridge.toolKind(for: "local.readFile") == "read")
        #expect(ZenCODEACPBridge.toolKind(for: "git.status") == "read")
        #expect(ZenCODEACPBridge.toolKind(for: "search.grep") == "search")
        #expect(ZenCODEACPBridge.toolKind(for: "web.search") == "search")
        #expect(ZenCODEACPBridge.toolKind(for: "web.fetch") == "read")
        #expect(ZenCODEACPBridge.toolKind(for: "local.writeFile") == "edit")
        #expect(ZenCODEACPBridge.toolKind(for: "xcode.XcodeWrite") == "edit")
        #expect(ZenCODEACPBridge.toolKind(for: "local.delete") == "delete")
        #expect(ZenCODEACPBridge.toolKind(for: "xcode.XcodeMV") == "move")
        #expect(ZenCODEACPBridge.toolKind(for: "local.exec") == "execute")
        #expect(ZenCODEACPBridge.toolKind(for: "xcode.BuildProject") == "execute")
        #expect(ZenCODEACPBridge.toolKind(for: "todo.write") == "edit")
        #expect(ZenCODEACPBridge.toolKind(for: "feature.build") == "execute")
        #expect(ZenCODEACPBridge.toolKind(for: "unknown.customTool") == "other")
    }

    @Test
    func permissionResponsesAcceptAlternateACPShapes() {
        let cases: [(JSONValue, String)] = [
            (.string("allow_once"), "allow_once"),
            (.object(["optionId": .string("allow_always")]), "allow_always"),
            (.object(["optionID": .string("allow_upper")]), "allow_upper"),
            (.object(["option_id": .string("allow_snake")]), "allow_snake"),
            (.object(["confirmKey": .string("allow_confirm")]), "allow_confirm"),
            (.object(["confirm_key": .string("allow_confirm_snake")]), "allow_confirm_snake"),
            (.object([
                "outcome": .object([
                    "outcome": .string("selected"),
                    "optionId": .string("reject_once")
                ])
            ]), "reject_once"),
            (.object([
                "outcome": .object([
                    "outcome": .string("selected"),
                    "option_id": .string("reject_always")
                ])
            ]), "reject_always"),
            (.object([
                "selected": .object([
                    "confirm_key": .string("allow_selected")
                ])
            ]), "allow_selected")
        ]

        for (value, expected) in cases {
            #expect(ACPPermissionBroker.permissionOptionID(from: value) == expected)
        }
    }

            @Test
    func cancelledPermissionOutcomeDoesNotSelectOption() {
        let value = JSONValue.object([
            "outcome": .object([
                "outcome": .string("cancelled")
            ])
        ])

        #expect(ACPPermissionBroker.permissionOptionID(from: value) == nil)
    }

    @Test
    func acpLocalExecAlwaysPermissionUsesExecutableOnly() {
        let localExecRequest = AgentToolAuthorizationRequest(
            sessionID: "session",
            toolCallID: "call_exec",
            toolName: "local.exec",
            title: "Run swift test --filter One",
            kind: "execute",
            command: "swift test --filter One",
            workingDirectory: "/tmp/project"
        )
        let secondLocalExecRequest = AgentToolAuthorizationRequest(
            sessionID: "session",
            toolCallID: "call_exec_2",
            toolName: "local.exec",
            title: "Run swift test --filter Two",
            kind: "execute",
            command: "swift test --filter Two",
            workingDirectory: "/tmp/project"
        )
        let nonLocalRequest = AgentToolAuthorizationRequest(
            sessionID: "session",
            toolCallID: "call_custom",
            toolName: "custom.tool",
            title: "Run custom tool",
            kind: "execute",
            command: "swift test --filter One",
            workingDirectory: "/tmp/project"
        )

        #expect(ACPPermissionBroker.permissionCacheCommandIdentity(for: localExecRequest) == "swift")
        #expect(ACPPermissionBroker.permissionCacheCommandIdentity(for: secondLocalExecRequest) == "swift")
        #expect(ACPPermissionBroker.permissionCacheCommandIdentity(for: nonLocalRequest) == "swift test --filter One")
    }

    @Test
    func sessionUpdatesWrapPayloadInStandardNotificationShape() {
        let usageUpdate = ZenCODEACPBridge.usageUpdate(
            for: DirectAgentContextWindowStatus(
                usedTokens: 42,
                maxTokens: 4096,
                modelID: "local-model",
                isApproximate: true
            )
        )

        let notification = JSONValue.acpValue(from: [
            "jsonrpc": "2.0",
            "method": "session/update",
            "params": [
                "sessionId": "session-1",
                "update": usageUpdate ?? [:]
            ]
        ])

        let object = notification.mlxObjectValue
        #expect(object?["method"]?.acpStringValue == "session/update")
        let params = object?["params"]?.mlxObjectValue
        #expect(params?["sessionId"]?.acpStringValue == "session-1")
        let update = params?["update"]?.mlxObjectValue
        #expect(update?["sessionUpdate"]?.acpStringValue == "usage_update")
        #expect(update?["used"]?.intValue == 42)
        #expect(update?["size"]?.intValue == 4096)
        let meta = update?["_meta"]?.mlxObjectValue
        #expect(meta?["modelID"]?.acpStringValue == "local-model")
    }

    @Test
    func imagePromptBlocksAreConvertedToAttachments() {
        let promptBlocks: [Any] = [
            [
                "type": "image",
                "mimeType": "image/png",
                "data": "AQID"
            ] as [String: Any]
        ]
        let attachments = ZenCODEACPBridge.promptAttachments(
            from: promptBlocks,
            renderedPromptText: "",
            cwd: "/tmp"
        )

        #expect(attachments.count == 1)
        #expect(attachments.first?.kind == .image)
        #expect(attachments.first?.contentType == "image/png")
        #expect(attachments.first?.data == Data([1, 2, 3]))
    }
}

private extension ACPCompatibilityTests {
    @Test
    func configOptionsIncludeThinkingForThinkingModels() async throws {
        let bridge = try makeBridge(
            models: [
                AgentSettingsModelManifest(
                    id: "thinking-model",
                    kind: .remoteAPI,
                    title: "Thinking Model",
                    modelID: "local/thinking-model",
                    thinkingOptions: [.off, .medium, .high],
                    defaultThinkingSelection: .medium
                )
            ]
        )

                        let values = await bridge.testThinkingOptionValues(for: "thinking-model")

        #expect(values.currentValue == "medium")
        #expect(values.optionValues == ["off", "medium", "high"])
    }

    @Test
    func configOptionsOmitThinkingForModelsWithoutThinking() async throws {
        let bridge = try makeBridge(
            models: [
                AgentSettingsModelManifest(
                    id: "plain-model",
                    kind: .remoteAPI,
                    modelID: "local/plain-model"
                )
            ]
        )

                        let hasThinking = await bridge.testHasThinkingOption(for: "plain-model")

        #expect(!hasThinking)
    }

    @Test
    func sessionLifecycleResultUsesSessionThinkingSelection() async throws {
        let bridge = try makeBridge(
            models: [
                AgentSettingsModelManifest(
                    id: "thinking-model",
                    kind: .remoteAPI,
                    modelID: "local/thinking-model",
                    thinkingOptions: [.off, .medium, .high],
                    defaultThinkingSelection: .medium
                )
            ]
        )
        let configuration = AgentCoreSessionConfiguration(
            sessionID: "session-thinking",
            modelID: "thinking-model",
                                    bearerToken: nil,
            workingDirectory: FileManager.default.temporaryDirectory,
            systemPrompt: nil,
            cacheKey: nil,
            history: [],
            thinkingSelection: .high,
            preserveThinking: false
        )
                        await bridge.installTestSession(configuration)

                        let currentValue = await bridge.testLifecycleThinkingCurrentValue(
            sessionID: "session-thinking"
        )

        #expect(currentValue == "high")
    }
}
