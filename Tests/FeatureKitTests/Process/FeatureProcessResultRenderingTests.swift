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

    @Test
    func successfulInvocationEnvelopeIncludesDeclaredAttachments() throws {
        let data = try FeatureProcessProtocol.renderSuccess(
            outputData: Data(#"{"summary":"captured"}"#.utf8),
            attachments: [
                FeatureInvocationAttachment(
                    path: "/tmp/screenshot.png",
                    kind: .image,
                    contentType: "image/png",
                    originalFilename: "screenshot.png"
                )
            ]
        )
        let root = try #require(
            JSONSerialization.jsonObject(with: data) as? [String: Any]
        )
        let output = try #require(root["output"] as? [String: Any])
        let attachments = try #require(root["attachments"] as? [[String: Any]])

        #expect(output["summary"] as? String == "captured")
        #expect(attachments.first?["path"] as? String == "/tmp/screenshot.png")
        #expect(attachments.first?["kind"] as? String == "image")
        #expect(attachments.first?["contentType"] as? String == "image/png")
    }

    @Test
    func successfulInvocationEnvelopeWithoutAttachmentsRetainsLegacyWire() throws {
        let data = try FeatureProcessProtocol.renderSuccess(
            outputData: Data(#""ok""#.utf8),
            attachments: []
        )

        #expect(String(decoding: data, as: UTF8.self) == #"{"ok":true,"output":"ok"}"# + "\n")
    }
}
