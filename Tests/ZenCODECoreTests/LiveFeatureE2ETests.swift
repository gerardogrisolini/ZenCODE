//
//  LiveFeatureE2ETests.swift
//  ZenCODE
//
//  Created by Gerardo Grisolini on 30/05/26.
//
import Foundation
import Testing

@Suite
struct LiveFeatureE2ETests {
    @Test
    func liveModelGeneratesBuildsEnablesAndUsesGitLikeFeature() async throws {
        guard ProcessInfo.processInfo.environment["ZENCODE_RUN_LIVE_FEATURE_E2E"] == "1" else {
            return
        }

        let packageRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let scriptURL = packageRoot
            .appendingPathComponent("Scripts", isDirectory: true)
            .appendingPathComponent("live-feature-e2e.sh")

        let result = try await LiveFeatureE2EProcess.run(
            executableURL: URL(fileURLWithPath: "/usr/bin/env"),
            arguments: ["bash", scriptURL.path],
            workingDirectory: packageRoot
        )

        #expect(
            result.exitCode == 0,
            """
            live-feature-e2e.sh failed with exit code \(result.exitCode)

            stdout:
            \(result.stdout)

            stderr:
            \(result.stderr)
            """
        )
        #expect(result.stdout.contains("LIVE_FEATURE_E2E_OK live.git_current_branch=live-feature-e2e-branch"))
    }
}

private enum LiveFeatureE2EProcess {
    static func run(
        executableURL: URL,
        arguments: [String],
        workingDirectory: URL
    ) async throws -> (exitCode: Int32, stdout: String, stderr: String) {
        let runID = UUID().uuidString
        let outputDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("live-feature-e2e-test-\(runID)", isDirectory: true)
        let stdoutURL = outputDirectory.appendingPathComponent("stdout.log")
        let stderrURL = outputDirectory.appendingPathComponent("stderr.log")
        try FileManager.default.createDirectory(
            at: outputDirectory,
            withIntermediateDirectories: true
        )
        FileManager.default.createFile(atPath: stdoutURL.path, contents: nil)
        FileManager.default.createFile(atPath: stderrURL.path, contents: nil)
        defer {
            try? FileManager.default.removeItem(at: outputDirectory)
        }

        let stdoutHandle = try FileHandle(forWritingTo: stdoutURL)
        let stderrHandle = try FileHandle(forWritingTo: stderrURL)
        defer {
            try? stdoutHandle.close()
            try? stderrHandle.close()
        }

        return try await withCheckedThrowingContinuation { continuation in
            do {
                let process = Process()
                process.executableURL = executableURL
                process.arguments = arguments
                process.currentDirectoryURL = workingDirectory
                process.standardOutput = stdoutHandle
                process.standardError = stderrHandle

                process.terminationHandler = { process in
                    let stdout = (try? String(contentsOf: stdoutURL, encoding: .utf8)) ?? ""
                    let stderr = (try? String(contentsOf: stderrURL, encoding: .utf8)) ?? ""
                    continuation.resume(
                        returning: (
                            process.terminationStatus,
                            stdout,
                            stderr
                        )
                    )
                }

                try process.run()
            } catch {
                continuation.resume(throwing: error)
            }
        }
    }
}
