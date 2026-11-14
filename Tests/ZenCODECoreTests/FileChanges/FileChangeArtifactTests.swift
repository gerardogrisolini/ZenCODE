import Foundation
@testable import ZenCODECore
import Testing
import ToolCore

@Suite
struct FileChangeArtifactTests {
    @Test
    func operationEvidenceNormalizesPathsAndDeduplicatesInInputOrder() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let changes = [
            OperationFileChange(path: "Sources/App.swift", oldText: "old\n", newText: "new\n"),
            OperationFileChange(path: directory.appendingPathComponent("Sources/App.swift").path,
                                oldText: "ignored", newText: "ignored")
        ]
        let artifacts = FileChangeArtifactMapper.artifacts(
            from: changes,
            workingDirectory: directory
        )

        #expect(artifacts.count == 1)
        #expect(artifacts[0].absolutePath == directory.appendingPathComponent("Sources/App.swift").path)
        #expect(artifacts[0].displayPath == "Sources/App.swift")
        #expect(artifacts[0].status == .modified)
        #expect(artifacts[0].oldText == "old\n")
        #expect(artifacts[0].newText == "new\n")
    }

    @Test
    func summaryMapperUsesPostContentForAddedFilesAndExplicitFallbacks() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let added = TurnFileChangeSummary.Entry(
            path: "new.txt",
            additions: 1,
            deletions: 0,
            status: .added,
            isBinary: false,
            existedBefore: false,
            beforeDataBase64: nil,
            patch: "@@ -0,0 +1 @@\n+hello"
        )
        let uncertain = TurnFileChangeSummary.Entry(
            path: "unknown.txt",
            additions: 0,
            deletions: 0,
            status: .modified,
            isBinary: false,
            existedBefore: true,
            beforeDataBase64: nil,
            patch: nil
        )
        let artifacts = FileChangeArtifactMapper.artifacts(
            from: TurnFileChangeSummary(entries: [added, uncertain]),
            workingDirectory: directory
        )

        #expect(artifacts[0].patch != nil)
        #expect(artifacts[0].status == .added)
        #expect(artifacts[1].explanation != nil)
    }

    @Test
    func mapperFallsBackForBinaryAndOversizedEvidence() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let oversized = String(repeating: "x", count: OperationFileChangeRecorder.maximumTextBytes + 1)
        let artifacts = FileChangeArtifactMapper.artifacts(
            from: [
                OperationFileChange(path: "large.txt", oldText: oversized, newText: oversized),
                OperationFileChange(path: "image.bin", oldText: "\0binary", newText: "\0changed")
            ],
            workingDirectory: directory
        )

        #expect(artifacts.count == 2)
        #expect(artifacts[0].oldText == nil)
        #expect(artifacts[0].newText == nil)
        #expect(artifacts[0].explanation?.contains("byte limit") == true)
        #expect(artifacts[1].isBinary)
        #expect(artifacts[1].explanation?.contains("binary") == true)
    }

    @Test
    func historyKeepsOnlyEffectiveTurnsAndRejectsStaleSessions() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let history = SessionFileArtifactHistory(sessionID: "session-1")
        let summary = TurnFileChangeSummary(entries: [
            TurnFileChangeSummary.Entry(
                path: "file.txt",
                additions: 1,
                deletions: 0,
                status: .added,
                isBinary: false,
                existedBefore: false,
                beforeDataBase64: nil,
                patch: nil
            )
        ])

        #expect(await history.append(summary: summary, sessionID: "old", workingDirectory: directory) == nil)
        #expect(await history.append(summary: TurnFileChangeSummary(entries: []), sessionID: "session-1", workingDirectory: directory) == nil)
        let first = await history.append(summary: summary, sessionID: "session-1", workingDirectory: directory)
        let second = await history.append(summary: summary, sessionID: "session-1", workingDirectory: directory)
        #expect(first?.number == 1)
        #expect(second?.number == 2)
        #expect((await history.snapshot()).count == 2)

        await history.reset(for: "session-2")
        #expect((await history.snapshot()).isEmpty)
        #expect(await history.append(summary: summary, sessionID: "session-1", workingDirectory: directory) == nil)
    }

    @Test
    func liveHistoryDeduplicatesEventsNotPathsAndReconcilesOnlyNetFinalTurns() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let history = SessionFileArtifactHistory(sessionID: "session")
        let id = try #require(await history.beginTurn(sessionID: "session"))
        let first = OperationFileChange(path: "file.txt", oldText: nil, newText: "one\n")
        let second = OperationFileChange(path: "file.txt", oldText: "one\n", newText: "two\n")
        let live = await history.recordLive([first], agentID: nil, callID: "call", turnID: id, workingDirectory: directory)
        #expect(live?.number == 1)
        #expect(await history.recordLive([first], agentID: nil, callID: "call", turnID: id, workingDirectory: directory) == nil)
        let delegated = await history.recordLive([second], agentID: "worker", callID: "call", turnID: id, workingDirectory: directory)
        #expect(delegated?.number == 1)
        #expect(delegated?.artifacts.first?.newText == "two\n")
        let third = OperationFileChange(path: "file.txt", oldText: "two\n", newText: "three\n")
        #expect(await history.recordLive([third], agentID: "worker", callID: "next", turnID: id, workingDirectory: directory) != nil)
        #expect(await history.snapshot().isEmpty)
        let latest = await history.sealTurn(id)
        #expect(latest.count == 1)
        #expect(latest.first?.newText == "three\n")
        #expect(await history.recordLive([first], agentID: nil, callID: "late", turnID: id, workingDirectory: directory) == nil)
        let summary = TurnFileChangeSummary(entries: [addedEntry("file.txt")])
        #expect(await history.finishTurn(
            id, summary: summary, matchingLivePaths: [directory.appendingPathComponent("file.txt").path],
            workingDirectory: directory
        ) == nil)
        let snapshot = await history.snapshot()
        #expect(snapshot.count == 1)
        #expect(snapshot.first?.number == 1)
        #expect(snapshot.first?.artifacts == FileChangeArtifactMapper.artifacts(from: summary, workingDirectory: directory))
        #expect(await history.finishTurn(id, summary: summary, matchingLivePaths: [], workingDirectory: directory) == nil)

        // Provider call identifiers may be reused in a different prompt.
        let nextID = try #require(await history.beginTurn(sessionID: "session"))
        #expect(await history.recordLive([first], agentID: nil, callID: "call", turnID: nextID, workingDirectory: directory)?.number == 2)
    }

    @Test
    func revertedLiveTurnsLeaveStableNumberGapsAndResetFencesOldTokens() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let history = SessionFileArtifactHistory(sessionID: "session")
        let id = try #require(await history.beginTurn(sessionID: "session"))
        let change = OperationFileChange(path: "file.txt", oldText: nil, newText: "one")
        #expect(await history.recordLive([change], agentID: nil, callID: "call", turnID: id, workingDirectory: directory)?.number == 1)
        _ = await history.sealTurn(id)
        #expect(await history.finishTurn(id, summary: nil, matchingLivePaths: [], workingDirectory: directory) == nil)
        #expect(await history.snapshot().isEmpty)
        let summary = TurnFileChangeSummary(entries: [addedEntry("file.txt")])
        #expect(await history.append(summary: summary, sessionID: "session", workingDirectory: directory)?.number == 2)
        let staleID = try #require(await history.beginTurn(sessionID: "session"))
        await history.reset(for: "session")
        #expect(await history.recordLive([change], agentID: nil, callID: "call", turnID: staleID, workingDirectory: directory) == nil)
        #expect(await history.finishTurn(staleID, summary: summary, matchingLivePaths: [], workingDirectory: directory) == nil)
        #expect(await history.append(summary: summary, sessionID: "session", workingDirectory: directory)?.number == 1)
    }

    private func addedEntry(_ path: String) -> TurnFileChangeSummary.Entry {
        .init(path: path, additions: 1, deletions: 0, status: .added, isBinary: false,
              existedBefore: false, beforeDataBase64: nil, patch: "@@ -0,0 +1 @@\n+three")
    }

    private func temporaryDirectory() throws -> URL {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("file-change-artifact-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}

extension FileChangeArtifactTests {
    @Test
    func compactOperationEvidenceKeepsCountsAndPatchWithoutReadingWorktree() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try "unrelated later state\n".write(to: directory.appendingPathComponent("CHANGELOG.md"), atomically: true, encoding: .utf8)
        let patch = "@@ -100,3 +100,3 @@\n context\n-old entry\n+new entry\n context\n"
        let artifacts = FileChangeArtifactMapper.artifacts(from: [
            .init(path: "CHANGELOG.md", oldText: nil, newText: nil,
                  compactDiff: .init(patch: patch, additions: 1, deletions: 1))
        ], workingDirectory: directory)
        let artifact = try #require(artifacts.first)
        #expect(artifact.status == .modified)
        #expect(artifact.hasLineCounts)
        #expect(artifact.additions == 1 && artifact.deletions == 1)
        #expect(artifact.oldText == nil && artifact.newText == nil)
        #expect(artifact.patch == patch)
        #expect(artifact.explanation == nil)
        let rendered = TerminalChat.renderFileArtifacts([.init(number: 1, artifacts: artifacts)], includeHistoryHeadings: true)
        #expect(rendered.contains("**modified `CHANGELOG.md`**  +1 -1"))
        #expect(rendered.contains("101 │ -old entry"))
        #expect(rendered.contains("101 │ +new entry"))
        #expect(!rendered.contains("unrelated later state"))
    }

    @Test
    func mapperAppliesOperationBudgetToCompactPatchesAndDropsCountsOnFallback() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let patch = String(repeating: "+", count: OperationFileChangeRecorder.maximumTextBytes)
        var changes = (0..<5).map {
            OperationFileChange(path: "file\($0)", oldText: nil, newText: nil,
                compactDiff: .init(patch: patch, additions: 10, deletions: 10))
        }
        changes.append(.init(path: "oversized", oldText: nil, newText: nil,
            compactDiff: .init(patch: patch + "+", additions: 1, deletions: 1)))
        let artifacts = FileChangeArtifactMapper.artifacts(from: changes, workingDirectory: directory)
        #expect(artifacts.prefix(4).allSatisfy { $0.patch == patch && $0.hasLineCounts })
        #expect(artifacts.suffix(2).allSatisfy { $0.patch == nil && !$0.hasLineCounts && $0.explanation != nil })
    }
}

