import Foundation
import Testing
import LocalToolsSupport

@Suite
struct PatchFileHeadersTests {
    /// Removing the SQL comment `-- old comment` and adding `++ new counter`
    /// yields lines that look exactly like file headers inside a valid hunk.
    private static let sqlLines = [
        "diff --git a/schema.sql b/schema.sql",
        "index 1111111..2222222 100644",
        "--- a/schema.sql",
        "+++ b/schema.sql",
        "@@ -1,3 +1,3 @@",
        " SELECT 1;",
        "--- old comment",
        "+++ new counter",
        " SELECT 2;"
    ]

    private static let sqlPatch = sqlLines.joined(separator: "\n")

    private static func patch(_ lines: [String], separator: String = "\n") -> String {
        lines.joined(separator: separator)
    }

    @Test
    func hunkBodyLinesThatLookLikeHeadersAreIgnoredInGitDiff() {
        let values = PatchFileHeaders.rawPathValues(in: Self.sqlPatch)

        #expect(values == ["a/schema.sql", "b/schema.sql"])
    }

    @Test
    func rawValuesAreReturnedInPayloadOrderWithoutNormalization() {
        let values = PatchFileHeaders.rawPathValues(in: Self.patch([
            "--- a/old.txt\t2024-01-01 10:00:00",
            "+++ /dev/null",
            "@@ -1 +0,0 @@",
            "-gone",
            "*** Delete File:   Sources/Gone.swift  "
        ]))

        #expect(values == [
            "a/old.txt\t2024-01-01 10:00:00",
            "/dev/null",
            "Sources/Gone.swift"
        ])
    }

    @Test
    func beginPatchSectionsTreatMarkerLookalikesAsContent() {
        let body = [
            "*** Update File: Sources/schema.sql",
            "@@",
            " SELECT 1;",
            "--- comment",
            "+++ y",
            "@@",
            "--- another",
            "+++ line",
            " SELECT 2;",
            "*** Add File: Sources/new.sql",
            "+--- dashed",
            "--- not a header",
            "+++ not a header either",
            "*** Delete File: Sources/old.sql"
        ]

        let withEnvelope = PatchFileHeaders.rawPathValues(
            in: Self.patch(["*** Begin Patch"] + body + ["*** End Patch"])
        )
        let withoutEnvelope = PatchFileHeaders.rawPathValues(in: Self.patch(body))

        let expected = ["Sources/schema.sql", "Sources/new.sql", "Sources/old.sql"]
        #expect(withEnvelope == expected)
        #expect(withoutEnvelope == expected)
    }

    // MARK: - fileHeaderLineIndices

    @Test
    func headerIndicesAndRawPathValuesShareTheSameRule() throws {
        let patches = [
            Self.sqlPatch,
            Self.patch([
                "--- a/one.txt",
                "+++ b/one.txt",
                "@@ -1,9 +1,9 @@",
                "-a",
                "+b",
                "--- a/two.txt",
                "+++ b/two.txt",
                "@@ -1 +1 @@",
                "-c",
                "+d"
            ]),
            Self.patch([
                "--- a/one.txt",
                "+++ b/one.txt",
                "@@",
                " ctx",
                "--- x",
                "+++ y",
                " ctx",
                "--- a/two.txt",
                "+++ b/two.txt",
                "@@",
                "-c",
                "+d"
            ])
        ]

        for patch in patches {
            let lines = patch.components(separatedBy: "\n")
            let valuesFromIndices = try PatchFileHeaders.fileHeaderLineIndices(in: patch)
                .sorted()
                .flatMap { index -> [String] in
                    let next = try #require(lines.indices.contains(index + 1) ? index + 1 : nil)
                    return [String(lines[index].dropFirst(4)), String(lines[next].dropFirst(4))]
                }

            #expect(valuesFromIndices == PatchFileHeaders.rawPathValues(in: patch))
        }
    }
}
