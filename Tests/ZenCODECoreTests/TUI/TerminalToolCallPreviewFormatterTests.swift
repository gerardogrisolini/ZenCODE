//
//  TerminalToolCallPreviewFormatterTests.swift
//  ZenCODE
//
//  The pure drawing of a file write or edit the model is still writing: the
//  header with the tool name alone (never the path, whatever the order of the
//  arguments), source rows written as they arrive and
//  repainted in color with a carriage return over the same cells, the diff
//  markers of an edit, the rows that are never repainted, terminal-safe text,
//  independence from how the stream was split, the interruption that
//  suspends a call until its next drawn source text reopens the header, and
//  the record of what an ended call showed (canonical tool, path, whether its
//  rows were still open on screen), which the coordinator uses to merge the
//  tool block that follows into the preview header.
//

import Foundation
import Testing
@testable import ZenCODECore

@Suite("Terminal tool-call preview formatter")
struct TerminalToolCallPreviewFormatterTests {
    typealias DrawnCall = TerminalToolCallPreviewFormatter.DrawnCall

    static let reset = TerminalStyle.reset
    private static let title = TerminalStyle.Tool.title
    private static let removal = TerminalMarkdownPalette.dark.diffRemoval
    private static let addition = TerminalMarkdownPalette.dark.diffAddition
    /// `let x = 1` as the Swift highlighter of the dark palette colors it.
    private static let highlightedLetX = "\u{1B}[38;5;141mlet\u{1B}[0m x = \u{1B}[38;5;215m1\u{1B}[0m"

    func makeFormatter(
        interactive: Bool = true,
        inset: String = " "
    ) -> TerminalToolCallPreviewFormatter {
        TerminalToolCallPreviewFormatter(
            isInteractive: interactive,
            lineInset: inset,
            palette: .dark
        )
    }

    /// The text returned for each event, in order.
    func outputs(
        _ events: [DirectAgentToolCallPreview],
        interactive: Bool = true,
        inset: String = " ",
        columns: Int = 80
    ) -> [String] {
        var formatter = makeFormatter(interactive: interactive, inset: inset)
        return events.map { formatter.consume($0, columns: { columns }) }
    }

    func rendered(
        _ events: [DirectAgentToolCallPreview],
        interactive: Bool = true,
        inset: String = " ",
        columns: Int = 80
    ) -> String {
        outputs(events, interactive: interactive, inset: inset, columns: columns).joined()
    }

    /// What reaches the terminal once the chat writer places the margin before
    /// the first visible cell of every row, as the coordinator does.
    private func terminalText(_ text: String, inset: String = " ") -> String {
        var state = TerminalChatTextFormatting.ChatLineInsetState()
        return TerminalChatTextFormatting.chatLineInsetApplied(
            to: text,
            prefix: inset,
            state: &state
        )
    }

    func write(
        path: String? = "Sources/A.swift",
        content: [String],
        tool: String = "local.write"
    ) -> [DirectAgentToolCallPreview] {
        var events: [DirectAgentToolCallPreview] = [.toolStarted(name: tool)]
        if let path {
            events += [.parameterStarted(name: "path"), .parameterText(path), .parameterEnded]
        }
        events.append(.parameterStarted(name: "content"))
        events += content.map(DirectAgentToolCallPreview.parameterText)
        events += [.parameterEnded, .ended]
        return events
    }

    /// Feeds `events` and returns the text they produced.
    func feed(
        _ events: [DirectAgentToolCallPreview],
        to formatter: inout TerminalToolCallPreviewFormatter
    ) -> String {
        events.map { formatter.consume($0, columns: { 80 }) }.joined()
    }

    func chunks(_ text: String, size: Int) -> [String] {
        let scalars = Array(text.unicodeScalars)
        return stride(from: 0, to: scalars.count, by: size).map { start in
            var chunk = String.UnicodeScalarView()
            chunk.append(contentsOf: scalars[start..<min(start + size, scalars.count)])
            return String(chunk)
        }
    }

    // MARK: - Header