// MARK: - Added-file truncation

extension FileChangeArtifactTests {
    private static let limit = OperationFileChangeRecorder.maximumTextBytes

    /// Git new-file patch, as produced by the workspace checkpoint.
    private func newFilePatch(
        path: String = "Scripts/Gen.swift", lines: [String], hunkCount: Int? = nil,
        marker: Bool = false
    ) -> String {
        var patch = "diff --git a/\(path) b/\(path)\nnew file mode 100644\nindex 0000000..422c2b7\n"
        patch += "--- /dev/null\n+++ b/\(path)\n@@ -0,0 +1,\(hunkCount ?? lines.count) @@\n"
        patch += lines.map { "+\($0)\n" }.joined()
        if marker { patch += "\\ No newline at end of file\n" }
        return patch
    }

    /// Fifty-ish bytes per line, with multibyte characters to catch byte/character mix-ups.
    private func sourceLines(_ count: Int, prefix: String = "row") -> [String] {
        (1...count).map { "\(prefix) \($0): é🙂 " + String(repeating: "abcdefghij", count: 3) }
    }

    private func addedEntry(
        path: String = "Scripts/Gen.swift", patch: String?, additions: Int,
        status: TurnFileChangeSummary.Entry.Status = .added, isBinary: Bool = false
    ) -> TurnFileChangeSummary.Entry {
        .init(path: path, additions: additions, deletions: 0, status: status, isBinary: isBinary,
              existedBefore: status != .added, beforeDataBase64: nil, patch: patch)
    }

