//
//  ACPPromptDisplayTextTests.swift
//  ZenCODE
//
//  The operator's text of an ACP prompt that carries the context Xcode sends
//  before it: the pure functions a saved ACP session names and presents its
//  turns with, and the display texts a restored session recovers.
//

import Foundation
import Testing
import ToolCore
@testable import ZenCODECore
@testable import ZenCODERuntime

struct ACPPromptDisplayTextTests {
    private static let reminder = "<system-reminder>## Xcode\n\nYou are working in Xcode.</system-reminder>"
    private static let structure = """
    Project structure (these are Xcode workspace-relative paths):
    A/B.swift

    The user has no file currently open.

    """

    private static func text(_ text: String) -> [String: Any] {
        ["type": "text", "text": text]
    }

    /// The prompt a regular turn sends the model: the rendered blocks, trimmed.
    private static func renderedPrompt(_ blocks: [Any]) -> String {
        PromptContentFormatter.renderPromptText(from: blocks).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - xcodeContextBlocks

    @Test
    func theContextBlocksAreTheXcodeBlocksOfThePrompt() {
        let blocks: [Any] = [Self.text(Self.reminder), Self.text(Self.structure), Self.text("Domanda vera")]
        // Kept as the rendered prompt holds them, whitespace included.
        #expect(ZenCODEACPBridge.xcodeContextBlocks(in: blocks) == [Self.reminder, Self.structure])
        #expect(Self.structure.hasSuffix("\n"))
    }

    @Test
    func onlyTextBlocksThatLookLikeContextAreContext() {
        // An operator's text that mentions the context without starting with it stays.
        let blocks: [Any] = [
            Self.text(Self.reminder),
            Self.text("Explain the Project structure: and <system-reminder>x</system-reminder>"),
        ]
        #expect(ZenCODEACPBridge.xcodeContextBlocks(in: blocks) == [Self.reminder])
        #expect(ZenCODEACPBridge.xcodeContextBlocks(in: []).isEmpty)
        #expect(ZenCODEACPBridge.xcodeContextBlocks(in: ["Hello"]).isEmpty)
    }

    @Test
    func theContextBlocksSkipWhatTheOperatorDidNotType() {
        let assistantOnly: [String: Any] = [
            "type": "text",
            "text": "<system-reminder>for the assistant</system-reminder>",
            "annotations": ["audience": ["assistant"]],
        ]
        let resource: [String: Any] = ["type": "resource", "resource": ["text": "Project structure: not a block"]]
        let blocks: [Any] = [assistantOnly, resource, Self.text(Self.reminder), "   ", Self.text("Domanda")]
        #expect(ZenCODEACPBridge.xcodeContextBlocks(in: blocks) == [Self.reminder])
        // A plain string is a text block too.
        #expect(ZenCODEACPBridge.xcodeContextBlocks(in: [Self.reminder, "Domanda"]) == [Self.reminder])
    }

    // MARK: - promptDisplayText

    @Test
    func theDisplayTextOfARegularTurnIsTheTextAfterTheContext() {
        let blocks: [Any] = [Self.text(Self.reminder), Self.text(Self.structure), Self.text("Domanda vera")]
        let prompt = Self.renderedPrompt(blocks)
        #expect(prompt.hasPrefix("<system-reminder>"))
        #expect(ZenCODEACPBridge.promptDisplayText(
            of: prompt,
            removingXcodeContext: ZenCODEACPBridge.xcodeContextBlocks(in: blocks)
        ) == "Domanda vera")
    }

    @Test
    func aMultilineOperatorTextIsKeptAsItIs() {
        let operatorText = "Prima riga\n\n  Seconda riga con rientro\n- elenco"
        let blocks: [Any] = [Self.text(Self.reminder), Self.text(Self.structure), Self.text(operatorText)]
        #expect(ZenCODEACPBridge.promptDisplayText(
            of: Self.renderedPrompt(blocks),
            removingXcodeContext: ZenCODEACPBridge.xcodeContextBlocks(in: blocks)
        ) == operatorText)
    }

    @Test
    func aResourceBetweenTheContextAndTheTextStaysInTheDisplayText() {
        let resource: [String: Any] = ["type": "resource", "resource": ["uri": "file:///A/B.swift", "text": "let a = 1"]]
        let blocks: [Any] = [Self.text(Self.reminder), resource, Self.text("Domanda vera")]
        #expect(ZenCODEACPBridge.promptDisplayText(
            of: Self.renderedPrompt(blocks),
            removingXcodeContext: ZenCODEACPBridge.xcodeContextBlocks(in: blocks)
        ) == "Resource: file:///A/B.swift\n\nlet a = 1\n\nDomanda vera")
    }

    @Test
    func aPromptWithoutXcodeContextHasNoDisplayText() {
        let blocks: [Any] = [Self.text("Domanda vera")]
        #expect(ZenCODEACPBridge.promptDisplayText(
            of: Self.renderedPrompt(blocks),
            removingXcodeContext: ZenCODEACPBridge.xcodeContextBlocks(in: blocks)
        ) == nil)
        // Context the prompt does not hold removes nothing.
        #expect(ZenCODEACPBridge.promptDisplayText(of: "Domanda vera", removingXcodeContext: [Self.reminder]) == nil)
        #expect(ZenCODEACPBridge.promptDisplayText(of: "Domanda vera", removingXcodeContext: []) == nil)
    }

    @Test
    func aPromptThatIsOnlyContextHasNoDisplayText() {
        let blocks: [Any] = [Self.text(Self.reminder), Self.text(Self.structure)]
        let contexts = ZenCODEACPBridge.xcodeContextBlocks(in: blocks)
        #expect(contexts == [Self.reminder, Self.structure])
        #expect(ZenCODEACPBridge.promptDisplayText(of: Self.renderedPrompt(blocks), removingXcodeContext: contexts) == nil)
        #expect(ZenCODEACPBridge.promptDisplayText(of: Self.reminder, removingXcodeContext: [Self.reminder]) == nil)
    }

    /// An attachment without text of the operator: only the attachment is left.
    @Test
    func aPromptWithContextAndAnAttachmentOnlyPresentsTheAttachment() {
        let image: [String: Any] = ["type": "image", "uri": "file:///A/shot.png", "mimeType": "image/png"]
        let blocks: [Any] = [Self.text(Self.reminder), Self.text(Self.structure), image]
        #expect(ZenCODEACPBridge.promptDisplayText(
            of: Self.renderedPrompt(blocks),
            removingXcodeContext: ZenCODEACPBridge.xcodeContextBlocks(in: blocks)
        ) == "Image attachment: file:///A/shot.png (image/png)")
    }

    @Test
    func contextWithSurroundingWhitespaceIsRemovedAlthoughThePromptIsTrimmed() {
        let padded = "  \n" + Self.reminder + "\n"
        let blocks: [Any] = [Self.text(padded), Self.text("Domanda vera")]
        let prompt = Self.renderedPrompt(blocks)
        // The whitespace the padding adds at the start of the prompt is trimmed away.
        #expect(!prompt.hasPrefix(" "))
        #expect(ZenCODEACPBridge.promptDisplayText(
            of: prompt,
            removingXcodeContext: ZenCODEACPBridge.xcodeContextBlocks(in: blocks)
        ) == "Domanda vera")
    }

    @Test
    func contextAtTheEndOfThePromptIsRemovedToo() {
        #expect(ZenCODEACPBridge.promptDisplayText(
            of: "Domanda vera\n\n" + Self.reminder,
            removingXcodeContext: [Self.reminder]
        ) == "Domanda vera")
    }

    /// A routed command or a mention typed after Xcode's context: the turn
    /// passes the context before its own prompt (`editorContext` is trimmed),
    /// and the display text is that prompt.
    @Test
    func theDisplayTextOfACommandTurnIsThePromptAfterTheContext() throws {
        let blocks: [Any] = [Self.text(Self.reminder), Self.text(Self.structure), Self.text("/goal ship it")]
        let source = try #require(ZenCODEACPBridge.commandSource(from: blocks))
        #expect(source.text == "/goal ship it")
        let editorContext = ZenCODEACPBridge.editorContext(around: source, in: blocks)
        #expect(editorContext?.hasPrefix("<system-reminder>") == true)
        // Rendered trimmed, so the project structure no longer ends with its newline.
        #expect(editorContext?.hasSuffix("currently open.") == true)

        let modelPrompt = ZenCODEACPBridge.modelPrompt("Plan the goal: ship it", editorContext: editorContext)
        #expect(ZenCODEACPBridge.promptDisplayText(
            of: modelPrompt,
            removingXcodeContext: ZenCODEACPBridge.xcodeContextBlocks(in: blocks)
        ) == "Plan the goal: ship it")

        let mention = ZenCODEACPBridge.modelPrompt("explain", editorContext: editorContext)
        #expect(ZenCODEACPBridge.promptDisplayText(
            of: mention,
            removingXcodeContext: ZenCODEACPBridge.xcodeContextBlocks(in: blocks)
        ) == "explain")
    }

    // MARK: - promptDisplayTexts(restoring:)

    private static func savedSession(
        history: [AgentRuntimeMessage],
        transcriptHistory: [AgentRuntimeMessage]?
    ) -> TerminalSavedSession {
        TerminalSavedSession(
            name: "Domanda vera",
            sessionID: "restored-session",
            cacheKey: nil,
            workingDirectoryPath: "/tmp/workspace",
            createdAt: Date(timeIntervalSince1970: 1_000),
            savedAt: Date(timeIntervalSince1970: 2_000),
            modelID: nil,
            agentID: nil,
            agentName: nil,
            selectedTools: [],
            selectedSkillNames: [],
            thinkingSelection: nil,
            systemPrompt: nil,
            history: history,
            transcriptHistory: transcriptHistory,
            checkpointTree: SessionCheckpointTree.fromLinearHistory(history, sessionID: "restored-session")
        )
    }

    private static func turn(_ prompt: String, reply: String) -> [AgentRuntimeMessage] {
        [AgentRuntimeMessage(role: .user, content: prompt), AgentRuntimeMessage(role: .assistant, content: reply)]
    }

    @Test
    func aRestoredSessionRecoversTheDisplayTextsOfItsTranscript() {
        let history = Self.turn(Self.reminder + "\n\nDomanda vera", reply: "Risposta")
            + Self.turn("Seconda", reply: "Ancora")
            + Self.turn(Self.reminder + "\n\nTerza", reply: "Fine")
        let transcript = Self.turn("Domanda vera", reply: "Risposta")
            + Self.turn("Seconda", reply: "Ancora")
            + Self.turn("Terza", reply: "Fine")
        let texts = ZenCODEACPBridge.promptDisplayTexts(
            restoring: Self.savedSession(history: history, transcriptHistory: transcript)
        )
        // Only the prompts the transcript presents otherwise.
        #expect(texts == [
            Self.reminder + "\n\nDomanda vera": "Domanda vera",
            Self.reminder + "\n\nTerza": "Terza",
        ])
    }

    @Test
    func aRestoredSessionWithoutAComparableTranscriptHasNoDisplayTexts() {
        let history = Self.turn(Self.reminder + "\n\nDomanda vera", reply: "Risposta")
        #expect(ZenCODEACPBridge.promptDisplayTexts(
            restoring: Self.savedSession(history: history, transcriptHistory: nil)
        ).isEmpty)
        // A transcript that holds another number of prompts, as a compacted one does.
        let longer = Self.turn("Prima", reply: "Uno") + Self.turn("Domanda vera", reply: "Risposta")
        #expect(ZenCODEACPBridge.promptDisplayTexts(
            restoring: Self.savedSession(history: history, transcriptHistory: longer)
        ).isEmpty)
        #expect(ZenCODEACPBridge.promptDisplayTexts(
            restoring: Self.savedSession(history: history, transcriptHistory: history)
        ).isEmpty)
    }
}
