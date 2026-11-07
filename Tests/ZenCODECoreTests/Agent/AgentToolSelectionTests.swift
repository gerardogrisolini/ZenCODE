//
//  AgentConfigurationTests.swift
//  ZenCODE
//
//  Created by Gerardo Grisolini on 30/05/26.
//

import Foundation
@testable import ZenCODECore
import Testing

extension AgentConfigurationTests {
    @Test
    func toolSelectionKeysKeepCoreAndFeaturePackagesDistinct() throws {
        let items = TerminalChat.toolSelectionItems(
            featureStatuses: [
                featureStatus(
                    id: "git-tools",
                    source: .bundled,
                    tools: ["git.status"]
                )
            ]
        )

        let selectedKeys = try TerminalChat.parseToolSelection(
            "shell files text search git",
            items: items
        )
        let allowedToolNames = TerminalToolSelectionCatalog.allowedToolNames(
            for: selectedKeys,
            items: items
        )

        #expect(selectedKeys.contains("search"))
        #expect(allowedToolNames.contains("local.exec"))
        #expect(allowedToolNames.contains("local.readFile"))
        #expect(allowedToolNames.contains("local.inspectFile"))
        #expect(allowedToolNames.contains("text.wc"))
        #expect(!allowedToolNames.contains("feature.list"))
        #expect(allowedToolNames.contains("search.grep"))
        #expect(allowedToolNames.contains("search.locate"))
        #expect(allowedToolNames.contains("git.status"))
    }

    @Test
    func developerProfileKeepsOptionalFeatureSelectionsButOnlyExpandsInstalledTools() {
        let profile = AgentProfile(
            id: "developer",
            name: "Developer",
            role: .developer,
            tools: AgentProfileStore.developerToolNames
        )

        let gitSelectionKey = TerminalToolSelectionCatalog.featurePackageKey(id: "git-tools")
        #expect(profile.tools.contains(gitSelectionKey))
        #expect(profile.tools.contains("search"))

        let coreItems = TerminalToolSelectionCatalog.items(featureStatuses: [])
        let coreAllowedToolNames = TerminalToolSelectionCatalog.allowedToolNames(
            for: Set(profile.tools.filter { !$0.hasPrefix(TerminalToolSelectionCatalog.featurePackageKeyPrefix) }),
            items: coreItems
        )
        #expect(coreAllowedToolNames.contains("local.exec"))
        #expect(coreAllowedToolNames.contains("local.readFile"))
        #expect(coreAllowedToolNames.contains("local.inspectFile"))
        #expect(coreAllowedToolNames.contains("search.glob"))
        #expect(coreAllowedToolNames.contains("search.grep"))
        #expect(coreAllowedToolNames.contains("search.locate"))
        #expect(coreAllowedToolNames.contains("text.wc"))
        #expect(!coreAllowedToolNames.contains("feature.list"))

        let uninstalledItems = TerminalToolSelectionCatalog.items(
            featureStatuses: [
                featureStatus(
                    id: "git-tools",
                    source: .bundled,
                    tools: ["git.status", "git.diff"],
                    enabled: false,
                    available: false
                )
            ]
        )
        let uninstalledAllowedToolNames = TerminalToolSelectionCatalog.allowedToolNames(
            for: [gitSelectionKey],
            items: uninstalledItems
        )

        #expect(!uninstalledItems.contains { $0.key == gitSelectionKey })
        #expect(!uninstalledAllowedToolNames.contains("git.status"))
        #expect(!uninstalledAllowedToolNames.contains("git.diff"))

        let installedItems = TerminalToolSelectionCatalog.items(
            featureStatuses: [
                featureStatus(
                    id: "git-tools",
                    source: .generated,
                    tools: ["git.status", "git.diff"],
                    enabled: true,
                    available: true
                )
            ]
        )
        let installedAllowedToolNames = TerminalToolSelectionCatalog.allowedToolNames(
            for: [gitSelectionKey],
            items: installedItems
        )

        #expect(installedItems.contains { $0.key == gitSelectionKey })
        #expect(installedAllowedToolNames.contains("git.status"))
        #expect(installedAllowedToolNames.contains("git.diff"))
    }

