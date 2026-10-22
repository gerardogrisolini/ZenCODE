import Foundation
import FeatureKit
import Testing
@testable import swift_tools_feature

private func decode<T: Decodable>(_ type: T.Type, _ json: String) throws -> T {
    try JSONDecoder().decode(T.self, from: Data(json.utf8))
}

private func processResult(
    exitCode: Int32,
    stdout: String = "",
    stderr: String = "",
    timedOut: Bool = false
) -> FeatureProcessResult {
    FeatureProcessResult(
        exitCode: exitCode,
        stdoutData: Data(stdout.utf8),
        stderrData: Data(stderr.utf8),
        timedOut: timedOut,
        stdoutWasTruncated: false
    )
}

@Suite("SwiftTools argument validation")
struct SwiftToolsArgumentTests {
    @Test func optionValuesRejectOptionLikeAndBlankValues() throws {
        #expect(try SwiftToolsSupport.optionValue(" release ", named: "configuration") == "release")
        #expect(throws: SwiftToolsFeatureError.self) { try SwiftToolsSupport.optionValue("--help", named: "target") }
        #expect(throws: SwiftToolsFeatureError.self) { try SwiftToolsSupport.optionValue("-x", named: "filter") }
        #expect(throws: SwiftToolsFeatureError.self) { try SwiftToolsSupport.optionValue("   ", named: "product") }
        #expect(throws: SwiftToolsFeatureError.self) { try SwiftToolsSupport.optionValue("a\nb", named: "product") }
    }

    @Test func runArgumentsForwardProgramArgumentsVerbatim() throws {
        let input = try decode(
            SwiftRunTool.Input.self,
            #"{"executable":"tool","configuration":"release","arguments":["--flag"," spaced ",""]}"#
        )
        #expect(try SwiftRunTool.arguments(for: input) == ["run", "-c", "release", "tool", "--flag", " spaced "])

        let product = try decode(SwiftRunTool.Input.self, #"{"product":"tool","args":["a"]}"#)
        #expect(try SwiftRunTool.arguments(for: product) == ["run", "tool", "a"])

        let optionLike = try decode(SwiftRunTool.Input.self, #"{"executable":"--disable-sandbox"}"#)
        #expect(throws: SwiftToolsFeatureError.self) { try SwiftRunTool.arguments(for: optionLike) }
    }

    @Test func packageDirectoryResolvesAliasesAndRejectsFiles() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("swift-tools-tests-\(UUID().uuidString)", isDirectory: true)
        let nested = root.appendingPathComponent("pkg", isDirectory: true)
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = nested.appendingPathComponent("Package.swift")
        try "// swift-tools-version: 6.0\n".write(to: file, atomically: true, encoding: .utf8)
        let context = FeatureContext(workingDirectory: root, environment: [:])

        let viaPath = try SwiftToolsSupport.packageDirectory(path: "pkg", workingDirectory: nil, context: context)
        #expect(viaPath.standardizedFileURL.path == nested.standardizedFileURL.path)
        let viaWorkingDirectory = try SwiftToolsSupport.packageDirectory(
            path: "missing", workingDirectory: nested.path, context: context
        )
        #expect(viaWorkingDirectory.standardizedFileURL.path == nested.standardizedFileURL.path)
        let defaulted = try SwiftToolsSupport.packageDirectory(path: " ", workingDirectory: nil, context: context)
        #expect(defaulted.standardizedFileURL.path == root.standardizedFileURL.path)

        #expect(throws: SwiftToolsFeatureError.self) {
            try SwiftToolsSupport.packageDirectory(path: "does-not-exist", workingDirectory: nil, context: context)
        }
        #expect(throws: SwiftToolsFeatureError.self) {
            try SwiftToolsSupport.packageDirectory(path: file.path, workingDirectory: nil, context: context)
        }
    }

    @Test func requiredPathRejectsBlankAliases() throws {
        let context = FeatureContext(workingDirectory: URL(fileURLWithPath: "/tmp"), environment: [:])
        #expect(throws: SwiftToolsFeatureError.self) {
            try SwiftToolsSupport.requiredPath(nil, "  ", context: context)
        }
        #expect(try SwiftToolsSupport.requiredPath(nil, "a.swift", context: context).path == "/tmp/a.swift")
    }
}

