// Initial, operator-driven, and automatic continuation of the same goal graph.

import ToolCore

extension PlanningCommandKernel {
    /// The completion contract shared by the initial `/goal` prompt and every
    /// continuation prompt. A clarification round-trip must not weaken it.
    static let workflowCompletionContract = """
        - Continue working until the stated goal is fully achieved and validated. Do not stop after \
        planning, after a partial implementation, or merely because one task or agent attempt ended.
        - Keep inspecting, executing directly or delegating when useful, validating, retrying failed work, and processing newly \
        unblocked tasks until the goal and every acceptance criterion are satisfied.
        - Completing all currently defined tasks does not complete the goal or close its graph. \
        Add newly discovered work to the same graph, or pause for clarification when needed.
        - After the entire goal is achieved and validated and every task is completed, call \
        tasks.list for the current graph revision, then tasks.update with only graphID, \
        expectedRevision, and workflow: {state: "completed"}. This explicit finalization requires \
        a non-empty graph with all tasks completed; do not finalize merely after analysis or planning. \
        Only after finalization report the final summary.
        - If any requirement, constraint, expected behavior, or necessary decision is unclear and \
        cannot be resolved reliably from the workspace or existing context, ask the user a focused \
        clarification question instead of guessing. Once clarified, resume this same goal graph.
        - To pause, call tasks.list to obtain the current graph revision, then tasks.update with \
        only graphID, expectedRevision, and workflow: {state: "awaiting_user", message: "your question"}. \
        End the turn with the focused question in normal prose. Text alone, including a \
        "Workflow question" heading, does not change workflow state. A user reply resumes this same graph.
        - Stop without achieving the goal only for a genuine blocker that cannot be resolved through \
        clarification, direct execution, optional suitable delegation, retry, or available project evidence; use tasks.update workflow mode \
        with state "blocked" and a precise message stating what is needed to continue. End the turn; \
        do not repeatedly retry blocked work. Runtime control is structured, not inferred from prose.
        """

    /// The invariant execution rules, shared by the initial and continuation
    /// prompts so a resumed workflow cannot silently lose them.
    static func workflowRules(graphID: String) -> String {
        """
        - Keep all work in the persistent task DAG, including direct work. Choose direct execution \
        or delegation when useful, within the tools and permissions already available; /goal grants no extra tools.
        - For direct work, declare execution.executor as coordinator and use tasks.update to move \
        a runnable task from pending to in_progress before working, then record its outcome and \
        mark it completed only after validation. This creates and finishes a coordinator attempt.
        - Only when delegating, declare execution.executor as sub_agent and claim the task through \
        the canonical agent.create `agents` array with `taskID` inside its item, never at the root.
        - Respect dependencies; never claim a task twice.
        - After failure, use tasks.retry before starting a new attempt. For delegated corrections, \
        use a new canonical agent.create item containing `taskID`; never use agent.message to \
        reopen a completed attempt. For direct retries, start again with tasks.update in_progress.
        - Use the active workflow graph \(graphID); do not recreate or replace it.
        - Your final summary must follow the session response language from the system \
        prompt. Do not answer in English merely because this internal prompt is in English.
        """
    }

    /// Resumes an existing workflow graph after the user answered the
    /// coordinator (clarification round-trip) or after a restart restored the
    /// graph. The graph ID, the completion contract and the execution rules are
    /// re-injected verbatim so the continuation turn is not a plain chat turn.
    static func workflowContinuationPrompt(
        state: WorkflowCommandRuntimeState,
        pendingTaskCount: Int,
        totalTaskCount: Int
    ) -> String {
        let goalLine = state.goal.nilIfBlank.map { "Goal: \($0)" }
            ?? "Original goal unavailable: this legacy checkpoint did not record it. Ask the user for any missing objective; do not invent one."
        let transcript = state.exchanges.suffix(3).map { exchange in
            """
            You asked:
            \(exchange.coordinatorMessage)

            The user answered:
            \(exchange.userReply)
            """
        }.joined(separator: "\n\n").nilIfBlank
            ?? "(no recorded exchange: continue from the state stored in the task graph.)"
        return """
        Continue the goal workflow you are already coordinating. This is not a new goal \
        and not a plain chat turn: keep using the same task graph, the same completion \
        contract, and the same execution rules.

        \(goalLine)

        Active workflow task graph: \(state.graphID)
        Task graph state: \(pendingTaskCount) of \(totalTaskCount) tasks still open.

        Latest exchange with the user:
        \(transcript)

        Apply the user's answer — or, when the exchange above says the previous turn did not \
        finish, recover that interrupted work — then resume on this same graph. Start by calling \
        tasks.list for \(state.graphID) to re-establish the current state before deciding \
        what to plan, execute directly, delegate, validate, or retry. Use tasks.retry for failed or \
        blocked tasks before starting a new direct or delegated attempt. Add any newly required tasks to this \
        graph with tasks.create; never create or replace another graph.

        Completion contract:
        \(workflowCompletionContract)

        Rules:
        \(workflowRules(graphID: state.graphID))
        """
    }

