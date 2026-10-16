import Testing
@testable import ZenCODECore

@Suite
struct TerminalAssistantResponseBufferTests {
    @Test
    func toolBoundaryDrainsOnlyCommentaryAndFinalContentDoesNotReplayIt() async {
        let buffer = TerminalAssistantResponseBuffer()
        await buffer.append("Preparing ")
        await buffer.append("edits")
        #expect(await buffer.takePending() == "Preparing edits")
        #expect(await buffer.takePending().isEmpty)
        await buffer.append("**Final ")
        await buffer.append("answer**")
        #expect(await buffer.finalContent(fallback: "Preparing edits**Final answer**") == "**Final answer**")
        #expect(await buffer.takePending().isEmpty)
    }

    @Test
    func nonStreamingResponseUsesFallbackButToolOnlyTailDoesNotReplayCommentary() async {
        let buffer = TerminalAssistantResponseBuffer()
        #expect(await buffer.finalContent(fallback: "Non-streamed answer") == "Non-streamed answer")
        await buffer.append("Commentary before tool")
        #expect(await buffer.takePending() == "Commentary before tool")
        #expect(await buffer.finalContent(fallback: "Commentary before tool").isEmpty)
    }

    @Test
    func interruptedTurnCanDrainPartialMarkdownExactlyOnce() async {
        let buffer = TerminalAssistantResponseBuffer()
        await buffer.append("Partial **answer")
        #expect(await buffer.takePending() == "Partial **answer")
        #expect(await buffer.takePending().isEmpty)
    }
}
