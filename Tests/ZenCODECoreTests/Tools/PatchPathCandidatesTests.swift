import Foundation
import Testing
import ToolCore
@testable import ZenCODECore

/// The three ZenCODECore consumers of the shared `PatchFileHeaders` rule must
/// ignore hunk-body lines that merely look like file headers.
@Suite
struct PatchPathCandidatesTests {
    /// Removing the SQL comment `-- old comment` and adding `++ new counter`
    /// yields lines that look exactly like file headers inside a valid hunk.
    private static let sqlPatch = [
        "diff --git a/schema.sql b/schema.sql",
        "index 1111111..2222222 100644",
        "--- a/schema.sql",
        "+++ b/schema.sql",
        "@@ -1,3 +1,3 @@",
        " SELECT 1;",
        "--- old comment",
        "+++ new counter",
        " SELECT 2;"
    ].joined(separator: "\n")

    @Test
    func turnFileChangeTrackerIgnoresHunkBodyLookalikes() {
        let candidates = TurnFileChangeTracker.patchPathCandidates(from: Self.sqlPatch)

        #expect(Set(candidates) == ["schema.sql"])
        #expect(TurnFileChangeTracker.patchPathCandidates(from: nil).isEmpty)
        #expect(TurnFileChangeTracker.patchPathCandidates(from: "  \n").isEmpty)
    }

    @Test
    func toolCallPresentationTargetIgnoresHunkBodyLookalikes() {
        let target = ToolCallPresentation.patchDisplayTarget(from: ["patch": Self.sqlPatch])

        #expect(target == "schema.sql")
    }

    @Test
    func toolPresentationResolverPatchPathsTargetIgnoresHunkBodyLookalikes() {
        let definition = ToolPresentationDefinition(
            title: "Patch",
            action: "Apply",
            kind: .edit,
            target: .argument(["patch", "diff"], format: .patchPaths)
        )
        let call = DirectAgentToolCall(
            id: "patch-target",
            name: "local.applyPatch",
            argumentsObject: ["patch": Self.sqlPatch],
            argumentsJSON: "{}",
            presentation: definition
        )

        let resolved = ToolPresentationResolver.resolve(call: call, mode: .compact)

        #expect(resolved.target == "schema.sql")
    }
}
