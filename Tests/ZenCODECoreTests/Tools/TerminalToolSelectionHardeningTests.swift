import Foundation
import Testing
@testable import ZenCODECore

@Suite
struct TerminalToolSelectionHardeningTests {
    @Test
    func ambiguousPrefixIsRejectedInsteadOfSelectingMultipleFamilies() throws {
        let items = [
            TerminalToolSelectionItem(
                key: "feature:alpha-tools",
                title: "Alpha",
                detail: "",
                groupTitle: "Features",
                allowedToolNames: ["alpha."]
            ),
            TerminalToolSelectionItem(
                key: "feature:alpine-tools",
                title: "Alpine",
                detail: "",
                groupTitle: "Features",
                allowedToolNames: ["alpine."]
            ),
        ]

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
