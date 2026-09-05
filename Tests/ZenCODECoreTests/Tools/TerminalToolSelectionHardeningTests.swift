import Foundation
import Testing
@testable import ZenCODECore

@Suite
struct TerminalToolSelectionHardeningTests {
    @Test(arguments: ["", " ,\t\n", "ALL", "none", "OFF", "clear", "disabled", "1", "+1,01", "cafe", "CAFÉ", "cafe---", "0", "-1", "2", "all,1", "none 1", "???"])
    func sharedSelectionSyntax(_ input: String) throws {
        let item = TerminalToolSelectionItem(key: "cafe", title: "Café", detail: nil, groupTitle: nil, allowedToolNames: ["coffee."])
        let skill = PromptSkill(canonicalName: "cafe", title: "Café", summary: "", promptBody: "", sourceHash: "cafe")
        if ["0", "-1", "2", "all,1", "none 1", "???"].contains(input) {
            let token = String(input.split { $0.isWhitespace || $0 == "," }[0])
            let toolError = #expect(throws: TerminalToolSelectionError.self) {
                _ = try TerminalChat.parseToolSelection(input, items: [item])
            }
            #expect(toolError?.localizedDescription == "Unknown tool or package '\(token)'.")
            let skillError = #expect(throws: TerminalSkillSelectionError.self) {
                _ = try TerminalChat.parseSkillSelection(input, availableSkills: [skill])
            }
            #expect(skillError?.localizedDescription == "Unknown skill '\(token)'.")
        } else {
            let expected: Set<String> = ["", " ,\t\n", "none", "OFF", "clear", "disabled"].contains(input) ? [] : ["cafe"]
            #expect(try TerminalChat.parseToolSelection(input, items: [item]) == expected)
            #expect(try TerminalChat.parseSkillSelection(input, availableSkills: [skill]) == expected)
        }
    }

    @Test(arguments: [(" Café__工具! ", "cafe-工具"), ("e\u{301}", "e"), ("👩🏽‍💻", "")])
    func unicodeLookupKeys(_ input: String, _ expected: String) {
        #expect(TerminalChat.selectionKey(input) == expected)
    }

    @Test
    func ambiguousPrefixIsRejectedInsteadOfSelectingMultipleFamilies() throws {
        let items = ["alpha", "alpine"].map { name in
            TerminalToolSelectionItem(
                key: "feature:\(name)-tools",
                title: name.capitalized,
                detail: "",
                groupTitle: "Features",
                allowedToolNames: ["\(name)."]
            )
        }

        let skills = ["alpha", "alpine"].map { name in
            PromptSkill(canonicalName: name, title: name, summary: "", promptBody: "", sourceHash: name)
        }
        #expect(try TerminalChat.parseSkillSelection("al", availableSkills: skills) == ["alpha"])

        do {
            _ = try TerminalToolSelectionCatalog.parseSelection("feature:al", items: items)
            Issue.record("Expected an ambiguous selection error.")
        } catch let error as TerminalToolSelectionCatalog.AmbiguousSelectionError {
            #expect(error.token == "feature:al")
            #expect(error.matches == ["feature:alpha-tools", "feature:alpine-tools"])
            #expect(error.localizedDescription.contains("Choose one exact key"))
        }

        #expect(
            try TerminalToolSelectionCatalog.parseSelection(
                "feature:alpha-tools",
                items: items
            ) == ["feature:alpha-tools"]
        )
    }
}
