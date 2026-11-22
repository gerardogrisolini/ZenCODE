//
//  TerminalToolCallPreviewFormatterTests+Ending.swift
//  ZenCODE
//
//  Tests of the tool-call preview formatter for ignored input, terminal
//  safety, stream splitting, the end of a call and the drawn call record.
//

import Foundation
import Testing
@testable import ZenCODECore

extension TerminalToolCallPreviewFormatterTests {
    // MARK: - Ignored input

    @Test(arguments: ["local.applyPatch", "local.read", "local.exec", "agent.create"])
    func toolsThatAreNotDrawnProduceNothing(name: String) {
        let events: [DirectAgentToolCallPreview] = [
            .toolStarted(name: name),
            .parameterStarted(name: "path"),
            .parameterText("A.swift"),
            .parameterEnded,
            .parameterStarted(name: "content"),
            .parameterText("let x = 1\n"),
            .parameterEnded,
            .ended
        ]

        #expect(!TerminalToolCallPreviewFormatter.drawsTool(named: name))
        #expect(rendered(events) == "")
    }

    @Test
    func argumentsThatAreNotDrawnProduceNothing() {
        let events: [DirectAgentToolCallPreview] = [
            .toolStarted(name: "local.editFile"),
            .parameterStarted(name: "replaceAll"),
            .parameterText("true"),
            .parameterEnded,
            .parameterStarted(name: "content"),
            .parameterText("not an edit argument\n"),
            .parameterEnded,
            .ended
        ]

        #expect(rendered(events, interactive: false) == "🛠️  local.editFile\n")
    }

