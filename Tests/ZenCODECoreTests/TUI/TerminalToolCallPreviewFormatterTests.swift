//
//  TerminalToolCallPreviewFormatterTests.swift
//  ZenCODE
//
//  The pure drawing of a file write or edit the model is still writing: the
//  header with its streamed path, source rows written as they arrive and
//  repainted in color with a carriage return over the same cells, the diff
//  markers of an edit, the rows that are never repainted, terminal-safe text,
//  independence from how the stream was split, the interruption that
//  suspends a call until its next drawn text reopens the header, and the
//  record of what an ended call showed (canonical tool, path, whether the
//  path reached the header), which the coordinator uses to merge the tool
//  block that follows into the preview header.
//

import Foundation
import Testing
@testable import ZenCODECore

@Suite("Terminal tool-call preview formatter")
struct TerminalToolCallPreviewFormatterTests {
    typealias DrawnCall = TerminalToolCallPreviewFormatter.DrawnCall

    static let reset = TerminalStyle.reset
    private static let title = TerminalStyle.Tool.title
    private static let value = TerminalStyle.Tool.value
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
        tool: String = "local.writeFile"
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
    func theHeaderOpensAtTheStartAndThePathJoinsItWhileItStreams() {
        let events: [DirectAgentToolCallPreview] = [
            .toolStarted(name: "local.writeFile"),
            .parameterStarted(name: "path"),
            .parameterText("Sources/"),
            .parameterText("A.swift"),
            .parameterEnded,
            .ended
        ]

        #expect(outputs(events) == [
            "\(Self.title)🛠️  local.writeFile\(Self.reset)",
            "",
            " \(Self.value)Sources/",
            "A.swift",
            "",
            "\(Self.reset)\n"
        ])
        #expect(outputs(events, interactive: false) == [
            "🛠️  local.writeFile", "", " Sources/", "A.swift", "", "\n"
        ])
    }

    @Test(arguments: [
        ("local.writeFile", "local.writeFile"),
        ("local.append", "local.append"),
        ("local.editFile", "local.editFile"),
        ("local.replace", "local.replace"),
        ("local_writeFile", "local.writeFile"),
        ("LOCAL.EDITFILE", "local.editFile"),
        ("local-replace", "local.replace")
    ])
    func drawnToolsAreRecognizedByTheirNormalizedName(name: String, canonicalName: String) {
        #expect(TerminalToolCallPreviewFormatter.drawsTool(named: name))
        #expect(rendered([.toolStarted(name: name), .ended], interactive: false) == "🛠️  \(canonicalName)\n")
    }

    @Test
    func thePathIsShownOnOneTerminalSafeRow() {
        let text = rendered([
            .toolStarted(name: "local.writeFile"),
            .parameterStarted(name: "file_path"),
            .parameterText("a\nb\u{1B}[2Jc\td"),
            .ended
        ], interactive: false)

        #expect(text == "🛠️  local.writeFile a␊b␛[2Jc    d\n")
    }

    // MARK: - Source rows

    @Test
    func sourceTextIsWrittenAsItArrivesAndTheRowIsRepaintedInColorAtItsEnd() {
        let events = write(content: ["let", " x = 1", "\n"])

        #expect(outputs(events) == [
            "\(Self.title)🛠️  local.writeFile\(Self.reset)",
            "",
            " \(Self.value)Sources/A.swift",
            "",
            "\(Self.reset)\n",
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
            " 🛠️  local.writeFile Sources/A.swift",
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
    func contentBeforeThePathUsesTheGenericProfileAndALatePathIsNotShown() {
        let text = rendered(writeWithContentBeforeThePath(path: "Late.swift"))
        let generic = TerminalCodeBlockRenderer.renderLine("let x = 1", language: nil, palette: .dark)

        #expect(text == "\(Self.title)🛠️  local.writeFile\(Self.reset)\nlet x = 1\r \(generic)\(Self.reset)\n")
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

        #expect(text == "\(Self.title)🛠️  local.editFile\(Self.reset) \(Self.value)A.swift\(Self.reset)\n"
            + "\(minus)let x = 1\r \(minus)\(Self.highlightedLetX)\(Self.reset)\n"
            + "\(minus)\n"
            + "\(minus)b\n"
            + "\(plus)let x = 1\r \(plus)\(Self.highlightedLetX)\(Self.reset)\n")
        #expect(terminalScreenText(terminalText(text), width: 80) == [
            " 🛠️  local.editFile A.swift",
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

        #expect(start == "🛠️  local.writeFile Sources/A.swift\nlet a = 1\nlet b")
        #expect(interruption == "\n")
        #expect(!formatter.isOpen)
        #expect(formatter.isSuspended)
        #expect(formatter.interrupt(columns: { 80 }) == "")
        #expect(!formatter.resumes(with: .parameterText("")))
        #expect(!formatter.resumes(with: .parameterEnded))
        #expect(formatter.resumes(with: .parameterText(" = 2\n")))

        // The row broken by the interruption goes on from a new row.
        let resumed = feed([.parameterText(" = 2\n"), .parameterText("let c = 3\n")], to: &formatter)
        #expect(resumed == "🛠️  local.writeFile Sources/A.swift\n = 2\nlet c = 3\n")
        #expect(formatter.isOpen)
        #expect(!formatter.isSuspended)
        #expect(feed([.parameterEnded, .ended], to: &formatter) == "")
        #expect(!formatter.isOpen)
    }

    @Test
    func theInterruptionRepaintsTheRowAndTheHeaderReopensAsItWasFirstWritten() {
        var formatter = makeFormatter()
        let header = "\(Self.title)🛠️  local.writeFile\(Self.reset) \(Self.value)Sources/A.swift\(Self.reset)\n"

        #expect(feed(Array(write(content: ["let x = 1"]).dropLast(2)), to: &formatter) == header + "let x = 1")
        #expect(formatter.interrupt(columns: { 80 }) == "\r \(Self.highlightedLetX)\(Self.reset)\n")
        #expect(feed([.parameterText("\nlet x = 1\n")], to: &formatter)
            == header + "let x = 1\r \(Self.highlightedLetX)\(Self.reset)\n")
    }

    @Test
    func aPathStillStreamingGoesOnAtTheEndOfTheReopenedHeader() {
        var formatter = makeFormatter()
        let plus = "\(Self.addition)+ \(Self.reset)"
        let start = feed([
            .toolStarted(name: "local.editFile"),
            .parameterStarted(name: "path"),
            .parameterText("Sources/")
        ], to: &formatter)

        #expect(start == "\(Self.title)🛠️  local.editFile\(Self.reset) \(Self.value)Sources/")
        #expect(formatter.interrupt(columns: { 80 }) == "\(Self.reset)\n")
        #expect(feed([
            .parameterText("A.swift"),
            .parameterEnded,
            .parameterStarted(name: "new"),
            .parameterText("let x = 1\n"),
            .ended
        ], to: &formatter) == "\(Self.title)🛠️  local.editFile\(Self.reset) \(Self.value)Sources/A.swift\(Self.reset)\n"
            + "\(plus)let x = 1\r \(plus)\(Self.highlightedLetX)\(Self.reset)\n")
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
        #expect(feed([.parameterText("y\n")], to: &formatter) == "🛠️  local.editFile A.swift\n+ y\n")

        // Its end writes nothing and forgets it.
        #expect(formatter.interrupt(columns: { 80 }) == "")
        #expect(feed([.ended], to: &formatter) == "")
        #expect(!formatter.isSuspended)
        #expect(!formatter.isOpen)
        #expect(feed([.parameterText("z\n")], to: &formatter) == "")

        // A new call writes only its own header.
        _ = feed([.toolStarted(name: "local.writeFile"), .parameterStarted(name: "content"), .parameterText("a")],
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
        #expect(text == "🛠️  local.editFile A.swift\n- let a = 1\n"
            + "🛠️  local.editFile A.swift\n- b\n+ let a = 2\n"
            + "🛠️  local.editFile A.swift\n+ c\n")

        // At the start of a row the interruption ended nothing: a line break
        // there is a blank row of the source.
        var blank = makeFormatter(interactive: false)
        _ = feed(Array(write(content: ["a\n"]).dropLast(2)), to: &blank)
        #expect(blank.interrupt(columns: { 80 }) == "")
        #expect(feed([.parameterText("\nb\n")], to: &blank) == "🛠️  local.writeFile Sources/A.swift\n\nb\n")
    }
}

// MARK: - Shared preview fixtures

/// A drawn `local.writeFile` call whose content arrives before its path: the
/// header row closes without the path, which is then never shown. Shared by
/// the formatter and coordinator suites.
func writeWithContentBeforeThePath(
    path: String,
    content: String = "let x = 1\n"
) -> [DirectAgentToolCallPreview] {
    [
        .toolStarted(name: "local.writeFile"),
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
