//
//  TerminalToolCallPreviewFormatterTests+MultiEdit.swift
//  ZenCODE
//
//  Tests of the live drawing of `local.multiEdit`: the `old` and `new`
//  strings of the JSON `edits` argument drawn as the arguments of
//  `local.editFile` are, the escapes decoded, the rest of the JSON skipped, the
//  output that does not depend on how the stream was split, the malformed JSON
//  that stops the drawing, the interruption in the middle of a string, and the
//  record of the call that ended.
//

import Foundation
import Testing
@testable import ZenCODECore

extension TerminalToolCallPreviewFormatterTests {
    private static let multiEditTitle = TerminalStyle.Tool.title
    private static let multiEditValue = TerminalStyle.Tool.value
    private static let minus = "\(TerminalMarkdownPalette.dark.diffRemoval)- \(TerminalStyle.reset)"
    private static let plus = "\(TerminalMarkdownPalette.dark.diffAddition)+ \(TerminalStyle.reset)"
    private static let plainHeader = "🛠️  local.multiEdit Sources/A.swift\n"

    /// `let x = <value>` as the Swift highlighter of the dark palette colors it.
    private static func highlightedLetX(_ value: Int) -> String {
        "\u{1B}[38;5;141mlet\u{1B}[0m x = \u{1B}[38;5;215m\(value)\u{1B}[0m"
    }

    /// The row `let x = <value>` of an edit, written and repainted in color.
    private static func repaintedRow(_ marker: String, _ value: Int) -> String {
        "\(marker)let x = \(value)\r \(marker)\(highlightedLetX(value))\(TerminalStyle.reset)\n"
    }

    /// A `local.multiEdit` call whose `edits` argument arrives as `json`.
    func multiEdit(
        _ json: [String],
        path: String? = "Sources/A.swift",
        tool: String = "local.multiEdit",
        ends: Bool = true
    ) -> [DirectAgentToolCallPreview] {
        var events: [DirectAgentToolCallPreview] = [.toolStarted(name: tool)]
        if let path {
            events += [.parameterStarted(name: "path"), .parameterText(path), .parameterEnded]
        }
        events.append(.parameterStarted(name: "edits"))
        events += json.map(DirectAgentToolCallPreview.parameterText)
        if ends {
            events += [.parameterEnded, .ended]
        }
        return events
    }

    /// The plain text of the drawing of `json`, with the header of the call.
    private func plainMultiEdit(_ json: String) -> String {
        rendered(multiEdit([json]), interactive: false)
    }

    /// What reaches a terminal once the chat writer places the margin before
    /// the first visible cell of every row.
    private func multiEditScreen(_ text: String) -> String {
        var state = TerminalChatTextFormatting.ChatLineInsetState()
        return terminalScreenText(
            TerminalChatTextFormatting.chatLineInsetApplied(to: text, prefix: " ", state: &state),
            width: 80
        )
    }

    // MARK: - Drawing

