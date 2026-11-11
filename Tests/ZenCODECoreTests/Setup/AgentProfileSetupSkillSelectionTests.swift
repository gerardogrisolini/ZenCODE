//
//  AgentProfileSetupSkillSelectionTests.swift
//  ZenCODE
//

import Foundation
@testable import ZenCODECore
import Testing

@Suite
struct AgentProfileSetupSkillSelectionTests {
    private typealias Setup = ZenCODEAgentProfileSetupRunner

    private static func installed(_ name: String, title: String, summary: String = "A skill.") -> PromptSkill {
        PromptSkill(
            canonicalName: name,
            title: title,
            summary: summary,
            promptBody: "Body of \(name).",
            sourceHash: "hash-of-\(name)"
        )
    }

    @Test
    func menuValuesAreTheCanonicalNamesOfTheInstalledSkills() {
        let items = Setup.skillCheckboxItems(
            availableSkills: [
                Self.installed("swift-review", title: "Swift Review Pro", summary: "Inspect  Swift\nchanges."),
                Self.installed("alpha", title: "alpha"),
            ],
            selectedSkillNames: []
        )

        #expect(items.map(\.value) == ["swift-review", "alpha"])
        // A title that differs from the name shows the name beside it.
        #expect(items.map(\.title) == ["Swift Review Pro (swift-review)", "alpha"])
        #expect(items.first?.detail == "Inspect Swift changes.")
        #expect(items.allSatisfy { $0.groupTitle == nil })
    }

    @Test
    func savedNamesNotInstalledAreListedByNameIgnoringCase() {
        let items = Setup.skillCheckboxItems(
            availableSkills: [Self.installed("swift-review", title: "Swift Review")],
            // Present in a different spelling, and one that is not installed.
            selectedSkillNames: ["SWIFT-REVIEW", "retired-skill"]
        )

        #expect(items.map(\.value) == ["swift-review", "retired-skill"])
        let missing = items.last
        #expect(missing?.title == "retired-skill")
        #expect(missing?.detail == "saved skill not currently installed")
        #expect(missing?.groupTitle == "Saved")
    }

    @Test
    func savedNamesPreselectInstalledSkillsIgnoringCase() {
        let installed = [
            Self.installed("swift-review", title: "Swift Review"),
            Self.installed("alpha", title: "Alpha"),
        ]
        let saved = [
            AgentProfileSkill(name: "Swift-Review"),
            AgentProfileSkill(name: "retired-skill"),
        ]

        // What `promptSkillSelection` preselects: the installed skill's
        // canonical name when one matches, else the saved name itself.
        let preselected = Set(saved.compactMap { skill in
            skill.matchingSkillName(in: installed) ?? skill.name
        })
        let items = Setup.skillCheckboxItems(
            availableSkills: installed,
            selectedSkillNames: preselected
        )

        #expect(preselected == ["swift-review", "retired-skill"])
        #expect(Set(items.map(\.value)).isSuperset(of: preselected))
        #expect(items.map(\.value) == ["swift-review", "alpha", "retired-skill"])
    }

    @Test
    func skillListShowsTheNamesAndSkipsBlankOnes() {
        let list = Setup.skillList([
            AgentProfileSkill(name: "swift-review", title: "Swift Review"),
            AgentProfileSkill(name: ""),
            AgentProfileSkill(name: "alpha"),
        ])

        #expect(list == "swift-review, alpha")
    }

    @Test
    func agentSummaryListsTheSkillNames() {
        let agent = AgentProfile(
            id: "custom",
            name: "Custom",
            role: .developer,
            tools: ["files"],
            skills: [AgentProfileSkill(name: "swift-review")]
        )

        #expect(Setup.agentSummary(agent).contains("skills: swift-review"))
    }
}
