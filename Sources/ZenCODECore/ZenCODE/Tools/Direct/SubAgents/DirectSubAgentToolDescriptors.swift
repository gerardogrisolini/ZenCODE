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

    /// Provider-neutral model-visible contract. A single batch shape avoids
    /// `oneOf`/`not`, which different remote APIs normalize inconsistently.
    /// Root calls and aliases remain accepted only by the compatibility parser.
    private static let agentCreateItemSchema = #"{"type":"object","properties":{"profile":{"type":"string","description":"Exact profile name from the delegatable roster."},"model":{"type":"string","description":"Exact binding:... reference from the selected profile."},"taskID":{"type":"string"},"prompt":{"type":"string"},"name":{"type":"string"},"role":{"type":"string"}},"required":["profile","model"],"additionalProperties":false}"#

    private static let agentCreateSchema = #"{"type":"object","properties":{"agents":{"type":"array","minItems":1,"maxItems":8,"items":\#(agentCreateItemSchema)}},"required":["agents"],"additionalProperties":false}"#

    private static let createDescriptor = DirectToolDescriptor(
            name: "agent.create",
            description: "Creates 1–8 delegated sub-agents from the exact profile and binding references in the delegatable roster. Use only the canonical agents array; each item requires profile and model. Independent items run in parallel. Pass taskID for coordinated graph work so the task is claimed atomically; task-bound children receive tasks.list, tasks.get, and tasks.update for attempt reporting. The selected profile owns the child tool grant. Legacy root fields and aliases remain input-compatible but are intentionally not model-visible.",
            inputSchema: agentCreateSchema,
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
            description: "Sends a live shared-chat message. Use id/name/ids for direct delivery, or set `to` to coordinator, peers, or all. `all` broadcasts to the coordinator and every active agent. `target` remains a compatibility alias. Direct messages wake idle or standby recipients immediately. After completing your task attempt you remain in standby while the task graph is active: you can receive and reply to messages from the coordinator and peers. For code corrections after negative validation, use tasks.retry then a new agent.create(taskID:) instead of messaging.",
            inputSchema: #"{"type":"object","properties":{"id":{"type":"string"},"name":{"type":"string"},"task_id":{"type":"string"},"ids":{"type":"array","items":{"type":"string"}},"to":{"type":"string","enum":["direct","coordinator","peers","all"]},"target":{"type":"string","enum":["direct","coordinator","peers","all"],"description":"Compatibility alias for to."},"message":{"type":"string"},"prompt":{"type":"string"},"input":{"type":"string"}},"required":["message"]}"#,
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
