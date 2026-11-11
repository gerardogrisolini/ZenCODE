//
//  ChatSessionSkillNameSelectionTests.swift
//  ZenCODE
//

import Foundation
@testable import ZenCODECore
import Testing

@Suite
struct ChatSessionSkillNameSelectionTests {
    private static let skills = [
        PromptSkill(
            canonicalName: "cafe",
            title: "Café Pro",
            summary: "Coffee.",
            promptBody: "COFFEE",
            sourceHash: "deadbeef01"
        ),
        PromptSkill(
            canonicalName: "swift-review",
            title: "Swift Review",
            summary: "Review Swift.",
            promptBody: "REVIEW",
            sourceHash: "cafe1234"
        ),
    ]

    @Test(arguments: ["cafe", "CAFE", "Café", " cafe "])
    func aSkillIsFoundByItsNameIgnoringCase(token: String) {
        #expect(ChatSessionController.skill(matching: token, in: Self.skills)?.canonicalName == "cafe")
    }

    @Test(arguments: ["deadbeef01", "deadbeef", "dead", "cafe1234", "Café Pro", "cafe-pro", "swift", "Swift Reviews", ""])
    func neitherTheTitleNorAHashOrPrefixSelectsASkill(token: String) {
        // `cafe1234` is the hash of the second skill, and also starts with
        // the first skill's name; only an exact name identifies a skill.
        #expect(ChatSessionController.skill(matching: token, in: Self.skills) == nil)
    }

    @Test
    func theSelectionSyntaxYieldsCanonicalNames() throws {
        let parse = { (selection: String) throws -> Set<String> in
            try ChatSessionController.parseSkillSelection(selection, availableSkills: Self.skills)
        }

        #expect(try parse("all") == ["cafe", "swift-review"])
        #expect(try parse("none").isEmpty)
        #expect(try parse("2") == ["swift-review"])
        #expect(try parse("1, SWIFT-REVIEW") == ["cafe", "swift-review"])
        #expect(try parse("Swift-Review") == ["swift-review"])
        #expect(throws: TerminalSkillSelectionError.self) {
            _ = try parse("deadbeef01")
        }
    }

    @Test
    func selectionNamesFilterTheInstalledSkillsInCatalogOrder() {
        let selected = ChatSessionController.promptSkills(
            withNames: ["swift-review", "cafe", "not-installed"],
            in: Self.skills
        )

        #expect(selected.map(\.canonicalName) == ["cafe", "swift-review"])
        #expect(ChatSessionController.promptSkills(withNames: [], in: Self.skills).isEmpty)
        // The hash is not a name.
        #expect(ChatSessionController.promptSkills(withNames: ["deadbeef01"], in: Self.skills).isEmpty)
    }

    @Test
    func anAgentDeclaresItsSkillsByName() {
        let agent = AgentProfile(
            id: "custom",
            name: "Custom",
            role: .developer,
            skills: [AgentProfileSkill(name: "SWIFT-REVIEW"), AgentProfileSkill(name: "deadbeef01")]
        )

        let names = ChatSessionController.promptSkillNames(of: agent, in: Self.skills)

        #expect(names == ["swift-review"])
        #expect(
            ChatSessionController.promptSkills(withNames: names, in: Self.skills).map(\.canonicalName)
                == ["swift-review"]
        )
    }
}
