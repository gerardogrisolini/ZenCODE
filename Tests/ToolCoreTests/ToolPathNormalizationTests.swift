import Testing
@testable import ToolCore

/// Caratterizza la normalizzazione dei percorsi che il livello di compatibilità
/// applica agli argomenti delle richieste tool (`assignPathString`).
@Suite
struct ToolPathNormalizationTests {
    @Test
    func emptyAndWhitespaceOnlyValuesAreReturnedUnchanged() {
        #expect(normalizedToolPathString("") == "")
        #expect(normalizedToolPathString("   ") == "   ")
        #expect(normalizedToolPathString(" \t\n ") == " \t\n ")
    }

    @Test
    func surroundingWhitespaceIsTrimmed() {
        #expect(normalizedToolPathString("  Sources/App.swift  ") == "Sources/App.swift")
        #expect(normalizedToolPathString("\n/abs/path\t") == "/abs/path")
    }

    @Test
    func fileURLsAreConvertedToTheirPath() {
        #expect(normalizedToolPathString("file:///abs/path") == "/abs/path")
        #expect(normalizedToolPathString("file:///a%20b/c") == "/a b/c")
        #expect(normalizedToolPathString("  file:///abs/path  ") == "/abs/path")
    }

    @Test
    func invalidFileURLFallsBackToSeparatorNormalization() {
        // `URL(string:)` rifiuta l'host: il valore resta una stringa e le
        // componenti vuote prodotte da `//` vengono eliminate.
        #expect(normalizedToolPathString("file://[bad") == "file:/[bad")
        #expect(normalizedToolPathString("file://") == "")
    }

    @Test
    func absolutePathsAreReturnedAsTrimmed() {
        #expect(normalizedToolPathString("/abs/path") == "/abs/path")
        #expect(normalizedToolPathString("/Sources/Sources/App.swift") == "/Sources/Sources/App.swift")
        #expect(normalizedToolPathString("//") == "//")
        #expect(normalizedToolPathString("/") == "/")
    }

    @Test
    func backslashesBecomeForwardSlashes() {
        #expect(normalizedToolPathString(#"Sources\App\main.swift"#) == "Sources/App/main.swift")
        #expect(normalizedToolPathString(#".\Sources\App.swift"#) == "Sources/App.swift")
        #expect(normalizedToolPathString(#"\abs\path"#) == "abs/path")
    }

    @Test
    func leadingDotSlashPrefixIsRemoved() {
        #expect(normalizedToolPathString("./Sources/App.swift") == "Sources/App.swift")
        #expect(normalizedToolPathString("././Sources/App.swift") == "./Sources/App.swift")
        #expect(normalizedToolPathString("../Sources/App.swift") == "../Sources/App.swift")
    }

    @Test
    func duplicatedLeadingComponentsAreCollapsedUnlessTheyContainADot() {
        #expect(normalizedToolPathString("Sources/Sources/App.swift") == "Sources/App.swift")
        #expect(normalizedToolPathString("a/a/a/x") == "a/x")
        #expect(normalizedToolPathString("a.b/a.b/x") == "a.b/a.b/x")
        #expect(normalizedToolPathString("Sources/App/Sources/App.swift") == "Sources/App/Sources/App.swift")
        #expect(normalizedToolPathString("Sources/Sources") == "Sources")
    }

    @Test
    func dotAndEmptyComponentEdgeCases() {
        #expect(normalizedToolPathString(".") == ".")
        #expect(normalizedToolPathString("./") == "")
        #expect(normalizedToolPathString("a//b///c") == "a/b/c")
        #expect(normalizedToolPathString("src/") == "src")
    }

    @Test
    func ordinaryRelativePathsAreUnchanged() {
        #expect(normalizedToolPathString("Sources/App.swift") == "Sources/App.swift")
        #expect(normalizedToolPathString("README.md") == "README.md")
        #expect(normalizedToolPathString("Package.swift") == "Package.swift")
    }

    @Test
    func assignPathStringNormalizesTheFirstMatchingSourceKey() {
        var normalized: [String: JSONValue] = [:]
        assignPathString(
            ["path", "file_path"],
            from: ["file_path": .string("./Sources/Sources/App.swift")],
            to: "path",
            in: &normalized
        )
        #expect(normalized == ["path": .string("Sources/App.swift")])
    }

    @Test
    func assignPathStringLeavesWhitespaceOnlyValuesUntouchedAndSkipsMissingKeys() {
        var normalized: [String: JSONValue] = ["existing": .string("keep")]
        assignPathString(
            ["path"],
            from: ["path": .string("  ")],
            to: "filePath",
            in: &normalized
        )
        assignPathString(
            ["missing"],
            from: ["path": .string("x")],
            to: "other",
            in: &normalized
        )
        #expect(normalized == ["existing": .string("keep"), "filePath": .string("  ")])
    }
}
