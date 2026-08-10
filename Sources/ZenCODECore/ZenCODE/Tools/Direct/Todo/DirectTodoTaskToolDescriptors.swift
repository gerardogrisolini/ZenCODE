//
//  DirectTodoTaskToolDescriptors.swift
//  ZenCODE
//

import Foundation
import ToolCore

extension DirectTodoRuntime {
    private static let taskExecutionSchema = #"{"type":"object","properties":{"executor":{"type":"string","enum":["coordinator","sub_agent"]},"profile":{"type":"string"},"role":{"type":"string"},"fileScopes":{"type":"array","items":{"type":"string"}},"file_scopes":{"type":"array","items":{"type":"string"}}}}"#

    private static let taskDefinitionSchema = #"{"type":"object","properties":{"id":{"type":"string"},"taskID":{"type":"string"},"task_id":{"type":"string"},"title":{"type":"string"},"name":{"type":"string"},"details":{"type":"string"},"description":{"type":"string"},"order":{"type":"integer"},"priority":{"type":"string","enum":["low","normal","high"]},"complexity":{"type":"integer","minimum":1,"maximum":10},"dependsOn":{"type":"array","items":{"type":"string"}},"depends_on":{"type":"array","items":{"type":"string"}},"acceptanceCriteria":{"type":"array","items":{"type":"string"}},"acceptance_criteria":{"type":"array","items":{"type":"string"}},"execution":\#(taskExecutionSchema)}}"#

    private static let todoReadDescriptor = DirectToolDescriptor(
            name: "todo.read",
            description: "Returns the session todo list.",
            inputSchema: #"{"type":"object","properties":{}}"#,
            presentation: .standard(title: "Todo list", action: "Read", kind: .read, includesParameters: false)
        )

    private static let todoWriteDescriptor = DirectToolDescriptor(
            name: "todo.write",
            description: "Creates or updates the session todo list. Supports replace, append, and upsert modes.",
            inputSchema: #"{"type":"object","properties":{"todos":{"type":"array","items":{"type":"object","properties":{"id":{"type":"string"},"content":{"type":"string"},"title":{"type":"string"},"status":{"type":"string"},"dependsOn":{"type":"array","items":{"type":"string"}},"depends_on":{"type":"array","items":{"type":"string"}}},"required":["content"]}},"items":{"type":"array","items":{"type":"object"}},"id":{"type":"string"},"content":{"type":"string"},"title":{"type":"string"},"status":{"type":"string"},"dependsOn":{"type":"array","items":{"type":"string"}},"depends_on":{"type":"array","items":{"type":"string"}},"mode":{"type":"string"}}}"#,
            presentation: .standard(title: "Todo list", action: "Update", kind: .edit, targetKeyPaths: ["id", "title", "content"])
        )

    private static let taskCreateDescriptor = DirectToolDescriptor(
            name: "tasks.create",
            description: "Atomically creates one or more tasks in the session task graph. Use the canonical tasks array and do not mix it with root-level single-task fields or the legacy items alias. Give every task a stable id, title, complexity, explicit dependsOn and acceptanceCriteria arrays, and execution. Dependencies must reference tasks in the same graph. Model true prerequisites as edges, leave independent tasks dependency-free, and prefer safe, useful parallelism over list-order sequencing. In a /workflow graph, every task must declare execution.executor as sub_agent and is then claimed atomically by putting its ID in an agent.create agents item's taskID field.",
            inputSchema: #"{"type":"object","properties":{"graphID":{"type":"string"},"graph_id":{"type":"string"},"id":{"type":"string"},"title":{"type":"string"},"name":{"type":"string"},"details":{"type":"string"},"description":{"type":"string"},"order":{"type":"integer"},"priority":{"type":"string","enum":["low","normal","high"]},"complexity":{"type":"integer","minimum":1,"maximum":10,"description":"Task difficulty 1-10. \#(TaskRecord.complexityRubric). Agent selection policy: \#(TaskRecord.agentSelectionPolicy)"},"dependsOn":{"type":"array","items":{"type":"string"}},"depends_on":{"type":"array","items":{"type":"string"}},"acceptanceCriteria":{"type":"array","items":{"type":"string"}},"acceptance_criteria":{"type":"array","items":{"type":"string"}},"execution":\#(taskExecutionSchema),"tasks":{"type":"array","items":\#(taskDefinitionSchema)},"items":{"type":"array","items":\#(taskDefinitionSchema)}}}"#,
            presentation: .standard(title: "Tasks", action: "Create", kind: .create, targetKeyPaths: ["graphID", "graph_id", "title", "name", "id"])
        )

