//
//  ACPWireCompatibilityTests+Messages.swift
//  ZenCODE
//
//  Wire compatibility tests of the other ACP messages: session resume,
//  permission replies, session update notifications, image prompt blocks,
//  config options, and usage updates.
//

import Foundation
import Synchronization
@testable import ZenCODECore
import Testing
import ToolCore

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
            #expect(ACPConsentHost.permissionOptionID(from: value) == expected)
        }
    }

            @Test
    func cancelledPermissionOutcomeDoesNotSelectOption() {
        let value = JSONValue.object([
            "outcome": .object([
                "outcome": .string("cancelled")
            ])
        ])

        #expect(ACPConsentHost.permissionOptionID(from: value) == nil)
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

        #expect(ChatToolConsentAuthorizer.permissionCacheCommandIdentity(for: localExecRequest) == "1:5:swift")
        #expect(ChatToolConsentAuthorizer.permissionCacheCommandIdentity(for: secondLocalExecRequest) == "1:5:swift")
        #expect(ChatToolConsentAuthorizer.permissionCacheCommandIdentity(for: nonLocalRequest) == "swift test --filter One")
        #expect(
            ChatToolConsentAuthorizer.permissionCacheCommandIdentity(for: pipelineRequest)
            == "2:5:swift4:tail"
        )
        #expect(
            ChatToolConsentAuthorizer.permissionCacheCommandIdentity(for: separatorPipelineRequest)
            != ChatToolConsentAuthorizer.permissionCacheCommandIdentity(for: separatorExecutableRequest)
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
            ChatToolConsentAuthorizer.permissionCacheKeyValue(for: tupleCollisionA)
            != ChatToolConsentAuthorizer.permissionCacheKeyValue(for: tupleCollisionB)
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
    func configOptionsUseStandardCategories() async throws {
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

        let categories = await bridge.testConfigOptionCategories(for: "thinking-model")

        #expect(categories == ["model": "model", "thinking": "thought_level"])
    }

    @Test
    func sessionLifecycleResultKeepsModelStateInMetaOnly() async throws {
        let bridge = try makeBridge(
            models: [
                AgentSettingsModelManifest(
                    id: "first-model", kind: .remoteAPI, modelID: "local/first-model"
                ),
                AgentSettingsModelManifest(
                    id: "second-model", kind: .remoteAPI, modelID: "local/second-model"
                )
            ]
        )
        let configuration = AgentCoreSessionConfiguration(
            sessionID: "session-models",
            modelID: "second-model",
            workingDirectory: FileManager.default.temporaryDirectory,
            systemPrompt: nil,
            cacheKey: nil,
            history: []
        )
        await bridge.installTestSession(configuration)

        let state = await bridge.testLifecycleModelState(sessionID: "session-models")

        // Model selection is published through `configOptions`; the removed
        // legacy top-level `models` field must not come back.
        #expect(state.current == nil)
        #expect(state.available == nil)
        #expect(state.metaCurrent == "second-model")
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
