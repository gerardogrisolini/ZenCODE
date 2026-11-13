//
//  ZenCronToolchainTests.swift
//  ZenCODE
//

import Foundation
import Testing
@testable import ZenCODECore

@Suite("Cron toolchain and crontab client")
struct ZenCronToolchainTests {
    // MARK: - SystemCrontabClient against a stand-in executable

    @Test("an executable that does not exist is reported as unavailable")
    func missingExecutable() throws {
        let directory = try Self.makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let client = SystemCrontabClient(
            crontabPath: directory.appendingPathComponent("missing").path
        )

        #expect(throws: ZenCrontabError.crontabUnavailable) {
            try client.readCrontab()
        }
        #expect(throws: ZenCrontabError.crontabUnavailable) {
            try client.writeCrontab("0 9 * * * echo hi\n")
        }
    }

    @Test("readCrontab runs -l and returns stdout verbatim")
    func readReturnsStdout() throws {
        let text = "# keep me\n0 9 * * * echo caffè\n"
        let fake = try FakeCrontab(standardOutput: text)
        defer { fake.remove() }

        let result = try fake.client.readCrontab()

        #expect(result == text)
        #expect(try fake.invocations() == ["-l"])
    }

    @Test("readCrontab maps no crontab to empty text")
    func readNoCrontab() throws {
        let fake = try FakeCrontab(
            status: 1,
            standardError: "crontab: no crontab for gerardo\n"
        )
        defer { fake.remove() }

        #expect(try fake.client.readCrontab() == "")
    }

    @Test("readCrontab surfaces other failures and bounds stderr")
    func readFailure() throws {
        let fake = try FakeCrontab(
            status: 3,
            standardError: String(repeating: "x", count: 20_000)
        )
        defer { fake.remove() }

        do {
            _ = try fake.client.readCrontab()
            Issue.record("expected commandFailed")
        } catch let ZenCrontabError.commandFailed(status, detail) {
            #expect(status == 3)
            #expect(detail.utf8.count == 4 * 1024)
        } catch {
            Issue.record("unexpected error: \(error)")
        }
    }

    @Test("readCrontab refuses a crontab that is not valid UTF-8")
    func readNonUTF8() throws {
        let fake = try FakeCrontab(standardOutputData: Data([0x23, 0x20, 0xE8, 0x0A]))
        defer { fake.remove() }

        do {
            _ = try fake.client.readCrontab()
            Issue.record("expected commandFailed")
        } catch let ZenCrontabError.commandFailed(status, detail) {
            #expect(status == 0)
            #expect(detail.contains("UTF-8"))
        } catch {
            Issue.record("unexpected error: \(error)")
        }
    }

    @Test("writeCrontab pipes the text to crontab - on stdin")
    func writeSendsStdin() throws {
        let text = "MAILTO=\"\"\n0 9 * * * echo caffè\n"
        let fake = try FakeCrontab()
        defer { fake.remove() }

        try fake.client.writeCrontab(text)

        #expect(try fake.invocations() == ["-"])
        #expect(try fake.recordedInput() == text)
    }

    @Test("writeCrontab with empty text removes the crontab with -r")
    func writeEmptyRemoves() throws {
        let fake = try FakeCrontab()
        defer { fake.remove() }

        try fake.client.writeCrontab("")

        #expect(try fake.invocations() == ["-r"])
        #expect(try fake.recordedInput() == nil)
    }

    @Test("a failing crontab - is an error even when the text mentions no crontab for")
    func writeFailure() throws {
        let fake = try FakeCrontab(
            status: 1,
            standardError: "crontab: no crontab for gerardo\n"
        )
        defer { fake.remove() }

        #expect(
            throws: ZenCrontabError.commandFailed(
                status: 1,
                detail: "crontab: no crontab for gerardo"
            )
        ) {
            try fake.client.writeCrontab("0 9 * * * echo hi\n")
        }
    }

    // MARK: - Fixtures

    private static func makeTemporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("zencode-cron-client-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        return directory
    }

    /// A stand-in `crontab` shell script in its own UUID-named temporary
    /// directory. It records its arguments (one line per invocation) and, for
    /// `-`, its stdin; the real `crontab` is never involved.
    private struct FakeCrontab {
        let directory: URL
        let scriptPath: String

        var client: SystemCrontabClient {
            SystemCrontabClient(crontabPath: scriptPath)
        }

        init(
            status: Int32 = 0,
            standardOutput: String = "",
            standardOutputData: Data? = nil,
            standardError: String = ""
        ) throws {
            directory = try ZenCronToolchainTests.makeTemporaryDirectory()
            let script = directory.appendingPathComponent("crontab")
            scriptPath = script.path

            try (standardOutputData ?? Data(standardOutput.utf8))
                .write(to: directory.appendingPathComponent("stdout.txt"))
            try Data(standardError.utf8)
                .write(to: directory.appendingPathComponent("stderr.txt"))
            let body = """
                #!/bin/sh
                dir=$(dirname "$0")
                printf '%s\\n' "$*" >> "$dir/args.log"
                if [ "$1" = "-" ]; then cat > "$dir/stdin.txt"; fi
                cat "$dir/stdout.txt"
                cat "$dir/stderr.txt" >&2
                exit \(status)

                """
            try Data(body.utf8).write(to: script)
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o755],
                ofItemAtPath: script.path
            )
        }

        func invocations() throws -> [String] {
            let log = directory.appendingPathComponent("args.log")
            guard FileManager.default.fileExists(atPath: log.path) else { return [] }
            return try String(contentsOf: log, encoding: .utf8)
                .split(separator: "\n", omittingEmptySubsequences: true)
                .map(String.init)
        }

        func recordedInput() throws -> String? {
            let input = directory.appendingPathComponent("stdin.txt")
            guard FileManager.default.fileExists(atPath: input.path) else { return nil }
            return try String(contentsOf: input, encoding: .utf8)
        }

        func remove() {
            try? FileManager.default.removeItem(at: directory)
        }
    }
}
