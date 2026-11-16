//
//  ZenCrontabDocumentTests+RenderAndMutation.swift
//  ZenCODE
//
//  Block error, render and mutation tests of the crontab document, split from
//  ZenCrontabDocumentTests.
//

import Foundation
import Testing
@testable import ZenCODECore

extension ZenCrontabDocumentTests {
    // MARK: - Block errors

    @Test(arguments: [
        // A block without its end marker.
        "0 1 * * * /bin/true\n# >>> ZenCODE cron >>>\nMAILTO=\"\"\n",
        // Two begin markers without an end marker between them.
        "# >>> ZenCODE cron >>>\nMAILTO=\"\"\n# >>> ZenCODE cron >>>\n# <<< ZenCODE cron <<<\n",
        // Two complete blocks.
        "# >>> ZenCODE cron >>>\n# <<< ZenCODE cron <<<\n# >>> ZenCODE cron >>>\n# <<< ZenCODE cron <<<\n"
    ])
    func unbalancedOrRepeatedBlockMarkersAreMalformed(_ text: String) {
        do {
            _ = try ZenCrontabDocument.parse(text)
            Issue.record("Expected malformedBlock")
        } catch ZenCrontabError.malformedBlock {
            // expected
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
    }

    // MARK: - render

    @Test
    func blockInTheMiddleIsMovedToTheTailAndForeignLinesStayByteIdentical() throws {
        let before = ["# head", "SHELL=/bin/zsh", "  0 3 * * *\t/usr/bin/backup --full   ", ""]
        let after = ["", "@reboot echo started", "# tail comment", "5 5 * * * /bin/other 'x'"]
        let text = (before + sampleBlockLines + after).joined(separator: "\n") + "\n"

        let document = try ZenCrontabDocument.parse(text)
        #expect(document.foreignLines == before + after)

        let rendered = document.render()
        let expected = (before + after + [""] + sampleBlockLines).joined(separator: "\n") + "\n"
        #expect(rendered == expected)
        #expect(rendered.hasSuffix("\(Self.end)\n"))

        // Foreign lines survive in order, with the block as the last lines.
        let renderedLines = rendered.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        #expect(Array(renderedLines.prefix(before.count + after.count)) == before + after)
    }

    @Test
    func blockGluedToTheLastForeignLineGetsOneBlankSeparator() throws {
        let text = (["0 1 * * * /bin/true"] + sampleBlockLines).joined(separator: "\n") + "\n"
        let document = try ZenCrontabDocument.parse(text)
        #expect(document.foreignLines == ["0 1 * * * /bin/true"])
        #expect(document.render() == (["0 1 * * * /bin/true", ""] + sampleBlockLines).joined(separator: "\n") + "\n")
    }

    @Test
    func noSeparatorIsAddedWhenForeignLinesAreEmptyOrAlreadyEndBlank() {
        let mail = ZenCrontabDocument.Block(mailTo: "", items: [])

        let onlyBlock = ZenCrontabDocument(foreignLines: [], block: mail)
        #expect(onlyBlock.render() == "\(Self.begin)\n\(Self.pathLine)\nMAILTO=\"\"\n\(Self.end)\n")

        let blankEnd = ZenCrontabDocument(foreignLines: ["a", ""], block: mail)
        #expect(blankEnd.render() == "a\n\n\(Self.begin)\n\(Self.pathLine)\nMAILTO=\"\"\n\(Self.end)\n")

        let blankOnly = ZenCrontabDocument(foreignLines: [""], block: mail)
        #expect(blankOnly.render() == "\n\(Self.begin)\n\(Self.pathLine)\nMAILTO=\"\"\n\(Self.end)\n")
    }

    @Test
    func emptyBlockIsOmittedFromTheOutput() throws {
        let explicitlyEmpty = ZenCrontabDocument(foreignLines: ["a", "b"], block: ZenCrontabDocument.Block())
        #expect(explicitlyEmpty.render() == "a\nb\n")

        let onlyEmptyBlock = ZenCrontabDocument(foreignLines: [], block: ZenCrontabDocument.Block())
        #expect(onlyEmptyBlock.render() == "")

        // An existing empty block disappears on the next write.
        let parsed = try ZenCrontabDocument.parse("a\n\n\(Self.begin)\n\(Self.end)\nb\n")
        #expect(parsed.block == nil)
        #expect(parsed.render() == "a\n\nb\n")
    }

    @Test
    func renderedEntriesReuseTheirOriginalLinesWithoutReencoding() throws {
        let marker = "# zencode-cron id=\(firstID.uuidString) created=2026-09-10T12:00:00Z"
        let cron = "0   9 * *  1-5 '/usr/local/bin/zen'   --working-directory '/w' --jsonl -p 'odd   spacing'"
        let text = [Self.begin, Self.pathLine, marker, cron, Self.end].joined(separator: "\n") + "\n"
        #expect(try ZenCrontabDocument.parse(text).render() == text)
    }

    // MARK: - mutation

    @Test
    func appendEntryCreatesTheBlockAndWritesMarkerAndEscapedCronLine() throws {
        var document = ZenCrontabDocument()
        let job = makeJob(prompt: "it's 50% done")
        try document.appendEntry(schedule: schedule("0 9 * * 1"), job: job, id: firstID, createdAt: createdAt)

        let expectedCron = "0 9 * * 1 "
            + "zen --working-directory '/Users/me/project' -p 'it'\\''s 50\\% done'"
        #expect(
            document.render() == [
                Self.begin,
                Self.pathLine,
                "# zencode-cron id=11111111-1111-1111-1111-111111111111 created=2026-09-10T12:00:00Z",
                expectedCron,
                Self.end
            ].joined(separator: "\n") + "\n"
        )

        let entry = try #require(entries(of: document).first)
        #expect(entry.id == firstID)
        #expect(entry.createdAt == createdAt)
        #expect(entry.schedule == "0 9 * * 1")
        #expect(entry.cronLine == expectedCron)
        #expect(entry.job == job)
    }

