import Foundation
import FeatureKit
import Testing
@testable import swift_tools_feature

@Suite(.serialized)
struct SwiftTestToolTests {
    @Test
    func additionalArgumentsRemainSeparateArgvElements() {
        let arguments = SwiftToolsSupport.additionalArguments([
            "--no-parallel",
            "--filter",
            "Suite name/test name",
            "",
        ])

        #expect(arguments == ["--no-parallel", "--filter", "Suite name/test name"])
        #expect(
            SwiftToolsSupport.renderCommand(["swift", "test"] + arguments)
                == "swift test --no-parallel --filter 'Suite name/test name'"
        )
    }

    @Test
    func testSummaryAlwaysReportsProcessAndRetentionState() {
        let result = FeatureProcessResult(
            exitCode: 9,
            stdoutData: Data(),
            stderrData: Data("failure".utf8),
            timedOut: true,
            stdoutWasTruncated: true,
            stderrWasTruncated: false
        )
        let summary = SwiftToolsSupport.renderTestResult(
            result,
            command: "swift test --no-parallel"
        )

        #expect(summary.contains("status: timed_out"))
        #expect(summary.contains("exit_code: 9"))
        #expect(summary.contains("timed_out: true"))
        #expect(summary.contains("stdout_truncated: true"))
        #expect(summary.contains("stderr_truncated: false"))
    }
}
