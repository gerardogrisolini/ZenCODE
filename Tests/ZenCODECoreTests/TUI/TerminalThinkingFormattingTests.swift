//
//  TerminalThinkingFormattingTests.swift
//  ZenCODETests
//

import Foundation
import Testing
@testable import ZenCODECore

@Suite("Thinking Markdown formatting")
struct TerminalThinkingFormattingTests {
    @Test(arguments: [
        ("\u{1B}[1m", "\u{1B}[90m"),
        ("\u{1B}[1;2;3;4;9m", "\u{1B}[2;3;4;9;90m"),
        ("\u{1B}[1;38;5;75m", "\u{1B}[38;5;109m"),
        ("\u{1B}[3;1;38;5;180m", "\u{1B}[3;38;5;144m"),
    ])
    func thinkingRemovesOnlyBoldWhileKeepingAttributesAndMutedAccents(
        _ input: String,
        _ expected: String
    ) {
        #expect(TerminalChatTextFormatting.dimmedANSISequence(
            input,
            gray: TerminalStyle.Thinking.body,
            reset: TerminalStyle.reset
        ) == expected)
    }

    @Test
    func subAgentThinkingUsesTheMainMarkdownPipeline() throws {
        let source = "# Inspect\n\nDone.**Next section** with *emphasis*, ~~obsolete~~ and `code`.\n\n- first\n- second\n\n> quoted\n"
        var state = TerminalChatBoldBreakState()
        var normalized = TerminalChatTextFormatting.normalizedBoldSectionBreak(source, state: &state)
        normalized += TerminalChatTextFormatting.flushBoldSectionBreak(state: &state)
        var formatter = TerminalMarkdownStreamFormatter(
            isEnabled: true,
            renderWidth: 80,
            supportsHyperlinks: false,
            removesUnbalancedStrongMarkers: true,
            usesTerminalWidthForStructuredContent: false
        )
        let expected = TerminalChatTextFormatting.renderThoughtMarkdown(
            formatter.consume(normalized) + formatter.finish(),
            standardErrorIsTerminal: true
        )
        let rendered = try #require(TerminalChat.renderSubAgentThinkingMarkdown(
            source,
            standardErrorIsTerminal: true,
            renderWidth: 80
        ))
        let plain = TerminalANSIText.stripANSI(rendered)

        #expect(rendered == expected)
        #expect(plain.contains("Done.\nNext section"))
        #expect(plain.contains("• first"))
        #expect(plain.contains("• second"))
        #expect(!plain.contains("**"))
        #expect(!plain.contains("`code`"))
        #expect(!plain.contains("# Inspect"))
        #expect(!containsBoldSGR(rendered))
        #expect(rendered.contains(TerminalStyle.Thinking.body))
        #expect(rendered.contains("\u{1B}[3;90m"))
        #expect(rendered.contains("\u{1B}[9;90m"))
    }

    @Test
    func subAgentThinkingPreservesTabIndentedNestedListsLikeTheMainFormatter() throws {
        let source = "- outer\n\t- inner\n\t\t- deepest\n"
        let rendered = try #require(TerminalChat.renderSubAgentThinkingMarkdown(
            source,
            standardErrorIsTerminal: true,
            renderWidth: 80
        ))
        let plain = TerminalANSIText.stripANSI(rendered)

        #expect(rendered == mainThinkingMarkdown(source))
        #expect(plain.contains("• outer\n  ◦ inner\n    ▪ deepest"))
        #expect(!rendered.contains("\t"))
        #expect(!containsBoldSGR(rendered))
    }

    @Test
    func subAgentThinkingPreservesFencedCodeTabStopsLikeTheMainFormatter() throws {
        let source = "```swift\n\tlet text = \"**literal**\"\n \tprint(text)\nlet\tvalue = 1\n```\n"
        let rendered = try #require(TerminalChat.renderSubAgentThinkingMarkdown(
            source,
            standardErrorIsTerminal: true,
            renderWidth: 80
        ))
        let plain = TerminalANSIText.stripANSI(rendered)

        #expect(rendered == mainThinkingMarkdown(source))
        #expect(plain.contains("Code · Swift"))
        #expect(plain.contains("    let text = \"**literal**\""))
        #expect(plain.contains("    print(text)"))
        #expect(plain.contains("let value = 1"))
        #expect(!rendered.contains("\t"))
        #expect(!containsBoldSGR(rendered))
    }

    @Test
    func subAgentThinkingPreservesTabIndentedCodeLikeTheMainFormatter() throws {
        // Use a structured block the main stream already parses as Markdown,
        // without changing its existing handling of top-level indentation.
        let source = "> \t\tlet text = \"**literal**\"\n"
        let rendered = try #require(TerminalChat.renderSubAgentThinkingMarkdown(
            source,
            standardErrorIsTerminal: true,
            renderWidth: 80
        ))
        let plain = TerminalANSIText.stripANSI(rendered)

        #expect(rendered == mainThinkingMarkdown(source))
        #expect(plain.contains("Code"))
        #expect(plain.contains("let text = \"**literal**\""))
        #expect(!rendered.contains("\t"))
        #expect(!containsBoldSGR(rendered))
    }

    @Test
    func subAgentThinkingRendersStructuredBlocksAndLiteralCode() throws {
        let source = """
        ```swift
        if ready {
            let text = "**literal**"
        }
        ```

        | Name | Value |
        | --- | --- |
        | item | `code` |
        """
        let rendered = try #require(TerminalChat.renderSubAgentThinkingMarkdown(
            source,
            standardErrorIsTerminal: true,
            renderWidth: 60
        ))
        let plain = TerminalANSIText.stripANSI(rendered)

        #expect(plain.contains("Code · Swift"))
        #expect(plain.contains("    let text = \"**literal**\""))
        #expect(plain.contains("┌"))
        #expect(plain.contains("Name"))
        #expect(plain.contains("item"))
        #expect(!plain.contains("```"))
        #expect(!plain.contains("`code`"))
        #expect(!containsBoldSGR(rendered))
        #expect(plain.components(separatedBy: "\n").allSatisfy {
            TerminalANSIText.visibleWidth($0) <= 60
        })
    }

    @Test(arguments: [
        "**safe** \u{1B}[2J\u{1B}]52;c;payload\u{7}\u{1B}]8;;https://example.com\u{1B}\\link\u{1B}]8;;\u{1B}\\\u{9B}2J\u{85}\u{202E}\u{200B}\u{200D}\r\tend",
        "**safe** &#27;[2J &#27;]52;c;payload&#7; &#x202e;&#x200b;&#x200d; end",
        "**safe** [link](https://example.com) end",
        "**safe**\t&#9;&#x09; end",
    ])
    func subAgentThinkingCannotInjectTerminalControls(_ source: String) throws {
        let rendered = try #require(TerminalChat.renderSubAgentThinkingMarkdown(
            source,
            standardErrorIsTerminal: true,
            renderWidth: 80
        ))
        // Remove only SGR, not arbitrary CSI/OSC, so an unsafe escape cannot
        // disappear from the test through the generic ANSI stripping helper.
        let visible = rendered.replacingOccurrences(
            of: "\u{1B}\\[[0-9;]*m",
            with: "",
            options: .regularExpression
        )
        #expect(visible.contains("safe"))
        #expect(visible.contains("end"))
        #expect(!visible.unicodeScalars.contains { scalar in
            scalar != "\n" && (
                CharacterSet.controlCharacters.contains(scalar)
                    || scalar.properties.isBidiControl
                    || scalar.properties.isJoinControl
            )
        })
        #expect(!containsBoldSGR(rendered))
    }

    @Test
    func nonTerminalThinkingRetainsMarkdownWithoutANSI() throws {
        let source = "# Inspect\r\n\r\n- **item**\n"
        let rendered = try #require(TerminalChat.renderSubAgentThinkingMarkdown(
            source,
            standardErrorIsTerminal: false
        ))
        #expect(rendered == "# Inspect\n\n- **item**\n")
        #expect(TerminalChat.renderSubAgentThinkingMarkdown(
            "\u{1B}\u{7}\u{202E}\u{200B}\n",
            standardErrorIsTerminal: true
        ) == nil)
    }

    @Test
    func streamedThinkingIsNotBoldButNormalAssistantMarkdownIsUnchanged() async {
        let renderer = makeRenderer()
        await renderer.writeThought("# Inspect\n\nDone.*")
        await renderer.writeThought("*Next section** with `code` and *emphasis*.\n")
        await renderer.finishThoughtOutput()
        let answer = "# Answer\n\n**Important** with `code`.\n"
        await renderer.writeAssistantContent(answer)
        await renderer.finishAssistantContent()
        let events = await renderer.capturedWriteEvents()
        let thinking = events.filter { $0.channel == .standardError }.map(\.text).joined()
        let normal = events.filter { $0.channel == .standardOutput }.map(\.text).joined()

        #expect(!containsBoldSGR(thinking))
        #expect(TerminalANSIText.stripANSI(thinking).contains("Done.\nNext section"))
        #expect(thinking.components(separatedBy: TerminalChat.thinkingPlaceholder).count - 1 == 1)
        #expect(thinking.contains(TerminalStyle.Thinking.body))
        #expect(containsBoldSGR(normal))
        var formatter = TerminalMarkdownStreamFormatter(isEnabled: true)
        let expected = formatter.consume(answer) + formatter.finish()
        #expect(normal == "💬 " + expected)
    }

    @Test
    func completedSubAgentResponseStillUsesBoldMarkdown() async {
        let renderer = makeRenderer()
        _ = await renderer.renderSubAgentOverview(
            signature: "thinking-format:completed",
            text: "Agents completed.\n",
            responses: [.init(
                token: "thinking-format:response",
                heading: "   ✅ Response from worker:\n",
                markdown: "**Important** with `code`.\n"
            )],
            force: false,
            rememberSignature: true
        )
        let output = await renderer.capturedWriteEvents().map(\.text).joined()

        #expect(output.contains("\u{1B}[1mImportant\u{1B}[0m"))
        #expect(!output.contains("**Important**"))
        #expect(!output.contains("`code`"))
    }

    @Test
    func thinkingOverviewKeepsOneTitleAndTheExistingRowBudgets() {
        let paragraph = "# Plan\n\n" + String(repeating: "- **Step** with `code` and 検証\n", count: 30)
        let snapshot = thinkingSnapshot(paragraph)
        for budget in [nil, 12, 8, 4] as [Int?] {
            let rows = TerminalChat.renderSubAgentOverviewRowsForTesting([snapshot], rowBudget: budget)
            let output = rows.joined(separator: "\n")
            #expect(output.components(separatedBy: TerminalChat.thinkingPlaceholder).count - 1 == 1)
            if let budget {
                #expect(rows.count <= budget)
            }
            #expect(rows.allSatisfy { TerminalANSIText.visibleWidth($0) < TerminalChat.terminalColumnCount() })
        }
        let replacement = TerminalChat.renderSubAgentOverview([thinkingSnapshot("Replacement paragraph")])
        #expect(replacement.contains("Replacement paragraph"))
        #expect(!replacement.contains("Step"))
        #expect(replacement.components(separatedBy: TerminalChat.thinkingPlaceholder).count - 1 == 1)
    }

    private func mainThinkingMarkdown(_ source: String, renderWidth: Int = 80) -> String {
        var state = TerminalChatBoldBreakState()
        var normalized = TerminalChatTextFormatting.normalizedBoldSectionBreak(source, state: &state)
        normalized += TerminalChatTextFormatting.flushBoldSectionBreak(state: &state)
        var formatter = TerminalMarkdownStreamFormatter(
            isEnabled: true,
            renderWidth: renderWidth,
            supportsHyperlinks: false,
            removesUnbalancedStrongMarkers: true
        )
        return TerminalChatTextFormatting.renderThoughtMarkdown(
            formatter.consume(normalized) + formatter.finish(),
            standardErrorIsTerminal: true
        )
    }

    private func containsBoldSGR(_ text: String) -> Bool {
        text.range(
            of: "\u{1B}\\[(?:[0-9]+;)*1(?:;[0-9]+)*m",
            options: .regularExpression
        ) != nil
    }

    private func makeRenderer() -> TerminalChatRenderCoordinator {
        TerminalChatRenderCoordinator(
            stdinIsTerminal: false,
            standardOutput: nil,
            standardError: nil,
            standardOutputIsTerminal: true,
            standardErrorIsTerminal: true,
            cursorTopology: .separate,
            capturesWrites: true,
            streamingFlushDelay: nil
        )
    }

    private func thinkingSnapshot(_ paragraph: String) -> DirectSubAgentRuntime.AgentSnapshot {
        DirectSubAgentRuntime.AgentSnapshot(
            id: "thinking-format",
            name: "worker",
            role: "Worker",
            status: .running,
            pending: true,
            currentActivity: paragraph,
            currentActivityKind: .thinking,
            latestOutput: nil,
            latestError: nil,
            createdAt: Date(timeIntervalSince1970: 1),
            updatedAt: Date(timeIntervalSince1970: 1)
        )
    }
}
