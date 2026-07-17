//
//  AgentToolCompactRenderingTests.swift
//  ZenCODE
//
//  Compact-rendering coverage for the `agent.*` delegation tools. These tools
//  were previously invisible in compact mode (no target line) because their
//  significant arguments (`message`, agent `name`/`profile`, the `agents`
//  batch array) are not part of the generic file-path/command fallback.
//

import Foundation
import Testing
@testable import ZenCODECore

extension TerminalChatRenderingTests {
    // MARK: - agent.message

    @Test
    func agentMessageCompactRenderingShowsRecipientAndMessage() {
        let toolCall = DirectAgentToolCall(
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

        #expect(lines == [
            "🛠️  agent.message:",
            "worker: fix the tests ✅"
        ])
    }

    @Test
    func agentMessageCompactRenderingCollapsesMultilineMessage() {
        let toolCall = DirectAgentToolCall(
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

        #expect(lines == [
            "🛠️  agent.message:",
            "worker: fix the tests now ✅"
        ])
    }

    @Test
    func agentMessageWithoutRecipientShowsMessageOnly() {
        let toolCall = DirectAgentToolCall(
            id: "msg",
            name: "agent.message",
            argumentsObject: ["message": "please review the diff"],
            argumentsJSON: "{}"
        )

        #expect(
            ToolCallPresentation.displayToolTarget(for: toolCall) == "please review the diff"
        )

        let lines = TerminalChat.compactToolLines(
            for: toolCall,
            statusIcon: "⏳",
            contentInsetWidth: 0
        )

        #expect(lines == [
            "🛠️  agent.message:",
            "please review the diff ⏳"
        ])
    }

    @Test
    func agentMessagePrefersMessageOverPromptAndInput() {
        let toolCall = DirectAgentToolCall(
            id: "msg",
            name: "agent.message",
            argumentsObject: [
                "message": "primary message",
                "prompt": "fallback prompt",
                "input": "fallback input"
            ],
            argumentsJSON: "{}"
        )

        #expect(
            ToolCallPresentation.displayToolTarget(for: toolCall) == "primary message"
        )
    }

    // MARK: - agent.create (single form)

    @Test
    func agentCreateSingleFormShowsNameAndPrompt() {
        let toolCall = DirectAgentToolCall(
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

        #expect(lines == [
            "🛠️  agent.create:",
            "worker fix the tests ✅"
        ])
    }

    @Test
    func agentCreateSingleFormShowsProfileWhenNameAbsent() {
        let toolCall = DirectAgentToolCall(
            id: "create",
            name: "agent.create",
            argumentsObject: ["profile": "builder", "prompt": "build it"],
            argumentsJSON: "{}"
        )

        #expect(
            ToolCallPresentation.displayToolTarget(for: toolCall) == "builder build it"
        )
    }

    @Test
    func agentCreateSingleFormShowsAgentIdentifierWithoutPrompt() {
        let toolCall = DirectAgentToolCall(
            id: "create",
            name: "agent.create",
            argumentsObject: ["agent": "explorer"],
            argumentsJSON: "{}"
        )

        #expect(
            ToolCallPresentation.displayToolTarget(for: toolCall) == "explorer"
        )
    }

    // MARK: - agent.create (batch `agents` form)

    @Test
    func agentCreateBatchFormJoinsAgentNames() {
        let toolCall = DirectAgentToolCall(
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

        #expect(lines == [
            "🛠️  agent.create:",
            "worker, builder ✅"
        ])
    }

    @Test
    func agentCreateBatchFormAcceptsJSONValueEntries() {
        // The streaming runtime sometimes delivers nested payloads as
        // JSONValue rather than native Swift dictionaries; both shapes must
        // resolve to the same compact target.
        let toolCall = DirectAgentToolCall(
            id: "create",
            name: "agent.create",
            argumentsObject: [
                "agents": [
                    JSONValue.object(["name": .string("worker")]),
                    JSONValue.object(["name": .string("builder")])
                ]
            ],
            argumentsJSON: "{}"
        )

        #expect(
            ToolCallPresentation.displayToolTarget(for: toolCall) == "worker, builder"
        )
    }

    @Test
    func agentCreateBatchFormFallsBackToCountWithoutNames() {
        let toolCall = DirectAgentToolCall(
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

    @Test
    func agentCreateBatchFormUsesItemsKeyAlias() {
        let toolCall = DirectAgentToolCall(
            id: "create",
            name: "agent.create",
            argumentsObject: [
                "items": [
                    ["name": "worker"],
                    ["name": "builder"]
                ]
            ],
            argumentsJSON: "{}"
        )

        #expect(
            ToolCallPresentation.displayToolTarget(for: toolCall) == "worker, builder"
        )
    }

    @Test
    func agentCreateBatchFormUnwrapsJSONValueArrayWrapper() {
        // A batch wrapped directly in `JSONValue.array(...)` is accepted by the
        // runtime; presentation must unwrap it rather than ignore the payload.
        let toolCall = DirectAgentToolCall(
            id: "create",
            name: "agent.create",
            argumentsObject: [
                "agents": JSONValue.array([
                    .object(["name": .string("worker")]),
                    .object(["name": .string("builder")])
                ])
            ],
            argumentsJSON: "{}"
        )

        #expect(
            ToolCallPresentation.displayToolTarget(for: toolCall) == "worker, builder"
        )
    }

    @Test
    func agentCreateBatchFormAppliesNameThenAgentReferencePerElement() {
        // Each batch element applies the same precedence as the single form:
        // explicit name first, then the agent-before-profile reference. An
        // element exposing only an `agent` reference must still be summarized.
        let toolCall = DirectAgentToolCall(
            id: "create",
            name: "agent.create",
            argumentsObject: [
                "agents": [
                    ["name": "worker"],
                    ["agent": "explorer"]
                ]
            ],
            argumentsJSON: "{}"
        )

        #expect(
            ToolCallPresentation.displayToolTarget(for: toolCall) == "worker, explorer"
        )
    }

    // MARK: - Other agent.* tools

    @Test
    func agentGetCompactRenderingShowsAgentName() {
        let toolCall = DirectAgentToolCall(
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

        #expect(lines == [
            "🛠️  agent.get:",
            "worker ✅"
        ])
    }

    @Test
    func agentWaitCompactRenderingShowsAgentID() {
        let toolCall = DirectAgentToolCall(
            id: "wait",
            name: "agent.wait",
            argumentsObject: ["id": "agent-42"],
            argumentsJSON: "{}"
        )

        #expect(
            ToolCallPresentation.displayToolTarget(for: toolCall) == "agent-42"
        )
    }

    @Test
    func agentListWithNoArgumentsRendersSingleLine() {
        let toolCall = DirectAgentToolCall(
            id: "list",
            name: "agent.list",
            argumentsObject: [:],
            argumentsJSON: "{}"
        )

        // `agent.list` legitimately has nothing to show: it falls back to the
        // single-line compact form (no separate target line).
        #expect(ToolCallPresentation.displayToolTarget(for: toolCall) == nil)

        let lines = TerminalChat.compactToolLines(
            for: toolCall,
            statusIcon: "✅",
            contentInsetWidth: 0
        )

        #expect(lines == ["🛠️  agent.list ✅"])
    }

    // MARK: - Multi-recipient ids forms, status, precedence

    @Test
    func agentWaitWithIdsArrayJoinsIdentifiers() {
        let toolCall = DirectAgentToolCall(
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
    func agentMessageCombinesScalarAndArrayIdentifiers() {
        // Mirrors the runtime: the scalar id is combined with the array ids
        // (scalar first), then deduplicated. The recipient summary must include
        // both unique identifiers.
        let toolCall = DirectAgentToolCall(
            id: "msg",
            name: "agent.message",
            argumentsObject: [
                "id": "agent-1",
                "ids": ["agent-2"],
                "message": "go"
            ],
            argumentsJSON: "{}"
        )

        #expect(
            ToolCallPresentation.displayToolTarget(for: toolCall) == "agent-1, agent-2: go"
        )
    }

    @Test
    func agentMessageDeduplicatesOverlappingScalarAndArrayIdentifiers() {
        // When the scalar id also appears in the array, the duplicate is
        // dropped (matches the runtime dedupe).
        let toolCall = DirectAgentToolCall(
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
    func agentGetWithSingleIdArrayShowsIdentifier() {
        let toolCall = DirectAgentToolCall(
            id: "get",
            name: "agent.get",
            argumentsObject: ["ids": ["agent-9"]],
            argumentsJSON: "{}"
        )

        #expect(
            ToolCallPresentation.displayToolTarget(for: toolCall) == "agent-9"
        )
    }

    @Test
    func agentGetWithNamesArrayJoinsIdentifiers() {
        let toolCall = DirectAgentToolCall(
            id: "get",
            name: "agent.get",
            argumentsObject: ["names": ["worker", "builder"]],
            argumentsJSON: "{}"
        )

        #expect(
            ToolCallPresentation.displayToolTarget(for: toolCall) == "worker, builder"
        )
    }

    @Test
    func agentMessageWithNamesArrayIncludesRecipientPrefix() {
        let toolCall = DirectAgentToolCall(
            id: "msg",
            name: "agent.message",
            argumentsObject: [
                "names": ["worker", "builder"],
                "message": "fix the tests"
            ],
            argumentsJSON: "{}"
        )

        #expect(
            ToolCallPresentation.displayToolTarget(for: toolCall) == "worker, builder: fix the tests"
        )

        let lines = TerminalChat.compactToolLines(
            for: toolCall,
            statusIcon: "✅",
            contentInsetWidth: 0
        )

        #expect(lines == [
            "🛠️  agent.message:",
            "worker, builder: fix the tests ✅"
        ])
    }

    @Test
    func agentMessageWithIdsArrayAcceptsJSONValueWrapper() {
        let toolCall = DirectAgentToolCall(
            id: "msg",
            name: "agent.message",
            argumentsObject: [
                "ids": JSONValue.array([.string("agent-1"), .string("agent-2")]),
                "message": "go"
            ],
            argumentsJSON: "{}"
        )

        #expect(
            ToolCallPresentation.displayToolTarget(for: toolCall) == "agent-1, agent-2: go"
        )
    }

    @Test
    func agentCloseCompactRenderingShowsIdentifier() {
        let toolCall = DirectAgentToolCall(
            id: "close",
            name: "agent.close",
            argumentsObject: ["name": "stale-worker"],
            argumentsJSON: "{}"
        )

        #expect(
            ToolCallPresentation.displayToolTarget(for: toolCall) == "stale-worker"
        )

        let lines = TerminalChat.compactToolLines(
            for: toolCall,
            statusIcon: "✅",
            contentInsetWidth: 0
        )

        #expect(lines == [
            "🛠️  agent.close:",
            "stale-worker ✅"
        ])
    }

    @Test
    func agentMessagePrefersPromptOverInput() {
        let toolCall = DirectAgentToolCall(
            id: "msg",
            name: "agent.message",
            argumentsObject: [
                "prompt": "preferred prompt",
                "input": "fallback input"
            ],
            argumentsJSON: "{}"
        )

        #expect(
            ToolCallPresentation.displayToolTarget(for: toolCall) == "preferred prompt"
        )
    }

    @Test
    func agentListRendersStatusFilterAsTarget() {
        let toolCall = DirectAgentToolCall(
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

        #expect(lines == [
            "🛠️  agent.list:",
            "idle ✅"
        ])
    }

    // MARK: - Alias-conflict precedence (aligned with runtime lookup)

    @Test
    func agentWaitPrefersIDOverName() {
        let toolCall = DirectAgentToolCall(
            id: "wait",
            name: "agent.wait",
            argumentsObject: [
                "id": "agent-42",
                "name": "worker"
            ],
            argumentsJSON: "{}"
        )

        #expect(
            ToolCallPresentation.displayToolTarget(for: toolCall) == "agent-42"
        )
    }

    @Test
    func agentMessageRecipientPrefersIDOverName() {
        let toolCall = DirectAgentToolCall(
            id: "msg",
            name: "agent.message",
            argumentsObject: [
                "id": "agent-42",
                "name": "worker",
                "message": "hi"
            ],
            argumentsJSON: "{}"
        )

        #expect(
            ToolCallPresentation.displayToolTarget(for: toolCall) == "agent-42: hi"
        )
    }

    @Test
    func agentCreatePrefersAgentOverProfileWhenNameAbsent() {
        let toolCall = DirectAgentToolCall(
            id: "create",
            name: "agent.create",
            argumentsObject: [
                "agent": "explorer",
                "profile": "builder"
            ],
            argumentsJSON: "{}"
        )

        #expect(
            ToolCallPresentation.displayToolTarget(for: toolCall) == "explorer"
        )
    }

    @Test
    func agentCreatePrefersExplicitNameOverAgentReference() {
        let toolCall = DirectAgentToolCall(
            id: "create",
            name: "agent.create",
            argumentsObject: [
                "name": "worker",
                "agent": "explorer",
                "profile": "builder"
            ],
            argumentsJSON: "{}"
        )

        #expect(
            ToolCallPresentation.displayToolTarget(for: toolCall) == "worker"
        )
    }

    // MARK: - Non-agent tools are unaffected

    @Test
    func nonAgentToolsKeepExistingKeyBasedFallback() {
        let toolCall = DirectAgentToolCall(
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
