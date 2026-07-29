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

    static let toolDescriptors: [DirectToolDescriptor] = [
        DirectToolDescriptor(
            name: "agent.create",
            description: "Creates up to 8 delegated sub-agents; independent sub-agents run in parallel. For coordinated work, define the session task graph first and pass taskID to atomically claim each runnable task and record a fenced execution attempt. A taskID is required while a task graph is active and for parallel or concurrent delegation when task workflow tools are available. A single self-contained delegation may omit taskID. Agent selection policy: \(TaskRecord.agentSelectionPolicy) Pass profile (or agent) to run the sub-agent with one of the agent profiles from agents.json, matched by name, role, or profile. When a profile has model bindings, pass model/modelID only to select one of that profile's authorized bindings; an unbound model is rejected. Otherwise the sub-agent uses the session's model. Give each sub-agent an explicit role and scope. A resolved profile grants its configured tools to the sub-agent, and toolNames can only narrow that grant. Only when no profile resolves does the sub-agent inherit the parent session's enabled tools, again narrowed by toolNames. Task-bound children also receive intrinsic tasks.list, tasks.get, and tasks.update tools for attempt reporting.",
            inputSchema: #"{"type":"object","properties":{"name":{"type":"string"},"role":{"type":"string"},"profile":{"type":"string"},"agent":{"type":"string"},"model":{"type":"string"},"modelID":{"type":"string"},"model_id":{"type":"string"},"taskID":{"type":"string"},"task_id":{"type":"string"},"prompt":{"type":"string"},"message":{"type":"string"},"toolNames":{"type":"array","items":{"type":"string"}},"agents":{"type":"array","maxItems":8,"items":{"type":"object","properties":{"name":{"type":"string"},"role":{"type":"string"},"profile":{"type":"string"},"agent":{"type":"string"},"model":{"type":"string"},"modelID":{"type":"string"},"model_id":{"type":"string"},"taskID":{"type":"string"},"task_id":{"type":"string"},"prompt":{"type":"string"},"message":{"type":"string"},"toolNames":{"type":"array","items":{"type":"string"}}}}},"items":{"type":"array","items":{"type":"object"}}}}"#,
            presentation: ToolPresentationDefinition(
                title: "Agent",
                action: "Create",
                kind: .create,
                target: .firstAvailable([agentCreateBatch, agentCreateSingle]),
                sections: [.parameters()],
                summary: ToolPresentationSummaryDefinition(value: .resultSummary(), strategy: .firstLine, label: "summary")
            )
        ),
        DirectToolDescriptor(
            name: "agent.list",
            description: "Lists delegated sub-agents, optionally filtered by status.",
            inputSchema: #"{"type":"object","properties":{"status":{"type":"string"}}}"#,
            presentation: .standard(title: "Agents", action: "List", kind: .read, targetKeyPaths: ["status"])
        ),
        DirectToolDescriptor(
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
        ),
        DirectToolDescriptor(
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
        ),
        DirectToolDescriptor(
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
        ),
        DirectToolDescriptor(
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
    ]
}
