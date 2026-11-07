//
//  AgentToolCompactRenderingTests.swift
//  ZenCODE
//
//  Compact-rendering coverage for the `agent.*` delegation tools. Compact rows
//  show the canonical tool name on the title line followed by the resolved
//  target on the status line; semantic target extraction is shared with the
//  expanded and ACP presentations.
//

import Foundation
import Testing
import ToolCore
@testable import ZenCODECore

extension TerminalChatRenderingTests {
    // MARK: - agent.message

    @Test
    func agentMessageCompactRenderingShowsRecipientAndMessage() {
        let toolCall = presentedToolCall(
            id: "msg",
            name: "agent.message",
            argumentsObject: [
                "name": "worker",
                "message": "fix the tests"
            ],
            argumentsJSON: "{}"
        )

        #expect(
            ToolCallPresentation.displayToolTarget(for: toolCall) == "worker: fix the tests"
        )

        let lines = TerminalChat.compactToolLines(
            for: toolCall,
            statusIcon: "✅",
            contentInsetWidth: 0
        )

        #expect(lines == ["🛠️  agent.message", "worker: fix the tests ✅"])
    }

    @Test
    func agentMessageCompactRenderingCollapsesMultilineMessage() {
        let toolCall = presentedToolCall(
            id: "msg",
            name: "agent.message",
            argumentsObject: [
                "name": "worker",
                "message": "fix the\ntests now"
            ],
            argumentsJSON: "{}"
        )

        // The raw target preserves the embedded newline; the status line
        // collapses whitespace (including newlines) into single spaces.
        #expect(
            ToolCallPresentation.displayToolTarget(for: toolCall) == "worker: fix the\ntests now"
        )

        let lines = TerminalChat.compactToolLines(
            for: toolCall,
            statusIcon: "✅",
            contentInsetWidth: 0
        )

        #expect(lines == ["🛠️  agent.message", "worker: fix the tests now ✅"])
    }

    // MARK: - agent.create (single form)

    @Test
    func agentCreateSingleFormShowsNameAndPrompt() {
        let toolCall = presentedToolCall(
            id: "create",
            name: "agent.create",
            argumentsObject: [
                "name": "worker",
                "prompt": "fix the tests"
            ],
            argumentsJSON: "{}"
        )

        #expect(
            ToolCallPresentation.displayToolTarget(for: toolCall) == "worker fix the tests"
        )

        let lines = TerminalChat.compactToolLines(
            for: toolCall,
            statusIcon: "✅",
            contentInsetWidth: 0
        )

        #expect(lines == ["🛠️  agent.create", "worker fix the tests ✅"])
    }

    // MARK: - agent.create (batch `agents` form)

    @Test
    func agentCreateBatchFormJoinsAgentNames() {
        let toolCall = presentedToolCall(
            id: "create",
            name: "agent.create",
            argumentsObject: [
                "agents": [
                    ["name": "worker", "prompt": "fix the tests"],
                    ["name": "builder", "prompt": "build it"]
                ]
            ],
            argumentsJSON: "{}"
        )

        #expect(
            ToolCallPresentation.displayToolTarget(for: toolCall) == "worker, builder"
        )

        let lines = TerminalChat.compactToolLines(
            for: toolCall,
            statusIcon: "✅",
            contentInsetWidth: 0
        )

        #expect(lines == ["🛠️  agent.create", "worker, builder ✅"])
    }

    @Test
    func agentCreateBatchFormFallsBackToCountWithoutNames() {
        let toolCall = presentedToolCall(
            id: "create",
            name: "agent.create",
            argumentsObject: [
                "agents": [
                    ["role": "worker"],
                    ["role": "builder"]
                ]
            ],
            argumentsJSON: "{}"
        )

        #expect(
            ToolCallPresentation.displayToolTarget(for: toolCall) == "2 agents"
        )
    }

    // MARK: - Other agent.* tools

    @Test
    func agentGetCompactRenderingShowsAgentName() {
        let toolCall = presentedToolCall(
            id: "get",
            name: "agent.get",
            argumentsObject: ["name": "worker"],
            argumentsJSON: "{}"
        )

        #expect(
            ToolCallPresentation.displayToolTarget(for: toolCall) == "worker"
        )

        let lines = TerminalChat.compactToolLines(
            for: toolCall,
            statusIcon: "✅",
            contentInsetWidth: 0
        )

        #expect(lines == ["🛠️  agent.get", "worker ✅"])
    }

    // MARK: - Multi-recipient ids forms, status, precedence

    @Test
    func agentWaitWithIdsArrayJoinsIdentifiers() {
        let toolCall = presentedToolCall(
            id: "wait",
            name: "agent.wait",
            argumentsObject: ["ids": ["agent-1", "agent-2"]],
            argumentsJSON: "{}"
        )

        #expect(
            ToolCallPresentation.displayToolTarget(for: toolCall) == "agent-1, agent-2"
        )
    }

    @Test
    func agentMessageDeduplicatesOverlappingScalarAndArrayIdentifiers() {
        // When the scalar id also appears in the array, the duplicate is
        // dropped (matches the runtime dedupe).
        let toolCall = presentedToolCall(
            id: "msg",
            name: "agent.message",
            argumentsObject: [
                "id": "agent-1",
                "ids": ["agent-1", "agent-2"],
                "message": "go"
            ],
            argumentsJSON: "{}"
        )

        #expect(
            ToolCallPresentation.displayToolTarget(for: toolCall) == "agent-1, agent-2: go"
        )
    }

    @Test
    func agentListRendersStatusFilterAsTarget() {
        let toolCall = presentedToolCall(
            id: "list",
            name: "agent.list",
            argumentsObject: ["status": "idle"],
            argumentsJSON: "{}"
        )

        #expect(
            ToolCallPresentation.displayToolTarget(for: toolCall) == "idle"
        )

        let lines = TerminalChat.compactToolLines(
            for: toolCall,
            statusIcon: "✅",
            contentInsetWidth: 0
        )

        #expect(lines == ["🛠️  agent.list", "idle ✅"])
    }

    // MARK: - Non-agent descriptor contract

    @Test
    func nonAgentToolsUseTheirOwnedTargetDefinition() {
        let toolCall = presentedToolCall(
            id: "read",
            name: "local.readFile",
            argumentsObject: ["path": "Sources/App.swift"],
            argumentsJSON: "{}"
        )

        #expect(
            ToolCallPresentation.displayToolTarget(for: toolCall) == "Sources/App.swift"
        )
    }
}
