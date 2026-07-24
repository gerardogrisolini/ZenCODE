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
                    id: "search-tools",
                    source: .bundled,
                    tools: ["search.glob", "search.grep", "search.locate"]
                ),
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
    func developerProfileEnablesCoreAndFeaturePackageTools() {
        let profile = AgentProfile(
            id: "developer",
            name: "Developer",
            tools: AgentProfileStore.developerToolNames
        )
        let allowedToolNames = profile.allowedToolNames()

        #expect(allowedToolNames.contains("local.exec"))
        #expect(allowedToolNames.contains("local.readFile"))
        #expect(allowedToolNames.contains("local.inspectFile"))
        #expect(allowedToolNames.contains("search.grep"))
        #expect(allowedToolNames.contains("search.locate"))
        #expect(allowedToolNames.contains("text.wc"))
        #expect(!allowedToolNames.contains("feature.list"))
    }

    @Test
    func xcodeToolReferencesSelectRuntimePackageBeforeDiscovery() throws {
        let items = TerminalChat.toolSelectionItems(
            featureStatuses: [
                featureStatus(
                    id: "xcode-tools",
                    source: .bundled,
                    tools: [],
                    toolNamePrefixes: ["xcode.", "Xcode"],
                    discoversToolsAtRuntime: true
                )
            ]
        )
        let xcodeKey = TerminalToolSelectionCatalog.featurePackageKey(id: "xcode-tools")

        let selectedKeys = TerminalChat.toolSelectionKeys(
            from: ["xcode", "xcode.", "xcode.BuildProject", "XcodeBuildProject"],
            items: items
        )
        let discoveryPrefixes = TerminalToolSelectionCatalog.externalDiscoveryPrefixes(
            for: selectedKeys,
            items: items
        )

        #expect(selectedKeys == Set([xcodeKey]))
        #expect(discoveryPrefixes.contains("xcode."))
    }

    @Test
    func swiftOutlineStaysInSwiftFeaturePackageSelection() throws {
        let items = TerminalChat.toolSelectionItems(
            featureStatuses: [
                featureStatus(
                    id: "swift-tools",
                    source: .bundled,
                    tools: ["swift.build", "swift.test", "swift.run", "swift.package", "swift.outline"]
                )
            ]
        )

        let selectedKeys = try TerminalChat.parseToolSelection(
            "swift",
            items: items
        )
        let allowedToolNames = TerminalToolSelectionCatalog.allowedToolNames(
            for: selectedKeys,
            items: items
        )

        #expect(allowedToolNames.contains("swift.outline"))
        #expect(allowedToolNames.contains("swift.build"))

        let developerProfile = AgentProfile(
            id: "developer",
            name: "Developer",
            tools: AgentProfileStore.developerToolNames
        )
        let developerAllowedToolNames = developerProfile.allowedToolNames()

        #expect(!developerAllowedToolNames.contains("swift.outline"))
        #expect(!developerAllowedToolNames.contains("swift.build"))
    }

    @Test
    func agentAllowedToolNamesNormalizeDirectXcodeReferences() {
        let profile = AgentProfile(
            id: "xcode-agent",
            name: "Xcode Agent",
            tools: ["xcode", "xcode.BuildProject"]
        )

        let allowedToolNames = profile.allowedToolNames()

        #expect(DirectMCPToolRuntime.discoveryFamilies(allowedToolNames: allowedToolNames).contains("xcode"))
        #expect(DirectToolExecutor.isAllowed("xcode.BuildProject", allowedToolNames: allowedToolNames))
    }

    @Test
    func unavailableXcodeStaysSelectedButIsNotDiscoverable() {
        let requestedToolNames = Set([
            "local.exec",
            "xcode.",
            "xcode.BuildProject",
            "Xcode",
            "figma."
        ])

        let allowedToolNames = ExternalToolAvailability.resolvedAllowedToolNames(requestedToolNames)
        let discoverableToolNames = ExternalToolAvailability.discoverableToolPrefixes(
            requestedToolNames,
            xcodeIsRunning: false
        )

        #expect(allowedToolNames?.contains("local.exec") == true)
        #expect(allowedToolNames?.contains("figma.") == true)
        #expect(allowedToolNames?.contains("xcode.") == true)
        #expect(allowedToolNames?.contains("xcode.BuildProject") == true)
        #expect(allowedToolNames?.contains("Xcode") == true)
        #expect(discoverableToolNames.contains("xcode.") == false)
        #expect(discoverableToolNames.contains("xcode.BuildProject") == false)
        #expect(discoverableToolNames.contains("Xcode") == false)
    }

    @Test
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
    func deselectingSkillUpdatesOnlyTheSessionProvider() async throws {
        let workingDirectory = URL(
            fileURLWithPath: "/tmp/ZenCODE-skill-revocation",
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
            promptBody: "FULL-SKILL-BODY",
            sourceHash: "release-review-hash"
        )
        terminal.availableSkillsCache = [skill]
        terminal.selectedSkillIDs = [skill.id]
        terminal.activeSessionHistory = [
            AgentRuntimeMessage(
                role: .assistant,
                content: "Loaded guidance.",
                toolCalls: [
                    AgentRuntimeToolCall(
                        id: "skill-read",
                        name: PromptSkillToolProvider.toolName,
                        argumentsJSON: #"{"identifier":"release-review"}"#
                    )
                ]
            ),
            AgentRuntimeMessage(
                role: .tool,
                content: "FULL-SKILL-BODY",
                toolCallID: "skill-read",
                toolName: PromptSkillToolProvider.toolName
            )
        ]

        try await terminal.createCurrentSession(discoverExternalTools: false)
        let initialCreateCount = await backend.createCount()
        let initialUpdateCount = await backend.updateCount()
        let preDeselectionSnapshot = try #require(
            await runner.snapshotSession(id: terminal.sessionID)
        )

        await terminal.applySkillSelection([])
        let snapshot = try #require(await runner.snapshotSession(id: terminal.sessionID))

        // Deselection must not create/update the remote session or alter its
        // prompt, allowlist, cache key, or history. Revocation is
        // non-retroactive, so the continuation and KV-cache prefix stay valid.
        #expect(await backend.createCount() == initialCreateCount)
        #expect(await backend.updateCount() == initialUpdateCount)
        #expect(snapshot.systemPrompt == preDeselectionSnapshot.systemPrompt)
        #expect(snapshot.allowedToolNames == preDeselectionSnapshot.allowedToolNames)
        #expect(snapshot.cacheKey == preDeselectionSnapshot.cacheKey)
        #expect(snapshot.history.count == preDeselectionSnapshot.history.count)
        #expect(snapshot.history.contains { $0.content.contains("FULL-SKILL-BODY") })
        // Both skill tools remain always-on even with no selection.
        #expect(snapshot.allowedToolNames?.contains(PromptSkillToolProvider.toolName) == true)
        #expect(snapshot.systemPrompt?.contains("FULL-SKILL-BODY") == false)
    }

    @Test
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
    func xcodeWorkspaceRootMatchesNestedWorkingDirectoryButRejectsSiblings() {
        #expect(
            XcodeWorkspaceContext.workspaceRootPath(
                "/tmp/XcodeApp",
                matchesPreferredRootPath: "/tmp/XcodeApp/Modules/Feature"
            )
        )
        #expect(
            XcodeWorkspaceContext.workspaceRootPath(
                "/tmp/XcodeApp/XcodeApp.xcodeproj",
                matchesPreferredRootPath: "/tmp/XcodeApp"
            )
        )
        #expect(
            !XcodeWorkspaceContext.workspaceRootPath(
                "/tmp/OtherApp",
                matchesPreferredRootPath: "/tmp/XcodeApp"
            )
        )
    }

    @Test
    func xcodeDiscoveryRejectsDifferentWorkspace() async {
        let runtime = DirectMCPToolRuntime(
            xcodeDiscoveryProvider: {
                Self.xcodeDiscovery(workspacePath: "/tmp/OtherApp/OtherApp.xcodeproj")
            }
        )

        let descriptors = await runtime.discoverDescriptors(
            allowedToolNames: ["xcode."],
            preferredWorkspaceRootURL: URL(fileURLWithPath: "/tmp/XcodeApp")
        )

        #expect(descriptors.isEmpty)
    }

    @Test
    func xcodeDiscoveryAcceptsWorkspaceContainingWorkingDirectory() async {
        let runtime = DirectMCPToolRuntime(
            xcodeDiscoveryProvider: {
                Self.xcodeDiscovery(workspacePath: "/tmp/XcodeApp/XcodeApp.xcodeproj")
            }
        )

        let descriptors = await runtime.discoverDescriptors(
            allowedToolNames: ["xcode."],
            preferredWorkspaceRootURL: URL(fileURLWithPath: "/tmp/XcodeApp/Modules/Feature")
        )

        #expect(descriptors.map(\.name) == ["xcode.BuildProject"])
    }

    @Test
    func xcodeDiscoveryKeepsGrantedSessionForMismatchedWorkspace() async {
        let discoveryProbe = XcodeDiscoveryProbe()
        let runtime = DirectMCPToolRuntime(
            xcodeDiscoveryProvider: {
                await discoveryProbe.discovery(workspacePath: "/tmp/XcodeApp/XcodeApp.xcodeproj")
            }
        )

        let initialDescriptors = await runtime.discoverDescriptors(
            allowedToolNames: ["xcode."],
            preferredWorkspaceRootURL: URL(fileURLWithPath: "/tmp/XcodeApp")
        )
        let otherWorkspaceDescriptors = await runtime.discoverDescriptors(
            allowedToolNames: ["xcode."],
            preferredWorkspaceRootURL: URL(fileURLWithPath: "/tmp/OtherApp")
        )
        let restoredWorkspaceDescriptors = await runtime.discoverDescriptors(
            allowedToolNames: ["xcode."],
            preferredWorkspaceRootURL: URL(fileURLWithPath: "/tmp/XcodeApp")
        )

        #expect(initialDescriptors.map(\.name) == ["xcode.BuildProject"])
        #expect(otherWorkspaceDescriptors.isEmpty)
        #expect(restoredWorkspaceDescriptors.map(\.name) == ["xcode.BuildProject"])
        #expect(await discoveryProbe.count() == 1)
    }

    @Test
    func appSessionConfigurationKeepsClosedXcodeSelection() throws {
        let xcodeAgent = AgentProfile(
            id: "xcode-agent",
            name: "Xcode Agent",
            tools: ["shell", "xcode"]
        )

        let allowedToolNames = AgentCoreAppSessionFactory.resolvedAllowedToolNames(
            selectedToolKeys: nil,
            explicitAllowedToolNames: nil,
            selectedAgent: xcodeAgent
        )

        #expect(allowedToolNames?.contains("local.exec") == true)
        #expect(allowedToolNames?.contains("xcode.") == true)
    }

    @Test
    func groupedModelTitlesOmitRedundantProviderFallback() throws {
        let providerID = UUID(uuidString: "11111111-1111-1111-1111-111111111111")!
        let fallbackTitleModel = AgentSettingsModelManifestFactory.remoteAPIModel(
            title: nil,
            modelID: "remote-community/qwen3",
            providerID: providerID,
            providerName: "remote-server",
            baseURL: "http://127.0.0.1:8080/v1",
            chatEndpoint: .responses,
            configuredContextWindowLimit: nil,
            generationParameterOverrides: nil,
            thinkingSupport: nil
        )
        let titledModel = AgentSettingsModelManifestFactory.remoteAPIModel(
            title: "Qwen3 Local",
            modelID: "remote-community/qwen3-local",
            providerID: providerID,
            providerName: "remote-server",
            baseURL: "http://127.0.0.1:8080/v1",
            chatEndpoint: .responses,
            configuredContextWindowLimit: nil,
            generationParameterOverrides: nil,
            thinkingSupport: nil
        )

        let group = try #require(
            AgentModelCatalogPresentation.groupedByProvider([fallbackTitleModel, titledModel])
                .first { $0.title == "remote-server" }
        )

        #expect(fallbackTitleModel.displayTitle == "remote-server - remote-community/qwen3")
        #expect(AgentModelCatalogPresentation.modelTitle(for: fallbackTitleModel) == "remote-community/qwen3")
        #expect(AgentModelCatalogPresentation.modelTitle(for: fallbackTitleModel, in: group) == "remote-community/qwen3")
        #expect(AgentModelCatalogPresentation.modelTitle(for: titledModel, in: group) == "Qwen3 Local")
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