    private func mappedArtifacts(
        _ entries: [TurnFileChangeSummary.Entry], in directory: URL
    ) -> [FileChangeArtifact] {
        FileChangeArtifactMapper.artifacts(
            from: TurnFileChangeSummary(entries: entries), workingDirectory: directory
        )
    }

    @Test
    func oversizedAddedFilePatchIsTruncatedAtWholeLinesWithRewrittenHunkHeader() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let lines = sourceLines(3142)
        let patch = newFilePatch(lines: lines)
        #expect(patch.utf8.count > Self.limit)
        let entry = addedEntry(patch: patch, additions: 3142)
        let summary = TurnFileChangeSummary(entries: [entry])

        let artifact = try #require(
            FileChangeArtifactMapper.artifacts(from: summary, workingDirectory: directory).first
        )
        let truncated = try #require(artifact.patch)
        #expect(truncated.utf8.count <= Self.limit)
        let rows = truncated.components(separatedBy: "\n")
        #expect(rows.last == "")
        let body = Array(rows[6..<(rows.count - 1)])
        let kept = body.count
        #expect(kept > 0 && kept < 3142)
        // Headers are verbatim, the hunk header counts the kept lines, and no line is cut.
        #expect(Array(rows[0..<5]) == Array(patch.components(separatedBy: "\n")[0..<5]))
        #expect(rows[5] == "@@ -0,0 +1,\(kept) @@")
        #expect(body == lines.prefix(kept).map { "+" + $0 })
        #expect(body.first == "+" + lines[0])
        #expect(!truncated.contains(lines[3141]))
        #expect(!truncated.contains(lines[kept]))
        // The next whole line would not have fit.
        #expect(truncated.utf8.count + lines[kept].utf8.count + 2 > Self.limit)

        #expect(artifact.status == .added)
        #expect(artifact.explanation == "Diff truncated: showing the first \(kept) of 3142 diff lines; file or operation evidence exceeds the byte limit.")
        #expect(artifact.explanation == FileChangeArtifactMapper.truncatedPatchExplanation(shown: kept, total: 3142))
        #expect(!artifact.isBinary)
        #expect(artifact.additions == 3142 && artifact.deletions == 0)
        #expect(artifact.hasLineCounts)
        #expect(artifact.oldText == nil && artifact.newText == nil)
        // The summary keeps the complete patch for undo and review.
        #expect(summary.entries[0].patch == patch)
        #expect(entry.patch == patch)
    }

    @Test
    func patchesWithAnUnusableShapeKeepTheByteLimitFallbackForEveryStatus() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let lines = sourceLines(1500)
        let statuses: [(status: TurnFileChangeSummary.Entry.Status, marker: String, hunk: String, valid: String)] = [
            (.added, "+", "@@ -0,0 +1,1500 @@", newFilePatch(lines: lines)),
            (.deleted, "-", "@@ -1,1500 +0,0 @@", deletedFilePatch(lines: lines)),
            (.modified, " ", "@@ -1,1500 +1,1500 @@",
             modifiedFilePatch(hunks: [("@@ -1,1500 +1,1500 @@", lines.map { " " + $0 })]))
        ]
        for (status, marker, hunk, valid) in statuses {
            #expect(valid.utf8.count > Self.limit)
            let line = "\(marker)\(lines[700])\n"
            let noNewline = "\\ No newline at end of file\n"
            let hugeLine = String(repeating: "y", count: Self.limit)
            let cases: [(String, String)] = [
                ("no hunk header", String(repeating: marker, count: Self.limit + 1)),
                ("no hunk header after file headers",
                 valid.replacingOccurrences(of: hunk + "\n", with: "")),
                ("blank line", valid.replacingOccurrences(of: line, with: "\n")),
                ("foreign line", valid.replacingOccurrences(of: line, with: "index 1111111..2222222\n")),
                ("second file", valid.replacingOccurrences(of: line, with: "diff --git a/o b/o\n" + line)),
                ("unparsable second hunk header", valid.replacingOccurrences(of: line, with: "@@ nonsense @@\n" + line)),
                ("marker opens a hunk", valid.replacingOccurrences(of: line, with: "@@ -1,1 +1,1 @@\n" + noNewline + line)),
                ("consecutive markers", valid.replacingOccurrences(of: line, with: line + noNewline + noNewline)),
                ("non-numeric count", valid.replacingOccurrences(of: hunk, with: "@@ -0,0 +1,x @@")),
                ("missing closing marker", valid.replacingOccurrences(of: hunk, with: String(hunk.dropLast(3)))),
                ("text glued to the closing marker", valid.replacingOccurrences(of: hunk, with: hunk + "x")),
                ("overflowing count", valid.replacingOccurrences(of: hunk, with: "@@ -1,99999999999 +1,1 @@")),
                ("empty count", valid.replacingOccurrences(of: hunk, with: "@@ -1, +1,1 @@")),
                ("first body line alone exceeds the limit",
                 valid.replacingOccurrences(of: hunk + "\n", with: hunk + "\n" + marker + hugeLine + "\n")),
                ("file headers alone exceed the limit",
                 valid.replacingOccurrences(of: "--- ", with: "x" + hugeLine + "\n--- "))
            ]
            for (name, patch) in cases {
                let comment = Comment(rawValue: "\(status) \(name)")
                #expect(patch != valid, comment)
                #expect(patch.utf8.count > Self.limit, comment)
                let entry = changeEntry(status: status, patch: patch, additions: 1500, deletions: 0)
                let artifact = try #require(mappedArtifacts([entry], in: directory).first, comment)
                #expect(artifact.patch == nil, comment)
                #expect(artifact.explanation == FileChangeArtifactMapper.byteLimitExplanation, comment)
            }
            // Binary evidence keeps its own explanation, even when the patch is large.
            let binary = mappedArtifacts([changeEntry(status: status, patch: valid, additions: 0, deletions: 0, isBinary: true)],
                                         in: directory)
            #expect(binary[0].explanation == FileChangeArtifactMapper.binaryExplanation)
            #expect(binary[0].patch == nil && binary[0].isBinary)
            let nul = mappedArtifacts([changeEntry(status: status, patch: valid + "\0", additions: 1500, deletions: 0)],
                                      in: directory)
            #expect(nul[0].explanation == FileChangeArtifactMapper.binaryExplanation)
            #expect(nul[0].patch == nil && nul[0].isBinary)
            // The unmodified shape is accepted for every status.
            let accepted = mappedArtifacts([changeEntry(status: status, patch: valid, additions: 1500, deletions: 0)],
                                           in: directory)
            #expect(accepted[0].patch != nil)
            #expect(accepted[0].explanation?.hasPrefix("Diff truncated: showing the first ") == true)
        }
    }
}

