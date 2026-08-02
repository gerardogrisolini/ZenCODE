//
//  ACPCompatibilityTests.swift
//  ZenCODE
//
//  Created by Gerardo Grisolini on 02/06/26.
//

import Foundation
@testable import FeatureMCPBridgeKit
@testable import ZenCODECore
import Testing
import ToolCore
#if os(macOS)
#endif

extension ACPCompatibilityTests {
    @Test
    func acpSessionKeepsTheEffectiveAgentAcrossRoutingAndRestore() async throws {
        let agentA = AgentProfile(
            id: "agent-a",
            name: "Agent A",
            instructions: "Instructions for Agent A.",
            tools: []
        )
        let agentB = AgentProfile(
            id: "agent-b",
            name: "Agent B",
            instructions: "Instructions for Agent B.",
            tools: []
        )
        let backend = CapturingACPBackend()
        let bridge = try makeBridge(
            models: [
                AgentSettingsModelManifest(
                    id: "test-model",
                    kind: .remoteAPI,
                    modelID: "local/test-model"
                )
            ],
            availableAgents: [agentA, agentB],
            agentName: agentA.name,
            backendFactory: { _, _ in backend }
        )

        try await bridge.newSession(id: nil, params: [
            "cwd": "/tmp/acp-agent-routing",
            "agentId": agentA.id
        ])
        let sessionID = try #require(
            await bridge.sessionConfigurationsForTesting().first?.sessionID
        )
        #expect(await bridge.selectedAgentIDForTesting(sessionID: sessionID) == agentA.id)

        try await bridge.prompt(id: nil, params: [
            "sessionId": sessionID,
            "prompt": "@AgentB inspect this session"
        ])

        #expect(await bridge.selectedAgentIDForTesting(sessionID: sessionID) == agentB.id)
        #expect(await backend.createdSystemPrompt()?.contains("Instructions for Agent B.") == true)
        #expect(await bridge.lifecycleAgentIDForTesting(sessionID: sessionID) == agentB.id)

