//
//  ZenCrontabDocumentTests.swift
//  ZenCODE
//

import Foundation
import Testing
@testable import ZenCODECore
@testable import ZenCODERuntime

@Suite("Crontab document")
struct ZenCrontabDocumentTests {
    static let begin = "# >>> ZenCODE cron >>>"
    static let end = "# <<< ZenCODE cron <<<"
    private static let defaultPath = "/usr/local/bin:/usr/bin:/bin"
    /// The `PATH=` line every rendered block starts with.
    static let pathLine = "PATH=/usr/local/bin:/usr/bin:/bin"

    let firstID = UUID(uuidString: "11111111-1111-1111-1111-111111111111")!
    let secondID = UUID(uuidString: "22222222-2222-2222-2222-222222222222")!
    /// 2026-09-10T12:00:00Z
    let createdAt = Date(timeIntervalSince1970: 1_789_041_600)

    func makeJob(
        outputFormat: ZenCronJobCommand.OutputFormat = .text,
        promptFile: String? = nil,
        prompt: String? = "summarize the repo"
    ) -> ZenCronJobCommand {
        ZenCronJobCommand(
            executable: "zen",
            supportDirectory: nil,
            agentName: nil,
            workingDirectory: "/Users/me/project",
            outputFormat: outputFormat,
            promptFile: promptFile,
            prompt: prompt
        )
    }

    func schedule(_ text: String) throws -> ZenCronSchedule {
        try ZenCronSchedule(parsing: text)
    }

    func entries(of document: ZenCrontabDocument) -> [ZenCronEntry] {
        (document.block?.items ?? []).compactMap { item in
            if case let .entry(entry) = item { return entry }
            return nil
        }
    }

    private func expectRoundTrip(_ text: String, sourceLocation: SourceLocation = #_sourceLocation) throws {
        let parsed = try ZenCrontabDocument.parse(text)
        let reparsed = try ZenCrontabDocument.parse(parsed.render())
        #expect(reparsed == parsed, sourceLocation: sourceLocation)
        #expect(reparsed.render() == parsed.render(), sourceLocation: sourceLocation)
    }

    var sampleBlockLines: [String] {
        [
            Self.begin,
            Self.pathLine,
            "MAILTO=ops@example.com",
            "# zencode-cron id=11111111-1111-1111-1111-111111111111 created=2026-09-10T12:00:00Z",
            "0 9 * * 1-5 zen --working-directory '/w' --jsonl -p 'daily report'",
            "# zencode-cron id=22222222-2222-2222-2222-222222222222 created=2026-09-11T08:30:00Z",
            "@hourly '/usr/local/bin/zen' --agent 'ops' --working-directory '/w' --jsonl -p 'status'",
            Self.end
        ]
    }

    /// A block whose `PATH=` was edited by hand, with `MAILTO=` before the entries.
    private var customPathBlockLines: [String] {
        [
            Self.begin,
            "PATH=/opt/zen/bin:/usr/local/bin:/usr/bin:/bin",
            "MAILTO=ops@example.com",
            "# zencode-cron id=11111111-1111-1111-1111-111111111111 created=2026-09-10T12:00:00Z",
            "0 9 * * 1-5 zen --working-directory '/w' --jsonl -p 'daily report'",
            Self.end
        ]
    }

    // MARK: - parse: no block

    @Test(arguments: [
        "# my jobs\nSHELL=/bin/zsh\n  0 3 * * *\t/usr/bin/backup --full   \n\n@reboot echo started # trailing comment\n\n\n",
        // Carriage returns stay attached to their line.
        "0 * * * * job\r\n5 * * * * other\r\n",
        // A stray end marker without a begin marker is a foreign line.
        "A\n# <<< ZenCODE cron <<<\nB\n",
        // Markers must match whole lines exactly.
        "  # >>> ZenCODE cron >>>\n# >>> ZenCODE cron >>> \n## >>> ZenCODE cron >>>\n"
    ])
    func crontabWithoutBlockIsPreservedVerbatim(_ text: String) throws {
        let document = try ZenCrontabDocument.parse(text)
        #expect(document.block == nil)
        #expect(document.foreignLines.joined(separator: "\n") + "\n" == text)
        #expect(document.render() == text)
    }