// MARK: - Deleted and modified truncation

extension FileChangeArtifactTests {
    private static let truncationNotice = "Diff truncated: showing the first "

    /// Git deleted-file patch, as produced by the workspace checkpoint.
    private func deletedFilePatch(
        path: String = "Scripts/Gen.swift", lines: [String], marker: Bool = false
    ) -> String {
        var patch = "diff --git a/\(path) b/\(path)\ndeleted file mode 100644\nindex 3b18e51..0000000\n"
        patch += "--- a/\(path)\n+++ /dev/null\n@@ -1\(lines.count == 1 ? "" : ",\(lines.count)") +0,0 @@\n"
        patch += lines.map { "-\($0)\n" }.joined()
        if marker { patch += "\\ No newline at end of file\n" }
        return patch
    }

    /// Git modification patch; every body line already carries its ` `, `+` or `-` marker.
    private func modifiedFilePatch(
        path: String = "Sources/Mod.swift", hunks: [(header: String, body: [String])]
    ) -> String {
        "diff --git a/\(path) b/\(path)\nindex 1111111..2222222 100644\n--- a/\(path)\n+++ b/\(path)\n"
            + hunks.map { $0.header + "\n" + $0.body.map { $0 + "\n" }.joined() }.joined()
    }

    private func changeEntry(
        path: String = "Scripts/Gen.swift", status: TurnFileChangeSummary.Entry.Status, patch: String?,
        additions: Int, deletions: Int, beforeText: String? = nil, isBinary: Bool = false
    ) -> TurnFileChangeSummary.Entry {
        .init(path: path, additions: additions, deletions: deletions, status: status, isBinary: isBinary,
              existedBefore: status != .added,
              beforeDataBase64: beforeText.map { Data($0.utf8).base64EncodedString() }, patch: patch)
    }