    @Test
    func appendEntryWritesTheJSONLFlagOnlyForAJSONLJob() throws {
        var document = ZenCrontabDocument()
        try document.appendEntry(
            schedule: schedule("@daily"),
            job: makeJob(outputFormat: .jsonl, prompt: "report"),
            id: firstID,
            createdAt: createdAt
        )
        try document.appendEntry(
            schedule: schedule("@hourly"),
            job: makeJob(outputFormat: .text, prompt: "report"),
            id: secondID,
            createdAt: createdAt
        )

        let found = entries(of: try ZenCrontabDocument.parse(document.render()))
        #expect(found.count == 2)
        #expect(found[0].cronLine == "@daily zen --working-directory '/Users/me/project' --jsonl -p 'report'")
        #expect(found[0].job?.outputFormat == .jsonl)
        #expect(found[1].cronLine == "@hourly zen --working-directory '/Users/me/project' -p 'report'")
        #expect(found[1].job?.outputFormat == .text)
    }

    @Test
    func appendEntryWritesThePromptFileBeforeTheOptionalPromptAndReadsItBack() throws {
        var document = ZenCrontabDocument()
        let fileOnly = makeJob(promptFile: "/Users/me/My Prompts/daily 100%.md", prompt: nil)
        let fileAndPrompt = makeJob(
            outputFormat: .jsonl,
            promptFile: "/Users/me/prompts/it's.md",
            prompt: "summarize it"
        )
        document.appendEntry(schedule: try schedule("@daily"), job: fileOnly, id: firstID, createdAt: createdAt)
        document.appendEntry(schedule: try schedule("@hourly"), job: fileAndPrompt, id: secondID, createdAt: createdAt)

        let found = entries(of: try ZenCrontabDocument.parse(document.render()))
        #expect(found.count == 2)
        #expect(
            found[0].cronLine
                == "@daily zen --working-directory '/Users/me/project' -f '/Users/me/My Prompts/daily 100\\%.md'"
        )
        #expect(found[0].job == fileOnly)
        #expect(found[0].job?.prompt == nil)
        #expect(
            found[1].cronLine
                == "@hourly zen --working-directory '/Users/me/project' --jsonl "
                + "-f '/Users/me/prompts/it'\\''s.md' -p 'summarize it'"
        )
        #expect(found[1].job == fileAndPrompt)
    }

    @Test
    func appendEntryUsesAliasSchedulesAndKeepsExistingItemsAndOrder() throws {
        var document = try ZenCrontabDocument.parse(
            (["0 1 * * * /bin/true"] + sampleBlockLines).joined(separator: "\n") + "\n"
        )
        try document.appendEntry(schedule: schedule("@DAILY"), job: makeJob(), id: UUID(), createdAt: createdAt)

        let block = try #require(document.block)
        #expect(block.mailTo == "ops@example.com")
        #expect(block.items.count == 3)
        let found = entries(of: document)
        #expect(found.map(\.id).prefix(2) == [firstID, secondID])
        #expect(found[2].schedule == "@daily")
        #expect(found[2].cronLine.hasPrefix("@daily zen --working-directory"))
        #expect(document.foreignLines == ["0 1 * * * /bin/true"])
    }

    @Test
    func appendedDocumentsSurviveARoundTripEvenWithSubsecondDates() throws {
        var document = ZenCrontabDocument(foreignLines: ["0 1 * * * /bin/true"])
        let fractional = Date(timeIntervalSince1970: 1_789_041_600.789)
        try document.appendEntry(
            schedule: schedule("*/10 * * * *"),
            job: makeJob(prompt: "100% 'quoted'"),
            id: firstID,
            createdAt: fractional
        )
        document.setMailTo("")
        #expect(try ZenCrontabDocument.parse(document.render()) == document)
    }

    @Test
    func appendEntryDefaultsGenerateDistinctIDsAndAMarkerInUTC() throws {
        var document = ZenCrontabDocument()
        try document.appendEntry(schedule: schedule("@daily"), job: makeJob())
        try document.appendEntry(schedule: schedule("@daily"), job: makeJob())
        let found = entries(of: document)
        #expect(found.count == 2)
        #expect(found[0].id != found[1].id)
        #expect(found[0].markerLine.hasPrefix("# zencode-cron id=\(found[0].id.uuidString) created="))
        #expect(found[0].markerLine.hasSuffix("Z"))
    }

    @Test
    func removeItemIsOneBasedAndKeepsTheOthers() throws {
        var document = try ZenCrontabDocument.parse(sampleBlockLines.joined(separator: "\n") + "\n")
        try document.removeItem(number: 1)

        let remaining = entries(of: document)
        #expect(remaining.map(\.id) == [secondID])
        #expect(document.block?.mailTo == "ops@example.com")

        try document.removeItem(number: 1)
        #expect(entries(of: document).isEmpty)
        // MAILTO alone still keeps the block alive.
        #expect(document.render() == "\(Self.begin)\n\(Self.pathLine)\nMAILTO=ops@example.com\n\(Self.end)\n")
    }

    @Test
    func removeItemCanTargetAnUnrecognizedLine() throws {
        var document = try ZenCrontabDocument.parse("\(Self.begin)\nhand written\n\(Self.end)\n")
        try document.removeItem(number: 1)
        #expect(document.block == nil)
        #expect(document.render() == "")
    }

    @Test(arguments: [-1, 0, 3, 99])
    func removeItemOutOfRangeThrowsNoSuchEntry(_ number: Int) throws {
        var document = try ZenCrontabDocument.parse(sampleBlockLines.joined(separator: "\n") + "\n")
        let before = document
        #expect(throws: ZenCrontabError.noSuchEntry(number)) {
            try document.removeItem(number: number)
        }
        #expect(document == before)
    }

    @Test
    func removeItemWithoutABlockThrowsNoSuchEntry() {
        var document = ZenCrontabDocument(foreignLines: ["0 1 * * * /bin/true"])
        #expect(throws: ZenCrontabError.noSuchEntry(1)) {
            try document.removeItem(number: 1)
        }
        #expect(document.block == nil)
    }
}
