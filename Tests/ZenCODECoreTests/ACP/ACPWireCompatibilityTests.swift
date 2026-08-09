//
//  ACPCompatibilityTests.swift
//  ZenCODE
//
//  Created by Gerardo Grisolini on 02/06/26.
//

import Foundation
@testable import ZenCODECore
import Testing
import ToolCore

extension ACPCompatibilityTests {
    @Test
    func authCapableClientReceivesCompatibilityAuthenticationMethod() {
        let methods = ZenCODEACPBridge.authenticationMethods(from: [
            "clientInfo": [
                "name": "FixtureClient",
                "version": "1.0"
            ] as [String: Any],
            "clientCapabilities": [
                "auth": ["terminal": true]
            ] as [String: Any]
        ])

        let secondAuthCapableClientMethods = ZenCODEACPBridge.authenticationMethods(from: [
            "clientInfo": [
                "name": "AnotherClient"
            ] as [String: Any],
            "clientCapabilities": [
                "auth": ["terminal": true]
            ] as [String: Any]
        ])

        #expect(methods.count == 1)
        #expect(secondAuthCapableClientMethods.count == 1)
        #expect(methods.first?["id"] as? String == "zencode-client-compatibility")
        #expect(methods.first?["name"] as? String == "Continue with ZenCODE")
        #expect(methods.first?["type"] as? String == "agent")
    }

    @Test
    func compatibilityAuthenticationMethodIsNotAdvertisedWithoutAuthCapability() {
        let firstClientMethods = ZenCODEACPBridge.authenticationMethods(from: [
            "clientInfo": [
                "name": "FixtureClient",
                "version": "1.0"
            ] as [String: Any]
        ])
        let otherClientMethods = ZenCODEACPBridge.authenticationMethods(from: [
            "clientInfo": [
                "name": "OtherClient",
                "version": "27.0"
            ] as [String: Any]
        ])

        #expect(firstClientMethods.isEmpty)
        #expect(otherClientMethods.isEmpty)
    }

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
        let toolCall = presentedToolCall(
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
        #expect(create["title"] as? String == "local.exec swift test")
        #expect(create["status"] as? String == "pending")
        #expect(create["tool_call_id"] == nil)

        let progress = ZenCODEACPBridge.toolCallProgressUpdate(for: toolCall)
        #expect(progress["sessionUpdate"] as? String == "tool_call_update")
        #expect(progress["toolCallId"] as? String == "call_001")
        #expect(progress["title"] as? String == "local.exec swift test")
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
        #expect(completion["title"] as? String == "local.exec swift test")
        #expect(completion["status"] as? String == "completed")
    }

    @Test
    func toolCallUpdatesOnlyUseProtocolToolKinds() {
        let acpToolKinds: Set<String> = [
            "read", "edit", "delete", "move", "search",
            "execute", "think", "fetch", "switch_mode", "other"
        ]
        let inspectToolCall = presentedToolCall(
            id: "call_inspect",
            name: "local.inspectFile",
            argumentsObject: ["path": "/tmp/workspace/alpha.swift"],
            argumentsJSON: #"{"path":"/tmp/workspace/alpha.swift"}"#
        )
        let directoryCreationToolCall = presentedToolCall(
            id: "call_mkdir",
            name: "local.mkdir",
            argumentsObject: ["path": "/tmp/workspace/new"],
            argumentsJSON: #"{"path":"/tmp/workspace/new"}"#
        )
        let taskCreationToolCall = presentedToolCall(
            id: "call_tasks",
            name: "tasks.create",
            argumentsObject: ["title": "Ship the fix"],
            argumentsJSON: #"{"title":"Ship the fix"}"#
        )
        let featureToolCall = presentedToolCall(
            id: "call_feature",
            name: "feature.enable",
            argumentsObject: ["id": "git-tools"],
            argumentsJSON: #"{"id":"git-tools"}"#
        )

        #expect(ZenCODEACPBridge.toolKind(for: inspectToolCall) == "read")
        #expect(ZenCODEACPBridge.toolKind(for: directoryCreationToolCall) == "edit")
        #expect(ZenCODEACPBridge.toolKind(for: taskCreationToolCall) == "other")
        #expect(ZenCODEACPBridge.toolKind(for: featureToolCall) == "other")
        #expect(ZenCODEACPBridge.acpToolKind("destructive") == "delete")
        #expect(ZenCODEACPBridge.acpToolKind("communicate") == "other")
        #expect(ZenCODEACPBridge.acpToolKind("search") == "search")

        for toolCall in [
            inspectToolCall,
            directoryCreationToolCall,
            taskCreationToolCall,
            featureToolCall
        ] {
            let create = ZenCODEACPBridge.toolCallCreateUpdate(for: toolCall)
            let progress = ZenCODEACPBridge.toolCallProgressUpdate(for: toolCall)
            let completion = ZenCODEACPBridge.toolCallCompletionUpdate(
                for: toolCall,
                result: DirectAgentToolResult(output: "done", summary: "done")
            )
            for update in [create, progress, completion] {
                let kind = update["kind"] as? String ?? ""
                #expect(acpToolKinds.contains(kind))
            }
        }
    }

