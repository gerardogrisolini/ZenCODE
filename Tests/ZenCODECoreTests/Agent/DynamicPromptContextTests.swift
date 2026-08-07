//
//  DynamicPromptContextTests.swift
//  ZenCODECoreTests
//

import Foundation
@testable import ZenCODECore
import Testing

@Suite("Dynamic prompt context")
struct DynamicPromptContextTests {
    @Test
    func standalonePromptKeepsCwdAndLanguageInSystemInstructions() throws {
        let first = SystemPromptBuilder.standalonePromptSections(
            cwd: "/tmp/one",
            agentsSection: "Agent instructions:\nUse concise answers.",
            memorySection: "Memory tools:\nRead project memory.",
            memoryToolEnabled: true,
            allowedToolNames: ["tasks.create", "tasks.list", "tasks.update", "agent.create"],
            responseLanguageSection: SystemPromptBuilder.responseLanguageSection(
                languageName: "Italian"
            )
        )
        let second = SystemPromptBuilder.standalonePromptSections(
            cwd: "/tmp/two",
            agentsSection: "Agent instructions:\nExplain decisions.",
            memorySection: nil,
            memoryToolEnabled: false,
            allowedToolNames: [],
            responseLanguageSection: SystemPromptBuilder.responseLanguageSection(
                languageName: "English"
            )
        )

        #expect(first.systemPrompt != second.systemPrompt)
        #expect(first.systemPrompt.contains("You are ZenCODE"))
        #expect(first.systemPrompt.contains(SystemPromptBuilder.staticSkillSectionMarker))
        #expect(first.systemPrompt.contains("Git, Shell, Web, memory") == false)
        #expect(first.systemPrompt.contains("/tmp/one"))
        #expect(first.systemPrompt.contains("locked to Italian"))
        #expect(first.dynamicContext.contains("/tmp/one") == false)
        #expect(first.dynamicContext.contains("locked to Italian") == false)
        #expect(first.dynamicContext.contains("Task workflow policy:"))
        #expect(first.dynamicContext.contains("Agent instructions:"))
        #expect(first.dynamicContext.contains("Memory tools:"))
        #expect(second.systemPrompt.contains("/tmp/two"))
        #expect(second.systemPrompt.contains("locked to English"))
        #expect(second.dynamicContext.contains("/tmp/two") == false)
        #expect(second.dynamicContext.contains("Task workflow policy:") == false)
        #expect(second.dynamicContext.contains("locked to English") == false)
        #expect(
            SystemPromptBuilder.standalonePrompt(
                cwd: "/tmp/one",
                agentsSection: "Agent instructions:\nUse concise answers.",
                memorySection: "Memory tools:\nRead project memory.",
                memoryToolEnabled: true,
                allowedToolNames: ["tasks.create", "tasks.list", "tasks.update", "agent.create"],
                responseLanguageSection: SystemPromptBuilder.responseLanguageSection(
                    languageName: "Italian"
                )
            ) == first.combinedPrompt
        )
    }

    @Test
    func wireContextIsOneLeadingUserMessageAndRoundTripsThroughSnapshot() throws {
        let dynamicContext = "Current task working directory for local tools:\n- Working directory path: /tmp/project"
        let history = [
            AgentRuntimeMessage(role: .user, content: "Implement the feature."),
            AgentRuntimeMessage(role: .assistant, content: "I will inspect the project.")
        ]
        let messages = RemoteGenerationClient.initialMessages(
            cwd: "/tmp/project",
            systemPrompt: "Stable instructions.",
            history: AgentRuntimeDynamicContext.inserting(dynamicContext, into: history),
            allowedToolNames: []
        )

        #expect(messages.count == 4)
        #expect(messages[0]["role"] as? String == "system")
        #expect(messages[0]["content"] as? String == "Stable instructions.")
        #expect(messages[1]["role"] as? String == "user")
        #expect((messages[1]["content"] as? String)?.hasPrefix(AgentRuntimeDynamicContext.marker) == true)

        let snapshot = RemoteGenerationClient.snapshotMessages(from: messages)
        #expect(snapshot.systemPrompt == "Stable instructions.")
        #expect(snapshot.dynamicContext == dynamicContext)
        #expect(snapshot.history == history)

        let restoredMessages = RemoteGenerationClient.initialMessages(
            cwd: "/tmp/project",
            systemPrompt: snapshot.systemPrompt,
            history: AgentRuntimeDynamicContext.inserting(
                snapshot.dynamicContext,
                into: snapshot.history
            ),
            allowedToolNames: []
        )
        let restoredSnapshot = RemoteGenerationClient.snapshotMessages(from: restoredMessages)
        #expect(restoredSnapshot.systemPrompt == snapshot.systemPrompt)
        #expect(restoredSnapshot.dynamicContext == snapshot.dynamicContext)
        #expect(restoredSnapshot.history == snapshot.history)
    }

    @Test
    func compactionKeepsDynamicContextOutsideTheSummary() throws {
        let dynamicContext = "Working directory: /tmp/project\nActive approved plan progress: keep task context current."
        let history = (0..<16).flatMap { index in
            [
                AgentRuntimeMessage(
                    role: .user,
                    content: "User request \(index): " + String(repeating: "details ", count: 45)
                ),
                AgentRuntimeMessage(
                    role: .assistant,
                    content: "Assistant response \(index): " + String(repeating: "analysis ", count: 45)
                )
            ]
        }
        let snapshot = AgentRuntimeSessionSnapshot(
            sessionID: "dynamic-compaction",
            workingDirectoryPath: "/tmp/project",
            systemPrompt: "Stable instructions.",
            dynamicContext: dynamicContext,
            cacheKey: "cache",
            history: history,
            allowedToolNames: [],
            thinkingSelection: nil,
            preserveThinking: false
        )

        let result = AgentConversationCompactionSupport.compactedMessagesIfNeeded(
            snapshot.compactionInputMessages,
            maxTokens: 1_000,
            force: true
        )
        let compacted = snapshot.applyingCompaction(result)

        #expect(result.wasCompacted)
        #expect(compacted.dynamicContext == dynamicContext)
        #expect(compacted.history.first?.content.hasPrefix(AgentRuntimeDynamicContext.marker) == false)
        #expect(
            result.messages.filter {
                AgentRuntimeDynamicContext.context(from: $0) != nil
            }.count == 1
        )
        #expect(
            compacted.systemPrompt?.contains(
                AgentConversationCompactionSupport.memorySummaryHeader
            ) == true
        )
    }

    @Test
    func chatGPTPromptCacheIdentityCanonicalizesToolsButExcludesDynamicContext() {
        func configuration(
            workingDirectory: String,
            allowedTools: Set<String>,
            history: [AgentRuntimeMessage] = []
        ) -> ChatGPTSubscriptionGenerationClient.RequestConfiguration {
            ChatGPTSubscriptionGenerationClient.RequestConfiguration(
                modelID: "gpt-5.5",
                workingDirectory: workingDirectory,
                systemPrompt: "Stable instructions.",
                sessionKey: "shared-session",
                connectionScopeID: nil,
                history: history,
                allowedToolNames: allowedTools,
                thinkingSelection: nil,
                appMode: false
            )
        }

        let first = ChatGPTSubscriptionGenerationClient.SessionIdentity(
            configuration: configuration(
                workingDirectory: "/tmp/one",
                allowedTools: ["local.readFile", " git.status "],
                history: [
                    AgentRuntimeMessage(
                        role: .user,
                        content: AgentRuntimeDynamicContext.marker + "First dynamic context."
                    )
                ]
            )
        )
        let canonicallyEquivalent = ChatGPTSubscriptionGenerationClient.SessionIdentity(
            configuration: configuration(
                workingDirectory: "/tmp/two",
                allowedTools: ["git.status", "local.readFile", " local.readFile "],
                history: [
                    AgentRuntimeMessage(
                        role: .user,
                        content: AgentRuntimeDynamicContext.marker + "Second dynamic context."
                    )
                ]
            )
        )
        let differentTools = ChatGPTSubscriptionGenerationClient.SessionIdentity(
            configuration: configuration(
                workingDirectory: "/tmp/two",
                allowedTools: ["git.status", "web.fetch"]
            )
        )

        #expect(first == canonicallyEquivalent)
        #expect(first.promptCachePersistenceKey == canonicallyEquivalent.promptCachePersistenceKey)
        #expect(first != differentTools)
        #expect(first.promptCachePersistenceKey != differentTools.promptCachePersistenceKey)
    }

    @Test
    func appProvidedInstructionsKeepCwdAndLanguageInSystemPrefix() {
        let sections = AgentSessionComposition.appProvidedPromptSections(
            "Client instructions.",
            cwd: "/tmp/client-project",
            allowedToolNames: ["tasks.create", "tasks.list", "tasks.update"],
            selectedAgent: nil,
            responseLanguageSection: SystemPromptBuilder.responseLanguageSection(
                languageName: "Italian"
            )
        )

        #expect(sections.systemPrompt.contains("Client instructions."))
        #expect(sections.systemPrompt.contains("/tmp/client-project"))
        #expect(sections.systemPrompt.contains("locked to Italian"))
        #expect(sections.dynamicContext.contains("Task workflow policy:"))
        #expect(sections.dynamicContext.contains("/tmp/client-project") == false)
        #expect(sections.dynamicContext.contains("locked to Italian") == false)
    }

    @Test
    func appSessionCacheKeyIncludesAllowedToolsButNotHistory() throws {
        let supportDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("zencode-prompt-cache-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: supportDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: supportDirectory) }

        try AppStorageDirectory.withSupportDirectoryURL(supportDirectory) {
            try AgentSettingsManifestStore.save(AgentSettingsManifest(models: []))
            try AgentProfileStore.save(AgentProfileStore.defaultProfiles())

            func configuration(
                allowedTools: Set<String>,
                history: [AgentRuntimeMessage]
            ) throws -> AgentCoreSessionConfiguration {
                try AgentCoreAppSessionFactory.makeConfiguration(
                    request: AgentCoreAppSessionRequest(
                        sessionID: "prompt-cache-session",
                        workingDirectory: URL(fileURLWithPath: "/tmp/prompt-cache"),
                        cacheKey: "shared-cache-seed",
                        history: history,
                        allowedToolNames: allowedTools
                    )
                )
            }

            let first = try configuration(
                allowedTools: ["local.readFile"],
                history: [AgentRuntimeMessage(role: .user, content: "First context.")]
            )
            let sameToolsDifferentHistory = try configuration(
                allowedTools: ["local.readFile"],
                history: [AgentRuntimeMessage(role: .user, content: "Second context.")]
            )
            let differentTools = try configuration(
                allowedTools: ["git.status"],
                history: [AgentRuntimeMessage(role: .user, content: "First context.")]
            )

            #expect(first.cacheKey == sameToolsDifferentHistory.cacheKey)
            #expect(first.cacheKey != differentTools.cacheKey)
        }
    }
}
