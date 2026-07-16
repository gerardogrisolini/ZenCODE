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

        if !isSubAgentToolEnabled {
            await writeFailureMessage(
                """
                ZenCODE: /workflow requires the sub-agents tool group. \
                Enable it with /tools (or switch to an agent that includes it) and try again.

                """
            )
            return .continueChat
        }

        await writeSubmittedPrompt(command)

        return .runHiddenPrompt(
            Self.workflowPrompt(goal: argument),
            purpose: .workflow(originalGoal: argument)
        )
    }

    static let workflowMissingGoalMessage =
        "ZenCODE: /workflow requires a goal. "
        + "Use /workflow <goal> to describe what should be planned and delegated.\n"

    static func workflowPrompt(goal: String) -> String {
        return """
        You are the coordinator of a delegated workflow. You plan the work, create the \
        task graph, delegate every task to the best-matching sub-agent, and act as the \
        final reviewer. You must not implement tasks yourself — your only direct actions \
        are workspace inspection (search, read) and task/sub-agent management.

        Goal: \(goal)

        Phase 1 — Plan and create the task graph:
        - Inspect the workspace to understand scope, relevant files, constraints, and risks.
        - Create tasks with tasks.create. Give each task a clear title, description, \
        complexity (1-10), and acceptance criteria.
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
        - For each runnable task, select the best-matching agent profile:
          - Determine the task type (investigation, implementation, review, planning) and \
        required tools before comparing capability.
          - Exclude profiles whose role or constraints are incompatible.
          - Choose the lowest-capability profile that meets the task complexity; if none \
        meets it, use the highest-capability compatible profile and report the gap.
        - Delegate each task by calling agent.create with its taskID and the selected \
        profile. Batch independent runnable tasks in a single agent.create call when \
        parallel execution is safe and useful.
        - Wait for sub-agents with agent.wait — they run in parallel.
        - When sub-agents complete, review their output with tasks.get. Verify results \
        against acceptance criteria and current files.
        - If work is incomplete or incorrect, use agent.message to request corrections or \
        tasks.retry to re-run the task with a better profile if needed.
        - Repeat: call tasks.list again to pick up newly unblocked tasks, delegate, wait, \
        and review until all tasks are completed or a real blocker is reached.

        Phase 3 — Final review:
        - Verify the completed work against the goal and acceptance criteria.
        - Inspect changed files to confirm correctness and consistency.
        - Report a concise summary: what was done, key decisions, validation results, and \
        any remaining concerns or follow-ups.

        Rules:
        - Never implement tasks yourself. Delegate all implementation work.
        - Respect dependencies; never claim a task twice.
        - Use tasks.retry only for explicit retries after failure.
        - Do not recreate or replace the task graph once it is created.
        - Your final summary must follow the session response language from the system \
        prompt. Do not answer in English merely because this internal prompt is in English.
        """
    }
}