    @Test
    func theHeaderIsTheToolNameAloneWhileThePathStreams() {
        let events: [DirectAgentToolCallPreview] = [
            .toolStarted(name: "local.write"),
            .parameterStarted(name: "path"),
            .parameterText("Sources/"),
            .parameterText("A.swift"),
            .parameterEnded,
            .ended
        ]

        #expect(outputs(events) == [
            "\(Self.title)🛠️  local.write\(Self.reset)",
            "", "", "", "",
            "\n"
        ])
        #expect(outputs(events, interactive: false) == [
            "🛠️  local.write", "", "", "", "", "\n"
        ])
    }

    @Test
    func theHeaderIsTheSameWhetherThePathComesBeforeOrAfterTheSourceText() {
        func edit(pathFirst: Bool) -> [DirectAgentToolCallPreview] {
            let path: [DirectAgentToolCallPreview] = [
                .parameterStarted(name: "path"), .parameterText("Sources/A.swift"), .parameterEnded
            ]
            let text: [DirectAgentToolCallPreview] = [
                .parameterStarted(name: "new"), .parameterText("let x = 1\n"), .parameterEnded,
                .parameterStarted(name: "old"), .parameterText("let x = 0\n"), .parameterEnded
            ]
            return [.toolStarted(name: "local.editFile")] + (pathFirst ? path + text : text + path) + [.ended]
        }
        let header = "\(Self.title)🛠️  local.write\(Self.reset)\n"

        // The same rows, written in the same way, whichever order the model used.
        #expect(rendered(write(content: ["let x = 1\n"]), interactive: false)
            == "🛠️  local.write\nlet x = 1\n")
        #expect(rendered(writeWithContentBeforeThePath(path: "Sources/A.swift"), interactive: false)
            == "🛠️  local.write\nlet x = 1\n")
        #expect(rendered(edit(pathFirst: true), interactive: false)
            == rendered(edit(pathFirst: false), interactive: false))
        #expect(rendered(edit(pathFirst: true), interactive: false)
            .hasPrefix("🛠️  local.editFile\n+ let x = 1\n"))

        // The header is the title and its row break, and no path follows it.
        #expect(rendered(write(content: ["let x = 1\n"])).hasPrefix(header))
        #expect(rendered(writeWithContentBeforeThePath(path: "Sources/A.swift")).hasPrefix(header))
        #expect(!rendered(write(content: ["let x = 1\n"])).contains("A.swift"))
        #expect(!rendered(writeWithContentBeforeThePath(path: "Sources/A.swift")).contains("A.swift"))
    }

    @Test(arguments: [
        ("local.write", "local.write"),
        ("local.append", "local.append"),
        ("local.editFile", "local.editFile"),
        ("local.replace", "local.replace"),
        ("local.multiEdit", "local.multiEdit"),
        ("local_write", "local.write"),
        ("LOCAL.EDITFILE", "local.editFile"),
        ("local-replace", "local.replace"),
        ("local_multiEdit", "local.multiEdit")
    ])
    func drawnToolsAreRecognizedByTheirNormalizedName(name: String, canonicalName: String) {
        #expect(TerminalToolCallPreviewFormatter.drawsTool(named: name))
        #expect(rendered([.toolStarted(name: name), .ended], interactive: false) == "🛠️  \(canonicalName)\n")
    }

    @Test
    func thePathIsNeverWrittenWhateverItContains() {
        let text = rendered([
            .toolStarted(name: "local.write"),
            .parameterStarted(name: "file_path"),
            .parameterText("a\nb\u{1B}[2Jc\td"),
            .ended
        ], interactive: false)

        #expect(text == "🛠️  local.write\n")
    }

    // MARK: - Source rows

    @Test
    func sourceTextIsWrittenAsItArrivesAndTheRowIsRepaintedInColorAtItsEnd() {
        let events = write(content: ["let", " x = 1", "\n"])

        #expect(outputs(events) == [
            "\(Self.title)🛠️  local.write\(Self.reset)",
            "",
            "",
            "",
            "\n",
            "let",
            " x = 1",
            "\r \(Self.highlightedLetX)\(Self.reset)\n",
            "",
            ""
        ])
    }

    @Test
    func theRepaintOccupiesExactlyTheCellsAlreadyWritten() {
        let text = terminalText(rendered(write(content: ["let x = 1\nlet y = 2\n"])))

        #expect(terminalScreenText(text, width: 80) == [
            " 🛠️  local.write",
            " let x = 1",
            " let y = 2",
            ""
        ].joined(separator: "\n"))
        #expect(!text.contains("\u{1B}[K"))
        #expect(!text.contains("\u{1B}[2K"))
        #expect(!text.contains("\u{1B}[1K"))
        #expect(!containsCursorUpSequence(text))
        #expect(containsOnlySGREscapes(text))
    }

    @Test
    func aRowAsWideAsTheTerminalIsNotRepainted() {
        // Inset + `let x = 1` take ten cells: they must be strictly narrower.
        let tooWide = rendered(write(content: ["let x = 1\n"]), columns: 10)
        let fits = rendered(write(content: ["let x = 1\n"]), columns: 11)

        #expect(!tooWide.contains("\r"))
        #expect(tooWide.hasSuffix("\(Self.reset)\nlet x = 1\n"))
        #expect(fits.contains("\r \(Self.highlightedLetX)\(Self.reset)\n"))
    }

    @Test
    func theWidthIsReadOnlyForARowThatWouldBeRepainted() {
        var reads = 0
        var formatter = makeFormatter()
        for event in write(content: ["x = y\n", "let é = 1\n", "let x = 1\n"]) {
            _ = formatter.consume(event, columns: {
                reads += 1
                return 80
            })
        }
        #expect(reads == 1)
    }

    @Test
    func nonASCIIRowsAreNotRepainted() {
        let text = rendered(write(content: ["let é = 1\n", "let s = \"🙂\"\n"]))

        #expect(!text.contains("\r"))
        #expect(text.hasSuffix("let é = 1\nlet s = \"🙂\"\n"))
    }

    @Test
    func rowsWithNothingToColorAreNotRepainted() {
        let text = rendered(write(content: ["x = y\n", "   \n"]))

        #expect(!text.contains("\r"))
        #expect(text.hasSuffix("x = y\n   \n"))
    }

    @Test
    func aNonInteractiveChannelReceivesPlainTextOnly() {
        let text = rendered(
            write(content: ["let x = 1\n", "\u{1B}[31mred\u{07}\n"])
                + [.toolStarted(name: "local.editFile"),
                   .parameterStarted(name: "old"), .parameterText("let a = 1\n"), .parameterEnded,
                   .parameterStarted(name: "new"), .parameterText("let a = 2"), .ended],
            interactive: false
        )

        #expect(!text.contains("\u{1B}"))
        #expect(!text.contains("\r"))
        #expect(text.contains("- let a = 1\n+ let a = 2\n"))
    }

    @Test
    func tabsAreExpandedFromTheSourceColumnAndKeepTheRowRepaintable() {
        let text = rendered(write(content: ["\tlet x = 1\n", "ab\tc\n"]))

        #expect(text.contains("    let x = 1\r" + " " + "    " + Self.highlightedLetX))
        #expect(text.hasSuffix("ab  c\n"))
        #expect(!text.contains("\t"))
    }

    @Test
    func lineBreaksOfEveryKindEndOneRow() {
        let text = rendered(write(content: ["a\r", "\nb\rc\r\n\n"]), interactive: false)

        #expect(text.hasSuffix("\na\nb\nc\n\n"))
    }

    @Test
    func contentBeforeThePathUsesTheGenericProfileAndALatePathIsNeverWritten() {
        let text = rendered(writeWithContentBeforeThePath(path: "Late.swift"))
        let generic = TerminalCodeBlockRenderer.renderLine("let x = 1", language: nil, palette: .dark)

        #expect(text == "\(Self.title)🛠️  local.write\(Self.reset)\nlet x = 1\r \(generic)\(Self.reset)\n")
        #expect(!text.contains("Late.swift"))
    }

    @Test
    func thePathSelectsTheLanguageOfTheSource() {
        let text = rendered(write(path: "config.json", content: ["{\"a\": 1}\n"]))
        let json = TerminalCodeBlockRenderer.renderLine("{\"a\": 1}", language: "json", palette: .dark)

        #expect(text.hasSuffix("{\"a\": 1}\r \(json)\(Self.reset)\n"))
    }

    // MARK: - Edits

    @Test
    func editRowsStartWithTheirDiffMarkerEvenWhenEmptyAndInTheRepaint() {
        let events: [DirectAgentToolCallPreview] = [
            .toolStarted(name: "local.editFile"),
            .parameterStarted(name: "path"),
            .parameterText("A.swift"),
            .parameterEnded,
            .parameterStarted(name: "old"),
            .parameterText("let x = 1\n\nb\n"),
            .parameterEnded,
            .parameterStarted(name: "new"),
            .parameterText("let x = 1"),
            .parameterEnded,
            .ended
        ]
        let minus = "\(Self.removal)- \(Self.reset)"
        let plus = "\(Self.addition)+ \(Self.reset)"
        let text = rendered(events)

        #expect(text == "\(Self.title)🛠️  local.editFile\(Self.reset)\n"
            + "\(minus)let x = 1\r \(minus)\(Self.highlightedLetX)\(Self.reset)\n"
            + "\(minus)\n"
            + "\(minus)b\n"
            + "\(plus)let x = 1\r \(plus)\(Self.highlightedLetX)\(Self.reset)\n")
        #expect(terminalScreenText(terminalText(text), width: 80) == [
            " 🛠️  local.editFile",
            " - let x = 1",
            " - ",
            " - b",
            " + let x = 1",
            ""
        ].joined(separator: "\n"))
    }

    @Test
    func theMarkerCountsInTheRepaintWidth() {
        // Inset, marker, and `let x = 1` take twelve cells.
        let events: [DirectAgentToolCallPreview] = [
            .toolStarted(name: "local.replace"),
            .parameterStarted(name: "new"),
            .parameterText("let x = 1\n"),
            .ended
        ]

        #expect(!rendered(events, columns: 12).contains("\r"))
        #expect(rendered(events, columns: 13).contains("\r"))
    }

    // MARK: - Interruption

    @Test
    func anInterruptionClosesTheRowsAndTheNextDrawnTextReopensTheHeader() {
        var formatter = makeFormatter(interactive: false)
        let start = feed(Array(write(content: ["let a = 1\nlet b"]).dropLast(2)), to: &formatter)
        let interruption = formatter.interrupt(columns: { 80 })

        #expect(start == "🛠️  local.write\nlet a = 1\nlet b")
        #expect(interruption == "\n")
        #expect(!formatter.isOpen)
        #expect(formatter.isSuspended)
        #expect(formatter.interrupt(columns: { 80 }) == "")
        #expect(!formatter.resumes(with: .parameterText("")))
        #expect(!formatter.resumes(with: .parameterEnded))
        #expect(formatter.resumes(with: .parameterText(" = 2\n")))

        // The row broken by the interruption goes on from a new row.
        let resumed = feed([.parameterText(" = 2\n"), .parameterText("let c = 3\n")], to: &formatter)
        #expect(resumed == "🛠️  local.write\n = 2\nlet c = 3\n")
        #expect(formatter.isOpen)
        #expect(!formatter.isSuspended)
        #expect(feed([.parameterEnded, .ended], to: &formatter) == "")
        #expect(!formatter.isOpen)
    }

    @Test
    func theInterruptionRepaintsTheRowAndTheHeaderReopensAsItWasFirstWritten() {
        var formatter = makeFormatter()
        let header = "\(Self.title)🛠️  local.write\(Self.reset)\n"

        #expect(feed(Array(write(content: ["let x = 1"]).dropLast(2)), to: &formatter) == header + "let x = 1")
        #expect(formatter.interrupt(columns: { 80 }) == "\r \(Self.highlightedLetX)\(Self.reset)\n")
        #expect(feed([.parameterText("\nlet x = 1\n")], to: &formatter)
            == header + "let x = 1\r \(Self.highlightedLetX)\(Self.reset)\n")
    }

    @Test
    func aPathStreamingWhileTheCallIsSuspendedWritesNothingAndSourceTextReopensTheToolNameAlone() {
        var formatter = makeFormatter()
        let plus = "\(Self.addition)+ \(Self.reset)"
        let start = feed([
            .toolStarted(name: "local.editFile"),
            .parameterStarted(name: "path"),
            .parameterText("Sources/")
        ], to: &formatter)

        #expect(start == "\(Self.title)🛠️  local.editFile\(Self.reset)")
        #expect(formatter.interrupt(columns: { 80 }) == "\n")
        #expect(formatter.isSuspended)

        // The rest of the path writes nothing, so it does not reopen the call.
        #expect(!formatter.resumes(with: .parameterText("A.swift")))
        #expect(feed([.parameterText("A.swift"), .parameterEnded], to: &formatter) == "")
        #expect(formatter.isSuspended)
        #expect(!formatter.isOpen)

        // Source text does: the tool name alone, then the text from the next row.
        #expect(feed([.parameterStarted(name: "new")], to: &formatter) == "")
        #expect(formatter.resumes(with: .parameterText("let x = 1\n")))
        #expect(feed([.parameterText("let x = 1\n")], to: &formatter)
            == "\(Self.title)🛠️  local.editFile\(Self.reset)\n"
            + "\(plus)let x = 1\r \(plus)\(Self.highlightedLetX)\(Self.reset)\n")
        #expect(formatter.isOpen)

        // The path received across the suspension still identifies the call.
        let ended = formatter.finish(columns: { 80 })
        #expect(ended.text == "")
        #expect(ended.drawn == DrawnCall(toolName: "local.editFile", path: "Sources/A.swift", endedOnScreen: true))
    }

    @Test
    func aSuspendedCallWritesOnlyItsDrawnTextAndItsEndOrANewCallForgetsIt() {
        var formatter = makeFormatter(interactive: false)
        _ = feed([
            .toolStarted(name: "local.editFile"),
            .parameterStarted(name: "path"),
            .parameterText("A.swift"),
            .parameterEnded,
            .parameterStarted(name: "old"),
            .parameterText("x\n")
        ], to: &formatter)

        // The row is already closed: the interruption has nothing to write.
        #expect(formatter.interrupt(columns: { 80 }) == "")
        #expect(formatter.isSuspended)
        // Starts and ends of arguments only change the open role, and the text
        // of an argument that is not drawn stays silent.
        #expect(feed([
            .parameterEnded,
            .parameterStarted(name: "replaceAll"),
            .parameterText("true"),
            .parameterEnded,
            .parameterStarted(name: "new")
        ], to: &formatter) == "")
        #expect(formatter.isSuspended)
        #expect(!formatter.resumes(with: .parameterStarted(name: "new")))
        #expect(feed([.parameterText("y\n")], to: &formatter) == "🛠️  local.editFile\n+ y\n")

        // Its end writes nothing and forgets it.
        #expect(formatter.interrupt(columns: { 80 }) == "")
        #expect(feed([.ended], to: &formatter) == "")
        #expect(!formatter.isSuspended)
        #expect(!formatter.isOpen)
        #expect(feed([.parameterText("z\n")], to: &formatter) == "")

        // A new call writes only its own header.
        _ = feed([.toolStarted(name: "local.write"), .parameterStarted(name: "content"), .parameterText("a")],
                 to: &formatter)
        #expect(formatter.interrupt(columns: { 80 }) == "\n")
        #expect(feed([.toolStarted(name: "local.append")], to: &formatter) == "🛠️  local.append")
        #expect(formatter.isOpen)
        #expect(!formatter.isSuspended)
    }

    @Test
    func aLineBreakRightAfterTheResumeCompletesTheRowTheInterruptionEnded() {
        var formatter = makeFormatter(interactive: false)
        var text = feed([
            .toolStarted(name: "local.editFile"),
            .parameterStarted(name: "path"),
            .parameterText("A.swift"),
            .parameterEnded,
            .parameterStarted(name: "old"),
            .parameterText("let a = 1")
        ], to: &formatter)
        text += formatter.interrupt(columns: { 80 })
        // Only the line break of the row already ended: nothing to draw.
        #expect(!formatter.resumes(with: .parameterText("\n")))
        text += feed([.parameterText("\n")], to: &formatter)
        #expect(formatter.isSuspended)
        text += feed([.parameterText("b\n"), .parameterEnded, .parameterStarted(name: "new"), .parameterText("let a = 2")],
                     to: &formatter)
        text += formatter.interrupt(columns: { 80 })
        // A CRLF break completes it as well.
        #expect(formatter.resumes(with: .parameterText("\r\nc")))
        text += feed([.parameterText("\r\nc"), .ended], to: &formatter)

        // Every row of the source once, and no empty row that is not in it.
        #expect(text == "🛠️  local.editFile\n- let a = 1\n"
            + "🛠️  local.editFile\n- b\n+ let a = 2\n"
            + "🛠️  local.editFile\n+ c\n")

        // At the start of a row the interruption ended nothing: a line break
        // there is a blank row of the source.
        var blank = makeFormatter(interactive: false)
        _ = feed(Array(write(content: ["a\n"]).dropLast(2)), to: &blank)
        #expect(blank.interrupt(columns: { 80 }) == "")
        #expect(feed([.parameterText("\nb\n")], to: &blank) == "🛠️  local.write\n\nb\n")
    }
}

