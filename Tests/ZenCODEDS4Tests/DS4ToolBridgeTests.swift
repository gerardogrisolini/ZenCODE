//
//  DS4ToolBridgeTests.swift
//  ZenCODE
//

#if ZENCODE_LOCAL_DS4
import Foundation
import ZenCODECore
import Testing
@testable import zen

@Suite
struct DS4ToolBridgeTests {
    @Test
    func parsesPrimaryDSMLSyntax() {
        let text = """
        Sure, running it.
        <｜DSML｜tool_calls>
        <｜DSML｜invoke name="read_file">
        <｜DSML｜parameter name="path" string="true">/tmp/a.txt</｜DSML｜parameter>
        <｜DSML｜parameter name="limit" string="false">10</｜DSML｜parameter>
        </｜DSML｜invoke>
        </｜DSML｜tool_calls>
        """
        let parsed = DS4ToolBridge.parseGeneratedMessage(text, requireThinkingClosed: false)
        #expect(parsed.parseError == nil)
        #expect(parsed.replayText == "Sure, running it.")
        #expect(parsed.toolCalls.count == 1)
        let call = parsed.toolCalls[0]
        #expect(call.name == "read_file")
        #expect(call.argumentsObject["path"] == AnyHashable("/tmp/a.txt"))
        #expect(call.argumentsJSON.contains("\"path\":\"/tmp/a.txt\""))
        #expect(call.argumentsJSON.contains("\"limit\":10"))
    }

    @Test
    func parsesPlainTagSyntaxVariant() {
        let text = """
        <tool_calls>
        <invoke name="list">
        <parameter name="all" string="false">true</parameter>
        </invoke>
        </tool_calls>
        """
        let parsed = DS4ToolBridge.parseGeneratedMessage(text, requireThinkingClosed: false)
        #expect(parsed.parseError == nil)
        #expect(parsed.toolCalls.count == 1)
        #expect(parsed.toolCalls[0].name == "list")
        #expect(parsed.toolCalls[0].argumentsObject["all"] == AnyHashable(true))
    }

    @Test
    func returnsNoToolCallsForPlainText() {
        let parsed = DS4ToolBridge.parseGeneratedMessage("just an answer", requireThinkingClosed: false)
        #expect(parsed.parseError == nil)
        #expect(parsed.toolCalls.isEmpty)
        #expect(parsed.replayText == "just an answer")
    }

    @Test
    func requiresThinkingClosedBeforeScanningToolCalls() {
        let text = """
        <think>plan <｜DSML｜tool_calls> inside reasoning
        """
        let parsed = DS4ToolBridge.parseGeneratedMessage(text, requireThinkingClosed: true)
        // The tool_calls marker appears before any </think>, so it must be ignored.
        #expect(parsed.toolCalls.isEmpty)
        #expect(parsed.parseError == nil)
    }

    @Test
    func scansToolCallsAfterThinkingClosed() {
        let text = """
        <think>reasoning</think>
        <｜DSML｜tool_calls>
        <｜DSML｜invoke name="noop">
        </｜DSML｜invoke>
        </｜DSML｜tool_calls>
        """
        let parsed = DS4ToolBridge.parseGeneratedMessage(text, requireThinkingClosed: true)
        #expect(parsed.parseError == nil)
        #expect(parsed.toolCalls.count == 1)
        #expect(parsed.toolCalls[0].name == "noop")
    }

    @Test
    func reportsParseErrorForMalformedInvoke() {
        let text = """
        <｜DSML｜tool_calls>
        <｜DSML｜invoke name="broken">
        <｜DSML｜parameter name="path" string="true">/tmp/a.txt
        </｜DSML｜invoke>
        </｜DSML｜tool_calls>
        """
        let parsed = DS4ToolBridge.parseGeneratedMessage(text, requireThinkingClosed: false)
        #expect(parsed.parseError != nil)
        #expect(parsed.toolCalls.isEmpty)
    }

    @Test
    func unescapesEntitiesInStringParameters() {
        let text = """
        <｜DSML｜tool_calls>
        <｜DSML｜invoke name="run">
        <｜DSML｜parameter name="cmd" string="true">a &amp;&amp; b &gt; c</｜DSML｜parameter>
        </｜DSML｜invoke>
        </｜DSML｜tool_calls>
        """
        let parsed = DS4ToolBridge.parseGeneratedMessage(text, requireThinkingClosed: false)
        #expect(parsed.parseError == nil)
        #expect(parsed.toolCalls[0].argumentsObject["cmd"] == AnyHashable("a && b > c"))
    }

    @Test
    func renderRoundTripsThroughParser() {
        let toolCalls = [
            AgentRuntimeToolCall(
                id: "call_1",
                name: "read_file",
                argumentsJSON: "{\"path\":\"/tmp/a.txt\",\"limit\":5}"
            )
        ]
        let rendered = DS4ToolBridge.renderToolCalls(toolCalls)
        let parsed = DS4ToolBridge.parseGeneratedMessage(rendered, requireThinkingClosed: false)
        #expect(parsed.parseError == nil)
        #expect(parsed.toolCalls.count == 1)
        #expect(parsed.toolCalls[0].name == "read_file")
        #expect(parsed.toolCalls[0].argumentsObject["path"] == AnyHashable("/tmp/a.txt"))
        #expect(parsed.toolCalls[0].argumentsJSON.contains("\"limit\":5"))
    }
}
#endif