    @Test
    func fragmentsWithoutTheStartOfADrawnToolAreIgnored() {
        let orphan: [DirectAgentToolCallPreview] = [
            .parameterStarted(name: "content"),
            .parameterText("let x = 1\n"),
            .parameterEnded,
            .ended
        ]
        var formatter = makeFormatter()

        #expect(rendered(orphan) == "")
        #expect(rendered([.toolStarted(name: "local.read")] + orphan) == "")
        // After its end a call takes no more fragments.
        #expect(rendered(write(content: ["a\n"]) + orphan, interactive: false)
            == rendered(write(content: ["a\n"]), interactive: false))
        #expect(!formatter.isOpen)
        _ = formatter.consume(.toolStarted(name: "local.append"), columns: { 80 })
        #expect(formatter.isOpen)
        _ = formatter.consume(.ended, columns: { 80 })
        #expect(!formatter.isOpen)
    }

    // MARK: - Terminal safety

    @Test
    func controlCharactersAndEscapesInTheContentNeverReachTheTerminal() throws {
        let hostile = "a\u{1B}[2J\u{1B}]8;;x\u{07}b\u{08}\u{7F}\u{9B}c\u{202E}d\u{200D}e\n"
        for interactive in [true, false] {
            let text = rendered(write(content: [hostile]), interactive: interactive)
            let body = String(text[try #require(text.range(of: "local.write")).upperBound...])

            #expect(body.contains("a␛[2J␛]8;;x␇b␈␡�c�d�e\n"))
            #expect(!body.contains("\u{07}"))
            #expect(!body.contains("\u{08}"))
            #expect(!body.contains("\u{9B}"))
            #expect(!body.contains("\u{202E}"))
            // A row with control pictures is not ASCII: it is never repainted.
            #expect(!body.contains("\r"))
            #expect(containsOnlySGREscapes(text))
        }
    }

    // MARK: - Stream splitting

    @Test
    func theOutputDoesNotDependOnHowTheStreamWasSplit() {
        let path = "Sources/Feature/Écran.swift"
        let content = "import Foundation\r\n\n\tstruct A {\n    let s = \"é🙂\"\r\n    // \u{1B}[1m\n}\nlast"
        func events(pathChunks: [String], contentChunks: [String]) -> [DirectAgentToolCallPreview] {
            [.toolStarted(name: "local.write"), .parameterStarted(name: "path")]
                + pathChunks.map(DirectAgentToolCallPreview.parameterText)
                + [.parameterEnded, .parameterStarted(name: "content")]
                + contentChunks.map(DirectAgentToolCallPreview.parameterText)
                + [.parameterEnded, .ended]
        }
        let whole = rendered(events(pathChunks: [path], contentChunks: [content]))

        for size in [1, 2, 3, 5, 8, 13] {
            let split = rendered(events(
                pathChunks: chunks(path, size: size),
                contentChunks: chunks(content, size: size)
            ))
            #expect(split == whole, "chunks of \(size) scalars")
        }
        #expect(whole.hasSuffix("}\nlast\n"))
    }

    // MARK: - Ending

    @Test
    func theEndClosesAnOpenRowAndAnArgumentLeftOpen() {
        let events: [DirectAgentToolCallPreview] = [
            .toolStarted(name: "local.write"),
            .parameterStarted(name: "content"),
            .parameterText("let x = 1"),
            .ended
        ]

        #expect(outputs(events).last == "\r \(TerminalCodeBlockRenderer.renderLine("let x = 1", language: nil, palette: .dark))\(Self.reset)\n")
        #expect(rendered(events, interactive: false).hasSuffix("\nlet x = 1\n"))
    }

    @Test
    func theEndClosesAHeaderThatIsStillOpen() {
        let events: [DirectAgentToolCallPreview] = [
            .toolStarted(name: "local.write"),
            .parameterStarted(name: "path"),
            .parameterText("A.swi"),
            .ended
        ]

        #expect(outputs(events).last == "\n")
    }

    @Test
    func aNewToolStartEndsThePreviousCall() {
        let events: [DirectAgentToolCallPreview] = [
            .toolStarted(name: "local.write"),
            .parameterStarted(name: "path"),
            .parameterText("A.swift"),
            .parameterStarted(name: "content"),
            .parameterText("a"),
            .toolStarted(name: "local.editFile"),
            .parameterStarted(name: "old"),
            .parameterText("b"),
            .toolStarted(name: "local.read"),
            .parameterStarted(name: "path"),
            .parameterText("ignored"),
            .ended
        ]

        #expect(rendered(events, interactive: false) == "🛠️  local.write\na\n🛠️  local.editFile\n- b\n")
    }

    @Test
    func finishingAClosedFormatterWritesNothing() {
        var formatter = makeFormatter()
        let finished = formatter.finish(columns: { 80 })
        #expect(finished.text == "")
        #expect(finished.drawn == nil)
        #expect(formatter.begin(toolNamed: "local.exec") == nil)
        #expect(!formatter.isOpen)
    }

    // MARK: - Drawn call record

    @Test
    func theEndKeepsWhatTheCallShowedForTheToolBlockThatFollowsIt() {
        var formatter = makeFormatter(interactive: false)
        _ = feed(Array(write(path: "/tmp/A.swift", content: ["let x = 1\n"]).dropLast(2)), to: &formatter)
        let ended = formatter.finish(columns: { 80 })

        #expect(ended.text == "")
        #expect(ended.drawn == DrawnCall(
            toolName: "local.write", path: "/tmp/A.swift", endedOnScreen: true
        ))
        // The record belongs to the call that ended: finishing again has none.
        #expect(formatter.finish(columns: { 80 }).drawn == nil)
    }

    @Test
    func aPathThatArrivesAfterTheSourceTextIsStillRecorded() {
        var formatter = makeFormatter(interactive: false)
        _ = feed(Array(writeWithContentBeforeThePath(path: "Late.swift").dropLast(2)), to: &formatter)
        let drawn = formatter.finish(columns: { 80 }).drawn

        #expect(drawn?.path == "Late.swift")
        // The rows are still on screen: the block can omit the header.
        #expect(drawn?.endedOnScreen == true)
    }

    @Test
    func aToolThatIsNotDrawnRecordsNoCall() {
        var formatter = makeFormatter(interactive: false)
        _ = feed([
            .toolStarted(name: "local.applyPatch"),
            .parameterStarted(name: "path"),
            .parameterText("A.swift")
        ], to: &formatter)

        #expect(formatter.finish(columns: { 80 }).drawn == nil)
    }

    @Test
    func aSuspendedCallThatEndsRecordsItsRowsAsNotOnScreen() {
        var formatter = makeFormatter(interactive: false)
        _ = feed(Array(write(path: "/tmp/A.swift", content: ["let x"]).dropLast(2)), to: &formatter)
        #expect(formatter.interrupt(columns: { 80 }) == "\n")
        let ended = formatter.finish(columns: { 80 })

        // Other output followed the header: the record keeps the path, but
        // not the header as on screen.
        #expect(ended.text == "")
        #expect(ended.drawn == DrawnCall(
            toolName: "local.write", path: "/tmp/A.swift", endedOnScreen: false
        ))
    }

    @Test
    func aPathStillStreamingWhenTheCallEndsIsRecorded() {
        var formatter = makeFormatter(interactive: false)
        _ = feed([
            .toolStarted(name: "local.write"),
            .parameterStarted(name: "path"),
            .parameterText("A.swi")
        ], to: &formatter)
        let ended = formatter.finish(columns: { 80 })

        #expect(ended.text == "\n")
        #expect(ended.drawn == DrawnCall(
            toolName: "local.write", path: "A.swi", endedOnScreen: true
        ))
    }

    @Test
    func theRecordNamesTheCanonicalTool() {
        var formatter = makeFormatter(interactive: false)
        _ = feed(Array(write(path: "A.swift", content: ["a\n"], tool: "local_write").dropLast(2)), to: &formatter)

        #expect(formatter.finish(columns: { 80 }).drawn?.toolName == "local.write")
    }

    @Test
    func thePathOfTheFilePathAliasIsRecorded() {
        var formatter = makeFormatter(interactive: false)
        _ = feed([
            .toolStarted(name: "local.editFile"),
            .parameterStarted(name: "file_path"),
            .parameterText("A.swift"),
            .parameterEnded,
            .parameterStarted(name: "new"),
            .parameterText("b\n")
        ], to: &formatter)

        #expect(formatter.finish(columns: { 80 }).drawn
            == DrawnCall(toolName: "local.editFile", path: "A.swift", endedOnScreen: true))
    }
}
