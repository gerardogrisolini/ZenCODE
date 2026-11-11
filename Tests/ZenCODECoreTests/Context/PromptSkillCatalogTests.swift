//
//  PromptSkillCatalogTests.swift
//  ZenCODE
//

import Foundation
@testable import ZenCODECore
import Testing

@Suite
struct PromptSkillCatalogTests {
    @Test
    func discoveryDeduplicatesByNameAndTheFirstSearchRootWins() throws {
        let base = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: base) }
        let firstRoot = base.appendingPathComponent("first", isDirectory: true)
        let secondRoot = base.appendingPathComponent("second", isDirectory: true)
        try writeSkill(named: "shared-skill", description: "Defined in the first root.", in: firstRoot)
        try writeSkill(named: "shared-skill", description: "Defined in the second root.", in: secondRoot)
        try writeSkill(named: "second-only", description: "Only in the second root.", in: secondRoot)

        let skills = PromptSkillCatalog.discoverSkills(searchRoots: [firstRoot, secondRoot])
        let reversed = PromptSkillCatalog.discoverSkills(searchRoots: [secondRoot, firstRoot])

        // Same name, different content (so a different `sourceHash`): one skill.
        #expect(skills.map(\.canonicalName).sorted() == ["second-only", "shared-skill"])
        #expect(skills.first { $0.canonicalName == "shared-skill" }?.summary == "Defined in the first root.")
        #expect(reversed.first { $0.canonicalName == "shared-skill" }?.summary == "Defined in the second root.")
        let hashes = Set(
            [skills, reversed].compactMap { $0.first { $0.canonicalName == "shared-skill" }?.sourceHash }
        )
        #expect(hashes.count == 2)
    }

    @Test
    func discoveryKeepsSkillsWithDistinctNames() throws {
        let base = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: base) }
        let root = base.appendingPathComponent("skills", isDirectory: true)
        try writeSkill(named: "alpha", description: "Shared description.", in: root)
        try writeSkill(named: "beta", description: "Shared description.", in: root)

        let skills = PromptSkillCatalog.discoverSkills(searchRoots: [root])

        #expect(skills.map(\.canonicalName).sorted() == ["alpha", "beta"])
    }

    @Test
    func skillNamesAreComparedCaseInsensitively() {
        #expect(
            PromptSkillCatalog.skillNameKey("Swift-Review")
                == PromptSkillCatalog.skillNameKey("swift-review")
        )
        #expect(
            PromptSkillCatalog.skillNameKey("swift-review")
                != PromptSkillCatalog.skillNameKey("swift-reviewer")
        )
        // A name with no alphanumeric character still has a stable key.
        #expect(PromptSkillCatalog.skillNameKey("---") == "---")
    }

    @Test
    func aSkillIsIdentifiedByItsNameWhateverItsContentHash() {
        let first = PromptSkill(
            canonicalName: "release-review",
            title: "Release Review",
            summary: "Version one.",
            promptBody: "ONE",
            sourceHash: "hash-one"
        )
        let updated = PromptSkill(
            canonicalName: "release-review",
            title: "Release Review",
            summary: "Version two.",
            promptBody: "TWO",
            sourceHash: "hash-two"
        )

        // The hash is content metadata: an edited skill keeps its name.
        #expect(first.canonicalName == updated.canonicalName)
        #expect(first.sourceHash != updated.sourceHash)
        #expect(first != updated)
    }

    private func writeSkill(named name: String, description: String, in root: URL) throws {
        let directory = root.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try """
        ---
        name: \(name)
        description: \(description)
        ---

        # \(name)

        Guidance for \(name).
        """.write(
            to: directory.appendingPathComponent("SKILL.md"),
            atomically: true,
            encoding: .utf8
        )
    }

    private func temporaryDirectory() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("ZenCODE-PromptSkillCatalogTests-\(UUID().uuidString)", isDirectory: true)
            .standardizedFileURL
    }
}
