import Foundation
import Testing
import ToolCore
@testable import ZenCODECore

extension TerminalChatRenderCoordinatorTests {
    @Test
    func markdownMessageCanRenderOnStandardErrorForOperatorCommands() async {
        let renderer = makeRenderer(standardErrorIsTerminal: false)

        await renderer.writeMarkdownMessage(
            "**Artifacts**\n\n```swift\nlet value = 1\n```\n",
            to: .standardError
        )

        let events = await renderer.capturedWriteEvents()
        #expect(!events.isEmpty)
        #expect(events.allSatisfy { $0.channel == .standardError })
        #expect(events.renderedText().contains("let value = 1"))
    }

    @Test(arguments: ["thought", "assistant", "tool"])
    func liveArtifactsInterruptStreamingAndToolsBeforeDeferredOverviews(_ active: String) async throws {
        let renderer = makeRenderer(
            standardErrorIsTerminal: true, standardOutputIsTerminal: true,
            columnWidthProvider: { 100 }
        )
        let call = presentedToolCall(
            id: "artifact-interleave", name: "local.exec",
            argumentsObject: ["command": "work"], argumentsJSON: "{}"
        )
        switch active {
        case "thought": await renderer.writeThought("thinking before artifact")
        case "assistant": await renderer.writeAssistantContent("assistant before artifact")
        default: await renderer.writeToolCallStarted(call)
        }
        let deferred = await renderer.renderTaskGraphOverview(
            signature: "artifact-graph", markdown: "## Deferred artifact overview\n"
        )
        #expect(deferred == .deferred)
        let artifacts = FileChangeArtifactMapper.artifacts(
            from: [.init(path: "Example.swift", oldText: "let x = 1\n", newText: "let x = 2\n")],
            workingDirectory: URL(fileURLWithPath: "/tmp")
        )
        await renderer.writeMarkdownMessage(
            TerminalChat.renderFileArtifacts(
                [.init(number: 1, artifacts: artifacts)], includeHistoryHeadings: false
            ),
            to: .standardError,
            preservingStreamingContext: true
        )
        let afterArtifact = await renderer.capturedWriteEvents()
        let output = afterArtifact.plainText()
        let artifactStart = try #require(output.range(of: "modified Example.swift"))
        let source = try #require(output.range(of: "let x = 2"))
        let overview = try #require(output.range(of: "Deferred artifact overview"))
        #expect(artifactStart.lowerBound < source.lowerBound)
        #expect(source.lowerBound < overview.lowerBound)
        #expect(!output.contains("🪬 Artifacts"))
        #expect(!output.contains("Turn 1 —"))
        #expect(output.contains("1 │ -let x = 1"))
        #expect(output.contains("1 │ +let x = 2"))
        let snapshot = await renderer.snapshot()
        #expect(snapshot.isStreamingThoughtOutput == (active == "thought"))
        #expect(snapshot.activeToolCallID == nil)
        #expect(!snapshot.deferredTaskGraphOverviewRender)
        if active == "tool" {
            await renderer.writeToolCallCompleted(call, result: .init(output: "done", summary: "done"))
        } else {
            if active == "thought" {
                await renderer.writeThought("thinking after artifact")
            } else {
                await renderer.writeAssistantContent("assistant after artifact")
            }
            await renderer.finishStreamingOutput()
        }
        let continuation = await renderer.capturedText(droppingFirst: afterArtifact.count)
        #expect(!containsCursorUpSequence(continuation))
        #expect(!continuation.contains("🪬 Artifacts"))
        #expect(!continuation.contains("let x = 2"))
    }
}
