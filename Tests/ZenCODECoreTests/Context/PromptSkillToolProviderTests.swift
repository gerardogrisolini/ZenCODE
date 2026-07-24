//
//  PromptSkillToolProviderTests.swift
//  ZenCODE
//
//  Created by Gerardo Grisolini on 24/07/26.
//

import Foundation
import FeatureKit
@testable import ZenCODECore
import Testing

@Suite
struct PromptSkillToolProviderTests {
    @Test
    func staticSkillSectionCarriesNoSelectionMetadata() throws {
        let skill = skill(promptBody: "FULL-SKILL-BODY")
        let section = try #require(
            SystemPromptBuilder.selectedSkillSection(skills: [skill])
        )

        #expect(section == SystemPromptBuilder.staticSkillSection)
        #expect(section.contains("skills.list"))
        #expect(section.contains("skills.read"))
        #expect(!section.contains("Release Review"))
        #expect(!section.contains(skill.id))
        #expect(!section.contains("FULL-SKILL-BODY"))
    }

    @Test
    func persistedPromptReplacesLegacySkillCatalogWithStaticInstruction() {
        let prompt = """
        Base instructions.

        Selected skill guidance for this task is supplemental context. Use it when relevant.

        Additional skill guidance selected for this task:
        Skill: Legacy Skill
        LEGACY-FULL-SKILL-BODY

        Response language:
        Use Italian.
        """

        let updated = SystemPromptBuilder.replacingSelectedSkillSection(in: prompt)

        #expect(updated.contains(SystemPromptBuilder.staticSkillSectionMarker))
        #expect(!updated.contains("LEGACY-FULL-SKILL-BODY"))
        #expect(!updated.contains("Selected skill guidance for this task"))
        #expect(updated.contains("Response language:\nUse Italian."))
    }

    @Test
    func replacingSkillSectionIsIdempotent() {
        let prompt = "Base.\n\n\(SystemPromptBuilder.staticSkillSection)\n\nResponse language:\nUse Italian."
        let once = SystemPromptBuilder.replacingSelectedSkillSection(in: prompt)
        let twice = SystemPromptBuilder.replacingSelectedSkillSection(in: once)

        #expect(once == twice)
        let markerOccurrences = once.components(
            separatedBy: SystemPromptBuilder.staticSkillSectionMarker
        ).count - 1
        #expect(markerOccurrences == 1)
    }

    @Test
    func listReturnsDeterministicMetadataWithoutBodies() async throws {
        let provider = PromptSkillSessionProvider(skills: [
            skill(promptBody: "BODY-A"),
            otherSkill(promptBody: "BODY-B")
        ])

        let output = try await provider.execute(
            toolCall: AgentToolCall(
                id: "list",
                name: PromptSkillToolProvider.listToolName,
                argumentsJSON: "{}"
            )
        )

        // Ordered by canonical name: "other-skill" precedes "release-review".
        #expect(output.contains(#""name":"other-skill""#))
        #expect(output.contains(#""id":"other-skill-hash""#))
        #expect(output.contains(#""name":"release-review""#))
        #expect(output.contains(#""id":"release-review-hash""#))
        #expect(output.range(of: "other-skill")!.lowerBound < output.range(of: "release-review")!.lowerBound)
        #expect(!output.contains("BODY"))
        #expect(!output.contains("/tmp/skills"))
        #expect(!output.contains("Release Review"))
    }

    @Test
    func listIsEmptyWhenNoSkillsAreSelected() async throws {
        let provider = PromptSkillSessionProvider()

        let output = try await provider.execute(
            toolCall: AgentToolCall(
                id: "list",
                name: PromptSkillToolProvider.listToolName,
                argumentsJSON: "{}"
            )
        )

        #expect(output == #"{"skills":[]}"#)
    }

    @Test
    func readPagesSelectedSkillGuidanceWithoutLosingTheTail() async throws {
        let body = String(repeating: "a", count: 6_000) + "TAIL-MARKER"
        let provider = PromptSkillSessionProvider(skills: [skill(promptBody: body)])

        let firstPage = try await provider.execute(
            toolCall: AgentToolCall(
                id: "first-page",
                name: PromptSkillToolProvider.toolName,
                argumentsJSON: #"{"identifier":"release-review","offset":0,"limit":6000}"#
            )
        )
        let secondPage = try await provider.execute(
            toolCall: AgentToolCall(
                id: "second-page",
                name: PromptSkillToolProvider.toolName,
                argumentsJSON: #"{"identifier":"release-review","offset":6000,"limit":6000}"#
            )
        )

        #expect(firstPage.contains("Skill: Release Review"))
        #expect(firstPage.contains("offset 6000"))
        #expect(!firstPage.contains("TAIL-MARKER"))
        #expect(secondPage.contains("TAIL-MARKER"))
        #expect(secondPage.contains("This is the final page."))
    }

    @Test
    func readFailsClosedForRevokedSkill() async throws {
        let provider = PromptSkillSessionProvider(skills: [skill(promptBody: "FULL-SKILL-BODY")])

        // Revoking the skill updates only the session-scoped snapshot; later
        // reads must fail closed even though the body was previously readable.
        await provider.update([])

        await #expect(throws: PromptSkillToolProviderError.self) {
            _ = try await provider.execute(
                toolCall: AgentToolCall(
                    id: "read-revoked",
                    name: PromptSkillToolProvider.toolName,
                    argumentsJSON: #"{"identifier":"release-review"}"#
                )
            )
        }
    }

    @Test
    func readRequiresAnIdentifier() async throws {
        let provider = PromptSkillSessionProvider(skills: [skill(promptBody: "FULL-SKILL-BODY")])

        await #expect(throws: PromptSkillToolProviderError.self) {
            _ = try await provider.execute(
                toolCall: AgentToolCall(
                    id: "missing-identifier",
                    name: PromptSkillToolProvider.toolName,
                    argumentsJSON: "{}"
                )
            )
        }
    }

    @Test
    func readKeepsExactCanonicalMatchesButRejectsAmbiguousNormalizedNames() async throws {
        let hyphenated = PromptSkill(
            canonicalName: "foo-bar",
            title: "Foo Bar",
            summary: "First collision.",
            promptBody: "FIRST",
            sourceHash: "foo-bar-hash"
        )
        let compact = PromptSkill(
            canonicalName: "foobar",
            title: "Foobar",
            summary: "Second collision.",
            promptBody: "SECOND",
            sourceHash: "foobar-hash"
        )
        let provider = PromptSkillSessionProvider(skills: [hyphenated, compact])

        let exactOutput = try await provider.execute(
            toolCall: AgentToolCall(
                id: "exact-canonical",
                name: PromptSkillToolProvider.toolName,
                argumentsJSON: #"{"identifier":"foobar"}"#
            )
        )
        #expect(exactOutput.contains("SECOND"))
        #expect(!exactOutput.contains("FIRST"))

        await #expect(throws: PromptSkillToolProviderError.self) {
            _ = try await provider.execute(
                toolCall: AgentToolCall(
                    id: "ambiguous-normalized",
                    name: PromptSkillToolProvider.toolName,
                    argumentsJSON: #"{"identifier":"foo bar"}"#
                )
            )
        }
    }

    @Test
    func updateReflectsImmediatelyInList() async throws {
        let provider = PromptSkillSessionProvider()

        let empty = try await provider.execute(
            toolCall: AgentToolCall(
                id: "list-empty",
                name: PromptSkillToolProvider.listToolName,
                argumentsJSON: "{}"
            )
        )
        #expect(empty == #"{"skills":[]}"#)

        await provider.update([skill(promptBody: "FULL-SKILL-BODY")])

        let populated = try await provider.execute(
            toolCall: AgentToolCall(
                id: "list-populated",
                name: PromptSkillToolProvider.listToolName,
                argumentsJSON: "{}"
            )
        )
        #expect(populated.contains("release-review"))
        #expect(!populated.contains("FULL-SKILL-BODY"))
    }

    @Test
    func sessionScopedProvidersDoNotCrossReadSkills() async throws {
        let executor = DirectToolExecutor(
            swiftFeatureRuntime: SwiftFeatureRuntime(features: []),
            subAgentBackendFactory: { PromptSkillProviderTestBackend() }
        )
        let providerA = PromptSkillSessionProvider(skills: [skill(promptBody: "BODY-A")])
        let providerB = PromptSkillSessionProvider(skills: [otherSkill(promptBody: "BODY-B")])
        await executor.updateToolProviders([providerA.asToolProvider()], sessionID: "session-a")
        await executor.updateToolProviders([providerB.asToolProvider()], sessionID: "session-b")

        let listA = await executor.execute(
            sessionID: "session-a",
            toolCall: DirectAgentToolCall(
                id: "list-a",
                name: PromptSkillToolProvider.listToolName,
                argumentsObject: [:],
                argumentsJSON: "{}"
            ),
            workingDirectory: URL(fileURLWithPath: "/tmp"),
            allowedToolNames: PromptSkillToolProvider.toolNames
        ).output
        let listB = await executor.execute(
            sessionID: "session-b",
            toolCall: DirectAgentToolCall(
                id: "list-b",
                name: PromptSkillToolProvider.listToolName,
                argumentsObject: [:],
                argumentsJSON: "{}"
            ),
            workingDirectory: URL(fileURLWithPath: "/tmp"),
            allowedToolNames: PromptSkillToolProvider.toolNames
        ).output

        #expect(listA.contains("release-review"))
        #expect(!listA.contains("other-skill"))
        #expect(listB.contains("other-skill"))
        #expect(!listB.contains("release-review"))
    }

    private func skill(promptBody: String) -> PromptSkill {
        PromptSkill(
            canonicalName: "release-review",
            title: "Release Review",
            summary: "Review release changes before publishing.",
            promptBody: promptBody,
            sourceDirectoryPath: "/tmp/skills/release-review",
            sourceHash: "release-review-hash"
        )
    }

    private func otherSkill(promptBody: String) -> PromptSkill {
        PromptSkill(
            canonicalName: "other-skill",
            title: "Other Skill",
            summary: "Other skill.",
            promptBody: promptBody,
            sourceDirectoryPath: "/tmp/skills/other-skill",
            sourceHash: "other-skill-hash"
        )
    }
}

private actor PromptSkillProviderTestBackend: AgentRuntimeBackend {
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