@Suite("SwiftTools output parsing")
struct SwiftToolsParsingTests {
    @Test func diagnosticsAreParsedAndDeduplicated() {
        let output = """
        Compiling Foo
        /tmp/error-prone/Sources/Foo/A.swift:10:5: error: cannot find 'x' in scope
        /tmp/error-prone/Sources/Foo/A.swift:10:5: error: cannot find 'x' in scope
        /tmp/p/Sources/Foo/B.swift:3:1: warning: variable 'y' was never used
        error: fatalError
        warning: unknown setting
        The word error: appears in prose but is not a diagnostic
        """
        let diagnostics = SwiftToolsSupport.parseDiagnostics(from: output)
        #expect(diagnostics.map(\.formatted) == [
            "/tmp/error-prone/Sources/Foo/A.swift:10:5: cannot find 'x' in scope",
            "/tmp/p/Sources/Foo/B.swift:3:1: variable 'y' was never used",
            "fatalError",
            "unknown setting",
        ])
        #expect(diagnostics.map(\.severity) == [.error, .warning, .error, .warning])
    }

    @Test func testFailuresExcludeRunSummary() {
        let output = """
        ✘ Test "adds numbers" recorded an issue at MathTests.swift:12:9: Expectation failed: (2 + 2 → 4) == 5
        ✘ Test "adds numbers" failed after 0.001 seconds with 1 issue.
        ✘ Test run with 3 tests in 1 suite failed after 0.010 seconds with 1 issue.
        Test Case '-[FooTests.FooTests testBar]' failed (0.001 seconds).
        /tmp/p/Tests/FooTests.swift:20: error: -[FooTests.FooTests testBar] : XCTAssertEqual failed: ("1") is not equal to ("2")
        """
        let failures = SwiftToolsSupport.parseTestFailures(from: output)
        #expect(failures.count == 4)
        #expect(!failures.contains { $0.contains("Test run with") })
        #expect(SwiftToolsSupport.parseTestSummaries(from: output)
            == ["✘ Test run with 3 tests in 1 suite failed after 0.010 seconds with 1 issue."])
    }

    @Test func multipleRunSummariesAreAggregated() {
        let output = """
        ✔ Test run with 12 tests in 3 suites passed after 0.100 seconds.
        ✘ Test run with 4 tests in 1 suite failed after 0.200 seconds with 1 issue.
        Executed 2 tests, with 0 failures (0 unexpected) in 0.001 (0.002) seconds
        """
        let summaries = SwiftToolsSupport.parseTestSummaries(from: output)
        #expect(summaries.count == 2)
        #expect(SwiftToolsSupport.aggregateTestSummary(summaries) == "16 tests in 4 suites across 2 runs failed")
        #expect(SwiftToolsSupport.aggregateTestSummary(Array(summaries.prefix(1))) == nil)
    }

    @Test func legacySummariesAreUsedWhenSwiftTestingIsAbsent() {
        let output = """
        Test Suite 'All tests' passed at 2026-01-01 10:00:00.000.
        Executed 7 tests, with 0 failures (0 unexpected) in 0.050 (0.060) seconds
        """
        #expect(SwiftToolsSupport.parseTestSummaries(from: output) == [
            "Test Suite 'All tests' passed at 2026-01-01 10:00:00.000.",
            "Executed 7 tests, with 0 failures (0 unexpected) in 0.050 (0.060) seconds",
        ])
    }

    @Test func tailClampsOverlongLines() {
        let long = String(repeating: "x", count: 1_200)
        let tail = SwiftToolsSupport.tail(of: "a\nb\n\(long)", lines: 2)
        let lines = tail.components(separatedBy: "\n")
        #expect(lines.count == 2)
        #expect(lines[0] == "b")
        #expect(lines[1].hasPrefix(String(repeating: "x", count: 500)))
        #expect(lines[1].hasSuffix("(+700 characters elided)"))
    }
}

@Suite("SwiftTools rendering")
struct SwiftToolsRenderingTests {
    @Test func buildResultSummarizesDiagnosticsAndRawTailOnFailure() {
        let result = processResult(
            exitCode: 1,
            stderr: "/tmp/p/A.swift:1:1: error: boom\n/tmp/p/A.swift:2:1: warning: meh\n"
        )
        let rendered = SwiftToolsSupport.renderBuildResult(result, command: "swift build")
        #expect(rendered.hasPrefix("command: swift build\nstatus: failed (exit 1)\nerrors: 1  warnings: 1\n"))
        #expect(rendered.contains("\nErrors:\n  /tmp/p/A.swift:1:1: boom"))
        #expect(rendered.contains("\nWarnings:\n  /tmp/p/A.swift:2:1: meh"))
        #expect(rendered.contains("\nRaw output:\n"))

        let success = SwiftToolsSupport.renderBuildResult(processResult(exitCode: 0, stdout: "Build complete!"), command: "swift build")
        #expect(success == "command: swift build\nstatus: success (exit 0)\nerrors: 0  warnings: 0")
    }

