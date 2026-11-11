//
//  AgentProfileSkillTests.swift
//  ZenCODE
//

import Foundation
@testable import ZenCODECore
import Testing

@Suite
struct AgentProfileSkillTests {
    private static func installed(
        _ name: String,
        title: String? = nil,
        summary: String = "",
        sourceHash: String = "hash"
    ) -> PromptSkill {
        PromptSkill(
            canonicalName: name,
            title: title ?? name,
            summary: summary,
            promptBody: "Body of \(name).",
            sourceHash: sourceHash
        )
    }

    // MARK: - Coding

    @Test
    func skillEncodesTheNameAndOnlyThePresentMetadata() throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]

        let bare = try encoder.encode(AgentProfileSkill(name: "swift-review"))
        let described = try encoder.encode(
            AgentProfileSkill(
                name: "swift-review",
                title: "Swift Review",
                summary: "Inspect Swift changes.",
                symbolName: "checkmark"
            )
        )

        #expect(String(decoding: bare, as: UTF8.self) == #"{"name":"swift-review"}"#)
        #expect(
            String(decoding: described, as: UTF8.self)
                == #"{"name":"swift-review","summary":"Inspect Swift changes.","symbolName":"checkmark","title":"Swift Review"}"#
        )
    }

    @Test
    func skillDecodesTheNameAndTheOptionalMetadata() throws {
        let skill = try JSONDecoder().decode(
            AgentProfileSkill.self,
            from: Data(
                #"{"name":" swift-review ","title":"Swift Review","summary":"Inspect.","symbolName":"checkmark"}"#.utf8
            )
        )

        #expect(skill.name == "swift-review")
        #expect(skill.title == "Swift Review")
        #expect(skill.summary == "Inspect.")
        #expect(skill.symbolName == "checkmark")
        #expect(skill == AgentProfileSkill(
            name: "swift-review",
            title: "Swift Review",
            summary: "Inspect.",
            symbolName: "checkmark"
        ))
    }

    @Test
    func skillsWithoutAUsableNameMakeTheManifestInvalid() throws {
        let hash = "9f86d081884c7d659a2feaa0c55ad015a3bf4f1b2b0b822cd15d6c15b0f00a08"
        // The former shape, and every way the required `name` can be unusable.
        let entries = [
            #"{"id": "\#(hash)"}"#,
            #"{"id": "\#(hash)", "canonicalName": "legacy-name", "title": "Legacy"}"#,
            "{}",
            #"{"name": ""}"#,
            #"{"name": "   "}"#,
            #"{"name": null}"#,
            #"{"name": 42}"#,
            #"{"name": ["swift-review"]}"#,
        ]
        for entry in entries {
            let json = AgentProfileRoleTestSupport.manifest(profile: """
            {
              "id": "custom", "name": "Custom", "role": "developer", "tools": [],
              "skills": [{"name": "valid-skill"}, \(entry)]
            }
            """)
            do {
                _ = try AgentProfileRoleTestSupport.loadManifest(json)
                Issue.record("The skill \(entry) must make agents.json invalid.")
            } catch let error as AgentProfileStoreError {
                guard case let .invalidFile(_, underlying) = error else {
                    Issue.record("Expected invalidFile for the skill \(entry), got \(error).")
                    continue
                }
                #expect(underlying as? AgentProfileSkillDecodingError == .missingName(profile: "Custom"))
                let message = try #require(error.errorDescription)
                #expect(message.contains(
                    "profile 'Custom' has a skill without the required \"name\" field"
                ))
            }
        }
    }

    @Test
    func aLegacyProfileFailsToDecodeNamingTheProfile() {
        let legacy = Data(
            #"{"id":"legacy","name":"Legacy","role":"developer","tools":[],"skills":[{"id":"abc123"}]}"#.utf8
        )

        #expect(throws: AgentProfileSkillDecodingError.missingName(profile: "Legacy")) {
            _ = try JSONDecoder().decode(AgentProfile.self, from: legacy)
        }
        // On its own, the skill has no profile to name.
        #expect(throws: AgentProfileSkillDecodingError.missingName(profile: nil)) {
            _ = try JSONDecoder().decode(AgentProfileSkill.self, from: Data(#"{"id":"abc123"}"#.utf8))
        }
    }

    @Test
    func anIdNextToAValidNameIsIgnoredAndAbsentSkillsDecodeAsEmpty() throws {
        let profiles = try AgentProfileRoleTestSupport.loadManifest(
            AgentProfileRoleTestSupport.manifest(profile: """
            {
              "id": "custom", "name": "Custom", "role": "developer", "tools": [],
              "skills": [{"id": "ignored-id", "name": "swift-review", "title": "Swift Review"}]
            }
            """)
        )
        let withoutSkills = try JSONDecoder().decode(
            AgentProfile.self,
            from: Data(#"{"id":"plain","name":"Plain","role":"developer","tools":[]}"#.utf8)
        )
        let nullSkills = try JSONDecoder().decode(
            AgentProfile.self,
            from: Data(#"{"id":"null","name":"Null","role":"developer","tools":[],"skills":null}"#.utf8)
        )

        let custom = try #require(profiles.first { $0.id == "custom" })
        #expect(custom.skills == [AgentProfileSkill(name: "swift-review", title: "Swift Review")])
        #expect(withoutSkills.skills.isEmpty)
        #expect(nullSkills.skills.isEmpty)
    }

    @Test
    func profileSkillsRoundTripThroughTheManifest() throws {
        let profile = AgentProfile(
            id: "custom",
            name: "Custom",
            role: .developer,
            skills: [AgentProfileSkill(name: "alpha"), AgentProfileSkill(name: "beta")]
        )
        let encoded = try JSONEncoder().encode(AgentProfileManifest(agents: [profile]))
        let json = String(decoding: encoded, as: UTF8.self)
        let decoded = try JSONDecoder().decode(AgentProfileManifest.self, from: encoded)

        #expect(json.contains(#""skills":[{"name":"alpha"},{"name":"beta"}]"#))
        #expect(!json.contains("canonicalName"))
        #expect(decoded.agents.first?.skills == profile.skills)
    }

    // MARK: - Matching

    @Test
    func profileSkillsMatchInstalledSkillsByNameIgnoringCase() {
        let installed = [
            Self.installed("swift-review"),
            Self.installed("alpha"),
            Self.installed("gamma"),
        ]
        let profile = AgentProfile(
            id: "custom",
            name: "Custom",
            role: .developer,
            skills: [
                AgentProfileSkill(name: "Swift-Review"),
                AgentProfileSkill(name: " ALPHA "),
                AgentProfileSkill(name: "not-installed"),
            ]
        )

        // The result holds the installed skills' canonical names, not the saved spelling.
        #expect(profile.selectedSkillNames(availableSkills: installed) == ["swift-review", "alpha"])
        #expect(profile.skills[0].matchingSkillName(in: installed) == "swift-review")
        #expect(profile.skills[2].matchingSkillName(in: installed) == nil)
    }

    @Test
    func titleSummaryHashAndSymbolNeverTakePartInTheMatch() {
        let installed = [
            Self.installed(
                "swift-review",
                title: "Swift Review Pro",
                summary: "Inspect Swift changes.",
                sourceHash: "f00dcafe"
            ),
        ]
        let byTitleAndSummary = AgentProfileSkill(
            name: "other-skill",
            title: "Swift Review Pro",
            summary: "Inspect Swift changes."
        )
        let byHash = AgentProfileSkill(name: "f00dcafe")
        let byTitle = AgentProfileSkill(name: "Swift Review Pro")
        // The matching name wins whatever the metadata says.
        let byNameWithStaleMetadata = AgentProfileSkill(
            name: "swift-review",
            title: "Stale Title",
            summary: "Stale summary.",
            symbolName: "stale"
        )

        #expect(byTitleAndSummary.matchingSkillName(in: installed) == nil)
        #expect(byHash.matchingSkillName(in: installed) == nil)
        #expect(byTitle.matchingSkillName(in: installed) == nil)
        #expect(byNameWithStaleMetadata.matchingSkillName(in: installed) == "swift-review")
    }

    @Test
    func anUpdatedSkillKeepsMatchingTheProfileThatNamesIt() {
        let profile = AgentProfile(
            id: "custom",
            name: "Custom",
            role: .developer,
            skills: [AgentProfileSkill(name: "release-review")]
        )
        let before = [Self.installed("release-review", sourceHash: "hash-before")]
        let after = [Self.installed("release-review", summary: "Edited.", sourceHash: "hash-after")]

        #expect(profile.selectedSkillNames(availableSkills: before) == ["release-review"])
        #expect(profile.selectedSkillNames(availableSkills: after) == ["release-review"])
    }

    @Test
    func aBlankNameMatchesNothing() {
        let installed = [Self.installed("alpha")]

        #expect(AgentProfileSkill(name: "").matchingSkillName(in: installed) == nil)
        #expect(AgentProfileSkill(name: "   ").matchingSkillName(in: installed) == nil)
    }
}
