//
//  TerminalChat+Goal.swift
//  ZenCODE
//

import Foundation

extension TerminalChat {
    func handleWorkflowCommand(_ command: String) async -> TerminalSubmittedLineAction {
        let argument = Self.slashCommandArguments(
            from: command,
            commandPrefix: "/goal"
        )

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
                ZenCODE: /goal requires the sub-agents tool group. \
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

    nonisolated static let workflowMissingGoalMessage =
        "ZenCODE: /goal requires a goal. "
        + "Use /goal <goal> to describe what should be planned and delegated.\n"

    nonisolated static let workflowActivePlanMessage =
        "ZenCODE: /goal cannot start while an active plan exists. "
        + "Finish it or use /plan clear before starting a workflow.\n"

    nonisolated static func workflowPrompt(goal: String, graphID: String) -> String {
        return """
        You are the coordinator of a delegated workflow. You plan the work, add tasks to \
        the active task graph, delegate every task to the best-matching sub-agent, and act \
        as the final reviewer. Every task in this graph must be executed through \
        agent.create using its canonical `agents` array with the task ID in the item's `taskID` \
        field; never pass taskID at the root. Do not start a task attempt directly with tasks.update.

        Goal: \(goal)

        Active workflow task graph: \(graphID)

        Completion contract:
        - Continue working until the stated goal is fully achieved and validated. Do not stop after \
        planning, after a partial implementation, or merely because one task or agent attempt ended.
        - Keep inspecting, delegating, validating, retrying failed work, and processing newly \
        unblocked tasks until the goal and every acceptance criterion are satisfied.
        - If any requirement, constraint, expected behavior, or necessary decision is unclear and \
        cannot be resolved reliably from the workspace or existing context, ask the user a focused \
        clarification question instead of guessing. Once clarified, resume this same goal graph.
        - Stop without achieving the goal only for a genuine blocker that cannot be resolved through \
        clarification, another suitable sub-agent, retry, or available project evidence; explain the \
        blocker precisely and state what is needed to continue.

        Phase 1 — Plan and define the task graph:
        - Inspect the workspace to understand scope, relevant files, constraints, and risks.
        - Add all tasks to the active workflow graph with one canonical tasks.create `tasks` \
        array. Do not mix root-level single-task fields or the legacy `items` alias. Give each \
        task a stable id, clear title, description, complexity (1-10), acceptance criteria, and \
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
        - Delegate each task with one canonical agent.create `agents` item containing the selected \
        profile and `model` binding, and put the task ID in that item's `taskID` field. Batch \
        independent runnable tasks in a single agent.create call when \
        parallel execution is safe and useful.
        - Wait for sub-agents with agent.wait — they run in parallel.
        - When sub-agents complete, review their output with tasks.get. Verify results \
        against acceptance criteria and current files.
        - For a task awaiting validation, record successful validation with tasks.update. If \
        validation is negative, record the task as failed with tasks.update, call tasks.retry, \
        then start a new attempt with a new canonical agent.create item containing `taskID` and \
        using a suitable profile. Do \
        not use agent.message to request corrections from an agent after its task completed.
        - Repeat: call tasks.list again to pick up newly unblocked tasks, delegate, wait, \
        and review until all tasks are completed. If progress is blocked, exhaust the clarification, \
        evidence, suitable-agent, and retry paths in the Completion contract before stopping.

        Phase 3 — Final review:
        - Verify the completed work against the goal and acceptance criteria.
        - Inspect changed files to confirm correctness and consistency.
        - Report a concise summary: what was done, key decisions, validation results, and only \
        non-blocking concerns or optional follow-ups. Never present an unsatisfied requirement or \
        acceptance criterion as a follow-up.

        Rules:
        - Every workflow task is delegated through the canonical agent.create `agents` array \
        with `taskID` inside its item; the task graph \
        enforces sub-agent execution.
        - Respect dependencies; never claim a task twice.
        - A negative validation follows failure, tasks.retry, then a new canonical agent.create \
        item containing `taskID`; never use agent.message to reopen a completed attempt.
        - Use the active workflow graph \(graphID); do not recreate or replace it.
        - Your final summary must follow the session response language from the system \
        prompt. Do not answer in English merely because this internal prompt is in English.
        """
    }
}