    @Test
    func missingFinalNewlineIsAddedButLinesAreUntouched() throws {
        let document = try ZenCrontabDocument.parse("0 * * * * job\n5 * * * * other")
        #expect(document.foreignLines == ["0 * * * * job", "5 * * * * other"])
        #expect(document.render() == "0 * * * * job\n5 * * * * other\n")
    }

    // MARK: - parse: block contents

    @Test
    func parsesMailToAndEntries() throws {
        let text = (["0 1 * * * /bin/true"] + [""] + sampleBlockLines).joined(separator: "\n") + "\n"
        let document = try ZenCrontabDocument.parse(text)

        #expect(document.foreignLines == ["0 1 * * * /bin/true"])
        let block = try #require(document.block)
        #expect(block.path == nil)
        #expect(block.mailTo == "ops@example.com")
        #expect(block.items.count == 2)

        let found = entries(of: document)
        #expect(found.count == 2)

        #expect(found[0].id == firstID)
        #expect(found[0].createdAt == createdAt)
        #expect(found[0].schedule == "0 9 * * 1-5")
        #expect(found[0].cronCommand == "zen --working-directory '/w' --jsonl -p 'daily report'")
        #expect(found[0].job?.executable == "zen")
        #expect(found[0].job?.prompt == "daily report")
        #expect(found[0].job?.agentName == nil)
        // Lines written before the text format existed carry `--jsonl`.
        #expect(found[0].job?.outputFormat == .jsonl)

        #expect(found[1].id == secondID)
        #expect(found[1].schedule == "@hourly")
        // A line written with a full path (older ZenCODE, or by hand) still decodes.
        #expect(found[1].job?.executable == "/usr/local/bin/zen")
        #expect(found[1].job?.agentName == "ops")
        #expect(found[1].job?.outputFormat == .jsonl)
        #expect(found[1].markerLine == sampleBlockLines[5])
        #expect(found[1].cronLine == sampleBlockLines[6])
    }

    @Test
    func entryWithPercentEscapesDecodesItsJob() throws {
        let job = makeJob(prompt: "100% done, 5%% more")
        var document = ZenCrontabDocument()
        try document.appendEntry(schedule: schedule("0 0 * * *"), job: job, id: firstID, createdAt: createdAt)

        let parsed = try ZenCrontabDocument.parse(document.render())
        let entry = try #require(entries(of: parsed).first)
        #expect(entry.cronCommand.contains("\\%"))
        #expect(!entry.cronCommand.replacingOccurrences(of: "\\%", with: "").contains("%"))
        #expect(entry.job == job)
    }

    @Test
    func scheduleKeepsFiveTokensEvenWhenSeparatedByTabsAndManySpaces() throws {
        let line = "*/5\t 1-3  *   jan,feb  mon    zen --working-directory '/w' --jsonl -p 'x'"
        let text = [Self.begin, "# zencode-cron id=\(firstID.uuidString) created=2026-09-10T12:00:00Z", line, Self.end]
            .joined(separator: "\n") + "\n"
        let entry = try #require(entries(of: ZenCrontabDocument.parse(text)).first)
        #expect(entry.schedule == "*/5 1-3 * jan,feb mon")
        #expect(entry.cronCommand == "zen --working-directory '/w' --jsonl -p 'x'")
        #expect(entry.cronLine == line)
    }

    @Test
    func handEditedCommandStaysAnEntryWithoutAJob() throws {
        let text = [
            Self.begin,
            Self.pathLine,
            "# zencode-cron id=\(firstID.uuidString) created=2026-09-10T12:00:00Z",
            "0 9 * * * /usr/bin/something --else",
            Self.end
        ].joined(separator: "\n") + "\n"
        let document = try ZenCrontabDocument.parse(text)
        let entry = try #require(entries(of: document).first)
        #expect(entry.job == nil)
        #expect(entry.cronCommand == "/usr/bin/something --else")
        #expect(document.render() == text)
    }