        let restoredBridge = try makeBridge(
            models: [
                AgentSettingsModelManifest(
                    id: "test-model",
                    kind: .remoteAPI,
                    modelID: "local/test-model"
                )
            ],
            availableAgents: [agentA, agentB],
            agentName: agentA.name,
            backendFactory: { _, _ in CapturingACPBackend() }
        )
        try await restoredBridge.restoreSession(
            id: nil,
            params: [
                "sessionId": "restored-agent-b",
                "cwd": "/tmp/acp-agent-routing",
                "agentId": agentB.id
            ],
            replayHistory: false
        )
        #expect(
            await restoredBridge.selectedAgentIDForTesting(sessionID: "restored-agent-b")
                == agentB.id
        )
    }

    @Test
    func newSessionSkipsUnavailableACPProvidedMCPServers() async throws {
        let bridge = try makeBridge(
            models: [
                AgentSettingsModelManifest(
                    id: "test-model",
                    kind: .remoteAPI,
                    modelID: "local/test-model"
                )
            ]
        )

        try await bridge.newSession(id: nil, params: [
            "cwd": "/tmp/acp-tools-workspace",
            "allowed_tools": ["shell"] as [String],
            "mcpServers": [
                [
                    "type": "stdio",
                    "name": "Unavailable",
                    "command": "/path/that/does/not/exist/fixture-server",
                    "args": [] as [String]
                ] as [String: Any]
            ]
        ])

        let configuration = try #require(await bridge.sessionConfigurationsForTesting().first)
        let allowedToolNames = try #require(configuration.allowedToolNames)

        #expect(allowedToolNames.contains("local.exec"))
        #expect(!allowedToolNames.contains("unavailable.run"))
    }

    @Test
    func newSessionConsumesAllowedToolsFromACPParams() async throws {
        let backend = CapturingACPBackend()
        let bridge = try makeBridge(
            models: [
                AgentSettingsModelManifest(
                    id: "test-model",
                    kind: .remoteAPI,
                    modelID: "local/test-model"
                )
            ],
            backendFactory: { _, _ in backend }
        )

        try await bridge.newSession(id: nil, params: [
            "cwd": "/tmp/acp-tools-workspace",
            "allowed_tools": ["custom.", "shell"] as [String]
        ])

        let configuration = try #require(await bridge.sessionConfigurationsForTesting().first)
        let allowedToolNames = try #require(configuration.allowedToolNames)

        #expect(allowedToolNames.contains("custom."))
        #expect(allowedToolNames.contains("local.exec"))
        try await bridge.prompt(id: nil, params: [
            "sessionId": configuration.sessionID,
            "prompt": "verify tools"
        ])
        #expect(await backend.createdAllowedToolNames() == allowedToolNames)
    }

    @Test
    func acpReadOnlyProfileCannotRestoreMutableCoreToolsFromClientSelection() async throws {
        let profile = AgentProfile(
            id: "read-only",
            name: "Read Only",
            readOnly: true
        )
        let rawCompatibilityAlias = "agent.spawn"
        let bridge = try makeBridge(
            models: [
                AgentSettingsModelManifest(
                    id: "test-model",
                    kind: .remoteAPI,
                    modelID: "local/test-model"
                )
            ],
            availableAgents: [profile],
            agentName: profile.name
        )

        try await bridge.newSession(id: nil, params: [
            "cwd": "/tmp/acp-read-only-tools",
            "agentId": profile.id,
            "allowed_tools": ["shell", "files", "custom.", rawCompatibilityAlias] as [String]
        ])

        let configuration = try #require(await bridge.sessionConfigurationsForTesting().first)
        let allowedToolNames = try #require(configuration.allowedToolNames)
        let mutatingCoreNames = Set(DirectToolCatalog.coreMutatingDescriptors.map(\.name))

        #expect(allowedToolNames.isDisjoint(with: mutatingCoreNames))
        #expect(allowedToolNames.contains("local.readFile"))
        #expect(allowedToolNames.contains("custom."))
        #expect(allowedToolNames.contains(rawCompatibilityAlias))
        #expect(
            !DirectToolExecutor.isCoreCoordinationToolAllowed(
                rawCompatibilityAlias,
                allowedToolNames: allowedToolNames
            )
        )
    }

    @Test
    func acpAgentMentionReappliesReadOnlyCoreToolPolicy() async throws {
        let developer = AgentProfile(
            id: "developer",
            name: "Developer",
            tools: ["shell", "files"]
        )
        let reviewer = AgentProfile(
            id: "reviewer",
            name: "Reviewer",
            readOnly: true,
            tools: ["shell", "files"]
        )
        let bridge = try makeBridge(
            models: [
                AgentSettingsModelManifest(
                    id: "test-model",
                    kind: .remoteAPI,
                    modelID: "local/test-model"
                )
            ],
            availableAgents: [developer, reviewer],
            agentName: developer.name,
            backendFactory: { _, _ in CapturingACPBackend() }
        )

        try await bridge.newSession(id: nil, params: [
            "cwd": "/tmp/acp-read-only-agent-switch",
            "agentId": developer.id,
            "allowed_tools": ["shell", "files"] as [String]
        ])
        let sessionID = try #require(
            await bridge.sessionConfigurationsForTesting().first?.sessionID
        )

        try await bridge.prompt(id: nil, params: [
            "sessionId": sessionID,
            "prompt": "@Reviewer inspect the change"
        ])

        let configuration = try #require(await bridge.sessionConfigurationsForTesting().first)
        let allowedToolNames = try #require(configuration.allowedToolNames)
        let mutatingCoreNames = Set(DirectToolCatalog.coreMutatingDescriptors.map(\.name))

        #expect(allowedToolNames.isDisjoint(with: mutatingCoreNames))
        #expect(allowedToolNames.contains("local.readFile"))
    }

    @Test
    func newSessionIgnoresNonStandardSystemPromptParameter() async throws {
        let bridge = try makeBridge(
            models: [
                AgentSettingsModelManifest(
                    id: "test-model",
                    kind: .remoteAPI,
                    modelID: "local/test-model"
                )
            ]
        )

        try await bridge.newSession(id: nil, params: [
            "cwd": "/tmp/acp-system-prompt-workspace",
            "systemPrompt": "CLIENT-SYSTEM-PROMPT-SHOULD-NOT-BE-INJECTED"
        ])

        let configuration = try #require(await bridge.sessionConfigurationsForTesting().first)
        let systemPrompt = try #require(configuration.systemPrompt)

        #expect(!systemPrompt.contains("CLIENT-SYSTEM-PROMPT-SHOULD-NOT-BE-INJECTED"))
    }

    @Test
    func newSessionUsesHostedDefaultThinkingWhenThinkingIsNotProvided() async throws {
        let bridge = try makeBridge(
            models: [
                Self.thinkingModel(defaultThinkingSelection: .high)
            ]
        )

        try await bridge.newSession(id: nil, params: [
            "cwd": "/tmp/acp-thinking-workspace"
        ])

        let configuration = try #require(await bridge.sessionConfigurationsForTesting().first)

        #expect(configuration.thinkingSelection == .high)
    }

    @Test
    func newSessionUsesAgentThinkingOverHostedDefault() async throws {
        let model = Self.thinkingModel(defaultThinkingSelection: .medium)
        let agent = AgentProfile(
            id: "thinking-agent",
            name: "Thinking Agent",
            tools: [],
            modelID: model.id,
            thinkingSelection: .high
        )
        let bridge = try makeBridge(
            models: [model],
            availableAgents: [agent],
            agentName: agent.name
        )

        try await bridge.newSession(id: nil, params: [
            "cwd": "/tmp/acp-thinking-workspace"
        ])

        let configuration = try #require(await bridge.sessionConfigurationsForTesting().first)

        #expect(configuration.modelID == model.id)
        #expect(configuration.thinkingSelection == .high)
    }

}
