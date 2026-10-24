//
//  ZenCronToolchainTests.swift
//  ZenCODE
//

import Foundation
import Testing
@testable import ZenCODECore

@Suite("Cron toolchain and crontab client")
struct ZenCronToolchainTests {
    // MARK: - Toolchain location

    @Test("locate keeps the first executable fixed path for each tool")
    func locateMatchesFixedPaths() {
        let fileManager = FileManager.default
        let toolchain = ZenCronToolchain.locate(fileManager: fileManager)

        let expectedCrontab = ["/usr/bin/crontab", "/bin/crontab"]
            .first { fileManager.isExecutableFile(atPath: $0) }
        let expectedSendmail = ["/usr/sbin/sendmail", "/usr/lib/sendmail"]
            .first { fileManager.isExecutableFile(atPath: $0) }

        #expect(toolchain.crontabPath == expectedCrontab)
        #expect(toolchain.sendmailPath == expectedSendmail)
        #expect(ZenCronToolchain.locate() == toolchain)
    }

    @Test("toolchain is a value type compared by both paths")
    func toolchainEquality() {
        let base = ZenCronToolchain(crontabPath: "/usr/bin/crontab", sendmailPath: nil)
        #expect(base == ZenCronToolchain(crontabPath: "/usr/bin/crontab", sendmailPath: nil))
        #expect(base != ZenCronToolchain(crontabPath: nil, sendmailPath: nil))
        #expect(base != ZenCronToolchain(crontabPath: "/usr/bin/crontab", sendmailPath: "/usr/sbin/sendmail"))
    }

    // MARK: - classifyRead

    @Test("classifyRead returns stdout on success")
    func classifyReadSuccess() throws {
        let text = "MAILTO=\"\"\n0 9 * * * echo hi\n"
        let result = try SystemCrontabClient.classifyRead(
            status: 0,
            stdout: text,
            stderr: ""
        )
        #expect(result == text)
    }

    @Test("classifyRead treats a missing crontab as empty")
    func classifyReadNoCrontab() throws {
        let result = try SystemCrontabClient.classifyRead(
            status: 1,
            stdout: "",
            stderr: "crontab: no crontab for gerardo\n"
        )
        #expect(result == "")
    }

    @Test("classifyRead reports any other failure with the trimmed stderr")
    func classifyReadFailure() {
        #expect(
            throws: ZenCrontabError.commandFailed(
                status: 1,
                detail: "crontab: you are not allowed to use this program"
            )
        ) {
            try SystemCrontabClient.classifyRead(
                status: 1,
                stdout: "",
                stderr: "  crontab: you are not allowed to use this program\n"
            )
        }
        #expect(throws: ZenCrontabError.commandFailed(status: 2, detail: "")) {
            try SystemCrontabClient.classifyRead(status: 2, stdout: "", stderr: "")
        }
    }

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

    @Test("readCrontab never truncates a large crontab")
    func readLargeCrontab() throws {
        let line = "0 9 * * * /usr/local/bin/zen --prompt filler\n"
        let text = String(repeating: line, count: 20_000)
        let fake = try FakeCrontab(standardOutput: text)
        defer { fake.remove() }

        let result = try fake.client.readCrontab()

        #expect(result.utf8.count == text.utf8.count)
        #expect(result == text)
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

    @Test("writeCrontab delivers a large text intact")
    func writeLargeText() throws {
        let line = "0 9 * * * /usr/local/bin/zen --prompt filler\n"
        let text = String(repeating: line, count: 20_000)
        let fake = try FakeCrontab()
        defer { fake.remove() }

        try fake.client.writeCrontab(text)

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

    @Test("removing a crontab that does not exist is tolerated")
    func removeMissingCrontab() throws {
        let fake = try FakeCrontab(
            status: 1,
            standardError: "crontab: no crontab for gerardo\n"
        )
        defer { fake.remove() }

        try fake.client.writeCrontab("")

        #expect(try fake.invocations() == ["-r"])
    }

    @Test("a failing -r other than no crontab is an error")
    func removeFailure() throws {
        let fake = try FakeCrontab(status: 1, standardError: "crontab: permission denied\n")
        defer { fake.remove() }

        #expect(
            throws: ZenCrontabError.commandFailed(
                status: 1,
                detail: "crontab: permission denied"
            )
        ) {
            try fake.client.writeCrontab("")
        }
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

    @Test("a crontab that exits without reading stdin fails cleanly")
    func writeWhenChildIgnoresStdin() throws {
        let fake = try FakeCrontab(
            status: 1,
            standardError: "crontab: you are not allowed to use this program\n",
            readsStandardInput: false
        )
        defer { fake.remove() }
        let text = String(repeating: "0 9 * * * echo hi\n", count: 100_000)

        #expect(
            throws: ZenCrontabError.commandFailed(
                status: 1,
                detail: "crontab: you are not allowed to use this program"
            )
        ) {
            try fake.client.writeCrontab(text)
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
            standardError: String = "",
            readsStandardInput: Bool = true
        ) throws {
            directory = try ZenCronToolchainTests.makeTemporaryDirectory()
            let script = directory.appendingPathComponent("crontab")
            scriptPath = script.path

            try (standardOutputData ?? Data(standardOutput.utf8))
                .write(to: directory.appendingPathComponent("stdout.txt"))
            try Data(standardError.utf8)
                .write(to: directory.appendingPathComponent("stderr.txt"))
            let readInput = readsStandardInput
                ? "if [ \"$1\" = \"-\" ]; then cat > \"$dir/stdin.txt\"; fi"
                : ":"
            let body = """
                #!/bin/sh
                dir=$(dirname "$0")
                printf '%s\\n' "$*" >> "$dir/args.log"
                \(readInput)
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