    /// Re-enters an open workflow after the coordinator ended a generation
    /// without either completing its graph or asking an explicit clarification.
    /// This is the runtime enforcement that makes `/goal` persistent rather than
    /// a one-shot prompt convention.
    static func workflowAutomaticContinuationPrompt(
        goal: String,
        graph: TaskGraphSnapshot
    ) -> String {
        let goalLine = (graph.workflow?.originalGoal ?? goal.nilIfBlank).map { "Goal: \($0)" }
            ?? "Original goal unavailable: this legacy checkpoint did not record it. Ask the user for any missing objective; do not invent one."
        let counts = Dictionary(grouping: graph.tasks, by: \.status)
            .map { status, tasks in "\(status.rawValue)=\(tasks.count)" }
            .sorted()
            .joined(separator: ", ")
            .nilIfBlank ?? "no tasks defined"
        return """
        Continue the active /goal workflow automatically. Your previous generation ended, but \
        the runtime verified that the goal graph is not complete. This is not a new user request \
        and not permission to return a progress summary.

        \(goalLine)

        Active workflow task graph: \(graph.id)
        Current task state: \(counts).

        Call tasks.list for \(graph.id) first. If the graph has no tasks, finish identifying the \
        concrete objective and create the persistent task DAG. Otherwise continue with \
        every pending, blocked, failed, or awaiting-validation task: inspect evidence, execute \
        runnable work directly or delegate when useful, validate results, retry failed attempts, and add any work discovered during \
        validation. Do not repeat a progress report and do not wait for the user unless a material \
        decision cannot be resolved from the request, workspace, existing context, or project \
        conventions.

        Completion contract:
        \(workflowCompletionContract)

        Rules:
        \(workflowRules(graphID: graph.id))
        """
    }

    static func workflowPrompt(goal: String, graphID: String) -> String {
        return """
        Work autonomously until the goal is complete or a genuine blocker requires a pause. \
        Plan the work in the active persistent task graph, execute directly or delegate when \
        useful, and validate the result. Delegation is optional, not a prerequisite for /goal. \
        Keep the task DAG even when doing all work directly; this is not a taskless mode.

        Goal: \(goal)

        Active workflow task graph: \(graphID)

        Completion contract:
        \(workflowCompletionContract)

        Phase 0 — Identify the objective autonomously:
        - Treat the user's wording as the requested outcome, not merely as a prompt to answer. \
        Inspect the workspace, relevant documentation, current implementation, tests, and session \
        context to determine the actual change required and the observable definition of done.
        - Resolve ordinary implementation details from project conventions and evidence. Do not \
        ask the user to confirm an objective you can establish reliably yourself.
        - Translate the objective into explicit, testable acceptance criteria. Ensure the task set \
        collectively covers the full objective, including integration, regression protection, \
        validation, and user-visible documentation when applicable.
        - Ask a focused clarification only when a material product decision remains genuinely \
        ambiguous after inspection. Do not create speculative implementation tasks before that \
        blocking ambiguity is resolved.

        Phase 1 — Plan and define the task graph:
        - Inspect the workspace to understand scope, relevant files, constraints, and risks.
        - Add all tasks to the active workflow graph with one canonical tasks.create `tasks` \
        array. Do not mix root-level single-task fields or the legacy `items` alias. Give each \
        task a stable id, clear title, description, complexity (1-10), acceptance criteria, and \
        execution.executor set to coordinator for direct work or sub_agent for delegated work.
        - Design dependencies as a DAG with minimum safe edges:
          - Independent tasks must have empty dependsOn arrays so they can run in parallel.
          - Add a dependency only when one task consumes another's output or decision, \
        validation must follow implementation, or concurrent work would mutate overlapping \
        files or shared state.
          - Never chain tasks merely because they are numbered; never split trivial work \
        solely to manufacture parallelism.
        - Keep task granularity meaningful: each task should be a coherent unit of work \
        that one executor can own end to end.

        Phase 2 — Execute directly or delegate when useful:
        - Call tasks.list with runnableOnly=true to find tasks ready to execute.
        - For direct work, use tasks.update status in_progress, perform and validate the work, \
        then record output/evidence and status completed; record failed or blocked when appropriate.
        - When delegation is useful and available, select the best-matching agent profile and, when configured, \
        one of its authorized model bindings:
          - Determine the task type (investigation, implementation, review, planning) and \
        required tools before comparing capability.
          - Exclude profiles whose role or constraints are incompatible.
          - Within a compatible profile, choose the lowest-capability authorized model binding \
        that meets the task complexity; if none meets it, use that profile's highest-capability \
        binding and report the gap.
          - For profiles without bindings, omit `model` to inherit the main session model and \
        provider; do not invent a binding or capability rating.
        - Claim each delegated task with one canonical agent.create `agents` item containing the selected \
        profile and, only when bindings are configured, the `model` binding. Put the task ID in \
        that item's `taskID` field. Batch \
        independent runnable tasks in a single agent.create call when \
        parallel execution is safe and useful.
        - When delegating, wait for sub-agents with agent.wait — they run in parallel.
        - When sub-agents complete, review their output with tasks.get. Verify results \
        against acceptance criteria and current files.
        - For a delegated task awaiting validation, record successful validation with tasks.update. If \
        validation is negative, record the task as failed with tasks.update, call tasks.retry, \
        then start a new delegated attempt with a new canonical agent.create item containing `taskID` and \
        using a suitable profile, or execute the retry directly with tasks.update. Do \
        not use agent.message to request corrections from an agent after its task completed.
        - Repeat: call tasks.list again to pick up newly unblocked tasks, execute directly or delegate, \
        and review until all tasks are completed. If progress is blocked, exhaust the clarification, \
        evidence, suitable-agent, and retry paths in the Completion contract before stopping.

        Phase 3 — Final review:
        - Verify the completed work against the goal and acceptance criteria.
        - Inspect changed files to confirm correctness and consistency.
        - Explicitly finalize the verified goal with tasks.update workflow state completed as \
        specified in the Completion contract; task completion alone leaves the workflow open.
        - Report a concise summary: what was done, key decisions, validation results, and only \
        non-blocking concerns or optional follow-ups. Never present an unsatisfied requirement or \
        acceptance criterion as a follow-up.

        Rules:
        \(workflowRules(graphID: graphID))
        """
    }
}
