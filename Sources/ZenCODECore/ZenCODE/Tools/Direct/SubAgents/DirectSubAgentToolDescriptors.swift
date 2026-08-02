//
//  DirectSubAgentToolDescriptors.swift
//  ZenCODE
//

import Foundation
import ToolCore

extension DirectSubAgentRuntime {
    private static let agentIdentifier = ToolPresentationValueDefinition.collected([
        .argument(["id", "agentID", "agent_id", "taskID", "task_id", "name", "agent"]),
        .collectedArguments(["ids", "agentIDs", "agent_ids", "names"])
    ],
        separator: ", "
    )

    private static let agentMessage = ToolPresentationValueDefinition.firstAvailable([
        .argument(["message", "prompt", "input"])
    ])

    private static let agentCreateBatch = ToolPresentationValueDefinition.firstAvailable([
        .itemArguments(
            ["agents", "items"],
            itemKeyPaths: ["name", "title", "agent", "agentName", "agent_name", "agentID", "agent_id", "profile", "profileName", "profile_name"],
            separator: ", "
        ),
        ToolPresentationValueDefinition(
            source: .arguments,
            keyPaths: ["agents", "items"],
            format: .itemCount,
            suffix: " agents"
        )
    ])

    private static let agentCreateSingle = ToolPresentationValueDefinition.joined([
        .argument(["name", "title", "agent", "agentName", "agent_name", "agentID", "agent_id", "profile", "profileName", "profile_name"]),
        .argument(["prompt", "message", "initialPrompt", "initial_prompt"])
    ], separator: " ")

    private static let createDescriptor = DirectToolDescriptor(
            name: "agent.create",
            description: "Creates up to 8 delegated sub-agents; independent sub-agents run in parallel. Prefer delegation for non-trivial, cleanly scoped work when a compatible configured profile has the required tools; use the coordinator directly only when delegation offers no meaningful benefit or no compatible profile can perform the work. For coordinated work, define the session task graph first and pass taskID to atomically claim each runnable task and record a fenced execution attempt. A taskID is required while a task graph is active and for parallel or concurrent delegation when task workflow tools are available. A single self-contained delegation may omit taskID. Agent selection policy: \(TaskRecord.agentSelectionPolicy) Pass profile (or agent) to select one configured agent profile from agents.json; the request is rejected when that profile does not resolve. The sub-agent receives the tools configured on that profile. When a profile has model bindings, pass model/modelID only to select one of its authorized bindings; an unbound model is rejected. Otherwise the sub-agent uses the session's model. Give each sub-agent an explicit role and scope. Task-bound children also receive intrinsic tasks.list, tasks.get, and tasks.update tools for attempt reporting.",
            inputSchema: #"{"type":"object","properties":{"name":{"type":"string"},"role":{"type":"string"},"profile":{"type":"string"},"agent":{"type":"string"},"model":{"type":"string"},"modelID":{"type":"string"},"model_id":{"type":"string"},"taskID":{"type":"string"},"task_id":{"type":"string"},"prompt":{"type":"string"},"message":{"type":"string"},"agents":{"type":"array","maxItems":8,"items":{"type":"object","properties":{"name":{"type":"string"},"role":{"type":"string"},"profile":{"type":"string"},"agent":{"type":"string"},"model":{"type":"string"},"modelID":{"type":"string"},"model_id":{"type":"string"},"taskID":{"type":"string"},"task_id":{"type":"string"},"prompt":{"type":"string"},"message":{"type":"string"}}}},"items":{"type":"array","items":{"type":"object"}}}}"#,
            presentation: ToolPresentationDefinition(
                title: "Agent",
                action: "Create",
                kind: .create,
                target: .firstAvailable([agentCreateBatch, agentCreateSingle]),
                sections: [.parameters()],
                summary: ToolPresentationSummaryDefinition(value: .resultSummary(), strategy: .firstLine, label: "summary")
            )
        )

