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
        // Each entry carries only `name` and `description`: no `id`, hash, or title.
        #expect(output == #"{"skills":[{"description":"Other skill.","name":"other-skill"},{"description":"Review release changes before publishing.","name":"release-review"}]}"#)
        #expect(!output.contains(#""id""#))
        #expect(!output.contains("-hash"))
        #expect(!output.contains("BODY"))
        #expect(!output.contains("/tmp/skills"))
        #expect(!output.contains("sourceDirectoryPath"))
        #expect(!output.contains("Release Review"))
    }

    @Test
    func listAndReadDescriptorsIdentifySkillsByNameOnly() {
        let list = PromptSkillToolProvider.listToolDescriptor
        let read = PromptSkillToolProvider.readToolDescriptor

        #expect(list.description.contains("returning only their name and description"))
        #expect(!list.description.contains("id, name"))
        #expect(read.description.contains("Use the name returned by skills.list."))
        #expect(read.inputSchema.contains("Selected skill name from skills.list."))
        #expect(!read.inputSchema.contains("skill id"))
        #expect(SystemPromptBuilder.staticSkillSection.contains("(name and description)"))
        #expect(SystemPromptBuilder.staticSkillSection.contains("with a listed name"))
        #expect(!SystemPromptBuilder.staticSkillSection.contains("listed id"))
    }

    @Test
    func listOrdersSkillsSharingANameByTitle() {
        let zeta = PromptSkill(canonicalName: "same-name", title: "Zeta", summary: "", promptBody: "", sourceHash: "1")
        let alpha = PromptSkill(canonicalName: "same-name", title: "Alpha", summary: "", promptBody: "", sourceHash: "2")

        #expect(PromptSkillToolProvider.sortedForListing([zeta, alpha]).map(\.title) == ["Alpha", "Zeta"])
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

        #expect(firstPage.contains("Skill sourceDirectoryPath:"))
        #expect(secondPage.contains("Skill sourceDirectoryPath:"))
        #expect(firstPage.contains("Skill: Release Review"))
        #expect(firstPage.contains("offset 6000"))
        // The continuation names the skill by its canonical name, never by hash.
        #expect(firstPage.contains("using identifier `release-review` and offset 6000"))
        #expect(!firstPage.contains("release-review-hash"))
        #expect(!firstPage.contains("TAIL-MARKER"))
        #expect(secondPage.contains("TAIL-MARKER"))
        #expect(secondPage.contains("This is the final page."))
    }

    @Test
    func readByNameIsCaseInsensitiveAndNeverByHashOrTitle() async throws {
        let provider = PromptSkillSessionProvider(skills: [
            PromptSkill(
                canonicalName: "release-review",
                title: "Shipping Checklist",
                summary: "Review release changes before publishing.",
                promptBody: "RELEASE-BODY",
                sourceHash: "release-review-hash"
            )
        ])

        let exact = try await read(provider, arguments: #"{"identifier":"release-review"}"#)
        let differentCase = try await read(provider, arguments: #"{"identifier":"Release-Review"}"#)
        #expect(exact.contains("RELEASE-BODY"))
        #expect(differentCase.contains("RELEASE-BODY"))

        // Neither the content hash nor the title identifies a skill.
        for identifier in ["release-review-hash", "Shipping Checklist"] {
            await #expect(throws: PromptSkillToolProviderError.self) {
                _ = try await self.read(provider, arguments: #"{"identifier":"\#(identifier)"}"#)
            }
        }
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

        let ambiguous = await #expect(throws: PromptSkillToolProviderError.self) {
            _ = try await provider.execute(
                toolCall: AgentToolCall(
                    id: "ambiguous-normalized",
                    name: PromptSkillToolProvider.toolName,
                    argumentsJSON: #"{"identifier":"foo bar"}"#
                )
            )
        }
        // The ambiguity lists the candidates' names, not their hashes.
        let message = try #require(ambiguous?.localizedDescription)
        #expect(message.contains("foo-bar, foobar"))
        #expect(message.contains("skill names"))
        #expect(!message.contains("hash"))
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
    @Test
    func readResourceReturnsUTF8Content() async throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let resource = root.appendingPathComponent("guides/italiano.txt")
        try FileManager.default.createDirectory(at: resource.deletingLastPathComponent(), withIntermediateDirectories: true)
        try "Caffè ☕ — risorsa UTF-8".write(to: resource, atomically: true, encoding: .utf8)
        let provider = PromptSkillSessionProvider(skills: [
            skill(promptBody: "unused", sourceDirectoryPath: root.path)
        ])

        let output = try await read(provider, arguments: #"{"identifier":"release-review","resource":"guides/italiano.txt"}"#)

        #expect(output.contains("Caffè ☕ — risorsa UTF-8"))
        #expect(output.contains("resource `guides/italiano.txt`"))
        #expect(output.contains(root.path))
    }

    @Test(arguments: ["/etc/passwd", "../outside.txt", "nested/../../outside.txt"])
    func readResourceRejectsAbsolutePathsAndTraversal(resource: String) async throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let provider = PromptSkillSessionProvider(skills: [
            skill(promptBody: "unused", sourceDirectoryPath: root.path)
        ])

        let argumentsData = try JSONSerialization.data(
            withJSONObject: ["identifier": "release-review", "resource": resource]
        )
        let arguments = try #require(String(data: argumentsData, encoding: .utf8))
        await #expect(throws: PromptSkillToolProviderError.self) {
            _ = try await self.read(provider, arguments: arguments)
        }
    }

    @Test
    func readResourceRejectsDirectoriesAndMissingFiles() async throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root.appendingPathComponent("directory"), withIntermediateDirectories: false)
        let provider = PromptSkillSessionProvider(skills: [
            skill(promptBody: "unused", sourceDirectoryPath: root.path)
        ])

        do {
            _ = try await read(provider, arguments: #"{"identifier":"release-review","resource":"directory"}"#)
            Issue.record("A directory must not be readable as a skill resource.")
        } catch let error as PromptSkillToolProviderError {
            guard case .invalidResourceFile("directory") = error else {
                Issue.record("Unexpected directory error: \(error.localizedDescription)")
                return
            }
        }
        do {
            _ = try await read(provider, arguments: #"{"identifier":"release-review","resource":"missing.txt"}"#)
            Issue.record("A missing resource must fail deterministically.")
        } catch let error as PromptSkillToolProviderError {
            guard case .unreadableResource("missing.txt") = error else {
                Issue.record("Unexpected missing-file error: \(error.localizedDescription)")
                return
            }
        }
    }

    @Test
    func readResourceRejectsSymlinkResolvingOutsideSkillRoot() async throws {
        let root = try makeTemporaryDirectory()
        let outside = try makeTemporaryDirectory()
        defer {
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: outside)
        }
        let outsideFile = outside.appendingPathComponent("secret.txt")
        try "SECRET".write(to: outsideFile, atomically: true, encoding: .utf8)
        let link = root.appendingPathComponent("outside-link.txt")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: outsideFile)
        let provider = PromptSkillSessionProvider(skills: [
            skill(promptBody: "unused", sourceDirectoryPath: root.path)
        ])

        await #expect(throws: PromptSkillToolProviderError.self) {
            _ = try await self.read(provider, arguments: #"{"identifier":"release-review","resource":"outside-link.txt"}"#)
        }
    }

    private func read(_ provider: PromptSkillSessionProvider, arguments: String) async throws -> String {
        try await provider.execute(
            toolCall: AgentToolCall(
                id: "read-resource",
                name: PromptSkillToolProvider.toolName,
                argumentsJSON: arguments
            )
        )
    }

    private func makeTemporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("ZenCODE-PromptSkillTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
        return url
    }

    private func skill(
        promptBody: String,
        sourceDirectoryPath: String? = "/tmp/skills/release-review"
    ) -> PromptSkill {
        PromptSkill(
            canonicalName: "release-review",
            title: "Release Review",
            summary: "Review release changes before publishing.",
            promptBody: promptBody,
            sourceDirectoryPath: sourceDirectoryPath,
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
