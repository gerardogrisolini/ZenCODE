//
//  DirectSubAgentToolDescriptors.swift
//  ZenCODE
//
//  Created by Gerardo Grisolini on 30/05/26.
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

    /// Quoted, comma-separated `AgentProfileRole` raw values for the `profileRole`
    /// enum, so the schema cannot drift from the role list.
    private static let agentCreateProfileRoleEnum = AgentProfileRole.allCases
        .map { "\"\($0.rawValue)\"" }
        .joined(separator: ",")

    /// Provider-neutral model-visible contract. A single batch shape avoids
    /// `oneOf`/`not`, which different remote APIs normalize inconsistently.
    /// Root calls and aliases remain accepted only by the compatibility parser.
    /// Neither `profile` nor `profileRole` is schema-required: the runtime
    /// enforces that exactly one of them is present.
    private static let agentCreateItemSchema = #"{"type":"object","properties":{"profile":{"type":"string","description":"Exact profile name from the delegatable roster."},"model":{"type":"string","description":"Exact binding:... reference from the selected profile when it has configured bindings. Otherwise omit model to inherit the main session model."},"taskID":{"type":"string","description":"Task ID returned by tasks.create/tasks.list. Put it in this agents item, never at the agent.create root."},"prompt":{"type":"string"},"name":{"type":"string"},"role":{"type":"string"},"profileRole":{"type":"string","enum":[\#(agentCreateProfileRoleEnum)],"description":"Delegate by role: the runtime resolves the profile associated with the sub-agent's working directory and selects its model binding from complexity. Exclusive with profile; never combine with model."},"complexity":{"type":"integer","minimum":1,"maximum":10,"description":"Difficulty 1-10. \#(TaskRecord.complexityRubric). Required with profileRole unless taskID is set; a task's complexity takes precedence."},"workingDirectory":{"type":"string","description":"Optional. Directory the sub-agent works in: absolute or relative to the coordinator's working directory; must be an existing directory inside it. Omit to inherit the coordinator's working directory. Files, shell, git, project memory, and project-agent association follow this directory."}},"additionalProperties":false}"#

    private static let agentCreateSchema = #"{"type":"object","properties":{"agents":{"type":"array","minItems":1,"maxItems":8,"items":\#(agentCreateItemSchema)}},"required":["agents"],"additionalProperties":false}"#

    private static let createDescriptor = DirectToolDescriptor(
            name: "agent.create",
            description: "Creates 1–8 delegated sub-agents from the exact profile and binding references in the delegatable roster. Use only the canonical agents array; each item requires exactly one of profile or profileRole. If the profile has configured bindings, model is required; otherwise omit model to inherit the main session model and provider. For graph work, put the task ID returned by tasks.create/tasks.list in that item's taskID field; taskID is never a root argument. Independent items run in parallel. A task-bound item claims its task atomically, and the child receives tasks.list, tasks.get, and tasks.update for attempt reporting. Different profiles retain their own tool grant; a child resolved to the coordinator's same profile inherits the coordinator's effective session allowlist. Child-intrinsic skills, collaboration, and applicable task-reporting tools are added automatically. Legacy root fields and aliases remain input-compatible but are intentionally not model-visible.",
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
            description: "Sends a live shared-chat message: the standard channel to coordinate with the operator, the coordinator, and delegated agents. Use id/name/ids for direct delivery, or set `to` to operator, coordinator, peers, or all. `operator` replies directly to the human terminal operator; `all` broadcasts to the operator, coordinator, and every active agent. `target` remains a compatibility alias. Direct messages wake idle or standby recipients immediately. Use the chat to clarify, steer, and query agents, including standby ones; after a task attempt closes the agent stays in standby and can answer in chat, but new implementation work needs tasks.retry and a new canonical agent.create item containing `taskID`. Sub-agents with an ambiguity or a decision outside their brief should message `coordinator` with `awaitReply` true (optional `replyTimeoutSeconds`) to keep the call open until the reply arrives, instead of proceeding on assumptions.",
            inputSchema: #"{"type":"object","properties":{"id":{"type":"string"},"name":{"type":"string"},"task_id":{"type":"string"},"ids":{"type":"array","items":{"type":"string"}},"to":{"type":"string","enum":["direct","operator","coordinator","peers","all"]},"target":{"type":"string","enum":["direct","operator","coordinator","peers","all"],"description":"Compatibility alias for to."},"message":{"type":"string"},"prompt":{"type":"string"},"input":{"type":"string"},"awaitReply":{"type":"boolean","description":"Sub-agents only. Blocks until a live reply arrives, then returns it."},"replyTimeoutSeconds":{"type":"number","description":"Maximum seconds to wait with awaitReply (default 600, range 1-900)."}},"required":["message"]}"#,
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
            description: "Waits until delegated sub-agents finish their pending work or a timeout elapses; returns early when live chat messages are waiting for you; reply with agent.message, then call agent.wait again.",
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
