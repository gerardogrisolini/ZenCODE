//
//  SwiftToolsSupport+Rendering.swift
//  ZenCODE
//
//  Created by Gerardo Grisolini on 31/05/26.
//

import ToolCore
import Foundation
import FeatureKit

extension SwiftToolsSupport {
    private static func headerLines(_ result: FeatureProcessResult, command: String, success: String = "success") -> [String] {
        let status = result.timedOut
            ? "timed_out"
            : "\(result.exitCode == 0 ? success : "failed") (exit \(result.exitCode))"
        return ["command: \(command)", "status: \(status)"]
    }

    static func renderBuildResult(_ result: FeatureProcessResult, command: String) -> String {
        let combined = result.stdout + "\n" + result.stderr
        let diagnostics = parseDiagnostics(from: combined)
        let errors = diagnostics.filter { $0.severity == .error }
        let warnings = diagnostics.filter { $0.severity == .warning }

        var lines = headerLines(result, command: command)
        lines.append("errors: \(errors.count)  warnings: \(warnings.count)")

        if !errors.isEmpty {
            lines.append("\nErrors:")
            lines.append(contentsOf: errors.prefix(50).map { "  " + $0.formatted })
        }
        if !warnings.isEmpty {
            lines.append("\nWarnings:")
            lines.append(contentsOf: warnings.prefix(30).map { "  " + $0.formatted })
        }
        if result.exitCode != 0 {
            // Always surface raw output tail when build fails, even when parsed diagnostics exist,
            // so the model can see full context that structured parsing may have missed.
            lines.append("\nRaw output:")
            lines.append(tail(of: combined, lines: 60))
        }
        return lines.joined(separator: "\n")
    }

    static func renderTestResult(_ result: FeatureProcessResult, command: String) -> String {
        let combined = result.stdout + "\n" + result.stderr
        let failures = parseTestFailures(from: combined)
        // An XCTest assertion is reported as `File.swift:12: error: Suite.test : XCTAssert… failed`
        // (`-[Suite test]` on Darwin), which is a test failure, not a compiler
        // diagnostic: keep those lines out of the build-error count so a red
        // test is never presented as a build break.
        let failureLines = Set(failures)
        let diagnosticsInput = combined.components(separatedBy: "\n")
            .filter { !failureLines.contains($0.trimmingCharacters(in: .whitespaces)) }
            .joined(separator: "\n")
        let buildErrors = parseDiagnostics(from: diagnosticsInput).filter { $0.severity == .error }
        let summaries = parseTestSummaries(from: combined)

        var lines = headerLines(result, command: command, success: "passed")
        lines.append("exit_code: \(result.exitCode)")
        lines.append("timed_out: \(result.timedOut)")
        lines.append("stdout_truncated: \(result.stdoutWasTruncated)")
        lines.append("stderr_truncated: \(result.stderrWasTruncated)")
        if let aggregate = aggregateTestSummary(summaries) {
            lines.append("summary: \(aggregate)")
            lines.append(contentsOf: summaries.map { "  " + $0 })
        } else if let summary = summaries.last {
            lines.append("summary: \(summary)")
        }

        if !buildErrors.isEmpty {
            lines.append("\nBuild errors: \(buildErrors.count)")
            lines.append(contentsOf: buildErrors.prefix(50).map { "  " + $0.formatted })
        }
        if !failures.isEmpty {
            lines.append("\nFailing tests: \(failures.count)")
            lines.append(contentsOf: failures.prefix(50).map { "  " + $0 })
        }
        if result.exitCode != 0 {
            // Always surface raw output tail when tests fail, so the model sees full context.
            lines.append("\nRaw output:")
            lines.append(tail(of: combined, lines: 200))
        }
        return lines.joined(separator: "\n")
    }

    static func renderRunResult(_ result: FeatureProcessResult, command: String) -> String {
        let stderr = result.stderr
        // swift run prints build diagnostics to stderr; program output goes to stdout.
        let errors = parseDiagnostics(from: stderr).filter { $0.severity == .error }

        var lines = headerLines(result, command: command)
        if !errors.isEmpty {
            lines.append("\nBuild errors: \(errors.count)")
            lines.append(contentsOf: errors.prefix(50).map { "  " + $0.formatted })
        }
        let stdout = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        if !stdout.isEmpty {
            lines.append("\nstdout:")
            lines.append(stdout)
        }
        let trimmedStderr = stderr.trimmingCharacters(in: .whitespacesAndNewlines)
        if result.exitCode != 0, !trimmedStderr.isEmpty {
            lines.append("\nstderr:")
            lines.append(tail(of: trimmedStderr, lines: 60))
        }
        if stdout.isEmpty, errors.isEmpty, result.exitCode == 0 {
            lines.append("<no output>")
        }
        return lines.joined(separator: "\n")
    }

    static func renderPackageResult(_ result: FeatureProcessResult, command: String) -> String {
        var lines = headerLines(result, command: command)
        let stdout = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        if !stdout.isEmpty {
            lines.append("")
            lines.append(stdout)
        }
        let stderr = result.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
        if !stderr.isEmpty, result.exitCode != 0 || stdout.isEmpty {
            lines.append("\nstderr:")
            lines.append(tail(of: stderr, lines: 40))
        }
        if stdout.isEmpty, stderr.isEmpty {
            lines.append("<no output>")
        }
        return lines.joined(separator: "\n")
    }
}
