//
//  TerminalToolCallPreviewFormatterTests+ApplyPatch.swift
//  ZenCODE
//
//  Tests of the live drawing of `local.applyPatch`: the header with the tool
//  name alone, the text of the patch written as it is (without markers of its
//  own, with the rules of source text), the repaint of every row with the diff
//  colors of the kind one `DiffState` gives it across the lines, the rows that
//  are classified without being repainted, the language of the file of the
//  current section, the `diff` alias, the line split by an interruption, the
//  independence from how the stream was split, and the target the record of
//  the call names.
//

import Foundation
import Testing
@testable import ZenCODECore

extension TerminalToolCallPreviewFormatterTests {
    private static let patchTitle = TerminalStyle.Tool.title
    private static let patchHeader = "\(TerminalStyle.Tool.title)🛠️  local.applyPatch\(TerminalStyle.reset)\n"
    private static let diffHeader = TerminalMarkdownPalette.dark.diffHeader
    private static let diffHunk = TerminalMarkdownPalette.dark.diffHunk
    private static let diffRemoval = TerminalMarkdownPalette.dark.diffRemoval
    private static let diffAddition = TerminalMarkdownPalette.dark.diffAddition

    /// `let x = <value>` as the Swift highlighter of the dark palette colors it.
    private static func swiftLetX(_ value: Int) -> String {
        "\u{1B}[38;5;141mlet\u{1B}[0m x = \u{1B}[38;5;215m\(value)\u{1B}[0m"
    }

    /// A patch row written as it arrives, then repainted with `colored` from
    /// its first cell; a row without `colored` stays as written.
    private static func patchRow(_ row: String, _ colored: String? = nil) -> String {
        guard let colored else {
            return "\(row)\n"
        }
        return "\(row)\r \(colored)\(TerminalStyle.reset)\n"
    }

    /// A `local.applyPatch` call whose `argument` (`patch` or its alias
    /// `diff`) arrives as `text`.
    func applyPatch(
        _ text: [String],
        argument: String = "patch",
        tool: String = "local.applyPatch",
        ends: Bool = true
    ) -> [DirectAgentToolCallPreview] {
        var events: [DirectAgentToolCallPreview] = [
            .toolStarted(name: tool),
            .parameterStarted(name: argument)
        ]
        events += text.map(DirectAgentToolCallPreview.parameterText)
        if ends {
            events += [.parameterEnded, .ended]
        }
        return events
    }

    /// What reaches a terminal once the chat writer places the margin before
    /// the first visible cell of every row.
    private func patchScreen(_ text: String, width: Int = 80) -> String {
        var state = TerminalChatTextFormatting.ChatLineInsetState()
        return terminalScreenText(
            TerminalChatTextFormatting.chatLineInsetApplied(to: text, prefix: " ", state: &state),
            width: width
        )
    }

    // MARK: - Header and rows

    @Test
    func theHeaderOfAPatchIsTheToolNameAlone() {
        let events = applyPatch(["*** Begin Patch\n", "*** Update File: Sources/A.swift\n"])

        #expect(outputs(events).first == "\(Self.patchTitle)🛠️  local.applyPatch\(Self.reset)")
        #expect(outputs(events, interactive: false).first == "🛠️  local.applyPatch")
        // The file appears only in the text of the patch, never in the header.
        let rows = rendered(events, interactive: false).components(separatedBy: "\n")
        #expect(rows.first == "🛠️  local.applyPatch")
        #expect(rows.filter { $0.contains("A.swift") } == ["*** Update File: Sources/A.swift"])
    }