    @Test(arguments: [
        "# zencode-cron id=not-a-uuid created=2026-09-10T12:00:00Z",
        "# zencode-cron id=11111111-1111-1111-1111-111111111111 created=yesterday",
        "# zencode-cron id=11111111-1111-1111-1111-111111111111",
        "# zencode-cron created=2026-09-10T12:00:00Z id=11111111-1111-1111-1111-111111111111",
        "# zencode-cron  id=11111111-1111-1111-1111-111111111111 created=2026-09-10T12:00:00Z",
        "# zencode-cron id=11111111-1111-1111-1111-111111111111 created=2026-09-10T12:00:00Z extra",
        "# zencode-cron"
    ])
    func malformedMarkerBecomesUnrecognizedAndItsCronLineToo(_ marker: String) throws {
        let cron = "0 9 * * * zen --working-directory '/w' --jsonl -p 'x'"
        let text = [Self.begin, Self.pathLine, marker, cron, Self.end].joined(separator: "\n") + "\n"
        let document = try ZenCrontabDocument.parse(text)
        let block = try #require(document.block)
        #expect(block.items == [.unrecognized(marker), .unrecognized(cron)])
        #expect(entries(of: document).isEmpty)
        #expect(document.render() == text)
    }

    @Test(arguments: [
        "",
        "# just a comment",
        "FOO=bar",
        "only three tokens"
    ])
    func validMarkerNotFollowedByACronLineIsUnrecognized(_ following: String) throws {
        let marker = "# zencode-cron id=\(firstID.uuidString) created=2026-09-10T12:00:00Z"
        let text = [Self.begin, marker, following, Self.end].joined(separator: "\n") + "\n"
        let document = try ZenCrontabDocument.parse(text)
        let block = try #require(document.block)
        #expect(entries(of: document).isEmpty)
        #expect(block.items.first == .unrecognized(marker))
        // The text after the marker is kept verbatim (blank lines inside the block are dropped).
        let expectedItems: [ZenCrontabDocument.Item] = following.isEmpty
            ? [.unrecognized(marker)]
            : [.unrecognized(marker), .unrecognized(following)]
        #expect(block.items == expectedItems)
    }

    @Test
    func unknownLinesInsideTheBlockAreKeptVerbatimInOrder() throws {
        let marker = "# zencode-cron id=\(firstID.uuidString) created=2026-09-10T12:00:00Z"
        let cron = "0 9 * * * zen --working-directory '/w' --jsonl -p 'x'"
        let lines = [Self.begin, "  stray line  ", marker, cron, "MAILTO=late@example.com", Self.end]
        let text = lines.joined(separator: "\n") + "\n"
        let document = try ZenCrontabDocument.parse(text)
        let block = try #require(document.block)
        #expect(block.path == nil)
        #expect(block.mailTo == nil)
        #expect(block.items.count == 3)
        #expect(block.items[0] == .unrecognized("  stray line  "))
        #expect(block.items[2] == .unrecognized("MAILTO=late@example.com"))
        // Only the `PATH=` header line is added: the stray lines keep their place.
        let expected = [Self.begin, Self.pathLine] + lines.dropFirst()
        #expect(document.render() == expected.joined(separator: "\n") + "\n")
    }