    @Test
    @ChatSessionActor
    func skillSelectionUpdatesAnExistingSessionWithoutRecreatingIt() async throws {
        let workingDirectory = URL(
            fileURLWithPath: "/tmp/ZenCODE-skill-selection",
            isDirectory: true
        )
        let configuration = try AgentConfiguration(
            hostedModelID: "remote-community/test",
            availableAgents: AgentProfileStore.defaultProfiles(),
            workingDirectory: workingDirectory
        )
        let backend = SkillSelectionCountingBackend()
        let runner = AgentCoreSessionRunner(
            backendFactory: { _, _ in backend }
        )
        let terminal = TerminalChat(
            configuration: configuration,
            stdinIsTerminal: false,
            sessionRunner: runner
        )
        let skill = PromptSkill(
            canonicalName: "release-review",
            title: "Release Review",
            summary: "Review release changes before publishing.",
            promptBody: "FULL-SKILL-BODY: inspect changelog.",
            sourceHash: "release-review-hash"
        )
        terminal.availableSkillsCache = [skill]

        try await terminal.createCurrentSession(discoverExternalTools: false)
        let initialConfiguration = terminal.currentSessionConfiguration(
            allowedToolNames: []
        )
        _ = try await runner.sendPrompt(
            configuration: initialConfiguration,
            prompt: "Initial request",
            attachments: [],
            onEvent: { _ in }
        )

        let preSelectionCreateCount = await backend.createCount()
        let preSelectionUpdateCount = await backend.updateCount()
        let preSelectionSnapshot = try #require(
            await runner.snapshotSession(id: terminal.sessionID)
        )

        await terminal.applySkillSelection([skill.id])
        let snapshot = try #require(
            await runner.snapshotSession(id: terminal.sessionID)
        )

        // Selecting a skill must not create or update the remote session, nor
        // change its prompt, allowlist, or cache key.
        #expect(preSelectionCreateCount > 0)
        #expect(await backend.createCount() == preSelectionCreateCount)
        #expect(await backend.updateCount() == preSelectionUpdateCount)
        #expect(snapshot.systemPrompt == preSelectionSnapshot.systemPrompt)
        #expect(snapshot.allowedToolNames == preSelectionSnapshot.allowedToolNames)
        #expect(snapshot.cacheKey == preSelectionSnapshot.cacheKey)
        let effectiveAllowedToolNames = await terminal.selectedAllowedToolNames(
            discoverExternalTools: false
        )
        // Both skill tools are intrinsic and always advertised.
        #expect(effectiveAllowedToolNames.contains(PromptSkillToolProvider.listToolName))
        #expect(effectiveAllowedToolNames.contains(PromptSkillToolProvider.toolName))
        #expect(snapshot.allowedToolNames?.contains(PromptSkillToolProvider.listToolName) == true)
        #expect(snapshot.allowedToolNames?.contains(PromptSkillToolProvider.toolName) == true)
        // The prompt is the static skill instruction, with no catalog or body.
        #expect(snapshot.systemPrompt?.contains(SystemPromptBuilder.staticSkillSectionMarker) == true)
        #expect(snapshot.systemPrompt?.contains(skill.summary) == false)
        #expect(snapshot.systemPrompt?.contains("FULL-SKILL-BODY") == false)
    }

    @Test
    @ChatSessionActor
    func toolSelectionChangeResetsSessionAndInformsModel() async throws {
        let workingDirectory = URL(
            fileURLWithPath: "/tmp/ZenCODE-tool-selection",
            isDirectory: true
        )
        let configuration = try AgentConfiguration(
            hostedModelID: "remote-community/test",
            availableAgents: AgentProfileStore.defaultProfiles(),
            workingDirectory: workingDirectory
        )
        let runner = AgentCoreSessionRunner()
        let terminal = TerminalChat(
            configuration: configuration,
            stdinIsTerminal: false,
            sessionRunner: runner
        )
        let items = TerminalChat.toolSelectionItems(featureStatuses: [])
        terminal.selectedToolKeys = try TerminalChat.parseToolSelection(
            "shell",
            items: items
        )
        terminal.activeSessionHistory = [
            AgentRuntimeMessage(role: .user, content: "First request"),
            AgentRuntimeMessage(
                role: .assistant,
                content: "I used shell.",
                toolCalls: [
                    AgentRuntimeToolCall(
                        id: "call_shell",
                        name: "local.exec",
                        argumentsJSON: #"{"cmd":"pwd"}"#
                    )
                ]
            ),
            AgentRuntimeMessage(
                role: .tool,
                content: workingDirectory.path,
                toolCallID: "call_shell",
                toolName: "local.exec"
            )
        ]

        try await terminal.createCurrentSession(discoverExternalTools: false)
        terminal.selectedToolKeys = []
        let allowedToolNames = await terminal.updateCurrentSessionToolOptions(
            discoverExternalTools: false
        )
        let snapshot = try #require(await runner.snapshotSession(id: terminal.sessionID))
        let notice = try #require(snapshot.history.last)

        #expect(allowedToolNames == PromptSkillToolProvider.toolNames)
        #expect(snapshot.allowedToolNames == PromptSkillToolProvider.toolNames)
        #expect(notice.role == .system)
        #expect(notice.content.contains("Tool selection changed during this session."))
        #expect(notice.content.contains("Current available tool names: skills.list, skills.read."))
        #expect(notice.content.contains("Removed tool names:"))
        #expect(notice.content.contains("local.exec"))
        #expect(notice.content.contains("historical context"))
    }

    @Test
    @ChatSessionActor
    func toolsSelectionCannotReenableMutableCoreToolsForReadOnlyProfile() async throws {
        let profile = AgentProfile(
            id: "read-only",
            name: "Read Only",
            readOnly: true,
            role: .developer
        )
        let configuration = try AgentConfiguration(
            hostedModelID: "remote-community/test",
            availableAgents: AgentProfileStore.defaultProfiles() + [profile],
            workingDirectory: URL(fileURLWithPath: "/tmp/ZenCODE-read-only-tools")
        )
        let terminal = TerminalChat(
            configuration: configuration,
            stdinIsTerminal: false,
            sessionRunner: AgentCoreSessionRunner()
        )
        terminal.selectedAgent = profile
        terminal.selectedToolKeys = ["shell", "files", "memory", "sub-agents"]

        let allowedToolNames = await terminal.selectedAllowedToolNames(
            discoverExternalTools: false
        )
        let mutatingCoreNames = Set(DirectToolCatalog.coreMutatingDescriptors.map(\.name))

        #expect(allowedToolNames.isDisjoint(with: mutatingCoreNames))
        #expect(allowedToolNames.contains("local.readFile"))
        #expect(allowedToolNames.contains("memory.read"))
        #expect(allowedToolNames.contains("agent.list"))
        #expect(allowedToolNames.contains("tasks.list"))
    }
}

