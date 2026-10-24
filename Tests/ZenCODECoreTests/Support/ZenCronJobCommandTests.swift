//
//  ZenCronJobCommandTests.swift
//  ZenCODE
//

import Foundation
import Testing
@testable import ZenCODECore

@Suite("Cron job command")
struct ZenCronJobCommandTests {
    private func makeJob(
        executable: String = "zen",
        supportDirectory: String? = nil,
        agentName: String? = nil,
        workingDirectory: String = "/Users/me/project",
        prompt: String = "summarize the repo"
    ) -> ZenCronJobCommand {
        ZenCronJobCommand(
            executable: executable,
            supportDirectory: supportDirectory,
            agentName: agentName,
            workingDirectory: workingDirectory,
            prompt: prompt
        )
    }

    // MARK: - encode

    @Test
    func encodesMinimalCommandWithABareZenInFixedOrder() {
        #expect(
            makeJob().encode()
                == "zen --working-directory '/Users/me/project' --jsonl -p 'summarize the repo'"
        )
    }

    @Test
    func encodesAnyOtherExecutableSingleQuoted() {
        #expect(
            makeJob(executable: "/usr/local/bin/zen").encode()
                == "'/usr/local/bin/zen' --working-directory '/Users/me/project' --jsonl -p 'summarize the repo'"
        )
        // Only the exact word `zen` is bare.
        #expect(makeJob(executable: "Zen").encode().hasPrefix("'Zen' "))
        #expect(makeJob(executable: "zen ").encode().hasPrefix("'zen ' "))
        #expect(makeJob(executable: "").encode().hasPrefix("'' "))
    }

    @Test
    func encodesAllOptionalPartsInFixedOrder() {
        let job = makeJob(
            supportDirectory: "/Users/me/.zencode",
            agentName: "reviewer",
            prompt: "hello"
        )
        #expect(
            job.encode()
                == "ZENCODE_SUPPORT_DIRECTORY='/Users/me/.zencode' zen --agent 'reviewer' "
                + "--working-directory '/Users/me/project' --jsonl -p 'hello'"
        )
    }

    @Test
    func encodesSingleQuotesAsCloseEscapeReopen() {
        let job = makeJob(prompt: "it's a 'test'")
        #expect(job.encode().hasSuffix("-p 'it'\\''s a '\\''test'\\'''"))
    }

    @Test
    func keepsShellMetacharactersInertInsideSingleQuotes() {
        let job = makeJob(prompt: "echo $HOME `id` \"x\" \\n ; rm -rf * | cat &")
        #expect(job.encode().hasSuffix("-p 'echo $HOME `id` \"x\" \\n ; rm -rf * | cat &'"))
    }

    // MARK: - round trip

    @Test(arguments: [
        "plain prompt",
        "",
        "it's",
        "'",
        "''",
        "'leading and trailing'",
        "two  spaces   and\ttab",
        "100% sure, 50%% more, %",
        "backslash \\ and \\% and \\\\%",
        "quote then combining mark '\u{0301}x",
        "unicode \u{1F600} \u{00E8}",
        "$(touch /tmp/x) `id` ${HOME}",
        "--agent 'x' --jsonl -p 'y'"
    ])
    func roundTripsPromptsThroughEncodeAndDecode(_ prompt: String) {
        let job = makeJob(
            supportDirectory: "/tmp/with space/and'quote",
            agentName: "agent with 'quotes'",
            prompt: prompt
        )
        #expect(ZenCronJobCommand.decode(job.encode()) == job)
    }

    @Test
    func roundTripsMinimalAndPathsWithSpacesAndQuotes() {
        let minimal = makeJob(
            executable: "/Applications/My Apps/zen's/zen",
            workingDirectory: "/Users/me/it's here/proj ect"
        )
        #expect(ZenCronJobCommand.decode(minimal.encode()) == minimal)

        let emptySupport = makeJob(supportDirectory: "")
        #expect(ZenCronJobCommand.decode(emptySupport.encode()) == emptySupport)
    }

    @Test(arguments: [
        "50% done",
        "100%% \\% mix",
        "%",
        "\\%",
        "\\\\%",
        "no percent at all"
    ])
    func roundTripsThroughCronPercentEscaping(_ prompt: String) throws {
        let job = makeJob(prompt: prompt)
        let onCronLine = ZenCronJobCommand.cronEscape(job.encode())
        let unescaped = try #require(ZenCronJobCommand.cronUnescape(onCronLine))
        #expect(ZenCronJobCommand.decode(unescaped) == job)
    }

    @Test
    func roundTripsTheBareZenAndAQuotedPathAlike() {
        for executable in ["zen", "/usr/local/bin/zen", "/opt/my apps/zen", "relative/zen", "it's"] {
            let job = makeJob(
                executable: executable,
                supportDirectory: "/s",
                agentName: "a",
                prompt: "100% it's 'quoted' \\% done"
            )
            #expect(ZenCronJobCommand.decode(job.encode()) == job)

            let onCronLine = ZenCronJobCommand.cronEscape(job.encode())
            #expect(ZenCronJobCommand.cronUnescape(onCronLine).flatMap(ZenCronJobCommand.decode) == job)
        }
    }

    // MARK: - decode rejections

    @Test(arguments: [
        "",
        "zen",
        "echo hello",
        // unquoted executable other than the bare `zen`
        "/usr/local/bin/zen --working-directory '/w' --jsonl -p 'x'",
        "zenith --working-directory '/w' --jsonl -p 'x'",
        "ls --working-directory '/w' --jsonl -p 'x'",
        "ZEN --working-directory '/w' --jsonl -p 'x'",
        "zen/zen --working-directory '/w' --jsonl -p 'x'",
        "echo --working-directory '/w' --jsonl -p 'x'",
        "zen'x' --working-directory '/w' --jsonl -p 'x'",
        "zen--working-directory '/w' --jsonl -p 'x'",
        "zen  --working-directory '/w' --jsonl -p 'x'",
        "zen \"zen\" --working-directory '/w' --jsonl -p 'x'",
        "zen --jsonl -p 'x'",
        "ZENCODE_SUPPORT_DIRECTORY='/s' ls --working-directory '/w' --jsonl -p 'x'",
        // missing pieces
        "'/z' --jsonl -p 'x'",
        "'/z' --working-directory '/w' -p 'x'",
        "'/z' --working-directory '/w' --jsonl",
        "'/z' --working-directory '/w' --jsonl -p",
        // wrong order
        "'/z' --jsonl --working-directory '/w' -p 'x'",
        "'/z' --working-directory '/w' --agent 'a' --jsonl -p 'x'",
        "'/z' --working-directory '/w' -p 'x' --jsonl",
        "'/z' --agent 'a' --agent 'b' --working-directory '/w' --jsonl -p 'x'",
        "'/z' --model 'm' --working-directory '/w' --jsonl -p 'x'",
        "'/z' --working-directory '/w' --jsonl -p 'x' --extra",
        // unquoted values
        "'/z' --agent a --working-directory '/w' --jsonl -p 'x'",
        "'/z' --working-directory /w --jsonl -p 'x'",
        "'/z' --working-directory '/w' --jsonl -p x",
        // environment prefix variations
        "ZENCODE_SUPPORT_DIRECTORY=/s '/z' --working-directory '/w' --jsonl -p 'x'",
        "ZENCODE_SUPPORT_DIRECTORY='/s''/z' --working-directory '/w' --jsonl -p 'x'",
        "ZENCODE_SUPPORT_DIRECTORY='/s'  '/z' --working-directory '/w' --jsonl -p 'x'",
        "OTHER='/s' '/z' --working-directory '/w' --jsonl -p 'x'",
        "'/z' ZENCODE_SUPPORT_DIRECTORY='/s' --working-directory '/w' --jsonl -p 'x'",
        // spacing
        "'/z'  --working-directory '/w' --jsonl -p 'x'",
        "'/z' --working-directory '/w' --jsonl -p 'x' ",
        " '/z' --working-directory '/w' --jsonl -p 'x'",
        "'/z' --working-directory '/w'\t--jsonl -p 'x'",
        // quoting defects
        "'/z' --working-directory '/w' --jsonl -p 'unterminated",
        "'/z' --working-directory '/w' --jsonl -p 'a''b'",
        "'/z' --working-directory '/w' --jsonl -p 'a'\\'",
        "'/z' --working-directory '/w' --jsonl -p 'a'\\' b",
        "\"/z\" --working-directory '/w' --jsonl -p 'x'",
        "'/z' --working-directory '/w' --jsonl -p \"x\"",
        // line breaks never fit on one crontab line
        "'/z' --working-directory '/w' --jsonl -p 'two\nlines'",
        "'/z' --working-directory '/w' --jsonl -p 'carriage\rreturn'",
        "'/z' --working-directory '/w' --jsonl -p 'x'\n"
    ])
    func decodeReturnsNilOutsideTheFixedGrammar(_ command: String) {
        #expect(ZenCronJobCommand.decode(command) == nil)
    }

    @Test
    func decodeAcceptsABareZen() {
        #expect(
            ZenCronJobCommand.decode("zen --working-directory '/w' --jsonl -p 'x'")
                == makeJob(workingDirectory: "/w", prompt: "x")
        )
        #expect(
            ZenCronJobCommand.decode(
                "ZENCODE_SUPPORT_DIRECTORY='/s' zen --agent 'a' --working-directory '/w' --jsonl -p 'x'"
            ) == makeJob(
                supportDirectory: "/s",
                agentName: "a",
                workingDirectory: "/w",
                prompt: "x"
            )
        )
    }

    @Test
    func decodeAcceptsAQuotedPathWrittenByHandOrByAnOlderVersion() {
        #expect(
            ZenCronJobCommand.decode("'/usr/local/bin/zen' --working-directory '/w' --jsonl -p 'x'")
                == makeJob(executable: "/usr/local/bin/zen", workingDirectory: "/w", prompt: "x")
        )
        #expect(
            ZenCronJobCommand.decode("'/Applications/My Apps/zen' --working-directory '/w' --jsonl -p 'x'")?
                .executable == "/Applications/My Apps/zen"
        )
        // A quoted `zen` is the same job as the bare one.
        #expect(
            ZenCronJobCommand.decode("'zen' --working-directory '/w' --jsonl -p 'x'")
                == makeJob(workingDirectory: "/w", prompt: "x")
        )
    }

    @Test
    func decodeAcceptsTheDocumentedGrammarWrittenByHand() {
        let decoded = ZenCronJobCommand.decode(
            "ZENCODE_SUPPORT_DIRECTORY='/s' '/z' --agent 'a b' --working-directory '/w' --jsonl -p 'it'\\''s'"
        )
        #expect(
            decoded == makeJob(
                executable: "/z",
                supportDirectory: "/s",
                agentName: "a b",
                workingDirectory: "/w",
                prompt: "it's"
            )
        )
    }

    // MARK: - cron escaping

    @Test
    func cronEscapeEscapesEveryPercent() {
        #expect(ZenCronJobCommand.cronEscape("a%b%%c") == "a\\%b\\%\\%c")
        #expect(ZenCronJobCommand.cronEscape("no percent") == "no percent")
        #expect(ZenCronJobCommand.cronEscape("") == "")
    }

    @Test
    func cronUnescapeReversesEscapedPercent() {
        #expect(ZenCronJobCommand.cronUnescape("a\\%b\\%\\%c") == "a%b%%c")
        #expect(ZenCronJobCommand.cronUnescape("plain") == "plain")
        #expect(ZenCronJobCommand.cronUnescape("") == "")
        #expect(ZenCronJobCommand.cronUnescape("trailing backslash \\") == "trailing backslash \\")
        #expect(ZenCronJobCommand.cronUnescape("\\n stays") == "\\n stays")
    }

    @Test(arguments: ["a%b", "%", "50\\%%", "100%", "\\\\\\%%"])
    func cronUnescapeReturnsNilWhenAnUnescapedPercentRemains(_ text: String) {
        #expect(ZenCronJobCommand.cronUnescape(text) == nil)
    }

    @Test
    func cronUnescapeTreatsABackslashBeforeAnEscapedPercentAsLiteral() {
        // `x\\%y` is a literal backslash followed by an escaped percent, as cron itself reads it.
        #expect(ZenCronJobCommand.cronUnescape("x\\\\%y") == "x\\%y")
    }

    @Test(arguments: ["", "%", "\\%", "\\\\%", "a%b\\%c", "%%%", "50\\\\%\\%"])
    func cronEscapeThenUnescapeIsTheIdentity(_ text: String) {
        #expect(ZenCronJobCommand.cronUnescape(ZenCronJobCommand.cronEscape(text)) == text)
    }

    @Test
    func cronEscapedCommandContainsNoBarePercent() {
        let escaped = ZenCronJobCommand.cronEscape(makeJob(prompt: "100% and %d").encode())
        var previous: Character?
        for character in escaped {
            if character == "%" {
                #expect(previous == "\\")
            }
            previous = character
        }
    }

    // MARK: - locating zen

    private func withTemporaryDirectories(
        _ count: Int,
        _ body: ([URL]) throws -> Void
    ) throws {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory
            .appendingPathComponent("zen-cron-locate-\(UUID().uuidString)", isDirectory: true)
        let directories = (0..<count).map { index in
            root.appendingPathComponent("dir\(index)-\(UUID().uuidString)", isDirectory: true)
        }
        for directory in directories {
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        defer { try? fileManager.removeItem(at: root) }
        try body(directories)
    }

    private func writeZen(in directory: URL, executable: Bool) throws -> String {
        let url = directory.appendingPathComponent("zen")
        try Data("#!/bin/sh\nexit 0\n".utf8).write(to: url)
        try FileManager.default.setAttributes(
            [.posixPermissions: executable ? 0o755 : 0o644],
            ofItemAtPath: url.path
        )
        return url.path
    }

    @Test
    func locateZenReturnsTheFirstExecutableZenOnThePath() throws {
        try withTemporaryDirectories(2) { directories in
            let first = try writeZen(in: directories[0], executable: true)
            _ = try writeZen(in: directories[1], executable: true)
            let path = directories.map(\.path).joined(separator: ":")
            #expect(ZenCronJobCommand.locateZen(onPath: path) == first)

            let reversed = directories.reversed().map(\.path).joined(separator: ":")
            #expect(
                ZenCronJobCommand.locateZen(onPath: reversed)
                    == directories[1].appendingPathComponent("zen").path
            )
        }
    }

    @Test
    func locateZenSkipsANonExecutableZenAndFallsThroughToTheNextDirectory() throws {
        try withTemporaryDirectories(2) { directories in
            _ = try writeZen(in: directories[0], executable: false)
            let second = try writeZen(in: directories[1], executable: true)
            let path = directories.map(\.path).joined(separator: ":")
            #expect(ZenCronJobCommand.locateZen(onPath: path) == second)
        }
    }

    @Test
    func locateZenReturnsNilWithoutAnExecutableZen() throws {
        try withTemporaryDirectories(2) { directories in
            _ = try writeZen(in: directories[0], executable: false)
            let path = directories.map(\.path).joined(separator: ":")
            #expect(ZenCronJobCommand.locateZen(onPath: path) == nil)
        }
        #expect(ZenCronJobCommand.locateZen(onPath: "") == nil)
        #expect(ZenCronJobCommand.locateZen(onPath: ":::") == nil)
    }

    @Test
    func locateZenIgnoresEmptyAndRelativeEntries() {
        let fileManager = ProbingFileManager(executables: ["/fixture/zen"])
        let path = ":.::./:bin:~/bin:$HOME/bin::/fixture::/other:"
        #expect(ZenCronJobCommand.locateZen(onPath: path, fileManager: fileManager) == "/fixture/zen")
        // Only the absolute entries up to the match were probed.
        #expect(fileManager.probedPaths == ["/fixture/zen"])

        let miss = ProbingFileManager(executables: [])
        #expect(ZenCronJobCommand.locateZen(onPath: path, fileManager: miss) == nil)
        #expect(miss.probedPaths == ["/fixture/zen", "/other/zen"])
    }

    @Test
    func locateZenToleratesATrailingSlashOnADirectory() throws {
        try withTemporaryDirectories(1) { directories in
            let zen = try writeZen(in: directories[0], executable: true)
            #expect(ZenCronJobCommand.locateZen(onPath: directories[0].path + "/") == zen)
            #expect(ZenCronJobCommand.locateZen(onPath: directories[0].path + "//") == zen)
        }
    }

    @Test
    func locateZenUsesTheGivenFileManager() {
        let fileManager = ProbingFileManager(executables: ["/fixture/b/zen"])
        #expect(
            ZenCronJobCommand.locateZen(onPath: "/fixture/a:/fixture/b:/fixture/c", fileManager: fileManager)
                == "/fixture/b/zen"
        )
        #expect(fileManager.probedPaths == ["/fixture/a/zen", "/fixture/b/zen"])
    }

    @Test
    func locateZenProbesTheRootDirectoryAsSlashZen() {
        let fileManager = ProbingFileManager(executables: ["/zen"])
        #expect(ZenCronJobCommand.locateZen(onPath: "/", fileManager: fileManager) == "/zen")
        #expect(fileManager.probedPaths == ["/zen"])
    }
}

/// A `FileManager` that records every path asked about and reports a fixed set
/// as executable, so `locateZen` is tested without touching the machine's PATH.
private final class ProbingFileManager: FileManager {
    private let lock = NSLock()
    private let executables: Set<String>
    private var probed: [String] = []

    init(executables: Set<String>) {
        self.executables = executables
        super.init()
    }

    var probedPaths: [String] {
        lock.withLock { probed }
    }

    override func isExecutableFile(atPath path: String) -> Bool {
        lock.withLock { probed.append(path) }
        return executables.contains(path)
    }
}
