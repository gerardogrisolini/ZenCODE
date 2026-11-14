import Foundation
import Testing
import ToolCore
@testable import ZenCODECore

extension TerminalChatRenderCoordinatorTests {

    @Test
    func onlyTheAssistantStreamExtendsCodeBackgroundsWithEraseToEndOfLine() async {
        let renderer = makeRenderer(
            standardErrorIsTerminal: true, standardOutputIsTerminal: true,
            columnWidthProvider: { 100 }
        )
        let flags = await renderer.codeBlockEraseFlags
        #expect(flags.assistant)
        #expect(!flags.thought)
    }
}

private extension TerminalChatRenderCoordinator {
    /// Reads the actor-isolated streaming formatters for the wiring assertions.
    var codeBlockEraseFlags: (assistant: Bool, thought: Bool) {
        (
            assistantStreamingState.markdownFormatter.codeBlocksUseEraseToEndOfLine,
            thoughtStreamingState.markdownFormatter.codeBlocksUseEraseToEndOfLine
        )
    }
}