    @Test func testResultDoesNotCountAssertionFailuresAsBuildErrors() {
        let stdout = """
        Test Case '-[FooTests.FooTests testBar]' started.
        /tmp/p/Tests/FooTests.swift:20: error: -[FooTests.FooTests testBar] : XCTAssertEqual failed: ("1") is not equal to ("2")
        Test Case '-[FooTests.FooTests testBar]' failed (0.001 seconds).
        Executed 1 test, with 1 failure (0 unexpected) in 0.001 (0.002) seconds
        """
        let rendered = SwiftToolsSupport.renderTestResult(processResult(exitCode: 1, stdout: stdout), command: "swift test")
        #expect(rendered.hasPrefix("command: swift test\nstatus: failed (exit 1)\nexit_code: 1\ntimed_out: false\nstdout_truncated: false\nstderr_truncated: false\nsummary: Executed 1 test, with 1 failure (0 unexpected) in 0.001 (0.002) seconds"))
        #expect(!rendered.contains("Build errors:"))
        #expect(rendered.contains("\nFailing tests: 2\n"))
        #expect(rendered.contains("\nRaw output:\n"))
    }

    @Test func testResultReportsCompilerErrorsAsBuildErrors() {
        let stderr = "/tmp/p/Tests/FooTests.swift:3:5: error: cannot find 'nope' in scope\nerror: fatalError\n"
        let rendered = SwiftToolsSupport.renderTestResult(processResult(exitCode: 1, stderr: stderr), command: "swift test")
        #expect(rendered.contains("\nBuild errors: 2\n  /tmp/p/Tests/FooTests.swift:3:5: cannot find 'nope' in scope\n  fatalError"))
        #expect(!rendered.contains("Failing tests:"))
    }

    @Test func passingTestResultIsCompact() {
        let stdout = "✔ Test run with 5 tests in 2 suites passed after 0.010 seconds.\n"
        let rendered = SwiftToolsSupport.renderTestResult(processResult(exitCode: 0, stdout: stdout), command: "swift test")
        #expect(rendered == "command: swift test\nstatus: passed (exit 0)\nexit_code: 0\ntimed_out: false\nstdout_truncated: false\nstderr_truncated: false\nsummary: ✔ Test run with 5 tests in 2 suites passed after 0.010 seconds.")
    }

    @Test func runResultSeparatesProgramOutputFromBuildErrors() {
        let ok = SwiftToolsSupport.renderRunResult(processResult(exitCode: 0, stdout: "hello\n", stderr: "Build complete!\n"), command: "swift run tool")
        #expect(ok == "command: swift run tool\nstatus: success (exit 0)\n\nstdout:\nhello")

        let empty = SwiftToolsSupport.renderRunResult(processResult(exitCode: 0), command: "swift run tool")
        #expect(empty == "command: swift run tool\nstatus: success (exit 0)\n<no output>")

        let failed = SwiftToolsSupport.renderRunResult(
            processResult(exitCode: 1, stderr: "/tmp/p/main.swift:1:1: error: boom\n"),
            command: "swift run tool"
        )
        #expect(failed.contains("\nBuild errors: 1\n  /tmp/p/main.swift:1:1: boom"))
        #expect(failed.contains("\nstderr:\n/tmp/p/main.swift:1:1: error: boom"))
    }

    @Test func packageResultShowsStderrOnlyWhenUseful() {
        let described = SwiftToolsSupport.renderPackageResult(
            processResult(exitCode: 0, stdout: "{\"name\":\"p\"}", stderr: "Fetching…"),
            command: "swift package describe --type json"
        )
        #expect(described == "command: swift package describe --type json\nstatus: success (exit 0)\n\n{\"name\":\"p\"}")

        let failed = SwiftToolsSupport.renderPackageResult(
            processResult(exitCode: 1, stderr: "error: root manifest not found"),
            command: "swift package resolve"
        )
        #expect(failed == "command: swift package resolve\nstatus: failed (exit 1)\n\nstderr:\nerror: root manifest not found")

        let timedOut = SwiftToolsSupport.renderPackageResult(processResult(exitCode: -1, timedOut: true), command: "swift package update")
        #expect(timedOut == "command: swift package update\nstatus: timed_out\n<no output>")
    }
}