private actor SkillSelectionCountingBackend: AgentRuntimeBackend {
    private var created = 0
    private var updated = 0

    func createSession(
        id _: String,
        cwd _: String,
        systemPrompt _: String?,
        history _: [AgentRuntimeMessage],
        cacheKey _: String?,
        allowedToolNames _: Set<String>?,
        thinkingSelection _: AgentThinkingSelection?,
        preserveThinking _: Bool
    ) {
        created += 1
    }

    func createSessionIfNeeded(
        id _: String,
        cwd _: String,
        systemPrompt _: String?,
        history _: [AgentRuntimeMessage],
        cacheKey _: String?,
        allowedToolNames _: Set<String>?,
        thinkingSelection _: AgentThinkingSelection?,
        preserveThinking _: Bool
    ) {}

    func updateSessionOptions(
        id _: String,
        systemPrompt _: String?,
        allowedToolNames _: Set<String>?,
        thinkingSelection _: AgentThinkingSelection?,
        preserveThinking _: Bool
    ) {
        updated += 1
    }

    func closeSession(id _: String) {}

    func shutdown() async {}

    func preloadModel(
        onEvent _: @escaping @Sendable (DirectAgentEvent) async -> Void
    ) async throws -> String {
        "test-model"
    }

    func activeToolDescriptors() async -> [DirectToolDescriptor] {
        []
    }

    func sendPrompt(
        sessionID _: String,
        prompt _: String,
        attachments _: [AgentRuntimeAttachment],
        onEvent _: @escaping @Sendable (DirectAgentEvent) async -> Void
    ) async throws -> DirectAgentResponse {
        DirectAgentResponse(text: "", stopReason: "end_turn", modelID: "test-model")
    }

    func createCount() -> Int {
        created
    }

    func updateCount() -> Int {
        updated
    }
}