    @Test
    func theOldAndNewTextOfEveryEditIsDrawnInOrderAndRepaintedInColor() {
        let json = #"[{"old": "let x = 1\nlet x = 2", "new": "let x = 3"}, {"old": "let x = 4\n", "new": "let x = 5"}]"#
        let text = rendered(multiEdit([json]))
        let header = "\(Self.multiEditTitle)🛠️  local.multiEdit\(Self.reset) "
            + "\(Self.multiEditValue)Sources/A.swift\(Self.reset)\n"

        // No separator between the edits and no JSON around the text.
        #expect(text == header
            + Self.repaintedRow(Self.minus, 1)
            + Self.repaintedRow(Self.minus, 2)
            + Self.repaintedRow(Self.plus, 3)
            + Self.repaintedRow(Self.minus, 4)
            + Self.repaintedRow(Self.plus, 5))
        #expect(multiEditScreen(text) == [
            " 🛠️  local.multiEdit Sources/A.swift",
            " - let x = 1",
            " - let x = 2",
            " + let x = 3",
            " - let x = 4",
            " + let x = 5",
            ""
        ].joined(separator: "\n"))
        #expect(containsOnlySGREscapes(text))
    }

    @Test
    func aNonInteractiveChannelReceivesThePlainRowsOfEveryEdit() {
        let json = #"[{"old": "a\n\nb", "new": "c"}, {"old": "d", "new": "e\n"}]"#
        let text = plainMultiEdit(json)

        #expect(text == Self.plainHeader + "- a\n- \n- b\n+ c\n- d\n+ e\n")
        #expect(!text.contains("\u{1B}"))
        #expect(!text.contains("\r"))
    }

    @Test
    func theRowsAreHighlightedWithTheLanguageOfThePath() {
        let json = #"[{"old": "{\"a\": 1}", "new": "caf\u00e9"}]"#
        let jsonFile = rendered(multiEdit([json], path: "config.json"))
        let object = TerminalCodeBlockRenderer.renderLine("{\"a\": 1}", language: "json", palette: .dark)

        #expect(jsonFile.contains("{\"a\": 1}\r \(Self.minus)\(object)\(Self.reset)\n"))
        // A row that is not ASCII stays as written.
        #expect(jsonFile.hasSuffix("\(Self.plus)café\n"))
    }

    @Test
    func theMarkerOfTheOpenStringCountsInTheRepaintWidth() {
        // Inset, marker, and `let x = 1` take twelve cells.
        let json = [#"[{"new": "let x = 1"}]"#]

        #expect(!rendered(multiEdit(json), columns: 12).contains("\r"))
        #expect(rendered(multiEdit(json), columns: 13).contains("\r"))
    }

    @Test
    func anEmptyStringAndAnEmptyListDrawNothing() {
        #expect(plainMultiEdit(#"[{"old": "", "new": "x"}]"#) == Self.plainHeader + "+ x\n")
        #expect(plainMultiEdit(#"[{"old": "", "new": ""}]"#) == Self.plainHeader)
        #expect(plainMultiEdit("[]") == Self.plainHeader)
        #expect(plainMultiEdit("[{}, {}]") == Self.plainHeader)
    }

    @Test
    func prettyPrintedJSONAndTheNewlinesAroundTheValueAreSkipped() {
        let json = "\n[\n  {\n    \"old\" : \"a\" ,\n    \"new\" : \"b\"\n  } ,\n  {\"new\": \"c\"}\n]\n"

        #expect(plainMultiEdit(json) == Self.plainHeader + "- a\n+ b\n+ c\n")
    }

    // MARK: - Decoding

    @Test
    func escapesAreDecodedAndOtherKeysAndValuesAreSkipped() {
        let json = #"[{"id": 1, "old": "a\tb \"q\" c\\d \u00e9 \ud83d\ude00 e\/f", "meta": {"old": "no", "list": [1, "}]", "\""]}, "new": "x\r\ny", "ok": true, "none": null, "n": -1.5e3}]"#

        #expect(plainMultiEdit(json) == Self.plainHeader + "- a   b \"q\" c\\d é 😀 e/f\n+ x\n+ y\n")
    }

    @Test
    func theEscapesOfAKeyAreDecodedBeforeItIsCompared() {
        let json = #"[{"\u006fld": "a", "n\u0065w": "b", "ol\"d": "c", "olds": "d", "ol": "e", "new ": "f", "\ud83d": "g"}]"#

        #expect(plainMultiEdit(json) == Self.plainHeader + "- a\n+ b\n")
    }

    @Test
    func valuesThatAreNotStringsAndNestedKeysAreNotDrawn() {
        let json = #"[{"old": 5, "new": "z"}, {"old": ["x"], "new": null}, {"old": {"old": "a", "new": "b"}, "new": "w"}, {"old": false, "new": -0.5}]"#

        #expect(plainMultiEdit(json) == Self.plainHeader + "+ z\n+ w\n")
    }

    @Test
    func aLineBreakInTheStringIsTakenAsItIsAndTheControlsAreMadeSafe() {
        // A raw line feed in the string is not valid JSON, but breaks the row.
        let json = "[{\"old\": \"a\nb\", \"new\": \"x\\u0007\\u001b[2Jy\"}]"

        #expect(plainMultiEdit(json) == Self.plainHeader + "- a\n- b\n+ x␇␛[2Jy\n")
    }

    @Test(arguments: [
        (#"a\ud83d\ude00b"#, "a😀b"),
        (#"\uD83D\uDE00"#, "😀"),
        (#"a\ud83dz"#, "a\u{FFFD}z"),
        (#"a\ude00z"#, "a\u{FFFD}z"),
        (#"a\ud83d\ud83d\ude00"#, "a\u{FFFD}😀"),
        (#"a\ud83d\u0041"#, "a\u{FFFD}A"),
        (#"a\ud83d"#, "a\u{FFFD}"),
        (#"a\qb"#, "a\u{FFFD}b"),
        (#"a\u12"#, "a\u{FFFD}"),
        (#"a\u12g"#, "a\u{FFFD}g"),
        (#"a\u00zz"#, "a\u{FFFD}zz"),
        (#"a\ud83d\u12g"#, "a\u{FFFD}\u{FFFD}g")
    ])
    func loneSurrogatesAndInvalidEscapesDecodeToTheReplacementGlyph(string: String, expected: String) {
        // The string ends at its own closing quote, and the next key is read.
        let text = plainMultiEdit(#"[{"old": ""# + string + #"", "new": "z"}]"#)

        #expect(text == Self.plainHeader + "- \(expected)\n+ z\n")
    }

    // MARK: - Stream splitting

    @Test
    func theDrawingOfAMultiEditDoesNotDependOnHowTheStreamWasSplit() {
        let json = #"[{"id": 1, "old": "let x = 1\r\n\tlet s = \"\u00e9\ud83d\ude00\"\\", "meta": {"k": ["}]", "\"", {"old": "no"}]}, "new": "let x = 2\n"}, {"\u006fld": "a", "n\u0065w": "b\/c\u0041\u12\ud83dz"}, {"old": 5, "new": true}, {"old": "end"}]"#
        let expected = Self.plainHeader
            + "- let x = 1\n- " + "    let s = \"é😀\"\\" + "\n+ let x = 2\n"
            + "- a\n+ b/cA\u{FFFD}\u{FFFD}z\n- end\n"

        for interactive in [false, true] {
            let whole = rendered(multiEdit([json]), interactive: interactive)
            for size in [1, 2, 3, 5, 8, 13] {
                #expect(
                    rendered(multiEdit(chunks(json, size: size)), interactive: interactive) == whole,
                    "chunks of \(size) scalars, interactive: \(interactive)"
                )
            }
            if !interactive {
                #expect(whole == expected)
            }
        }
    }

    @Test
    func theKeysAndTheEscapesAreReadAcrossFragments() {
        // Every cut falls inside a key, a value, an escape, or a surrogate pair.
        let fragments = [#"[{"ol"#, #"d": "a\"#, #"u00"#, #"e9\ud8"#, #"3d\ude"#, #"00", "ne"#, #"w": "b"}"#, "]"]

        #expect(rendered(multiEdit(fragments), interactive: false) == Self.plainHeader + "- aé😀\n+ b\n")
    }

    // MARK: - Malformed JSON

    @Test(arguments: [
        (#"{"old": "a"}"#, ""),
        (#"x[{"old": "a"}]"#, ""),
        (#"[1, {"old": "a"}]"#, ""),
        (#"["a", {"old": "a"}]"#, ""),
        (#"[{old: "a"}]"#, ""),
        (#"[{"old": "a", "new": "b"} x {"old": "c", "new": "d"}]"#, "- a\n+ b\n"),
        (#"[{"old": "a" "new": "b"}]"#, "- a\n"),
        (#"[{"old": "a"} ! {"old": "b"}, {"new": "c"}]"#, "- a\n"),
        (#"[{"old": "a"}] {"old": "b"}"#, "- a\n"),
        (#"[{"old": "a"}, {"old": "b""#, "- a\n- b\n"),
        (#"[{"old": "a", "x": }, {"old": "b"}]"#, "- a\n")
    ])
    func malformedJSONStopsTheDrawingForTheRestOfTheArgument(json: String, rows: String) {
        #expect(plainMultiEdit(json) == Self.plainHeader + rows)
        // The same stops at the same scalar, however the stream was split.
        #expect(rendered(multiEdit(chunks(json, size: 1)), interactive: false) == Self.plainHeader + rows)
    }

    @Test
    func aNewEditsArgumentIsReadFromItsStart() {
        var events = multiEdit(["x[{\"old\": \"a\"}]"], ends: false)
        events += [.parameterEnded, .parameterStarted(name: "edits"), .parameterText(#"[{"new": "b"}]"#), .ended]

        #expect(rendered(events, interactive: false) == Self.plainHeader + "+ b\n")
    }

    // MARK: - Interruption

    @Test
    func aStringInterruptedInTheMiddleKeepsItsMarkerAndTheReopenedHeaderGoesOn() {
        var formatter = makeFormatter(interactive: false)
        let start = feed(multiEdit([#"[{"old": "let a = 1\nlet b"#], ends: false), to: &formatter)
        let interruption = formatter.interrupt(columns: { 80 })

        #expect(start == Self.plainHeader + "- let a = 1\n- let b")
        #expect(interruption == "\n")
        #expect(formatter.isSuspended)
        // The closing quote and the structure up to the next string write nothing.
        #expect(!formatter.resumes(with: .parameterText(#"", "new": "#)))
        #expect(feed([.parameterText(#"", "new": "#)], to: &formatter) == "")
        #expect(formatter.isSuspended)
        #expect(formatter.resumes(with: .parameterText(#""c"#)))

        // Each string goes on from a new row with its own marker.
        #expect(feed([.parameterText(#""c"#)], to: &formatter) == Self.plainHeader + "+ c")
        #expect(formatter.interrupt(columns: { 80 }) == "\n")
        #expect(feed([.parameterText(#"d\ne"}]"#), .parameterEnded, .ended], to: &formatter)
            == Self.plainHeader + "+ d\n+ e\n")
    }

    @Test
    func theMarkerOfTheOpenStringIsRepaintedAtTheInterruptionAndAtTheEnd() {
        var formatter = makeFormatter()
        let header = "\(Self.multiEditTitle)🛠️  local.multiEdit\(Self.reset) "
            + "\(Self.multiEditValue)Sources/A.swift\(Self.reset)\n"
        let start = feed(multiEdit([#"[{"old": "let x = 1"#], ends: false), to: &formatter)

        #expect(start == header + "\(Self.minus)let x = 1")
        #expect(formatter.interrupt(columns: { 80 }) == "\r \(Self.minus)\(Self.highlightedLetX(1))\(Self.reset)\n")
        #expect(feed([.parameterText(#"", "new": "#)], to: &formatter) == "")
        #expect(feed([.parameterText(#""let x = 1"#)], to: &formatter) == header + "\(Self.plus)let x = 1")
        #expect(formatter.interrupt(columns: { 80 })
            == "\r \(Self.plus)\(Self.highlightedLetX(1))\(Self.reset)\n")
        #expect(feed([.parameterText(#"\nlet x = 1"}]"#), .parameterEnded, .ended], to: &formatter)
            == header + Self.repaintedRow(Self.plus, 1))
    }

    @Test
    func aLineBreakEscapeRightAfterTheResumeCompletesTheRowTheInterruptionEnded() {
        var formatter = makeFormatter(interactive: false)
        var text = feed(multiEdit([#"[{"old": "a\"#], ends: false), to: &formatter)
        text += formatter.interrupt(columns: { 80 })

        // The cut falls inside the escape: the line feed it decodes to only
        // completes the row `a` that the interruption ended.
        #expect(!formatter.resumes(with: .parameterText("n")))
        #expect(feed([.parameterText("n")], to: &formatter) == "")
        #expect(formatter.isSuspended)
        #expect(formatter.resumes(with: .parameterText("b")))
        text += feed([.parameterText(#"b\r\nc"#), .parameterText(#"", "new": "d"}]"#), .parameterEnded, .ended],
                     to: &formatter)

        // Every row of the source once, and no empty row that is not in it.
        #expect(text == Self.plainHeader + "- a\n" + Self.plainHeader + "- b\n- c\n+ d\n")
    }

    @Test
    func anEscapeCutByTheInterruptionIsCompletedAfterTheResume() {
        var formatter = makeFormatter(interactive: false)
        var text = feed(multiEdit([#"[{"old": "caf\u00"#], ends: false), to: &formatter)
        text += formatter.interrupt(columns: { 80 })

        #expect(formatter.resumes(with: .parameterText(#"e9 x"}]"#)))
        text += feed([.parameterText(#"e9 x"}]"#), .parameterEnded, .ended], to: &formatter)

        #expect(text == Self.plainHeader + "- caf\n" + Self.plainHeader + "- é x\n")
    }

    @Test
    func anInterruptionAtAnyScalarOfTheJSONLosesNoTextAndAddsNoBlankRow() {
        // No tab: the interruption restarts the columns of the row it breaks.
        let json = #"[{"old": "let a = 1\r\nlet b = 2\n\nlet c = \"\u00e9\ud83d\ude00\"", "meta": {"x": ["}]"]}, "new": "let a = 3\n\n\nlet b = 4\r\r\n"}, {"old": "z", "new": ""}, {"new": "\\q"}]"#
        let scalars = chunks(json, size: 1)

        /// The text of the rows without headers and markers, which marker
        /// starts each of its scalars, and how many rows are blank.
        func summary(_ text: String) -> (content: String, markers: String, blankRows: Int) {
            var content = ""
            var markers = ""
            var blankRows = 0
            for line in text.split(separator: "\n", omittingEmptySubsequences: true) where !line.hasPrefix("🛠️") {
                let rest = line.dropFirst(2)
                content += rest
                markers += String(repeating: String(line.prefix(1)), count: rest.count)
                blankRows += rest.isEmpty ? 1 : 0
            }
            return (content, markers, blankRows)
        }
        let whole = summary(rendered(multiEdit(scalars), interactive: false))
        #expect(whole.blankRows == 4)
        #expect(whole.content.hasPrefix("let a = 1let b = 2let c = \"é😀\"let a = 3"))

        for cut in 0...scalars.count {
            var formatter = makeFormatter(interactive: false)
            var text = feed(multiEdit(Array(scalars[..<cut]), ends: false), to: &formatter)
            text += formatter.interrupt(columns: { 80 })
            text += feed(
                scalars[cut...].map(DirectAgentToolCallPreview.parameterText) + [.parameterEnded, .ended],
                to: &formatter
            )

            let interrupted = summary(text)
            #expect(interrupted.content == whole.content, "cut after \(cut) scalars")
            #expect(interrupted.markers == whole.markers, "cut after \(cut) scalars")
            #expect(interrupted.blankRows == whole.blankRows, "cut after \(cut) scalars")
        }
    }

    @Test
    func aBlankRowOfTheStringIsKeptAfterTheResume() {
        var formatter = makeFormatter(interactive: false)
        var text = feed(multiEdit([#"[{"old": "a\n"#], ends: false), to: &formatter)
        // The interruption ended no row: the row was closed by the line feed.
        #expect(formatter.interrupt(columns: { 80 }) == "")
        text += feed([.parameterText(#"\nb"}]"#), .parameterEnded, .ended], to: &formatter)

        #expect(text == Self.plainHeader + "- a\n" + Self.plainHeader + "- \n- b\n")
    }

    // MARK: - Ending

    @Test
    func theEndKeepsWhatTheMultiEditShowedForTheToolBlockThatFollowsIt() {
        for name in ["local.multiEdit", "local_multiEdit", "LOCAL.MULTIEDIT"] {
            var formatter = makeFormatter(interactive: false)
            _ = feed(Array(multiEdit([#"[{"old": "a", "new": "b"}]"#], tool: name).dropLast(2)), to: &formatter)
            let ended = formatter.finish(columns: { 80 })

            #expect(ended.text == "")
            #expect(ended.drawn == DrawnCall(
                toolName: "local.multiEdit", path: "Sources/A.swift", endedOnScreen: true
            ))
            #expect(formatter.finish(columns: { 80 }).drawn == nil)
        }
    }

    @Test
    func theFilePathAliasAndAPathAfterTheEditsAreRecorded() {
        var aliased = makeFormatter(interactive: false)
        _ = feed([
            .toolStarted(name: "local.multiEdit"),
            .parameterStarted(name: "file_path"),
            .parameterText("B.swift"),
            .parameterEnded,
            .parameterStarted(name: "edits"),
            .parameterText(#"[{"new": "b"}]"#)
        ], to: &aliased)
        #expect(aliased.finish(columns: { 80 }).drawn
            == DrawnCall(toolName: "local.multiEdit", path: "B.swift", endedOnScreen: true))

        var late = makeFormatter(interactive: false)
        _ = feed([
            .toolStarted(name: "local.multiEdit"),
            .parameterStarted(name: "edits"),
            .parameterText(#"[{"new": "b"}]"#),
            .parameterEnded,
            .parameterStarted(name: "path"),
            .parameterText("Late.swift"),
            .parameterEnded
        ], to: &late)
        #expect(late.finish(columns: { 80 }).drawn
            == DrawnCall(toolName: "local.multiEdit", path: "Late.swift", endedOnScreen: true))
    }

    @Test
    func theEndClosesAStringLeftOpenWithItsOwnMarker() {
        var formatter = makeFormatter()
        _ = feed(multiEdit([#"[{"old": "a", "new": "let x = 1"#], ends: false), to: &formatter)
        let ended = formatter.finish(columns: { 80 })

        #expect(ended.text == "\r \(Self.plus)\(Self.highlightedLetX(1))\(Self.reset)\n")
        #expect(ended.drawn == DrawnCall(
            toolName: "local.multiEdit", path: "Sources/A.swift", endedOnScreen: true
        ))
        #expect(!formatter.isOpen)
        #expect(plainMultiEdit(#"[{"old": "a", "new": "b"#) == Self.plainHeader + "- a\n+ b\n")
    }
}
