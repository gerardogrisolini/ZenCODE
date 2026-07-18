//
//  TerminalChat+Workflow.swift
//  ZenCODE
//

import Foundation

extension TerminalChat {
    func handleWorkflowCommand(_ command: String) async -> TerminalSubmittedLineAction {
        let argument = String(command.dropFirst("/workflow".count))
            .trimmingCharacters(in: .whitespacesAndNewlines)

        guard !argument.isEmpty else {
            await writeFailureMessage(Self.workflowMissingGoalMessage)
            return .continueChat
        }

        guard activePlan == nil else {
            await writeFailureMessage(Self.workflowActivePlanMessage)
            return .continueChat
        }

        if !isSubAgentToolEnabled {
            await writeFailureMessage(
                """
                ZenCODE: /workflow requires the sub-agents tool group. \
                Enable it with /tools (or switch to an agent that includes it) and try again.

                """
            )
            return .continueChat
        }

        let graphID = "workflow_\(UUID().uuidString.lowercased())"
        do {
            _ = try await sessionRunner.taskOrchestrator.createGraph(
                sessionID: sessionID,
                id: graphID,
                source: .workflow,
                state: .active,
                tasks: []
            )
        } catch {
            await writeFailureMessage("ZenCODE: \(error.localizedDescription)\n")
            return .continueChat
        }

        await writeSubmittedPrompt(command)

        return .runHiddenPrompt(
            Self.workflowPrompt(goal: argument, graphID: graphID),
            purpose: .workflow(originalGoal: argument)
        )
    }

    static let workflowMissingGoalMessage =
        "ZenCODE: /workflow requires a goal. "
        + "Use /workflow <goal> to describe what should be planned and delegated.\n"

    static let workflowActivePlanMessage =
        "ZenCODE: /workflow cannot start while an active plan exists. "
        + "Finish it or use /plan clear before starting a workflow.\n"

    static func workflowPrompt(goal: String, graphID: String) -> String {
        return """
        You are the coordinator of a delegated workflow. You plan the work, add tasks to \
        the active task graph, delegate every task to the best-matching sub-agent, and act \
        as the final reviewer. Every task in this graph must be executed through \
        agent.create(taskID:); do not start a task attempt directly with tasks.update.

        Goal: \(goal)

        Active workflow task graph: \(graphID)

        Phase 1 — Plan and define the task graph:
        - Inspect the workspace to understand scope, relevant files, constraints, and risks.
        - Add all tasks to the active workflow graph with tasks.create. Give each task a \
        clear title, description, complexity (1-10), acceptance criteria, and \
        execution.executor set to sub_agent.
        - Design dependencies as a DAG with minimum safe edges:
          - Independent tasks must have empty dependsOn arrays so they can run in parallel.
          - Add a dependency only when one task consumes another's output or decision, \
        validation must follow implementation, or concurrent work would mutate overlapping \
        files or shared state.
          - Never chain tasks merely because they are numbered; never split trivial work \
        solely to manufacture parallelism.
        - Keep task granularity meaningful: each task should be a coherent unit of work \
        that one sub-agent can own end to end.

        Phase 2 — Delegate all work to sub-agents:
        - Call tasks.list with runnableOnly=true to find tasks ready to execute.
        - For each runnable task, select the best-matching agent profile and one of its \
          authorized model bindings:
          - Determine the task type (investigation, implementation, review, planning) and \
        required tools before comparing capability.
          - Exclude profiles whose role or constraints are incompatible.
          - Within a compatible profile, choose the lowest-capability authorized model binding \
        that meets the task complexity; if none meets it, use that profile's highest-capability \
        binding and report the gap.
        - Delegate each task by calling agent.create with its taskID and the selected \
        profile plus its selected `model` binding. Batch independent runnable tasks in a single \
        agent.create call when \
        parallel execution is safe and useful.
        - Wait for sub-agents with agent.wait — they run in parallel.
        - When sub-agents complete, review their output with tasks.get. Verify results \
        against acceptance criteria and current files.
        - For a task awaiting validation, record successful validation with tasks.update. If \
        validation is negative, record the task as failed with tasks.update, call tasks.retry, \
        then start a new attempt with a new agent.create(taskID:) using a suitable profile. Do \
        not use agent.message to request corrections from an agent after its task completed.
        - Repeat: call tasks.list again to pick up newly unblocked tasks, delegate, wait, \
        and review until all tasks are completed or a real blocker is reached.

        Phase 3 — Final review:
        - Verify the completed work against the goal and acceptance criteria.
        - Inspect changed files to confirm correctness and consistency.
        - Report a concise summary: what was done, key decisions, validation results, and \
        any remaining concerns or follow-ups.

        Rules:
        - Every workflow task is delegated through agent.create(taskID:); the task graph \
        enforces sub-agent execution.
        - Respect dependencies; never claim a task twice.
        - A negative validation follows failure, tasks.retry, then a new agent.create(taskID:); \
        never use agent.message to reopen a completed attempt.
        - Use the active workflow graph \(graphID); do not recreate or replace it.
        - Your final summary must follow the session response language from the system \
        prompt. Do not answer in English merely because this internal prompt is in English.
        """
    }
}