// MARK: - Shared preview fixtures

/// A drawn `local.write` call whose content arrives before its path: the
/// header is the same as when the path comes first (the tool name alone), and
/// the path only identifies the call. Shared by the formatter and coordinator
/// suites.
func writeWithContentBeforeThePath(
    path: String,
    content: String = "let x = 1\n"
) -> [DirectAgentToolCallPreview] {
    [
        .toolStarted(name: "local.write"),
        .parameterStarted(name: "content"),
        .parameterText(content),
        .parameterEnded,
        .parameterStarted(name: "path"),
        .parameterText(path),
        .parameterEnded,
        .ended
    ]
}

/// Every escape sequence in `text` is a Select Graphic Rendition: no erase
/// sequence and no cursor movement, so only a carriage return can move the
/// cursor back.
func containsOnlySGREscapes(_ text: String) -> Bool {
    let scalars = Array(text.unicodeScalars)
    var index = 0
    while index < scalars.count {
        guard scalars[index] == "\u{1B}" else {
            index += 1
            continue
        }
        guard index + 1 < scalars.count, scalars[index + 1] == "[" else { return false }
        index += 2
        while index < scalars.count,
              scalars[index].properties.numericType != nil || scalars[index] == ";" {
            index += 1
        }
        guard index < scalars.count, scalars[index] == "m" else { return false }
        index += 1
    }
    return true
}