    private func patchRows(_ patch: String) -> [String] {
        patch.utf8.split(separator: 0x0A, omittingEmptySubsequences: false)
            .map { String(decoding: $0, as: UTF8.self) }
    }

    /// Old-side, new-side and total counts of unified-diff body rows.
    private func bodyCounts(_ rows: [String]) -> (old: Int, new: Int, lines: Int) {
        rows.reduce(into: (old: 0, new: 0, lines: 0)) { counts, row in
            switch row.utf8.first {
            case 0x20: counts.old += 1; counts.new += 1; counts.lines += 1
            case 0x2D: counts.old += 1; counts.lines += 1
            case 0x2B: counts.new += 1; counts.lines += 1
            default: break
            }
        }
    }

    @Test
    func deletedFileWithAnOversizedSnapshotIsTruncatedFromThePatch() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let text = String(repeating: "abcdefghi\n", count: 12_000)
        #expect(text.utf8.count > Self.limit)
        let entry = changeEntry(
            status: .deleted, patch: deletedFilePatch(lines: sourceLines(3142)), additions: 0, deletions: 3142,
            beforeText: text
        )

        let artifact = try #require(mappedArtifacts([entry], in: directory).first)
        #expect(artifact.oldText == nil && artifact.newText == nil)
        #expect(artifact.patch?.hasPrefix("diff --git a/Scripts/Gen.swift") == true)
        #expect(artifact.explanation?.hasPrefix(Self.truncationNotice) == true)
        #expect(artifact.deletions == 3142 && artifact.hasLineCounts)
    }

    @Test
    func modifiedPatchKeepsWholeHunksThenAPrefixOfTheFirstHunkThatDoesNotFit() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        func small(_ oldStart: Int, _ newStart: Int, _ name: String) -> (header: String, body: [String]) {
            ("@@ -\(oldStart),7 +\(newStart),8 @@ func \(name)()",
             [" ctx 1", " ctx 2", " ctx 3", "-old \(name)", "\\ No newline at end of file",
              "+new \(name) a", "+new \(name) b", " ctx 4", " ctx 5", " ctx 6"])
        }
        let padding = String(repeating: "r", count: 30)
        var bigBody = [" top 1", " top 2", " top 3"]
        for index in 1...1000 { bigBody += ["-removed \(index) é🙂 \(padding)", "+added \(index) é🙂 \(padding)"] }
        bigBody += [" end 1", " end 2", " end 3"]
        let big = (header: "@@ -100,1006 +102,1006 @@ func big()", body: bigBody)
        let patch = modifiedFilePatch(hunks: [small(3, 3, "one"), small(40, 41, "two"), big, small(5000, 5002, "four")])
        #expect(patch.utf8.count > Self.limit)
        let entry = changeEntry(
            path: "Sources/Mod.swift", status: .modified, patch: patch, additions: 1006, deletions: 1003
        )

        let artifact = try #require(mappedArtifacts([entry], in: directory).first)
        let truncated = try #require(artifact.patch)
        #expect(truncated.utf8.count <= Self.limit)
        let rows = patchRows(truncated)
        let headers = rows.indices.filter { rows[$0].hasPrefix("@@") }
        #expect(headers.count == 3)
        // The first two hunks (marker included) are verbatim; the third one is cut.
        let verbatim = rows[0..<headers[2]].joined(separator: "\n") + "\n"
        #expect(patch.hasPrefix(verbatim))
        #expect(verbatim.contains("-old two\n\\ No newline at end of file\n+new two a\n"))
        let body = Array(rows[(headers[2] + 1)..<(rows.count - 1)])
        let kept = body.count
        #expect(kept > 3 && kept < bigBody.count)
        #expect(body == bigBody.prefix(kept).map { $0 })
        // The start lines are unchanged; the counts describe the kept lines; the section stays.
        let counts = bodyCounts(body)
        #expect(rows[headers[2]] == "@@ -100,\(counts.old) +102,\(counts.new) @@ func big()")
        #expect(counts.old > 0 && counts.new > 0 && counts.old != 1006 && counts.new != 1006)
        // Hunks after the cut are dropped, even though they would have fit.
        #expect(!truncated.contains("func four()") && !truncated.contains("-old four"))
        // The next line would not have fit.
        #expect(truncated.utf8.count + bigBody[kept].utf8.count + 1 > Self.limit)

        #expect(artifact.status == .modified)
        #expect(artifact.explanation == FileChangeArtifactMapper.truncatedPatchExplanation(
            shown: 18 + kept, total: 27 + bigBody.count
        ))
        #expect(artifact.oldText == nil && artifact.newText == nil)
        #expect(artifact.additions == 1006 && artifact.deletions == 1003 && artifact.hasLineCounts)
    }

    @Test
    func truncatedHunkWhoseKeptLinesOnlyAddOrOnlyRemoveMovesThatSideToThePrecedingLine() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let padding = String(repeating: "g", count: 30)
        let added = (1...2000).map { "+grow \($0) \(padding)" } + [" tail 1", " tail 2", " tail 3", " tail 4"]
        let removed = (1...2000).map { "-shrink \($0) \(padding)" } + [" tail 1", " tail 2"]
        let cases: [(name: String, header: String, body: [String], expected: (Int, Int) -> String)] = [
            ("additions inside the file", "@@ -50,4 +50,2004 @@ func grow()", added,
             { _, new in "@@ -49,0 +50,\(new) @@ func grow()" }),
            ("additions at the first line", "@@ -1,4 +1,2004 @@", added,
             { _, new in "@@ -0,0 +1,\(new) @@" }),
            ("removals inside the file", "@@ -30,2002 +30,2 @@ func shrink()", removed,
             { old, _ in "@@ -30,\(old) +29,0 @@ func shrink()" }),
            ("removals at the first line", "@@ -1,2002 +1,2 @@", removed,
             { old, _ in "@@ -1,\(old) +0,0 @@" }),
            ("one-line hunks", "@@ -1 +1 @@", ["-old", "+" + String(repeating: "z", count: Self.limit)],
             { old, _ in "@@ -1,\(old) +0,0 @@" })
        ]
        for testCase in cases {
            let comment = Comment(rawValue: testCase.name)
            let patch = modifiedFilePatch(hunks: [(testCase.header, testCase.body)])
            #expect(patch.utf8.count > Self.limit, comment)
            let artifact = try #require(mappedArtifacts(
                [changeEntry(path: "Sources/Mod.swift", status: .modified, patch: patch, additions: 2000, deletions: 2000)],
                in: directory
            ).first, comment)
            let truncated = try #require(artifact.patch, comment)
            let rows = patchRows(truncated)
            #expect(rows[4].hasPrefix("@@ -"), comment)
            let body = Array(rows[5..<(rows.count - 1)])
            let counts = bodyCounts(body)
            #expect(body == testCase.body.prefix(body.count).map { $0 }, comment)
            #expect(counts.lines == body.count && !body.isEmpty, comment)
            #expect(counts.old == 0 || counts.new == 0, comment)
            #expect(rows[4] == testCase.expected(counts.old, counts.new), comment)
            #expect(truncated.utf8.count <= Self.limit, comment)
            #expect(artifact.explanation?.hasPrefix(Self.truncationNotice + "\(body.count) of ") == true, comment)
        }
    }

    @Test
    func truncatedModifiedFileRendersExplanationAndHunkNumberedLines() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let padding = String(repeating: "t", count: 30)
        var body = [" top"]
        for index in 1...1000 { body += ["-old \(index) \(padding)", "+new \(index) \(padding)"] }
        body += [" end"]
        let patch = modifiedFilePatch(hunks: [("@@ -20,1002 +20,1002 @@ func swap()", body)])
        let artifacts = mappedArtifacts(
            [changeEntry(path: "Sources/Mod.swift", status: .modified, patch: patch, additions: 1000, deletions: 1000)],
            in: directory
        )
        let truncated = try #require(artifacts.first?.patch)
        let rows = Array(patchRows(truncated).dropLast())
        let kept = Array(rows[5...])
        #expect(kept.count > 10 && kept.count < body.count)

        // Expected gutter: context rows take the new-side line, removals the old side.
        var oldLine = 20
        var newLine = 20
        var numbers: [Int?] = Array(repeating: nil, count: 5)
        for row in kept {
            switch row.utf8.first {
            case 0x20: numbers.append(newLine); oldLine += 1; newLine += 1
            case 0x2D: numbers.append(oldLine); oldLine += 1
            default: numbers.append(newLine); newLine += 1
            }
        }
        let width = String(numbers.compactMap { $0 }.max() ?? 0).count
        let gutterRows = zip(numbers, rows).map { number, row in
            let text = number.map(String.init) ?? ""
            return String(repeating: " ", count: width - text.count) + text + " │ " + row
        }
        let counts = bodyCounts(kept)

        for rendered in [
            TerminalChat.renderFileArtifacts([.init(number: 1, artifacts: artifacts)], includeHistoryHeadings: true),
            TerminalChat.renderFileArtifacts([.init(number: 1, artifacts: artifacts)], includeHistoryHeadings: false)
        ] {
            let metadata = "**modified `Sources/Mod.swift`**  +1000 -1000\n"
            let explanation = "Explanation: Diff truncated: showing the first \(kept.count) of \(body.count) diff lines; file or operation evidence exceeds the byte limit.\n"
            #expect(rendered.contains(metadata + explanation))
            #expect(rendered.contains(gutterRows.joined(separator: "\n") + "\n"))
            #expect(rendered.contains(" │ @@ -20,\(counts.old) +20,\(counts.new) @@ func swap()\n"))
            #expect(rendered.contains("20 │  top\n"))
            #expect(!rendered.contains("old 1000"))
        }
    }

    @Test
    func addedDeletedAndModifiedFilesShareTheOperationBudgetInOrder() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let operationBudget = OperationFileChangeRecorder.maximumOperationBytes
        let smallLines = Array(repeating: "abcdefghi", count: 6000)
        let smallText = smallLines.joined(separator: "\n") + "\n"
        func huge(_ name: String) -> [String] { sourceLines(2000, prefix: name) }
        let entries = [
            changeEntry(path: "A1.swift", status: .added, patch: newFilePatch(path: "A1.swift", lines: huge("a1")),
                        additions: 2000, deletions: 0),
            changeEntry(path: "D1.swift", status: .deleted, patch: deletedFilePatch(path: "D1.swift", lines: huge("d1")),
                        additions: 0, deletions: 2000),
            changeEntry(path: "M1.swift", status: .modified,
                        patch: modifiedFilePatch(path: "M1.swift", hunks: [("@@ -1,2000 +1,2000 @@", huge("m1").map { " " + $0 })]),
                        additions: 1, deletions: 1),
            // Fits the per-file limit, so it is shown whole from its snapshot.
            changeEntry(path: "D2.swift", status: .deleted, patch: deletedFilePatch(path: "D2.swift", lines: smallLines),
                        additions: 0, deletions: 6000, beforeText: smallText),
            // Only the remaining budget is left for this one.
            changeEntry(path: "D3.swift", status: .deleted, patch: deletedFilePatch(path: "D3.swift", lines: huge("d3")),
                        additions: 0, deletions: 2000),
            // Not even one whole line fits any more.
            changeEntry(path: "A2.swift", status: .added, patch: newFilePatch(path: "A2.swift", lines: huge("a2")),
                        additions: 2000, deletions: 0)
        ]
        #expect(entries.allSatisfy { ($0.patch?.utf8.count ?? 0) > Self.limit })

        let result = mappedArtifacts(entries, in: directory)
        #expect(result.count == 6)
        for index in 0..<3 {
            let patch = try #require(result[index].patch)
            #expect(patch.utf8.count <= Self.limit && patch.utf8.count > Self.limit - 100)
            #expect(result[index].explanation?.hasPrefix(Self.truncationNotice) == true)
            #expect(result[index].hasLineCounts)
        }
        #expect(result.map(\.status) == [.added, .deleted, .modified, .deleted, .deleted, .added])
        #expect(result[3].oldText == smallText && result[3].patch == nil && result[3].explanation == nil)
        let used = result[0..<3].reduce(0) { $0 + ($1.patch?.utf8.count ?? 0) } + smallText.utf8.count
        let remaining = operationBudget - used
        #expect(remaining > 0 && remaining < Self.limit)
        let partial = try #require(result[4].patch)
        #expect(partial.utf8.count <= remaining && remaining - partial.utf8.count < 100)
        #expect(result[4].explanation?.hasPrefix(Self.truncationNotice) == true)
        #expect(result[4].oldText == nil && result[4].deletions == 2000 && result[4].hasLineCounts)
        #expect(result[5].patch == nil)
        #expect(result[5].explanation == FileChangeArtifactMapper.byteLimitExplanation)
        #expect(result[5].additions == 2000 && result[5].hasLineCounts)
        let shown = result.reduce(0) { $0 + ($1.patch?.utf8.count ?? 0) + ($1.oldText?.utf8.count ?? 0) }
        #expect(shown <= operationBudget)
    }

    @Test
    func directOperationEvidenceStillRejectsOversizedDeletedAndModifiedEvidence() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let big = String(repeating: "x", count: Self.limit + 1)
        let result = FileChangeArtifactMapper.artifacts(from: [
            .init(path: "gone.txt", oldText: big, newText: nil),
            .init(path: "edited.txt", oldText: nil, newText: nil,
                  compactDiff: .init(
                    patch: modifiedFilePatch(hunks: [("@@ -1,2 +1,2 @@", [" a", "-" + big, "+b"])]),
                    additions: 1, deletions: 1))
        ], workingDirectory: directory)
        #expect(result.map(\.status) == [.deleted, .modified])
        for artifact in result {
            #expect(artifact.patch == nil)
            #expect(artifact.explanation == FileChangeArtifactMapper.byteLimitExplanation)
        }
    }
}