    private static let listDescriptor = DirectToolDescriptor(
            name: "agent.list",
            description: "Lists delegated sub-agents, optionally filtered by status.",
            inputSchema: #"{"type":"object","properties":{"status":{"type":"string"}}}"#,
            presentation: .standard(title: "Agents", action: "List", kind: .read, targetKeyPaths: ["status"])
        )

    private static let getDescriptor = DirectToolDescriptor(
            name: "agent.get",
            description: "Returns status and latest output for delegated sub-agents. Reference an agent by id, name, task_id, or ids.",
            inputSchema: #"{"type":"object","properties":{"id":{"type":"string"},"name":{"type":"string"},"task_id":{"type":"string"},"ids":{"type":"array","items":{"type":"string"}}}}"#,
            presentation: ToolPresentationDefinition(
                title: "Agent",
                action: "Get",
                kind: .read,
                target: agentIdentifier,
                sections: [.parameters()],
                summary: ToolPresentationSummaryDefinition(value: .resultSummary(), strategy: .firstLine, label: "summary")
            )
        )

    private static let messageDescriptor = DirectToolDescriptor(
            name: "agent.message",
            description: "Queues a follow-up prompt for one or more delegated sub-agents. Reference an agent by id, name, task_id, or ids. Do not use it to reopen a completed /workflow task: record negative validation as failure, call tasks.retry, then use a new agent.create(taskID:).",
            inputSchema: #"{"type":"object","properties":{"id":{"type":"string"},"name":{"type":"string"},"task_id":{"type":"string"},"ids":{"type":"array","items":{"type":"string"}},"message":{"type":"string"},"prompt":{"type":"string"},"input":{"type":"string"}},"required":["message"]}"#,
            presentation: ToolPresentationDefinition(
                title: "Agent",
                action: "Message",
                kind: .communicate,
                target: .joined([agentIdentifier, agentMessage], separator: ": "),
                sections: [.parameters()],
                summary: ToolPresentationSummaryDefinition(value: .resultSummary(), strategy: .firstLine, label: "summary")
            )
        )

    private static let waitDescriptor = DirectToolDescriptor(
            name: "agent.wait",
            description: "Waits until delegated sub-agents finish their pending work or a timeout elapses.",
            inputSchema: #"{"type":"object","properties":{"id":{"type":"string"},"name":{"type":"string"},"task_id":{"type":"string"},"ids":{"type":"array","items":{"type":"string"}},"timeoutSeconds":{"type":"number"},"pollIntervalSeconds":{"type":"number"}}}"#,
            presentation: ToolPresentationDefinition(
                title: "Agent",
                action: "Wait",
                kind: .read,
                target: agentIdentifier,
                sections: [.parameters()],
                summary: ToolPresentationSummaryDefinition(value: .resultSummary(), strategy: .firstLine, label: "summary")
            )
        )

    private static let closeDescriptor = DirectToolDescriptor(
            name: "agent.close",
            description: "Closes a delegated sub-agent and cancels pending work.",
            inputSchema: #"{"type":"object","properties":{"id":{"type":"string"},"name":{"type":"string"},"task_id":{"type":"string"}}}"#,
            presentation: ToolPresentationDefinition(
                title: "Agent",
                action: "Close",
                kind: .delete,
                target: agentIdentifier,
                sections: [.parameters()],
                summary: ToolPresentationSummaryDefinition(value: .resultSummary(), strategy: .firstLine, label: "summary")
            )
        )

    static let readOnlyToolDescriptors: [DirectToolDescriptor] = [
        listDescriptor,
        getDescriptor,
        waitDescriptor
    ]

    static let mutatingToolDescriptors: [DirectToolDescriptor] = [
        createDescriptor,
        messageDescriptor,
        closeDescriptor
    ]

    static let toolDescriptors: [DirectToolDescriptor] = [
        createDescriptor,
        listDescriptor,
        getDescriptor,
        messageDescriptor,
        waitDescriptor,
        closeDescriptor
    ]
}
