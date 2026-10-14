// TerminalDialogPresentationTests.swift
import Foundation
import Synchronization
import Testing
@testable import ZenCODECore

@Suite(TerminalBlockingTestScope()) struct TerminalDialogPresentationTests {
    private let footerLines = ["PROMPT| draft 界🙂", "draft second line", "DOCK| 2 unread", "STATUS| ready"]

    private func install(_ screen: TerminalPrimaryScreen, rows: Int = 24, columns: Int = 100) {
        let footer = footerLines.enumerated().map {
            "\u{1B}[\(rows - footerLines.count + 1 + $0.offset);1H\u{1B}[2K" + $0.element
        }.joined()
        screen.commitFooter(geometry: .init(rows: rows, columns: columns),
                            reservedRows: footerLines.count, sequence: footer)
    }

    private func prompt(columns: Int = 100, command: String = "swift test --filter One") -> String {
        LocalExecPermissionAuthorizer.terminalPrompt(
            for: AgentToolAuthorizationRequest(
                sessionID: "session", toolCallID: "call", toolName: "local.exec",
                title: "Run tests", kind: "shell", command: command, workingDirectory: "/tmp/project",
            ),
            terminalColumns: columns,
        )
    }

    private func cardLines(_ prompt: String) -> [String] {
        TerminalANSIText.stripANSI(prompt).split(separator: "\n").map(String.init)
    }

    @Test(arguments: [40, 100])
    func `real compositor preserves exactly the original card and its full width`(columns: Int) {
        let capture = PrimaryScreenCapture(columns: columns), screen = capture.screen()
        install(screen, columns: columns)
        let rendered = prompt(columns: columns, command: "printf " + String(repeating: "wide-argument ", count: 12))
        let expected = cardLines(rendered)
        let modal = TerminalModalSession(screen: screen)
        defer { modal.close() }
        modal.updateDialog(TerminalDialogPresentation(prompt: rendered))

        let rows = capture.terminal.withLock { $0.viewport.map(\.text) }
        #expect(Array(rows.dropLast(footerLines.count).suffix(expected.count)) == expected)
        #expect(Array(rows.suffix(footerLines.count)) == footerLines)
        #expect(expected.map(TerminalANSIText.visibleWidth).max() == columns - 1)
        #expect(capture.visible.filter { $0 == "╭" }.count == 1)
        #expect(capture.visible.filter { $0 == "╰" }.count == 1)
        #expect(!capture.bytes.contains("?1049"))
        #expect(!capture.bytes.contains("\u{1B}[2J"))
    }

    @Test(arguments: [20, 40, 48, 100, 160], [
        "pwd",
        "printf " + String(repeating: "界🙂e\u{301}-long-argument ", count: 12) + "tail-token",
    ])
    func `authorization right border aligns with the real prompt for short and long commands`(
        columns: Int, command: String
    ) async {
        // Forty rows retain the whole wrapped card above the actual prompt;
        // this is an alignment regression, not a resize or clipping fixture.
        let capture = PrimaryScreenCapture(rows: 40, columns: columns)
        let bar = TerminalStatusBar(
            isEnabled: true, cursorReports: capture.reports, outputSink: capture.write,
        )
        await bar.configureForTesting(row: 40, columns: columns, modelID: "test-model")
        await bar.updateInputPanel(text: "draft", cursorIndex: 5, modeText: "Prompt", helpText: "Enter")
        let reservedRows = await bar.reservedRowsForOverlay()
        let originalFooter = capture.terminal.withLock { Array($0.viewport.suffix(reservedRows)) }
        let promptRightBorder = originalFooter.first?.cells.lastIndex(of: "╮")
        #expect(originalFooter.first?.text.hasPrefix("╭") == true)
        #expect(promptRightBorder == columns - 2) // zero-based; one spare column

        let rendered = prompt(columns: columns, command: command)
        let expected = cardLines(rendered)
        let modal = TerminalModalSession(screen: await bar.primaryScreen)
        modal.updateDialog(TerminalDialogPresentation(prompt: rendered))
        let viewport = capture.terminal.withLock { $0.viewport }
        let authorizationRows = Array(viewport.dropLast(reservedRows).suffix(expected.count))

        #expect(authorizationRows.map(\.text) == expected)
        #expect(authorizationRows.allSatisfy { row in
            row.cells.lastIndex(where: { $0 == "╮" || $0 == "│" || $0 == "┤" || $0 == "╯" })
                == promptRightBorder
        })
        #expect(authorizationRows.allSatisfy { row in
            TerminalANSIText.visibleWidth(row.text) == columns - 1 && row.cells.last == " "
        })
        #expect(Array(viewport.suffix(reservedRows).map(\.text)) == originalFooter.map(\.text))
        if command != "pwd" {
            #expect(expected.filter { $0.hasPrefix("│") }.count > 4)
            let bodyContent = expected.filter { $0.hasPrefix("│") }.map {
                String($0.dropFirst(2).dropLast(2)).trimmingCharacters(in: .whitespaces)
            }.joined()
            #expect(bodyContent.contains("tail-token"))
        }
        modal.close()
        await bar.stop()
    }

    @Test func `dialog rows retain whitespace and ANSI without menu normalization`() {
        let content = "  \u{1B}[36mplain dialog 界🙂\u{1B}[0m  "
        let dialog = TerminalDialogPresentation(prompt: "\n" + content + "\n")
        #expect(dialog.lines == [content])
        #expect(dialog.visibleLines(columns: 80, capacity: 5) == [content])
        #expect(dialog.visibleLines(columns: 10, capacity: 5).allSatisfy {
            TerminalANSIText.visibleWidth($0) <= 10
        })
        #expect(dialog.visibleLines(columns: 0, capacity: 5).isEmpty)
        #expect(dialog.visibleLines(columns: 80, capacity: 0).isEmpty)
        #expect(TerminalDialogPresentation(prompt: "\n\n").lines.isEmpty)
    }

    @Test(arguments: ["r", "a", "c", ""])
    func `single key reader uses the dialog path and retains answers`(key: String) {
        let capture = PrimaryScreenCapture(), screen = capture.screen()
        install(screen)
        let pipe = Pipe()
        pipe.fileHandleForWriting.write(Data((key.isEmpty ? "\r" : key).utf8))
        pipe.fileHandleForWriting.closeFile()
        let reader = TerminalInteractiveLineReader(rawInput: TerminalRawInput(
            fileDescriptor: pipe.fileHandleForReading.fileDescriptor, cursorReports: capture.reports,
        ))
        let observed = Mutex<String?>(nil)
        let rendered = prompt()
        let answer = reader.readSingleKey(prompt: rendered, shouldCancel: {
            observed.withLock { $0 = capture.visible }
            return false
        }, screen: screen)

        #expect(answer == key)
        let visible = observed.withLock { $0 ?? "" }
        #expect(visible.contains(cardLines(rendered).joined(separator: "\n")))
        #expect(visible.filter { $0 == "╭" }.count == 1)
        #expect(visible.filter { $0 == "╰" }.count == 1)
        #expect(!capture.visible.contains("Authorization")) // defer closes the surface
        #expect(capture.visible.contains("STATUS| ready"))
    }

    @Test func `retry is plain dialog content rather than a menu`() {
        let capture = PrimaryScreenCapture(), screen = capture.screen()
        install(screen)
        let retry = LocalExecPermissionAuthorizer.terminalRetryPrompt()
        let modal = TerminalModalSession(screen: screen)
        defer { modal.close() }
        modal.updateDialog(TerminalDialogPresentation(prompt: retry))
        let rows = capture.terminal.withLock { $0.viewport.map(\.text) }
        #expect(rows[rows.count - footerLines.count - 1] == TerminalANSIText.stripANSI(retry))
        #expect(!capture.visible.contains("╭"))
        #expect(!capture.visible.contains("│"))
        #expect(!capture.visible.contains("more"))
    }

    @Test(arguments: [8, 10, 12])
    func `short terminals prioritize consent actions without covering the footer`(rows: Int) {
        let capture = PrimaryScreenCapture(rows: rows, columns: 60), screen = capture.screen()
        install(screen, rows: rows, columns: 60)
        let rendered = prompt(columns: 60, command: "printf " + String(repeating: "large-command ", count: 120))
        let modal = TerminalModalSession(screen: screen)
        modal.updateDialog(TerminalDialogPresentation(prompt: rendered))
        for index in 0..<20 { screen.append("transcript-\(index)|\n") }

        #expect(capture.visible.contains("[R]un once / [A]lways / [C]ancel"))
        #expect(capture.visible.filter { $0 == "╰" }.count == 1)
        if rows >= 10 {
            #expect(capture.visible.contains("Authorization"))
            #expect(capture.visible.contains("…"))
        }
        #expect(!capture.visible.contains("↑ more"))
        #expect(!capture.visible.contains("↓ more"))
        #expect(capture.terminal.withLock { Array($0.viewport.suffix(4).map(\.text)) } == footerLines)
        #expect(!capture.history.contains("Authorization"))
        #expect(!capture.history.contains("[R]"))
        #expect(!capture.history.contains("STATUS|"))
        modal.close()
        #expect(!capture.visible.contains("[R]"))
        #expect(capture.visible.contains("draft second line"))
    }

    @Test func `resize keeps real status draft dock and consent choices`() async throws {
        let capture = PrimaryScreenCapture()
        let bar = TerminalStatusBar(isEnabled: true, cursorReports: capture.reports,
            resizeGeneration: { capture.generation.withLock { $0 } }, outputSink: capture.write)
        await bar.configureForTesting(row: 24, columns: 100, modelID: "test-model", isProcessing: true)
        let draft = "draft 界🙂\nsecond line"
        await bar.updateInputPanel(text: draft, cursorIndex: draft.count, modeText: "Prompt", helpText: "Enter")
        await bar.setSharedChatReader(entries: [], unreadCount: 0, isExpanded: true)
        let screen = await bar.primaryScreen
        let modal = TerminalModalSession(screen: screen)
        let rendered = prompt(command: "echo " + String(repeating: "long-argument ", count: 6))
        modal.updateDialog(TerminalDialogPresentation(prompt: rendered))
        for (rows, columns) in [(18, 45), (24, 100)] {
            capture.resize(rows: rows, columns: columns)
            await bar.handleTerminalResizeForTesting(rows: rows, columns: columns)
            screen.append("queued-\(columns)|\n")
            try await capture.answerReport()
            #expect(!screen.isAppendOnly)
            #expect(await bar.state.inputPanelState?.text == draft)
            #expect(capture.visible.contains("test-model"))
            #expect(capture.visible.contains("Chat"))
            #expect(capture.visible.contains("[R]un once / [A]lways / [C]ancel"))
            let footerRows = await bar.reservedRowsForOverlay()
            let dialogArea = capture.terminal.withLock {
                $0.viewport.dropLast(footerRows).map(\.text).joined(separator: "\n")
            }
            #expect(dialogArea.filter { $0 == "╭" }.count == 1)
            #expect(!capture.history.contains("[R]"))
        }
        #expect(capture.visible.contains(cardLines(rendered).joined(separator: "\n")))
        modal.close()
        #expect(capture.visible.contains("second line"))
        #expect(!capture.visible.contains("Authorization"))
        await bar.stop()
    }

    @Test func `closing a dialog restores the menu border focus and overflow markers`() {
        let capture = PrimaryScreenCapture(), screen = capture.screen()
        install(screen)
        let menu = TerminalModalSession(screen: screen)
        menu.update(.init(title: "MENU_ONLY", help: ["Enter"],
            lines: (0..<40).map { (index: Int) in .init(text: "item-\(index)|", itemIndex: index) }, focusedIndex: 39))
        let original = capture.visible
        #expect(original.contains("item-39|"))
        #expect(original.contains("↑ more"))
        #expect(original.filter { $0 == "╭" }.count == 1)

        let dialog = TerminalModalSession(screen: screen)
        dialog.updateDialog(TerminalDialogPresentation(prompt: prompt()))
        #expect(!capture.visible.contains("MENU_ONLY"))
        #expect(!capture.visible.contains("↑ more"))
        #expect(capture.visible.filter { $0 == "╭" }.count == 1)
        dialog.close()
        dialog.close() // closing is idempotent and cannot pop the underlying menu
        #expect(capture.visible == original)
        menu.close()
        #expect(!capture.visible.contains("MENU_ONLY"))
        #expect(capture.visible.contains("STATUS| ready"))
    }

    @Test(arguments: ["r", "\r"])
    func `append only cancellation cannot accept consent or the Enter default`(input: String) {
        let capture = PrimaryScreenCapture(), screen = capture.screen()
        install(screen)
        let pipe = Pipe()
        pipe.fileHandleForWriting.write(Data(input.utf8))
        pipe.fileHandleForWriting.closeFile()
        let reader = TerminalInteractiveLineReader(rawInput: TerminalRawInput(
            fileDescriptor: pipe.fileHandleForReading.fileDescriptor, cursorReports: capture.reports,
        ))
        let answer = reader.readSingleKey(prompt: prompt(), shouldCancel: {
            screen.enterAppendOnly(reason: "consent cancellation fixture")
            return false
        }, screen: screen)
        #expect(answer == nil)
        #expect(screen.isAppendOnly)
    }

    @Test(arguments: [false, true])
    func `EOF and explicit cancellation close the dialog without accepting`(cancel: Bool) {
        let capture = PrimaryScreenCapture(), screen = capture.screen()
        install(screen)
        let pipe = Pipe()
        pipe.fileHandleForWriting.closeFile()
        let reader = TerminalInteractiveLineReader(rawInput: TerminalRawInput(
            fileDescriptor: pipe.fileHandleForReading.fileDescriptor, cursorReports: capture.reports,
        ))
        #expect(reader.readSingleKey(prompt: prompt(), shouldCancel: { cancel }, screen: screen) == nil)
        #expect(!capture.visible.contains("Authorization"))
        #expect(capture.visible.contains("STATUS| ready"))
    }

    @Test func `text prompts keep their existing menu framing and default semantics`() {
        let capture = PrimaryScreenCapture(), screen = capture.screen()
        install(screen)
        let answer = TerminalCheckboxMenu.readPromptLine(title: "Text prompt", prompt: "Name",
            defaultValue: "existing", allowEmpty: true, help: "Enter to accept", reservedBottomRows: 4,
            screen: screen) {
                #expect(capture.visible.contains("Text prompt"))
                #expect(capture.visible.contains("Name [existing]: ▏"))
                #expect(capture.visible.filter { $0 == "╭" }.count == 1)
                #expect(capture.visible.filter { $0 == "╰" }.count == 1)
                return .submitted("")
            }
        #expect(answer == "existing")
        #expect(!capture.visible.contains("Text prompt"))
        #expect(capture.visible.contains("STATUS| ready"))
    }
}
