//
//  FeatureProcessResultRenderingTests.swift
//  ZenCODE
//

import Foundation
import FeatureKit
import Testing

@Suite
struct FeatureProcessResultRenderingTests {
    private func result(
        exitCode: Int32 = 0,
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

    @Test
    func rendersExitCodeStdoutAndStderrSections() {
        let rendered = result(
            exitCode: 2,
            stdout: "hello",
            stderr: "boom"
        ).renderedProcessOutput

        #expect(rendered == "exit_code: 2\nstdout:\nhello\nstderr:\nboom")
    }

    @Test
    func emitsNoOutputPlaceholderWhenOnlyExitCodePresent() {
        let rendered = result(exitCode: 0).renderedProcessOutput

        #expect(rendered == "exit_code: 0\n<no output>")
    }

    @Test
    func includesTimedOutMarkerBeforeStreams() {
        let rendered = result(
            exitCode: -1,
            stdout: "partial",
            timedOut: true
        ).renderedProcessOutput

        #expect(rendered == "exit_code: -1\ntimed_out: true\nstdout:\npartial")
    }

    @Test
    func treatsWhitespaceOnlyStreamsAsEmpty() {
        let rendered = result(
            exitCode: 0,
            stdout: "   \n",
            stderr: "\t"
        ).renderedProcessOutput

        // Whitespace-only stdout/stderr are dropped, leaving the placeholder.
        #expect(rendered == "exit_code: 0\n<no output>")
    }

    @Test
    func staticRendererMatchesValueTypeRendering() {
        // Callers holding already-decoded stdout/stderr (e.g. ProcessResult)
        // must produce byte-identical output to FeatureProcessResult.
        let viaRenderer = FeatureProcessOutputRenderer.render(
            exitCode: 2,
            stdout: "hello",
            stderr: "boom",
            timedOut: true
        )

        #expect(viaRenderer == "exit_code: 2\ntimed_out: true\nstdout:\nhello\nstderr:\nboom")
    }
}