    @Test
    func thePatchIsWrittenAsItIsWithTheRulesOfSourceText() {
        let patch = "*** Begin Patch\r\n*** Update File: A.swift\n@@\n-\tlet x = 0\r\n+\tlet x = 1\r ok\u{1B}[2J\u{07}\n\n*** End Patch"
        let text = rendered(applyPatch(Array(chunks(patch, size: 7))), interactive: false)

        // No marker of its own: the diff markers are in the text. Tabs expand
        // from the first column of the row, every line break ends one row, and
        // controls become their pictures.
        #expect(text == "🛠️  local.applyPatch\n"
            + "*** Begin Patch\n*** Update File: A.swift\n@@\n"
            + "-   let x = 0\n+   let x = 1\n ok␛[2J␇\n\n*** End Patch\n")
        #expect(!text.contains("\u{1B}"))
        #expect(!text.contains("\r"))
        #expect(!text.contains("\t"))
    }

    @Test
    func aLongPatchIsWrittenInFull() {
        let lines = (1...400).map { "+line \($0)" }
        let text = rendered(applyPatch([lines.joined(separator: "\n") + "\n"]), interactive: false)

        #expect(text == "🛠️  local.applyPatch\n" + lines.map { "\($0)\n" }.joined())
    }

    @Test
    func everyKindOfRowIsRepaintedWithTheDiffColors() {
        let rows = [
            "--- a/A.swift", "+++ b/A.swift", "@@ -1,2 +1,2 @@",
            "-let x = 0", "+let x = 1", " let x = 2", "\\ No newline at end of file"
        ]
        let text = rendered(applyPatch(rows.map { "\($0)\n" }))

        // The source of the hunk is highlighted as Swift, the file of `+++`.
        #expect(text == Self.patchHeader
            + Self.patchRow("--- a/A.swift", "\(Self.diffHeader)--- a/A.swift\(Self.reset)")
            + Self.patchRow("+++ b/A.swift", "\(Self.diffHeader)+++ b/A.swift\(Self.reset)")
            + Self.patchRow("@@ -1,2 +1,2 @@", "\(Self.diffHunk)@@ -1,2 +1,2 @@\(Self.reset)")
            + Self.patchRow("-let x = 0", "\(Self.diffRemoval)-\(Self.reset)\(Self.swiftLetX(0))")
            + Self.patchRow("+let x = 1", "\(Self.diffAddition)+\(Self.reset)\(Self.swiftLetX(1))")
            + Self.patchRow(" let x = 2", " \(Self.swiftLetX(2))")
            // A plain row has nothing to color: it is not repainted.
            + Self.patchRow("\\ No newline at end of file"))
        #expect(patchScreen(text) == ([" 🛠️  local.applyPatch"] + rows.map { " \($0)" } + [""])
            .joined(separator: "\n"))
        #expect(containsOnlySGREscapes(text))
        #expect(!containsCursorUpSequence(text))
    }

    @Test
    func aNonInteractiveChannelReceivesThePatchWithoutColors() {
        let patch = "--- a/A.swift\n+++ b/A.swift\n@@ -1 +1 @@\n-let x = 0\n+let x = 1\n"
        let text = rendered(applyPatch([patch]), interactive: false)

        #expect(text == "🛠️  local.applyPatch\n" + patch)
    }

    // MARK: - Classification

    @Test
    func theSourceIsHighlightedInTheLanguageOfTheFileOfItsSection() {
        let rows = [
            "+let x = 1",
            "*** Update File: Sources/A.swift",
            "@@",
            "+let x = 1",
            "*** Add File: b/config.json",
            "+{\"a\": 1}",
            "*** Delete File: notes.txt",
            "+let x = 1",
            "--- a/Old.swift",
            "+++ b/New.swift\t2026-11-24",
            "+let x = 1",
            "+++ /dev/null",
            "-let x = 1"
        ]
        let json = TerminalCodeBlockRenderer.renderLine("{\"a\": 1}", language: "json", palette: .dark)
        let text = rendered(applyPatch([rows.joined(separator: "\n")]))
        let plusDiffOnly = "\(Self.diffAddition)+\(Self.reset)let x = 1"
        let plusSwift = "\(Self.diffAddition)+\(Self.reset)\(Self.swiftLetX(1))"

        #expect(text == Self.patchHeader
            // Before any file header only the diff colors apply.
            + Self.patchRow("+let x = 1", plusDiffOnly)
            + Self.patchRow("*** Update File: Sources/A.swift")
            + Self.patchRow("@@", "\(Self.diffHunk)@@\(Self.reset)")
            + Self.patchRow("+let x = 1", plusSwift)
            // The `b/` prefix is a Git prefix: the file is `config.json`.
            + Self.patchRow("*** Add File: b/config.json")
            + Self.patchRow("+{\"a\": 1}", "\(Self.diffAddition)+\(Self.reset)\(json)")
            // A file without a highlighted language leaves the diff colors.
            + Self.patchRow("*** Delete File: notes.txt")
            + Self.patchRow("+let x = 1", plusDiffOnly)
            + Self.patchRow("--- a/Old.swift", "\(Self.diffHeader)--- a/Old.swift\(Self.reset)")
            // The file of a unified diff is the one of `+++`, without its
            // timestamp; the tab of the row expands from its first column.
            + Self.patchRow(
                "+++ b/New.swift 2026-11-24",
                "\(Self.diffHeader)+++ b/New.swift 2026-11-24\(Self.reset)"
            )
            + Self.patchRow("+let x = 1", plusSwift)
            // A deleted file has no language of its own.
            + Self.patchRow("+++ /dev/null", "\(Self.diffHeader)+++ /dev/null\(Self.reset)")
            + Self.patchRow("-let x = 1", "\(Self.diffRemoval)-\(Self.reset)let x = 1"))
    }

    @Test
    func rowsThatAreNotRepaintedAreStillClassifiedInOrder() {
        let long = "-" + String(repeating: "x", count: 60)
        // Three removals exhaust the hunk: the `--- b` after them is a file
        // header only if every row before it was counted, the non-ASCII and
        // the too wide one included.
        let counted = rendered(
            applyPatch(["@@ -1,3 +1,0 @@\n-é\n\(long)\n--- a\n--- b\n"]),
            columns: 40
        )
        #expect(counted == Self.patchHeader
            + Self.patchRow("@@ -1,3 +1,0 @@", "\(Self.diffHunk)@@ -1,3 +1,0 @@\(Self.reset)")
            + Self.patchRow("-é")
            + Self.patchRow(long)
            + Self.patchRow("--- a", "\(Self.diffRemoval)-\(Self.reset)-- a")
            + Self.patchRow("--- b", "\(Self.diffHeader)--- b\(Self.reset)"))

        // An empty row ends a counted hunk, as in a diff fence.
        let ended = rendered(applyPatch(["@@ -1,2 +1,2 @@\n-a\n\n--- b\n"]))
        #expect(ended == Self.patchHeader
            + Self.patchRow("@@ -1,2 +1,2 @@", "\(Self.diffHunk)@@ -1,2 +1,2 @@\(Self.reset)")
            + Self.patchRow("-a", "\(Self.diffRemoval)-\(Self.reset)a")
            + "\n"
            + Self.patchRow("--- b", "\(Self.diffHeader)--- b\(Self.reset)"))
    }

    @Test
    func theDiffAliasIsDrawnAsThePatch() {
        let patch = "--- a/A.swift\n+++ b/A.swift\n@@ -1 +1 @@\n-let x = 0\n+let x = 1\n"

        #expect(rendered(applyPatch([patch], argument: "diff")) == rendered(applyPatch([patch])))
        #expect(rendered(applyPatch([patch], argument: "diff"), interactive: false)
            == "🛠️  local.applyPatch\n" + patch)
    }

    @Test
    func thePatchDrawingDoesNotDependOnHowTheStreamWasSplit() {
        let patch = "*** Begin Patch\r\n*** Update File: Sources/É.swift\n@@\n-\tlet x = 0\r\n"
            + "+let s = \"é🙂\"\n let y = 2\n\n@@ -1,2 +1,2 @@\n-a\n+b\n*** End Patch"
        let whole = rendered(applyPatch([patch]))

        for size in [1, 2, 3, 5, 8, 13] {
            #expect(rendered(applyPatch(chunks(patch, size: size))) == whole, "chunks of \(size) scalars")
        }
        #expect(whole.contains("\r"))
        #expect(whole.hasSuffix("*** End Patch\n"))
    }

    // MARK: - Interruption

    @Test
    func aLineSplitByAnInterruptionIsClassifiedOnceWholeAndNoneOfItsRowsIsRepainted() {
        var formatter = makeFormatter()
        let start = feed(Array(applyPatch(["@@ -0,0 +1,2 @@\n+le"], ends: false)), to: &formatter)

        #expect(start == Self.patchHeader
            + Self.patchRow("@@ -0,0 +1,2 @@", "\(Self.diffHunk)@@ -0,0 +1,2 @@\(Self.reset)")
            + "+le")
        // The row ends on screen without a repaint: it does not hold the line.
        #expect(formatter.interrupt(columns: { 80 }) == "\n")
        #expect(formatter.isSuspended)
        #expect(!formatter.resumes(with: .parameterEnded))
        #expect(formatter.resumes(with: .parameterText("t x = 1")))

        // The rest of the line is not repainted either. The next row is the
        // second addition of the hunk, not a file header: the split line was
        // classified once, whole.
        let resumed = feed([.parameterText("t x = 1"), .parameterText("\n+++ y\n")], to: &formatter)
        #expect(resumed == Self.patchHeader
            + "t x = 1\n"
            + Self.patchRow("+++ y", "\(Self.diffAddition)+\(Self.reset)++ y"))
        #expect(formatter.isOpen)
    }

    @Test
    func aLineBreakRightAfterTheResumeEndsTheLineTheInterruptionSplit() {
        for lineBreak in ["\n", "\r\n"] {
            var formatter = makeFormatter()
            _ = feed(Array(applyPatch(["@@ -0,0 +1,2 @@\n+let x = 1"], ends: false)), to: &formatter)
            #expect(formatter.interrupt(columns: { 80 }) == "\n")

            // Only the line break of the row already ended: nothing to draw.
            #expect(!formatter.resumes(with: .parameterText(lineBreak)))
            #expect(feed([.parameterText(lineBreak)], to: &formatter) == "")
            #expect(formatter.isSuspended)

            // The line it ended was counted: `+++ y` is the second addition.
            #expect(formatter.resumes(with: .parameterText("+++ y\n")))
            #expect(feed([.parameterText("+++ y\n"), .parameterEnded, .ended], to: &formatter)
                == Self.patchHeader + Self.patchRow("+++ y", "\(Self.diffAddition)+\(Self.reset)++ y"))
        }
    }

    // MARK: - Drawn call record

    @Test(arguments: [
        ("*** Begin Patch\n*** Update File: Sources/A.swift\n@@\n-a\n+b\n*** End Patch\n", "Sources/A.swift"),
        (
            "*** Begin Patch\n*** Update File: Sources/A.swift\n@@\n-a\n+b\n"
                + "*** Add File: Sources/B.swift\n+c\n*** Delete File: C.txt\n*** End Patch\n",
            "Sources/A.swift (+2 more)"
        ),
        ("--- a/A.swift\n+++ b/A.swift\n@@ -1 +1 @@\n-a\n+b\n", "A.swift"),
        ("+a line without any file header\n", "")
    ])
    func theRecordOfAPatchNamesTheTargetOfItsFiles(patch: String, target: String) {
        var formatter = makeFormatter(interactive: false)
        _ = feed(Array(applyPatch(chunks(patch, size: 4), ends: false)), to: &formatter)
        let drawn = formatter.finish(columns: { 80 }).drawn

        #expect(drawn == DrawnCall(toolName: "local.applyPatch", path: target, endedOnScreen: true))
        // The target the tool block shows for the same patch.
        #expect(target == (ToolCallPresentation.patchDisplayTarget(from: ["patch": patch]) ?? ""))
    }

    @Test
    func theRecordUsesThePatchTheToolApplies() {
        let patch = "*** Begin Patch\n*** Update File: P.swift\n@@\n-a\n+b\n*** End Patch\n"
        let diff = "--- a/D.swift\n+++ b/D.swift\n@@ -1 +1 @@\n-a\n+b\n"
        func recordedPath(_ arguments: [(String, String)]) -> String? {
            var formatter = makeFormatter(interactive: false)
            var events: [DirectAgentToolCallPreview] = [.toolStarted(name: "local.applyPatch")]
            for (name, text) in arguments {
                events += [.parameterStarted(name: name), .parameterText(text), .parameterEnded]
            }
            _ = feed(events, to: &formatter)
            return formatter.finish(columns: { 80 }).drawn?.path
        }

        #expect(recordedPath([("diff", diff)]) == "D.swift")
        // `patch` wins unless it is empty, whichever order the model used.
        #expect(recordedPath([("patch", patch), ("diff", diff)]) == "P.swift")
        #expect(recordedPath([("diff", diff), ("patch", patch)]) == "P.swift")
        #expect(recordedPath([("patch", ""), ("diff", diff)]) == "D.swift")
        // A call with no patch text yet names no file.
        #expect(recordedPath([]) == "")
    }

    @Test
    func aSuspendedPatchThatEndsKeepsItsTargetButNotItsRowsOnScreen() {
        var formatter = makeFormatter(interactive: false)
        _ = feed(Array(applyPatch(
            ["*** Begin Patch\n*** Update File: A.swift\n@@\n-a\n*** Add File: B.swift\n+b"],
            ends: false
        )), to: &formatter)
        #expect(formatter.interrupt(columns: { 80 }) == "\n")
        let ended = formatter.finish(columns: { 80 })

        // Other output followed the header: the record keeps the target of
        // the patch, but not the header as on screen.
        #expect(ended.text == "")
        #expect(ended.drawn == DrawnCall(
            toolName: "local.applyPatch", path: "A.swift (+1 more)", endedOnScreen: false
        ))
    }
}