    @Test
    func toolCallLocationsResolveRelativePathsAgainstTheSessionWorkspace() {
        let workspaceURL = URL(fileURLWithPath: "/tmp/acp-workspace")
        let relativeToolCall = presentedToolCall(
            id: "call_grep",
            name: "search.grep",
            argumentsObject: [
                "pattern": "needle",
                "path": "Sources/App"
            ],
            argumentsJSON: #"{"pattern":"needle","path":"Sources/App"}"#
        )
        let absoluteToolCall = presentedToolCall(
            id: "call_read",
            name: "local.readFile",
            argumentsObject: ["path": "/tmp/other/beta.swift"],
            argumentsJSON: #"{"path":"/tmp/other/beta.swift"}"#
        )

        let relativeLocations = ZenCODEACPBridge.toolLocations(
            for: relativeToolCall,
            workingDirectory: workspaceURL
        )
        let absoluteLocations = ZenCODEACPBridge.toolLocations(
            for: absoluteToolCall,
            workingDirectory: workspaceURL
        )

        #expect(relativeLocations.count == 1)
        #expect(relativeLocations.first?["path"] as? String == "/tmp/acp-workspace/Sources/App")
        #expect(absoluteLocations.first?["path"] as? String == "/tmp/other/beta.swift")

        let update = ZenCODEACPBridge.toolCallCreateUpdate(
            for: relativeToolCall,
            workingDirectory: workspaceURL
        )
        let updateLocations = update["locations"] as? [[String: Any]] ?? []
        #expect(updateLocations.first?["path"] as? String == "/tmp/acp-workspace/Sources/App")
    }