    @Test
    func blankLinesInsideTheBlockAreDropped() throws {
        let marker = "# zencode-cron id=\(firstID.uuidString) created=2026-09-10T12:00:00Z"
        let cron = "0 9 * * * zen --working-directory '/w' --jsonl -p 'x'"
        let text = [Self.begin, "", marker, cron, "   ", Self.end].joined(separator: "\n") + "\n"
        let document = try ZenCrontabDocument.parse(text)
        #expect(
            document.render() == [Self.begin, Self.pathLine, marker, cron, Self.end].joined(separator: "\n") + "\n"
        )
    }

    @Test
    func acceptsFractionalSecondsInTheMarkerTimestamp() throws {
        let marker = "# zencode-cron id=\(firstID.uuidString) created=2026-09-10T12:00:00.250Z"
        let cron = "0 9 * * * zen --working-directory '/w' --jsonl -p 'x'"
        let document = try ZenCrontabDocument.parse([Self.begin, marker, cron, Self.end].joined(separator: "\n"))
        let entry = try #require(entries(of: document).first)
        #expect(abs(entry.createdAt.timeIntervalSince(createdAt) - 0.25) < 0.001)
    }

    // MARK: - MAILTO

    @Test
    func unquotedEmptyMailToNormalizesToQuotedEmpty() throws {
        let document = try ZenCrontabDocument.parse([Self.begin, "MAILTO=", Self.end].joined(separator: "\n"))
        #expect(document.block?.mailTo == "")
        #expect(
            document.render()
                == [Self.begin, Self.pathLine, "MAILTO=\"\"", Self.end].joined(separator: "\n") + "\n"
        )
    }

    @Test
    func outerDoubleQuotesAreRemovedFromMailTo() throws {
        let document = try ZenCrontabDocument.parse(
            [Self.begin, "MAILTO=\"me@example.com\"", Self.end].joined(separator: "\n")
        )
        #expect(document.block?.mailTo == "me@example.com")
        #expect(document.render().contains("\nMAILTO=me@example.com\n"))
    }

    @Test
    func setMailToCreatesTheBlockAndEmptyStringIsRenderedExplicitly() {
        var document = ZenCrontabDocument(foreignLines: ["0 1 * * * /bin/true"])
        document.setMailTo("")
        #expect(document.block?.mailTo == "")
        #expect(
            document.render()
                == "0 1 * * * /bin/true\n\n\(Self.begin)\n\(Self.pathLine)\nMAILTO=\"\"\n\(Self.end)\n"
        )

        document.setMailTo("a@b.c")
        #expect(document.render().contains("\nMAILTO=a@b.c\n"))

        document.setMailTo(nil)
        #expect(document.block == nil)
        #expect(document.render() == "0 1 * * * /bin/true\n")
    }

    @Test
    func clearingMailToKeepsTheBlockWhileItHasEntries() throws {
        var document = ZenCrontabDocument()
        try document.appendEntry(schedule: schedule("@daily"), job: makeJob(), id: firstID, createdAt: createdAt)
        document.setMailTo("a@b.c")
        document.setMailTo(nil)
        #expect(document.block?.mailTo == nil)
        #expect(document.block?.items.count == 1)
        #expect(!document.render().contains("MAILTO"))
    }

    @Test
    func mailToThatLooksQuotedSurvivesARoundTrip() throws {
        var document = ZenCrontabDocument()
        document.setMailTo("\"\"")
        let reparsed = try ZenCrontabDocument.parse(document.render())
        #expect(reparsed == document)
    }

    // MARK: - PATH

    private let entryMarker = "# zencode-cron id=11111111-1111-1111-1111-111111111111 created=2026-09-10T12:00:00Z"
    private let entryCron = "@daily zen --working-directory '/w' --jsonl -p 'x'"

    @Test
    func renderWritesPathBeforeMailToAndBeforeTheEntries() throws {
        var document = ZenCrontabDocument(foreignLines: ["0 1 * * * /bin/true"])
        try document.appendEntry(schedule: schedule("@daily"), job: makeJob(), id: firstID, createdAt: createdAt)
        document.setMailTo("ops@example.com")

        let lines = document.render().split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        let begin = try #require(lines.firstIndex(of: Self.begin))
        #expect(lines[begin + 1] == Self.pathLine)
        #expect(lines[begin + 2] == "MAILTO=ops@example.com")
        #expect(lines[begin + 3].hasPrefix("# zencode-cron id="))
        #expect(lines.last == "")
        #expect(lines[lines.count - 2] == Self.end)
    }

    @Test
    func parsesPathAndMailToInEitherOrder() throws {
        let pathFirst = [Self.begin, "PATH=/opt/bin:/usr/bin", "MAILTO=a@b.c", entryMarker, entryCron, Self.end]
        let mailFirst = [Self.begin, "MAILTO=a@b.c", "PATH=/opt/bin:/usr/bin", entryMarker, entryCron, Self.end]

        for lines in [pathFirst, mailFirst] {
            let document = try ZenCrontabDocument.parse(lines.joined(separator: "\n") + "\n")
            let block = try #require(document.block)
            #expect(block.path == "/opt/bin:/usr/bin")
            #expect(block.mailTo == "a@b.c")
            #expect(entries(of: document).count == 1)
            #expect(block.items.count == 1)
            // Always redrawn as PATH first, then MAILTO.
            #expect(document.render() == pathFirst.joined(separator: "\n") + "\n")
        }
    }

    @Test
    func headerAcceptsBlankLinesBetweenItsLines() throws {
        let text = [Self.begin, "", "PATH=/p", "  ", "MAILTO=a@b.c", "", entryMarker, entryCron, Self.end]
            .joined(separator: "\n") + "\n"
        let block = try #require(ZenCrontabDocument.parse(text).block)
        #expect(block.path == "/p")
        #expect(block.mailTo == "a@b.c")
        #expect(block.items.count == 1)
    }

    @Test
    func aBlockWithoutAPathLineHasTheDefaultPathAndGainsTheLineWhenRendered() throws {
        let legacy = [
            Self.begin,
            "MAILTO=ops@example.com",
            entryMarker,
            "@daily '/usr/local/bin/zen' --working-directory '/w' --jsonl -p 'x'",
            Self.end
        ]
        let document = try ZenCrontabDocument.parse(legacy.joined(separator: "\n") + "\n")
        #expect(document.block?.path == nil)
        #expect(document.block?.mailTo == "ops@example.com")
        #expect(document.effectivePath == Self.defaultPath)

        let rendered = [legacy[0], Self.pathLine] + legacy.dropFirst()
        #expect(document.render() == rendered.joined(separator: "\n") + "\n")
    }

    @Test(arguments: [
        "/opt/zen/bin:/usr/local/bin:/usr/bin:/bin",
        "/usr/bin:/bin",
        "/usr/local/bin:/usr/bin:/bin:",
        "/usr/local/bin:/usr/bin",
        "\"/opt/bin:/usr/bin\"",
        "",
        "$HOME/bin:/usr/bin",
        " /with space:/usr/bin "
    ])
    func aCustomPathIsKeptVerbatimAndRedrawnIdentically(_ value: String) throws {
        let text = [Self.begin, "PATH=\(value)", entryMarker, entryCron, Self.end].joined(separator: "\n") + "\n"
        let document = try ZenCrontabDocument.parse(text)
        #expect(document.block?.path == value)
        #expect(document.render() == text)

        // The path survives the edits ZenCODE makes to the block.
        var edited = document
        try edited.appendEntry(schedule: schedule("@hourly"), job: makeJob(), id: secondID, createdAt: createdAt)
        edited.setMailTo("a@b.c")
        let reparsed = try ZenCrontabDocument.parse(edited.render())
        #expect(reparsed.block?.path == value)
        #expect(reparsed == edited)
    }

    @Test
    func aSecondPathLineIsUnrecognizedAndEndsTheHeader() throws {
        let text = [
            Self.begin, "PATH=/first", "PATH=/second", "MAILTO=a@b.c", entryMarker, entryCron, Self.end
        ].joined(separator: "\n") + "\n"
        let document = try ZenCrontabDocument.parse(text)
        let block = try #require(document.block)
        #expect(block.path == "/first")
        // The repeat ended the header, so the MAILTO after it is not a header line either.
        #expect(block.mailTo == nil)
        #expect(block.items.first == .unrecognized("PATH=/second"))
        #expect(block.items.dropFirst().first == .unrecognized("MAILTO=a@b.c"))
        #expect(entries(of: document).count == 1)
        #expect(document.render() == text)
    }

    @Test
    func aPathLineAfterAnEntryOrAStrayLineIsUnrecognized() throws {
        let afterEntry = [Self.begin, entryMarker, entryCron, "PATH=/late", Self.end].joined(separator: "\n") + "\n"
        let block = try #require(ZenCrontabDocument.parse(afterEntry).block)
        #expect(block.path == nil)
        #expect(block.items.last == .unrecognized("PATH=/late"))

        let afterStray = [Self.begin, "stray", "PATH=/late", Self.end].joined(separator: "\n") + "\n"
        let strayBlock = try #require(ZenCrontabDocument.parse(afterStray).block)
        #expect(strayBlock.path == nil)
        #expect(strayBlock.items == [.unrecognized("stray"), .unrecognized("PATH=/late")])
    }

    @Test
    func aLowercaseOrSpacedPathAssignmentIsNotTheHeader() throws {
        for line in ["path=/p", "PATH =/p", " PATH=/p", "export PATH=/p"] {
            let text = [Self.begin, line, entryMarker, entryCron, Self.end].joined(separator: "\n") + "\n"
            let block = try #require(ZenCrontabDocument.parse(text).block)
            #expect(block.path == nil)
            #expect(block.items.first == .unrecognized(line))
        }
    }

    @Test
    func removingTheLastItemWithoutMailToDropsTheBlockAndRestoresTheOriginalTextByteForByte() throws {
        let original = "# jobs\nSHELL=/bin/zsh\n  0 3 * * *\t/usr/bin/backup --full   \n\n0 1 * * * /bin/true\n"
        let defaultBlock = [Self.begin, Self.pathLine, entryMarker, entryCron, Self.end]
        let customBlock = [Self.begin, "PATH=/opt/bin:/usr/bin", entryMarker, entryCron, Self.end]

        for block in [defaultBlock, customBlock] {
            let text = original + "\n" + block.joined(separator: "\n") + "\n"
            var document = try ZenCrontabDocument.parse(text)
            #expect(document.render() == text)

            try document.removeItem(number: 1)
            #expect(document.block == nil)
            #expect(document.render() == original)
            #expect(Array(document.render().utf8) == Array(original.utf8))
        }
    }

    @Test
    func removingTheLastItemKeepsABlockThatStillHasMailTo() throws {
        let text = [Self.begin, "PATH=/opt/bin:/usr/bin", "MAILTO=a@b.c", entryMarker, entryCron, Self.end]
            .joined(separator: "\n") + "\n"
        var document = try ZenCrontabDocument.parse(text)
        try document.removeItem(number: 1)
        #expect(document.block?.path == "/opt/bin:/usr/bin")
        #expect(document.block?.mailTo == "a@b.c")
        #expect(document.render() == [Self.begin, "PATH=/opt/bin:/usr/bin", "MAILTO=a@b.c", Self.end]
            .joined(separator: "\n") + "\n")
    }

    @Test
    func effectivePathIsTheBlocksPathOrTheDefault() {
        #expect(ZenCrontabDocument().effectivePath == Self.defaultPath)
        #expect(ZenCrontabDocument(foreignLines: ["a"], block: .init()).effectivePath == Self.defaultPath)
        #expect(ZenCrontabDocument.Block().effectivePath == Self.defaultPath)
        #expect(ZenCrontabDocument.Block(path: "/opt/bin:/usr/bin").effectivePath == "/opt/bin:/usr/bin")
        #expect(
            ZenCrontabDocument(block: .init(path: "/opt/bin:/usr/bin", mailTo: "")).effectivePath
                == "/opt/bin:/usr/bin"
        )
    }

    @Test
    func effectivePathRemovesOneOuterPairOfDoubleQuotes() {
        #expect(ZenCrontabDocument.Block(path: "\"/opt/bin:/usr/bin\"").effectivePath == "/opt/bin:/usr/bin")
        #expect(ZenCrontabDocument(block: .init(path: "\"/opt/bin\"")).effectivePath == "/opt/bin")
        #expect(ZenCrontabDocument.Block(path: "\"\"\"/x\"\"\"").effectivePath == "\"\"/x\"\"")
        // Unbalanced or inner quotes are left alone.
        #expect(ZenCrontabDocument.Block(path: "\"/opt/bin").effectivePath == "\"/opt/bin")
        #expect(ZenCrontabDocument.Block(path: "/opt/bin\"").effectivePath == "/opt/bin\"")
        #expect(ZenCrontabDocument.Block(path: "\"").effectivePath == "\"")
        #expect(ZenCrontabDocument.Block(path: "\"\"").effectivePath == "")
        #expect(ZenCrontabDocument.Block(path: "").effectivePath == "")
    }

    // MARK: - idempotence

    @Test(arguments: [
        "",
        "\n",
        "0 1 * * * /bin/true\n",
        "0 1 * * * /bin/true\n\n\n",
        "# only a comment",
        "a\n# >>> ZenCODE cron >>>\n# <<< ZenCODE cron <<<\n",
        "a\n\n# >>> ZenCODE cron >>>\n# <<< ZenCODE cron <<<\n\n",
        "# >>> ZenCODE cron >>>\nMAILTO=\"\"\n# <<< ZenCODE cron <<<\n",
        "a\n# >>> ZenCODE cron >>>\nMAILTO=\"\"\n# <<< ZenCODE cron <<<\n",
        "a\n\n# >>> ZenCODE cron >>>\nMAILTO=\"\"\n# <<< ZenCODE cron <<<\n",
        "a\n\n\n# >>> ZenCODE cron >>>\nMAILTO=\"\"\n# <<< ZenCODE cron <<<\n",
        "# >>> ZenCODE cron >>>\nMAILTO=\"\"\n# <<< ZenCODE cron <<<\nb\n",
        "# >>> ZenCODE cron >>>\nMAILTO=\"\"\n# <<< ZenCODE cron <<<\nb\n\n",
        "a\n\n# >>> ZenCODE cron >>>\nMAILTO=\"\"\n# <<< ZenCODE cron <<<\n\nb\n\n",
        "\n# >>> ZenCODE cron >>>\nMAILTO=\"\"\n# <<< ZenCODE cron <<<\n",
        "a\r\n# >>> ZenCODE cron >>>\nMAILTO=\"\"\n# <<< ZenCODE cron <<<\n",
        "# >>> ZenCODE cron >>>\nPATH=/usr/local/bin:/usr/bin:/bin\nMAILTO=\"\"\n# <<< ZenCODE cron <<<\n",
        "# >>> ZenCODE cron >>>\nMAILTO=\"\"\nPATH=/usr/local/bin:/usr/bin:/bin\n# <<< ZenCODE cron <<<\n",
        "a\n# >>> ZenCODE cron >>>\nPATH=/opt/bin:/usr/bin\nMAILTO=me@example.com\n# <<< ZenCODE cron <<<\nb\n",
        "a\n# >>> ZenCODE cron >>>\nMAILTO=me@example.com\nPATH=\"/opt/bin:/usr/bin\"\n# <<< ZenCODE cron <<<\n",
        "# >>> ZenCODE cron >>>\nPATH=\nMAILTO=\"\"\n# <<< ZenCODE cron <<<\n",
        "# >>> ZenCODE cron >>>\nPATH=/a\nPATH=/b\nMAILTO=\"\"\n# <<< ZenCODE cron <<<\n",
        "# >>> ZenCODE cron >>>\nPATH=/usr/local/bin:/usr/bin:/bin\nPATH=/b\n# <<< ZenCODE cron <<<\n",
        "# >>> ZenCODE cron >>>\nMAILTO=a\nMAILTO=b\nPATH=/p\n# <<< ZenCODE cron <<<\n",
        "# >>> ZenCODE cron >>>\nPATH=/only/custom\n# <<< ZenCODE cron <<<\n",
        "# >>> ZenCODE cron >>>\nPATH=/p\nstray\nPATH=/q\nMAILTO=late\n# <<< ZenCODE cron <<<\n"
    ])
    func parseRenderParseIsStable(_ text: String) throws {
        try expectRoundTrip(text)
    }

    @Test
    func parseRenderParseIsStableForRealisticBlocks() throws {
        let variants: [[String]] = [
            sampleBlockLines,
            ["x", "y"] + sampleBlockLines,
            ["x", ""] + sampleBlockLines + ["", "y", ""],
            sampleBlockLines + ["after"],
            [Self.begin, "# zencode-cron id=broken", "0 9 * * * cmd", "junk line", Self.end, "tail"],
            customPathBlockLines,
            ["x", ""] + customPathBlockLines + ["", "y"],
            [Self.begin, "MAILTO=ops@example.com", "PATH=/opt/bin:/usr/bin"] + sampleBlockLines.dropFirst(3)
        ]
        for lines in variants {
            try expectRoundTrip(lines.joined(separator: "\n") + "\n")
        }
    }

    // MARK: - errors
}