    private static let taskListDescriptor = DirectToolDescriptor(
            name: "tasks.list",
            description: "Lists task graph records with derived runnable and dependency state.",
            inputSchema: #"{"type":"object","properties":{"graphID":{"type":"string"},"graph_id":{"type":"string"},"status":{"type":"string"},"assigneeAgentID":{"type":"string"},"assignee_agent_id":{"type":"string"},"agentID":{"type":"string"},"agent_id":{"type":"string"},"runnableOnly":{"type":"boolean"},"runnable_only":{"type":"boolean"},"includeTerminal":{"type":"boolean"},"include_terminal":{"type":"boolean"},"limit":{"type":"integer"}}}"#,
            presentation: .standard(title: "Tasks", action: "List", kind: .read, targetKeyPaths: ["graphID", "graph_id", "status", "assigneeAgentID", "assignee_agent_id"])
        )

    private static let taskGetDescriptor = DirectToolDescriptor(
            name: "tasks.get",
            description: "Returns one task with dependencies, dependents, attempts, results, evidence, and runnable reason.",
            inputSchema: #"{"type":"object","properties":{"id":{"type":"string"},"taskID":{"type":"string"},"task_id":{"type":"string"},"graphID":{"type":"string"},"graph_id":{"type":"string"}},"required":["id"]}"#,
            presentation: .standard(title: "Task", action: "Get", kind: .read, targetKeyPaths: ["id", "taskID", "task_id", "graphID", "graph_id"])
        )

    private static let taskUpdateDescriptor = DirectToolDescriptor(
            name: "tasks.update",
            description: "Updates task metadata, progress, result, evidence, or an allowed lifecycle transition. Use tasks.retry and tasks.cancel for those operations.",
            inputSchema: #"{"type":"object","properties":{"id":{"type":"string"},"taskID":{"type":"string"},"task_id":{"type":"string"},"graphID":{"type":"string"},"graph_id":{"type":"string"},"title":{"type":"string"},"name":{"type":"string"},"details":{"type":["string","null"]},"description":{"type":["string","null"]},"status":{"type":"string"},"statusReason":{"type":"string"},"status_reason":{"type":"string"},"priority":{"type":"string"},"complexity":{"type":"integer","minimum":1,"maximum":10,"description":"Task difficulty 1-10. \#(TaskRecord.complexityRubric). Agent selection policy: \#(TaskRecord.agentSelectionPolicy)"},"dependsOn":{"type":"array","items":{"type":"string"}},"depends_on":{"type":"array","items":{"type":"string"}},"output":{"type":"string"},"progress":{"type":"string"},"error":{"type":"string"},"evidence":{"type":"array","items":{}},"expectedRevision":{"type":"integer"},"expected_revision":{"type":"integer"}},"required":["id"]}"#,
            presentation: .standard(title: "Task", action: "Update", kind: .edit, targetKeyPaths: ["id", "taskID", "task_id", "title", "name"])
        )

    private static let taskRetryDescriptor = DirectToolDescriptor(
            name: "tasks.retry",
            description: "Retries a failed or blocked task while preserving all prior attempts and outputs. A retried /workflow task must be claimed through a new canonical agent.create agents item containing `taskID`; do not reopen its completed attempt with agent.message.",
            inputSchema: #"{"type":"object","properties":{"id":{"type":"string"},"taskID":{"type":"string"},"task_id":{"type":"string"},"graphID":{"type":"string"},"graph_id":{"type":"string"},"expectedRevision":{"type":"integer"},"expected_revision":{"type":"integer"}},"required":["id"]}"#,
            presentation: .standard(title: "Task", action: "Retry", kind: .execute, targetKeyPaths: ["id", "taskID", "task_id"])
        )

    private static let taskCancelDescriptor = DirectToolDescriptor(
            name: "tasks.cancel",
            description: "Cancels a task and its active attempt.",
            inputSchema: #"{"type":"object","properties":{"id":{"type":"string"},"taskID":{"type":"string"},"task_id":{"type":"string"},"graphID":{"type":"string"},"graph_id":{"type":"string"},"reason":{"type":"string"}},"required":["id"]}"#,
            presentation: .standard(title: "Task", action: "Cancel", kind: .delete, targetKeyPaths: ["id", "taskID", "task_id"])
        )

    static let readOnlyToolDescriptors: [DirectToolDescriptor] = [
        todoReadDescriptor,
        taskListDescriptor,
        taskGetDescriptor,
        taskUpdateDescriptor
    ]

    static let mutatingToolDescriptors: [DirectToolDescriptor] = [
        todoWriteDescriptor,
        taskCreateDescriptor,
        taskRetryDescriptor,
        taskCancelDescriptor
    ]

    static let toolDescriptors: [DirectToolDescriptor] = [
        todoReadDescriptor,
        todoWriteDescriptor,
        taskCreateDescriptor,
        taskListDescriptor,
        taskGetDescriptor,
        taskUpdateDescriptor,
        taskRetryDescriptor,
        taskCancelDescriptor
    ]
}