    @Test
    func toolCallTitlesAppendOnlySafeFallbackTargetsWithoutPresentation() {
        let searchableToolCall = DirectAgentToolCall(
            id: "call_search",
            name: "custom.search",
            argumentsObject: [
                "query": "needle",
                "content": "sensitive payload"
            ],
            argumentsJSON: "{}"
        )
        let payloadOnlyToolCall = DirectAgentToolCall(
            id: "call_send",
            name: "custom.send",
            argumentsObject: [
                "content": "sensitive payload",
                "token": "secret"
            ],
            argumentsJSON: "{}"
        )

        #expect(ZenCODEACPBridge.toolTitle(for: searchableToolCall) == "custom.search needle")
        #expect(ZenCODEACPBridge.toolTitle(for: payloadOnlyToolCall) == "custom.send")
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
        let pipelineRequest = AgentToolAuthorizationRequest(
            sessionID: "session",
            toolCallID: "call_pipeline",
            toolName: "local.exec",
            title: "Run swift and tail",
            kind: "execute",
            command: "swift build | tail -n 20",
            workingDirectory: "/tmp/project"
        )
        let separatorPipelineRequest = AgentToolAuthorizationRequest(
            sessionID: "session",
            toolCallID: "call_separator_pipeline",
            toolName: "local.exec",
            title: "Run a and b",
            kind: "execute",
            command: "a | b",
            workingDirectory: "/tmp/project"
        )
        let separatorExecutableRequest = AgentToolAuthorizationRequest(
            sessionID: "session",
            toolCallID: "call_separator_executable",
            toolName: "local.exec",
            title: "Run one unusual executable",
            kind: "execute",
            command: "'a\u{1e}b'",
            workingDirectory: "/tmp/project"
        )

        #expect(ACPPermissionBroker.permissionCacheCommandIdentity(for: localExecRequest) == "1:5:swift")
        #expect(ACPPermissionBroker.permissionCacheCommandIdentity(for: secondLocalExecRequest) == "1:5:swift")
        #expect(ACPPermissionBroker.permissionCacheCommandIdentity(for: nonLocalRequest) == "swift test --filter One")
        #expect(
            ACPPermissionBroker.permissionCacheCommandIdentity(for: pipelineRequest)
            == "2:5:swift4:tail"
        )
        #expect(
            ACPPermissionBroker.permissionCacheCommandIdentity(for: separatorPipelineRequest)
            != ACPPermissionBroker.permissionCacheCommandIdentity(for: separatorExecutableRequest)
        )

        let tupleCollisionA = AgentToolAuthorizationRequest(
            sessionID: "session",
            toolCallID: "tuple_a",
            toolName: "local.exec",
            title: "Run unusual executable",
            kind: "execute",
            command: "'p\u{1f}1:1:q'",
            workingDirectory: "/tmp/a"
        )
        let tupleCollisionB = AgentToolAuthorizationRequest(
            sessionID: "session",
            toolCallID: "tuple_b",
            toolName: "local.exec",
            title: "Run q",
            kind: "execute",
            command: "q",
            workingDirectory: "/tmp/a\u{1f}1:7:p"
        )
        #expect(
            ACPPermissionBroker.permissionCacheKeyValue(for: tupleCollisionA)
            != ACPPermissionBroker.permissionCacheKeyValue(for: tupleCollisionB)
        )
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

        let object = notification.objectValue
        #expect(object?["method"]?.acpStringValue == "session/update")
        let params = object?["params"]?.objectValue
        #expect(params?["sessionId"]?.acpStringValue == "session-1")
        let update = params?["update"]?.objectValue
        #expect(update?["sessionUpdate"]?.acpStringValue == "usage_update")
        #expect(update?["used"]?.intValue == 42)
        #expect(update?["size"]?.intValue == 4096)
        let meta = update?["_meta"]?.objectValue
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

    // MARK: - ACP v1 extensibility conformance

    @Test
    func toolCallUpdatesCarryRawInputInMetaNotAtRoot() {
        let toolCall = presentedToolCall(
            id: "call_meta",
            name: "local.exec",
            argumentsObject: [
                "command": "swift test",
                "workingDirectory": "/tmp/workspace"
            ],
            argumentsJSON: #"{"command":"swift test","workingDirectory":"/tmp/workspace"}"#
        )

        let create = ZenCODEACPBridge.toolCallCreateUpdate(for: toolCall)
        #expect(create["rawInput"] == nil)
        #expect((create["_meta"] as? [String: Any])?["rawInput"] != nil)

        let progress = ZenCODEACPBridge.toolCallProgressUpdate(for: toolCall)
        #expect(progress["rawInput"] == nil)
        #expect((progress["_meta"] as? [String: Any])?["rawInput"] != nil)

        let completion = ZenCODEACPBridge.toolCallCompletionUpdate(
            for: toolCall,
            result: DirectAgentToolResult(output: "done", summary: "done")
        )
        #expect(completion["rawInput"] == nil)
        #expect(completion["rawOutput"] == nil)
        let completionMeta = completion["_meta"] as? [String: Any]
        #expect(completionMeta?["rawInput"] != nil)
        #expect(completionMeta?["rawOutput"] != nil)
    }

    @Test
    func toolCallJSONUpdatesCarryRawInputInMetaNotAtRoot() throws {
        let toolCall = presentedToolCall(
            id: "call_json_meta",
            name: "local.readFile",
            argumentsObject: ["path": "/tmp/file.swift"],
            argumentsJSON: #"{"path":"/tmp/file.swift"}"#
        )

        let create = ZenCODEACPBridge.toolCallCreateJSONUpdate(for: toolCall)
        #expect(create.objectValue?["rawInput"] == nil)
        #expect(create.objectValue?["_meta"]?.objectValue?["rawInput"] != nil)

        let progress = ZenCODEACPBridge.toolCallProgressJSONUpdate(for: toolCall)
        #expect(progress.objectValue?["rawInput"] == nil)
        #expect(progress.objectValue?["_meta"]?.objectValue?["rawInput"] != nil)

        let completion = ZenCODEACPBridge.toolCallCompletionJSONUpdate(
            for: toolCall,
            result: DirectAgentToolResult(output: "content", summary: "content")
        )
        #expect(completion.objectValue?["rawInput"] == nil)
        #expect(completion.objectValue?["rawOutput"] == nil)
        let meta = try #require(completion.objectValue?["_meta"]?.objectValue)
        #expect(meta["rawInput"] != nil)
        #expect(meta["rawOutput"] != nil)
    }

    @Test
    func subscriptionUsageDataDoesNotWrapInSessionUpdate() {
        let status = DirectAgentSubscriptionUsageStatus(
            provider: "claude",
            dailyUsedPercent: 42.0,
            weeklyUsedPercent: nil,
            dailyResetsInSeconds: 3600
        )
        let data = ZenCODEACPBridge.subscriptionUsageJSONData(for: status)
        #expect(data != nil)
        let object = data?.objectValue
        #expect(object?["sessionUpdate"] == nil)
        #expect(object?["provider"]?.acpStringValue == "claude")
        #expect(object?["dailyUsedPercent"]?.numberValue == 42.0)
        #expect(object?["dailyResetsInSeconds"]?.numberValue == 3600)
        #expect(object?["weeklyUsedPercent"] == nil)
    }

    @Test
    func subscriptionUsageDataReturnsNilForEmptyStatus() {
        let status = DirectAgentSubscriptionUsageStatus(
            provider: "claude",
            dailyUsedPercent: nil,
            weeklyUsedPercent: nil
        )
        #expect(ZenCODEACPBridge.subscriptionUsageJSONData(for: status) == nil)
    }

    @Test(arguments: [
        (AgentSharedChat.ParticipantKind.coordinator, "Coordinator"),
        (.agent, "Worker")
    ])
    func sharedChatUsesStandardRenderedACPChunk(
        kind: AgentSharedChat.ParticipantKind,
        name: String
    ) throws {
        let message = AgentSharedChat.Message(
            roomID: "acp-session",
            sender: AgentSharedChat.Participant(id: "sender", name: name, kind: kind),
            recipientIDs: ["operator", "coordinator:root"],
            text: "live update"
        )

        let data = try #require(ZenCODEACPBridge.sharedChatUpdate(for: message))
        let object = try #require(data.objectValue)
        let content = try #require(object["content"]?.objectValue)

        #expect(object["sessionUpdate"]?.acpStringValue == "agent_message_chunk")
        #expect(content["type"]?.acpStringValue == "text")
        #expect(content["text"]?.acpStringValue == "[\(name)] live update")
    }

    /// Operator traffic is already on the client's screen, so it is not
    /// forwarded: rendering it would duplicate the host's own input.
    @Test
    func sharedChatDropsOperatorMessagesInsteadOfDuplicatingThem() throws {
        let message = AgentSharedChat.Message(
            roomID: "acp-session",
            sender: AgentSharedChat.Participant(
                id: "operator:acp-session",
                name: "operator",
                kind: .operator
            ),
            recipientIDs: ["coordinator:root"],
            text: "hello"
        )

        #expect(ZenCODEACPBridge.sharedChatUpdate(for: message) == nil)
    }

    @Test
    func tokenUsageUpdateIsStillASessionUpdateWithUsedAndSize() throws {
        let status = DirectAgentContextWindowStatus(
            usedTokens: 5000,
            maxTokens: 20000,
            modelID: "test-model",
            isApproximate: false
        )
        let update = ZenCODEACPBridge.usageJSONUpdate(for: status)
        let object = try #require(update?.objectValue)
        // Token usage remains a schema-valid session/update with usage_update
        #expect(object["sessionUpdate"]?.acpStringValue == "usage_update")
        #expect(object["used"]?.numberValue == 5000)
        #expect(object["size"]?.numberValue == 20000)
    }
}
