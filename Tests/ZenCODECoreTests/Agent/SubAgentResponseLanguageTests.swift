//
//  SubAgentResponseLanguageTests.swift
//  ZenCODECoreTests
//
//  The coordinator's response-language section reaches delegated agents: the
//  channel's section rides on the session configuration, `AgentCoreBackend`
//  keeps it per session and installs one source per backend incarnation, and
//  the section never takes part in the session identity, so it recreates
//  neither the backend nor the session.
//

import Foundation
import Testing
@testable import ZenCODECore

@Suite
struct SubAgentResponseLanguageTests {
    private static let italian = SystemPromptBuilder.responseLanguageSection(languageName: "Italian")
    private static let english = SystemPromptBuilder.responseLanguageSection(languageName: "English")

    @Test
    func theSessionSectionFeedsASourceInstalledOncePerBackend() async throws {
        try await Self.withTemporarySupportDirectory { directory in
            let backend = ResponseLanguageSourceBackend()
            let runner = AgentCoreSessionRunner(backendFactory: { _, _ in backend })
            let sessionID = "session-language-\(UUID().uuidString)"
            let configuration = Self.configuration(
                sessionID: sessionID,
                directory: directory,
                section: Self.italian
            )
            try await runner.createSession(configuration: configuration)
            // The runtime backend is resolved lazily by the first prompt.
            _ = try await runner.sendPrompt(
                configuration: configuration,
                prompt: "hello",
                attachments: [],
                onEvent: { _ in }
            )
            #expect(await backend.providerInstallCount() == 1)
            #expect(await backend.section(forRootSessionID: sessionID) == Self.italian)
            #expect(await backend.section(forRootSessionID: "another-session") == nil)

            try await runner.updateSessionOptions(
                configuration: Self.configuration(
                    sessionID: sessionID,
                    directory: directory,
                    section: Self.english
                )
            )
            #expect(await backend.section(forRootSessionID: sessionID) == Self.english)
            #expect(await backend.providerInstallCount() == 1)

            await runner.closeSession(id: sessionID)
            #expect(await backend.section(forRootSessionID: sessionID) == nil)
        }
    }

    @Test
    func theSectionIsOutsideTheSessionIdentity() {
        let directory = FileManager.default.temporaryDirectory
        let unlocked = Self.configuration(sessionID: "s", directory: directory, section: nil)
        let locked = AgentCoreSessionConfiguration(
            sessionID: "s",
            modelID: "test-model",
            workingDirectory: directory,
            systemPrompt: unlocked.systemPrompt,
            cacheKey: nil,
            history: [],
            allowedToolNames: [],
            responseLanguageSection: Self.italian
        )
        #expect(locked.matchesSessionIdentity(unlocked))
        #expect(locked.matchesRuntime(unlocked))
        #expect(locked == unlocked)
        // Derived configurations keep it.
        #expect(locked.withModelID("other-model").responseLanguageSection == Self.italian)
        #expect(locked.addingAllowedToolNames(["agent.create"]).responseLanguageSection == Self.italian)
        #expect(
            AgentCoreSessionConfiguration(
                sessionID: "s",
                modelID: nil,
                workingDirectory: directory,
                systemPrompt: nil,
                cacheKey: nil,
                history: [],
                responseLanguageSection: " \n"
            ).responseLanguageSection == nil
        )
    }

    @Test
    func theControllerComposesTheChannelSectionIntoTheConfiguration() async throws {
        try await Self.withTemporarySupportDirectory { directory in
            let agentConfiguration = try AgentConfiguration.withoutPersistedConfiguration(
                arguments: ["zen", "--working-directory", directory.path]
            )
            let locked = await Self.sessionConfiguration(
                configuration: agentConfiguration,
                workingDirectory: directory,
                section: Self.italian
            )
            #expect(locked.responseLanguageSection == Self.italian)
            #expect(locked.systemPrompt?.contains(Self.italian) == true)

            let unlocked = await Self.sessionConfiguration(
                configuration: agentConfiguration,
                workingDirectory: directory,
                section: nil
            )
            #expect(unlocked.responseLanguageSection == nil)
        }
    }

    @Test
    func bothLanguageRulesCoverTheTextWrittenForOtherAgents() {
        for section in [Self.italian, SystemPromptBuilder.responseLanguageSection()] {
            #expect(section.contains("the natural-language text you author for other agents"))
            #expect(section.contains("delegated-agent prompts in agent.create"))
            #expect(section.contains("task descriptions and acceptance criteria"))
            #expect(section.contains("agent.message messages"))
        }
        #expect(Self.italian.contains("Also write in Italian the natural-language text"))
        #expect(SystemPromptBuilder.responseLanguageSection().contains(
            "Also write in that session language the natural-language text"
        ))
    }

    // MARK: - Support

    private static func configuration(
        sessionID: String,
        directory: URL,
        section: String?
    ) -> AgentCoreSessionConfiguration {
        AgentCoreSessionConfiguration(
            sessionID: sessionID,
            modelID: "test-model",
            workingDirectory: directory,
            systemPrompt: ["Base instructions.", section].compactMap { $0 }.joined(separator: "\n\n"),
            cacheKey: nil,
            history: [],
            allowedToolNames: [],
            responseLanguageSection: section
        )
    }

    @ChatSessionActor
    private static func sessionConfiguration(
        configuration: AgentConfiguration,
        workingDirectory: URL,
        section: String?
    ) -> AgentCoreSessionConfiguration {
        let host = ScriptedChatInteractionHost(capabilities: [.toolConsent])
        return ChatSessionController(
            sessionID: "response-language-\(UUID().uuidString.lowercased())",
            runtime: ScriptedChatRuntime(),
            environment: ChatSessionEnvironment(configuration: configuration, featureRuntime: nil),
            workingDirectory: workingDirectory,
            presenter: RecordingChatPresenter(),
            host: host,
            authorizer: ChatToolConsentAuthorizer(host: host)
        )
        .currentSessionConfiguration(allowedToolNames: [], responseLanguageSection: section)
    }

    /// Runs `body` with a throwaway support directory and workspace.
    private static func withTemporarySupportDirectory(
        _ body: @Sendable (_ workspace: URL) async throws -> Void
    ) async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("sub-agent-response-language-\(UUID().uuidString)", isDirectory: true)
        let support = root.appendingPathComponent("support", isDirectory: true)
        let workspace = root.appendingPathComponent("workspace", isDirectory: true)
        for directory in [support, workspace] {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        defer { try? FileManager.default.removeItem(at: root) }
        try await AppStorageDirectory.withSupportDirectoryURL(support) {
            try await body(workspace)
        }
    }
}

/// A runtime backend that records the response-language source it receives.
private actor ResponseLanguageSourceBackend: AgentRuntimeBackend {
    private var provider: DirectSubAgentResponseLanguageSectionProvider?
    private var installs = 0

    func updateSubAgentResponseLanguageSectionProvider(
        _ provider: DirectSubAgentResponseLanguageSectionProvider?
    ) async {
        self.provider = provider
        installs += 1
    }

    func providerInstallCount() -> Int {
        installs
    }

    func section(forRootSessionID rootSessionID: String) async -> String? {
        await provider?(rootSessionID)
    }

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

    func closeSession(id _: String) async {}

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
