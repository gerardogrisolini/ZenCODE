//
//  TerminalChatLaunchFolderProjectsTests.swift
//  ZenCODE
//

import Foundation
import Testing
@testable import ZenCODECore

@Suite
struct TerminalChatLaunchFolderProjectsTests {
    private typealias Support = ProjectAgentSelectionTestSupport

    private static let organizer = AgentProfile(
        id: "organizer",
        name: "Organizer",
        role: .organizer
    )
    private static let headline = "Projects in the launch folder:"

    @Test
    func theListingIsReadWhenTheOrganizerIsSelectedAndNeverOnLaterSends() async throws {
        try await Support.withTemporaryProjectAsync { _, workspace in
            try await Self.selectionScenario(in: workspace)
        }
    }

    @Test
    func theCacheIsKeyedByTheSelectedAgentAndRefilledAfterAnInvalidation() async throws {
        try await Support.withTemporaryProjectAsync { _, workspace in
            try await Self.cacheKeyScenario(in: workspace)
        }
    }

    private nonisolated static func makeFolder(_ name: String, in workspace: URL) throws {
        try FileManager.default.createDirectory(
            at: workspace.appendingPathComponent(name, isDirectory: true),
            withIntermediateDirectories: true
        )
    }

    /// Drives the real `applyAgentSelection` of a terminal chat and checks
    /// what each later prompt composition lists.
    @TerminalChatActor
    private static func selectionScenario(in workspace: URL) async throws {
        let agents = [Support.developer, Self.organizer]
        try AgentProfileStore.save(agents)
        try makeFolder("beta", in: workspace)
        try makeFolder("alpha", in: workspace)
        let terminal = TerminalChat(
            configuration: try AgentConfiguration(
                hostedModelID: "remote-community/test",
                availableAgents: agents,
                workingDirectory: workspace
            ),
            stdinIsTerminal: false,
            sessionRunner: AgentCoreSessionRunner(
                backendFactory: { _, _ in LaunchFolderStubBackend() }
            )
        )

        // No agent is selected: no listing, no cache.
        #expect(!terminal.currentPromptSections(allowedToolNames: []).dynamicContext.contains(headline))
        #expect(terminal.launchFolderProjectsForSelectedAgent() == nil)
        #expect(terminal.launchFolderProjectsCache == nil)

        // Selecting the Organizer reads the folder once, when the session is
        // created.
        try await terminal.applyAgentSelection(organizer)
        #expect(terminal.launchFolderProjectsCache?.projects.folderNames == ["alpha", "beta"])
        #expect(
            terminal.launchFolderProjectsCache?.agentKey
                == ProjectAgentSelectionStore.selectionKey(for: organizer)
        )
        let selectedAt = try #require(terminal.launchFolderProjectsCache?.projects)
        let firstContext = terminal.currentSessionConfiguration(allowedToolNames: []).dynamicContext
        #expect(firstContext?.contains(headline) == true)
        #expect(firstContext?.contains("\n- alpha\n- beta") == true)

        // A folder created afterwards does not appear on later sends, nor
        // after a `/tools`-style recomposition.
        try makeFolder("gamma", in: workspace)
        for _ in 0..<3 {
            let sections = terminal.currentPromptSections(allowedToolNames: [])
            #expect(sections.dynamicContext.contains("\n- alpha\n- beta"))
            #expect(!sections.dynamicContext.contains("gamma"))
            let context = terminal.currentSessionConfiguration(allowedToolNames: []).dynamicContext
            #expect(context?.contains("gamma") == false)
        }
        await terminal.updateCurrentSessionToolOptions(discoverExternalTools: false)
        #expect(!terminal.currentPromptSections(allowedToolNames: []).dynamicContext.contains("gamma"))
        #expect(terminal.launchFolderProjectsCache?.projects == selectedAt)

        // Selecting the Organizer again reads the folder anew.
        try await terminal.applyAgentSelection(organizer)
        #expect(terminal.launchFolderProjectsCache?.projects.folderNames == ["alpha", "beta", "gamma"])
        let reselected = terminal.currentSessionConfiguration(allowedToolNames: []).dynamicContext
        #expect(reselected?.contains("\n- alpha\n- beta\n- gamma") == true)

        // Another agent gets no listing.
        try await terminal.applyAgentSelection(Support.developer)
        #expect(terminal.launchFolderProjectsForSelectedAgent() == nil)
        let developerContext = terminal.currentSessionConfiguration(allowedToolNames: []).dynamicContext
        #expect(developerContext?.contains(headline) == false)
    }

    @TerminalChatActor
    private static func cacheKeyScenario(in workspace: URL) throws {
        try makeFolder("one", in: workspace)
        try makeFolder("two", in: workspace)
        let terminal = TerminalChat(
            configuration: try AgentConfiguration(
                hostedModelID: "remote-community/test",
                availableAgents: [Support.developer, organizer],
                workingDirectory: workspace
            ),
            stdinIsTerminal: false
        )

        terminal.selectedAgent = Support.developer
        #expect(terminal.launchFolderProjectsForSelectedAgent() == nil)
        #expect(terminal.launchFolderProjectsCache == nil)

        terminal.selectedAgent = organizer
        let first = try #require(terminal.launchFolderProjectsForSelectedAgent())
        #expect(first.folderNames == ["one", "two"])
        #expect(first.workingDirectoryPath == workspace.standardizedFileURL.path)

        try makeFolder("three", in: workspace)
        // Same selection: the cached snapshot is returned.
        #expect(terminal.launchFolderProjectsForSelectedAgent() == first)

        // A cache read for another selection key is not reused.
        terminal.launchFolderProjectsCache = TerminalChat.LaunchFolderProjectsCache(
            agentKey: "another-agent",
            projects: first
        )
        let refreshed = try #require(terminal.launchFolderProjectsForSelectedAgent())
        #expect(refreshed.folderNames == ["one", "three", "two"])
        #expect(
            terminal.launchFolderProjectsCache?.agentKey
                == ProjectAgentSelectionStore.selectionKey(for: organizer)
        )

        // After an invalidation the next composition reads the folder again.
        try makeFolder("four", in: workspace)
        terminal.launchFolderProjectsCache = nil
        #expect(
            try #require(terminal.launchFolderProjectsForSelectedAgent()).folderNames
                == ["four", "one", "three", "two"]
        )
    }
}

private actor LaunchFolderStubBackend: AgentRuntimeBackend {
    func createSession(
        id _: String,
        cwd _: String,
        systemPrompt _: String?,
        history _: [AgentRuntimeMessage],
        cacheKey _: String?,
        allowedToolNames _: Set<String>?,
        thinkingSelection _: AgentThinkingSelection?,
        preserveThinking _: Bool
    ) {}

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
    ) {}

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
}
