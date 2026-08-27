//
//  CoordinatorCommandKernel.swift
//  ZenCODE
//
//  Shared runtime-only routing for /plan, /goal, and /review.
//

import Foundation
import ToolCore

enum CoordinatorCommand: Sendable, Equatable {
    enum PlanAction: Sendable, Equatable {
        case start(goal: String)
        case save
        case load
        case list
        case delete(target: String?)
        case status
        case approve
        case clear
        case missingGoal
    }

    case plan(PlanAction)
    case goal(String)
    case review(String)
}

/// Parses the command families that must behave identically in every frontend.
/// It deliberately does not treat unrelated slash commands or `@mentions` as
/// planning replies; those remain owned by their transport-specific routers.
enum CoordinatorCommandParser {
    static func parse(_ input: String) -> CoordinatorCommand? {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("/") else { return nil }

        let tokenEnd = trimmed.firstIndex(where: \Character.isWhitespace)
            ?? trimmed.endIndex
        let rawToken = String(trimmed[..<tokenEnd]).lowercased()
        let token: String
        if let atSign = rawToken.firstIndex(of: "@"),
           atSign != rawToken.startIndex,
           rawToken.index(after: atSign) != rawToken.endIndex {
            token = String(rawToken[..<atSign])
        } else {
            token = rawToken
        }
        let argument = String(trimmed[tokenEnd...])
            .trimmingCharacters(in: .whitespacesAndNewlines)

        switch token {
        case "/goal":
            return .goal(argument)
        case "/plan":
            return .plan(planAction(argument))
        case "/review":
            return .review(argument)
        default:
            return nil
        }
    }

    static func isSlashCommand(_ input: String) -> Bool {
        input.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("/")
    }

    private static func planAction(_ argument: String) -> CoordinatorCommand.PlanAction {
        guard !argument.isEmpty else { return .missingGoal }
        let normalized = argument.lowercased()
        switch normalized {
        case "save": return .save
        case "load": return .load
        case "list": return .list
        case "status": return .status
        case "approve": return .approve
        case "clear": return .clear
        case "delete": return .delete(target: nil)
        default:
            if normalized.hasPrefix("delete ") {
                let target = argument.dropFirst("delete".count)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                return .delete(target: target.nilIfBlank)
            }
            return .start(goal: argument)
        }
    }
}

/// Runtime-only Planner discussion state. This type intentionally does not
/// conform to `Codable`: saved sessions, plan-library entries, and task-graph
/// checkpoints must never restore an unfinished clarification loop.
struct PlanningCommandRuntimeState: Sendable, Equatable {
    struct Exchange: Sendable, Equatable {
        let plannerMessage: String
        let userReply: String
    }

    let collectionID: UUID
    let goal: String
    var plannerAgentID: String?
    var plannerOutputRevision: UInt64?
    var exchanges: [Exchange]
    var pendingPlannerMessage: String?

    init(goal: String, collectionID: UUID = UUID()) {
        self.collectionID = collectionID
        self.goal = goal.trimmingCharacters(in: .whitespacesAndNewlines)
        self.plannerAgentID = nil
        self.plannerOutputRevision = nil
        self.exchanges = []
        self.pendingPlannerMessage = nil
    }

    var isAwaitingReply: Bool {
        pendingPlannerMessage?.nilIfBlank != nil
    }

    mutating func recordReply(_ reply: String) -> Bool {
        guard let pendingPlannerMessage = pendingPlannerMessage?.nilIfBlank,
              let normalizedReply = reply.nilIfBlank else {
            return false
        }
        exchanges.append(
            Exchange(
                plannerMessage: pendingPlannerMessage,
                userReply: normalizedReply
            )
        )
        self.pendingPlannerMessage = nil
        return true
    }

    mutating func recordPlannerOutput(
        _ text: String,
        agentID: String,
        revision: UInt64
    ) {
        plannerAgentID = agentID
        plannerOutputRevision = revision
        if PlanningCommandKernel.isPlannerQuestionResponse(text) {
            pendingPlannerMessage = text
        } else {
            pendingPlannerMessage = nil
        }
    }
}

struct PlannerTurnBaseline: Sendable, Equatable {
    let expectedAgentID: String?
    let expectedRevision: UInt64?
    let expectedAgentWasAvailable: Bool
    let revisionsByAgentID: [String: UInt64]
    /// A newly started `/plan` discussion must receive the Planner's mandatory
    /// question block before it can accept a final plan.
    let requiresInitialQuestion: Bool

    init(
        state: PlanningCommandRuntimeState?,
        snapshots: [DirectSubAgentRuntime.AgentSnapshot],
        rootSessionID: String?
    ) {
        expectedAgentID = state?.plannerAgentID
        expectedRevision = state?.plannerOutputRevision
        requiresInitialQuestion = state?.plannerAgentID == nil
            && state?.plannerOutputRevision == nil
            && state?.exchanges.isEmpty == true
            && state?.pendingPlannerMessage == nil
        let plannerSnapshots = PlanningCommandKernel.plannerSnapshots(
            snapshots,
            rootSessionID: rootSessionID
        )
        expectedAgentWasAvailable = plannerSnapshots.contains { snapshot in
            snapshot.id == state?.plannerAgentID && snapshot.status != .closed
        }
        revisionsByAgentID = Dictionary(
            uniqueKeysWithValues: plannerSnapshots.map {
                ($0.id, $0.latestOutputRevision)
            }
        )
    }
}

enum PlanningCommandKernel {
    static let planAuthorAgentName = "plan-author"

    static func plannerSnapshots(
        _ snapshots: [DirectSubAgentRuntime.AgentSnapshot],
        rootSessionID: String?
    ) -> [DirectSubAgentRuntime.AgentSnapshot] {
        snapshots.filter { snapshot in
            (rootSessionID == nil || snapshot.rootSessionID == rootSessionID)
                && snapshot.name.caseInsensitiveCompare(planAuthorAgentName) == .orderedSame
                && snapshot.role.caseInsensitiveCompare(AgentProfileStore.plannerAgentName) == .orderedSame
                && isPlannerSnapshotProfile(snapshot)
        }
    }

    static func freshPlannerSnapshot(
        from snapshots: [DirectSubAgentRuntime.AgentSnapshot],
        baseline: PlannerTurnBaseline,
        rootSessionID: String?
    ) -> DirectSubAgentRuntime.AgentSnapshot? {
        let completed = plannerSnapshots(snapshots, rootSessionID: rootSessionID).filter { snapshot in
            (snapshot.status == .idle || snapshot.status == .closed)
                && !snapshot.pending
                && snapshot.latestOutput?.nilIfBlank != nil
        }

        if let expectedAgentID = baseline.expectedAgentID,
           baseline.expectedAgentWasAvailable {
            let expected = completed.filter { snapshot in
                snapshot.id == expectedAgentID
                    && snapshot.latestOutputRevision > (baseline.expectedRevision ?? 0)
            }
            guard expected.count == 1 else { return nil }
            return expected[0]
        }

        let fresh = completed.filter { snapshot in
            if snapshot.id == baseline.expectedAgentID,
               let expectedRevision = baseline.expectedRevision {
                return snapshot.latestOutputRevision > expectedRevision
            }
            guard let priorRevision = baseline.revisionsByAgentID[snapshot.id] else {
                return true
            }
            return snapshot.latestOutputRevision > priorRevision
        }
        guard fresh.count == 1 else { return nil }
        return fresh[0]
    }

    static func plannerResponse(
        parentResponse: DirectAgentResponse,
        snapshots: [DirectSubAgentRuntime.AgentSnapshot],
        baseline: PlannerTurnBaseline,
        rootSessionID: String?
    ) -> (response: DirectAgentResponse, snapshot: DirectSubAgentRuntime.AgentSnapshot)? {
        guard let snapshot = freshPlannerSnapshot(
            from: snapshots,
            baseline: baseline,
            rootSessionID: rootSessionID
        ), let text = snapshot.latestOutput?.nilIfBlank else {
            return nil
        }
        guard !baseline.requiresInitialQuestion || isPlannerQuestionResponse(text) else {
            return nil
        }
        return (
            DirectAgentResponse(
                text: text,
                stopReason: parentResponse.stopReason,
                modelID: snapshot.modelID?.nilIfBlank ?? parentResponse.modelID
            ),
            snapshot
        )
    }

    static func isPlannerSnapshotProfile(
        _ snapshot: DirectSubAgentRuntime.AgentSnapshot
    ) -> Bool {
        snapshot.profileID?.caseInsensitiveCompare(
            AgentProfileStore.plannerAgentID.uuidString
        ) == .orderedSame
            || snapshot.profileName?.caseInsensitiveCompare(
                AgentProfileStore.plannerAgentName
            ) == .orderedSame
    }

    static func isPlannerQuestionResponse(_ text: String) -> Bool {
        guard let firstLine = text
            .split(whereSeparator: \Character.isNewline)
            .map(String.init)
            .first(where: { $0.nilIfBlank != nil }) else {
            return false
        }
        let heading = firstLine
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .drop(while: { $0 == "#" || $0.isWhitespace })
            .lowercased()
        return heading == "planner questions" || heading.hasPrefix("planner questions:")
    }

    static func planStartPrompt(goal: String, planner: AgentProfile) -> String {
        """
        You are only the coordinator for this planning pass. Stay on your current agent \
        profile, but do not author, draft, consolidate, rewrite, or improve the plan \
        yourself. The Planner agent is the sole author of the final plan and of every question.

        Planning goal requested by the user: \(goal)
        Plan only this requested activity unless the conversation clearly provides required constraints.

        Planner protocol:
        - Create exactly one sub-agent with agent.create. Use name \
        "\(planAuthorAgentName)", role "Planner", and profile "\(planner.id)". The Planner \
        must not edit files or run mutating commands.
        - Give that Planner the complete requested goal and every relevant constraint from the \
        conversation. Explicitly tell it that it, not the current coordinator, must inspect the \
        workspace as needed before formulating its mandatory initial brainstorming question.
        - The first Planner turn is always a brainstorming turn, even when the request is simple, \
        apparently complete, or already sufficiently defined. It must return exactly one block headed \
        "Planner questions" with at least one focused numbered question that lets the user confirm or \
        refine scope, assumptions, behavior, or acceptance criteria. It returns no plan in that turn, \
        and you must not call todo.write.
        - The Planner must first analyze implications it can resolve from the conversation and workspace, \
        so its mandatory question is specific and useful rather than a generic request for more detail. \
        After the user's first reply, it asks further questions only for material decisions that cannot \
        be derived reliably.
        - A final plan starts with "Specifiche concordate" and includes pertinent scope, non-goals, \
        decisions, and acceptance criteria. It then contains an ordered, numbered \
        "Implementation plan" usable by an implementer who has only that plan and the workspace.
        - Require the final response to be a concise, self-contained functional analysis. Every numbered \
        item must be self-contained as a specification and implementable after its declared dependencies: \
        state the concrete observable behavior and relevant flow, verified components/files/symbols, \
        applicable constraints and edge cases, concrete validation, and an explicit "Dependencies" \
        entry naming prerequisite item numbers or "none".
        - Do not include context summaries, generic background, non-pertinent sections, or detail that does not \
        change implementation. Use the fewest points and words that preserve implementation certainty. \
        Resolve needed decisions from the workspace and conversation; if a decision is genuinely blocking, \
        ask one focused question rather than guessing. Include persistence, compatibility, security, concurrency, \
        risks, and open questions only when pertinent to the requested work.
        - Dependencies form a DAG with the minimum safe edges. Expose useful independent branches; \
        add an edge only for a real prerequisite, validation ordering, or overlapping mutable state. The Planner \
        must not chain items merely because they are numbered. When translating tasks, never add an edge merely \
        because one point appears earlier; use sequential dependencies only when parallelism has no useful benefit \
        or overlapping mutable work makes concurrency unsafe.
        - Prohibit generic formulations, placeholders, repetition, alternatives, and decisions left \
        to the implementer. Include persistence, compatibility, security, concurrency, risks, and open \
        questions only when pertinent.
        - Require the Planner to support /plan <goal> -> /plan approve, which automatically starts implementation, \
        followed by /review and corrections. It must not tell the user to send another implementation prompt.
        - The final response follows the session response language from the system prompt.

        After delegating:
        - Wait for the Planner with agent.wait.
        - The initial turn is valid only when the Planner returns the mandatory "Planner questions" \
        block. If it returns a final plan instead, use agent.message to require the same Planner to \
        replace it with the mandatory focused question block, then wait again.
        - If output is failed, empty, or malformed, ask that same Planner to correct it with agent.message and wait again.
        - If the Planner reports questions, return its latest output verbatim and do not call todo.write.
        - If the Planner reports a final plan, call todo.write once with mode "upsert" and one pending item \
        for every numbered implementation point. Copy wording/order without reinterpretation, use a fresh \
        shared short token and stable IDs "plan-<token>-1", "plan-<token>-2", and so on, and \
        translate every explicit dependency to those IDs (empty arrays for independent items).
        - A claimed final response without a valid todo.write task for every point is a structural error; \
        never disguise it as a clarification request or invent tasks yourself.
        - Your final response is exactly the Planner's latest output, verbatim, with no wrapper. Freshness is \
        enforced by the Planner id and output revision for this turn.
        - Do not edit any files yourself in this planning turn.
        """
    }

    static func planContinuationPrompt(
        state: PlanningCommandRuntimeState,
        planner: AgentProfile
    ) -> String {
        let transcript = state.exchanges.enumerated().map { index, exchange in
            "Question block \(index + 1):\n\(exchange.plannerMessage)\n\nOperator reply \(index + 1):\n\(exchange.userReply)"
        }.joined(separator: "\n\n")
        let routing: String
        if let plannerAgentID = state.plannerAgentID?.nilIfBlank {
            routing = """
            Send the operator's newest reply verbatim to the existing Planner with agent.message, \
            using agent id "\(plannerAgentID)", then wait for that same agent. Do not reinterpret, \
            summarize, or answer the reply yourself. If and only if that agent no longer exists, \
            recreate exactly one agent named "\(planAuthorAgentName)" with role "Planner" and \
            profile "\(planner.id)", give it the original goal and the complete transcript below, \
            and wait for it.
            """
        } else {
            routing = """
            Recreate exactly one agent named "\(planAuthorAgentName)" with role "Planner" and \
            profile "\(planner.id)", give it the original goal and complete transcript below, \
            and wait for it. Do not reinterpret, summarize, or answer the operator replies yourself.
            """
        }

        return """
        Continue the runtime-only planning discussion for this original goal:
        \(state.goal)

        Complete question/answer transcript:
        \(transcript)

        \(routing)

        The Planner again decides whether information is sufficient. If material decisions remain, \
        return exactly one fresh numbered block headed "Planner questions" and do not call todo.write. \
        Otherwise return "Specifiche concordate" followed by the numbered "Implementation plan", \
        then call todo.write exactly once with one pending task per point and explicit dependency arrays. \
        A final answer without those structured tasks is an error. Return only the Planner's fresh latest \
        output verbatim and do not edit files.
        """
    }

    static func workflowPrompt(goal: String, graphID: String) -> String {
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

    static func planImplementationPrompt(for plan: TerminalSessionPlan) -> String {
        """
        Implement the active approved plan now, using the session task graph as the control \
        plane. Complete every task in the graph, deciding for yourself whether to work \
        directly or delegate. Validate important changes before marking tasks completed. \
        Stop when the graph is completed or a real blocker is reached. Do not recreate or \
        replace the approved plan.

        Goal: \(plan.originalGoal)

        Approved plan:
        \(plan.consolidatedText)

        Your final summary must follow the session response language from the system prompt. \
        Do not answer in English merely because this internal prompt is in English.
        """
    }

    static func historyByReplacingCoordinatorOutput(
        _ history: [AgentRuntimeMessage],
        with plannerOutput: String
    ) -> [AgentRuntimeMessage] {
        guard let turnStart = history.lastIndex(where: { $0.role == .user }) else {
            return history + [AgentRuntimeMessage(role: .assistant, content: plannerOutput)]
        }
        // The last user message is the hidden operational prompt. Keep the
        // replay-required tool envelope from its turn, but do not persist that
        // implementation detail into snapshots or resumed conversations.
        var correctedHistory = Array(history[..<turnStart])
        correctedHistory.append(contentsOf: history[history.index(after: turnStart)...].compactMap {
            message -> AgentRuntimeMessage? in
            guard message.role == .assistant else { return message }
            guard !message.toolCalls.isEmpty else { return nil }
            // Preserve the provider/tool-call envelope required for replay, but
            // remove coordinator prose from the operational assistant response.
            return AgentRuntimeMessage(
                role: message.role,
                content: "",
                reasoningContent: message.reasoningContent,
                reasoningItemsJSON: message.reasoningItemsJSON,
                thinkingBlocksJSON: message.thinkingBlocksJSON,
                anthropicContentBlocksJSON: message.anthropicContentBlocksJSON,
                providerResponseID: message.providerResponseID,
                attachments: message.attachments,
                toolCalls: message.toolCalls,
                toolCallID: message.toolCallID,
                toolName: message.toolName,
                toolResultIsError: message.toolResultIsError
            )
        })
        correctedHistory.append(
            AgentRuntimeMessage(role: .assistant, content: plannerOutput)
        )
        return correctedHistory
    }

    enum SavedPlanDeletionResolution: Equatable {
        case ids([String])
        case ambiguous(matches: [String])
        case notFound
    }

    static func planPreparedForSaving(
        _ plan: TerminalSessionPlan
    ) -> TerminalSessionPlan {
        TerminalSessionPlan(
            id: plan.id,
            originalGoal: plan.originalGoal,
            consolidatedText: plan.consolidatedText,
            createdAt: plan.createdAt,
            isApproved: false,
            points: plan.points.map { point in
                TerminalSessionPlanPoint(
                    id: point.id,
                    text: point.text,
                    dependsOn: point.dependsOn,
                    hasExplicitDependencies: point.hasExplicitDependencies
                )
            }
        )
    }

    static func planFromLatestAssistantMessage(
        in messages: [AgentRuntimeMessage],
        createdAt: Date = Date()
    ) -> TerminalSessionPlan? {
        guard let assistantIndex = messages.indices.reversed().first(where: { index in
            messages[index].role == .assistant
                && messages[index].content.nilIfBlank != nil
        }), let content = messages[assistantIndex].content.nilIfBlank,
              !isPlannerQuestionResponse(content) else {
            return nil
        }
        let originalGoal = messages[..<assistantIndex]
            .reversed()
            .first(where: { message in
                message.role == .user && message.content.nilIfBlank != nil
            })?
            .content
            .nilIfBlank
            ?? "Saved plan"
        return TerminalSessionPlan(
            originalGoal: originalGoal,
            consolidatedText: content,
            createdAt: createdAt
        )
    }

    static func loadableSavedPlan(
        from savedPlans: [SavedTaskPlan]
    ) -> SavedTaskPlan? {
        savedPlans.first { !$0.graph.state.isTerminal }
    }

    static func planPreparedForReuse(
        _ savedPlan: SavedTaskPlan
    ) -> TerminalSessionPlan {
        let sourcePlan = savedPlan.snapshot.plan
        let savedPointsByID = Dictionary(
            sourcePlan.points.map { ($0.id, $0) },
            uniquingKeysWith: { current, _ in current }
        )
        let points: [TerminalSessionPlanPoint]
        if savedPlan.graph.tasks.isEmpty {
            points = sourcePlan.points.map { point in
                TerminalSessionPlanPoint(
                    id: point.id,
                    text: point.text,
                    dependsOn: point.dependsOn,
                    hasExplicitDependencies: point.hasExplicitDependencies
                )
            }
        } else {
            points = savedPlan.graph.tasks
                .sorted { lhs, rhs in
                    if lhs.order == rhs.order { return lhs.id < rhs.id }
                    return lhs.order < rhs.order
                }
                .map { task in
                    TerminalSessionPlanPoint(
                        id: task.id,
                        text: task.title,
                        dependsOn: task.dependsOn,
                        hasExplicitDependencies: savedPointsByID[task.id]?
                            .hasExplicitDependencies ?? !task.dependsOn.isEmpty
                    )
                }
        }
        return TerminalSessionPlan(
            id: sourcePlan.id,
            originalGoal: sourcePlan.originalGoal,
            consolidatedText: sourcePlan.consolidatedText,
            createdAt: sourcePlan.createdAt,
            isApproved: false,
            points: points
        )
    }

    static func planMaterializedForApproval(
        _ plan: TerminalSessionPlan
    ) -> TerminalSessionPlan {
        guard plan.points.isEmpty else { return plan }
        var materializedPlan = plan
        materializedPlan.points = [
            TerminalSessionPlanPoint(
                id: "\(plan.id)-implementation",
                text: "Implement approved plan: \(plan.originalGoal)",
                hasExplicitDependencies: true
            )
        ]
        return materializedPlan
    }

    static func savedPlanContextMessage(
        _ savedPlan: SavedTaskPlan,
        plan: TerminalSessionPlan
    ) -> String {
        let savingAgent = savedPlan.snapshot.savingAgentName?.nilIfBlank.map {
            "\nSaved by agent: \($0)"
        } ?? ""
        return """
        [Saved plan handoff]
        A plan from an earlier ZenCODE session has been loaded for review and further elaboration. \
        Treat it as unapproved until the user explicitly runs /plan approve.\(savingAgent)

        Original goal:
        \(plan.originalGoal)

        Saved plan:
        \(plan.consolidatedText)
        """
    }

    static func savedPlanDeletionTarget(
        _ target: String,
        in planIDs: [String]
    ) -> SavedPlanDeletionResolution {
        let trimmedTarget = target.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedTarget.isEmpty else { return .notFound }
        if trimmedTarget.lowercased() == "all" {
            return .ids(planIDs)
        }
        if let exactID = planIDs.first(where: { $0 == trimmedTarget }) {
            return .ids([exactID])
        }
        let prefixMatches = planIDs
            .filter { $0.hasPrefix(trimmedTarget) }
            .sorted()
        switch prefixMatches.count {
        case 0: return .notFound
        case 1: return .ids(prefixMatches)
        default: return .ambiguous(matches: prefixMatches)
        }
    }

    static func planDeleteNotFoundMessage(
        availablePlanIDs: [String]
    ) -> String {
        "ZenCODE: no saved plan matches. Available plans: "
            + availablePlanIDs.joined(separator: ", ")
            + ".\n"
    }

    static func planDeleteAmbiguousMessage(
        matches: [String]
    ) -> String {
        "ZenCODE: the plan id prefix is ambiguous: "
            + matches.joined(separator: ", ")
            + ". Provide more characters.\n"
    }

    static func planDeleteSuccessMessage(
        deletedPlanIDs: [String],
        activePlanAffected: Bool
    ) -> String {
        guard !deletedPlanIDs.isEmpty else {
            return "ZenCODE: no saved plans were deleted.\n"
        }
        var message: String
        if deletedPlanIDs.count == 1, let planID = deletedPlanIDs.first {
            message = "Deleted saved plan `\(planID)`.\n"
        } else {
            message = "Deleted \(deletedPlanIDs.count) saved plans.\n"
        }
        if activePlanAffected {
            message += "The active plan in this session is unaffected; use /plan clear to discard it.\n"
        }
        return message
    }

    static func savedPlansListMessage(
        for savedPlans: [SavedTaskPlan]
    ) -> String {
        var lines = [
            "## Saved plans",
            "",
            "**Total:** \(savedPlans.count)",
            "",
            "| Plan | Saved | Status | Items done | Goal |",
            "|---|---|---|---:|---|",
        ]
        for saved in savedPlans {
            let id = saved.graph.id
            let shortID = id.hasPrefix("plan-")
                ? String(id.prefix("plan-".count + 8))
                : String(id.prefix(12))
            let savedAt = saved.snapshot.savedAt.formatted(
                date: .abbreviated,
                time: .shortened
            )
            let completedCount = saved.graph.tasks
                .filter { $0.status == .completed }
                .count
            let goal = saved.snapshot.plan.originalGoal
                .replacingOccurrences(of: "\n", with: " ")
            let truncatedGoal = goal.count > 60
                ? String(goal.prefix(60)) + "…"
                : goal
            lines.append(
                "| `\(shortID)` | \(savedAt) | `\(saved.graph.state.rawValue)` "
                    + "| \(completedCount)/\(saved.graph.tasks.count) "
                    + "| \(escapedPlanTableCell(truncatedGoal)) |"
            )
        }
        lines.append("")
        lines.append(
            "Use /plan load to restore the newest draft, or /plan delete <plan|prefix|all> to remove saved plans."
        )
        return lines.joined(separator: "\n") + "\n"
    }

    static func planStatusTable(
        for plan: TerminalSessionPlan,
        graph: TaskGraphSnapshot?
    ) -> String {
        let overallStatus: String
        if let graph {
            switch graph.state {
            case .draft:
                overallStatus = "awaiting_approval"
            case .completed, .cancelled, .archived:
                overallStatus = graph.state.rawValue
            case .active:
                if graph.tasks.contains(where: { $0.status == .failed }) {
                    overallStatus = "failed"
                } else if graph.tasks.contains(where: { $0.status == .blocked }) {
                    overallStatus = "blocked"
                } else if graph.tasks.contains(where: { $0.status == .inProgress }) {
                    overallStatus = "in_progress"
                } else if graph.tasks.contains(where: { $0.status == .awaitingValidation }) {
                    overallStatus = "awaiting_validation"
                } else if graph.tasks.contains(where: { $0.status == .cancelled }) {
                    overallStatus = "cancelled"
                } else {
                    overallStatus = "active"
                }
            }
        } else if plan.isCompleted {
            overallStatus = "completed"
        } else if plan.points.contains(where: { $0.status == .failed }) {
            overallStatus = "failed"
        } else if plan.points.contains(where: { $0.status == .blocked }) {
            overallStatus = "blocked"
        } else if plan.points.contains(where: { $0.status == .inProgress }) {
            overallStatus = "in_progress"
        } else if plan.points.contains(where: { $0.status == .awaitingValidation }) {
            overallStatus = "awaiting_validation"
        } else if plan.isApproved {
            overallStatus = "pending"
        } else {
            overallStatus = "awaiting_approval"
        }

        var lines = [
            "## Plan status",
            "",
            "**Goal:** \(plan.originalGoal)",
            "",
            "**Overall status:** `\(overallStatus)`",
            "",
            "| # | Plan item | Status |",
            "|---:|---|---|",
        ]
        if plan.points.isEmpty {
            lines.append("| 1 | Legacy plan without structured items | `not_tracked` |")
        } else {
            lines.append(contentsOf: plan.points.enumerated().map { index, point in
                "| \(index + 1) | \(escapedPlanTableCell(point.text)) | `\(point.status.rawValue)` |"
            })
        }
        return lines.joined(separator: "\n") + "\n"
    }

    static func plan(
        _ plan: TerminalSessionPlan,
        applying graph: TaskGraphSnapshot
    ) -> TerminalSessionPlan {
        var projected = plan
        let tasksByID = Dictionary(uniqueKeysWithValues: graph.tasks.map { ($0.id, $0) })
        for index in projected.points.indices {
            guard let task = tasksByID[projected.points[index].id] else { continue }
            projected.points[index].status = planPointStatus(for: task.status)
            projected.points[index].dependsOn = task.dependsOn
        }
        return projected
    }

    static func planPointStatus(
        for status: TaskStatus
    ) -> TerminalSessionPlanPointStatus {
        switch status {
        case .pending: .pending
        case .inProgress: .inProgress
        case .awaitingValidation: .awaitingValidation
        case .completed: .completed
        case .blocked: .blocked
        case .failed: .failed
        case .cancelled: .cancelled
        }
    }

    private static func escapedPlanTableCell(_ text: String) -> String {
        text
            .replacingOccurrences(of: "|", with: "\\|")
            .replacingOccurrences(of: "\r\n", with: " ")
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\r", with: " ")
    }

    /// Validates the coordinator's bootstrap independently of task-graph
    /// creation. A final Planner turn must describe the same ordered points it
    /// registered, with explicit, closed, acyclic dependencies.
    static func structuredPlanOutputIsCoherent(
        text: String,
        points: [TerminalSessionPlanPoint]
    ) -> Bool {
        guard !points.isEmpty,
              points.allSatisfy({
                  $0.hasExplicitDependencies && $0.status == .pending
              }) else {
            return false
        }
        let ids = points.map(\.id)
        let idSet = Set(ids)
        let prefixes = points.enumerated().compactMap { index, point in
            planIDPrefix(point.id, expectedOrdinal: index + 1)
        }
        guard idSet.count == ids.count,
              prefixes.count == points.count,
              Set(prefixes).count == 1,
              points.allSatisfy({ point in
                  Set(point.dependsOn).count == point.dependsOn.count
                      && point.dependsOn.allSatisfy { dependency in
                          dependency != point.id && idSet.contains(dependency)
                      }
              }), dependenciesAreAcyclic(points) else {
            return false
        }

        guard let describedPoints = implementationPoints(in: text),
              describedPoints.count == points.count else {
            return false
        }
        return zip(describedPoints, points).enumerated().allSatisfy { index, pair in
            let (described, point) = pair
            let normalizedDescription = normalizedPlanComparisonText(described.text)
            let normalizedPoint = normalizedPlanComparisonText(point.text)
            guard !normalizedDescription.isEmpty, !normalizedPoint.isEmpty else {
                return false
            }
            guard described.dependencyOrdinals.allSatisfy({ ordinal in
                ordinal > 0 && ordinal <= points.count && ordinal != index + 1
            }) else {
                return false
            }
            let describedDependencies = described.dependencyOrdinals.map {
                points[$0 - 1].id
            }
            return normalizedPoint == normalizedDescription
                && point.dependsOn == describedDependencies
        }
    }

    private struct DescribedImplementationPoint {
        let text: String
        let dependencyOrdinals: [Int]
    }

    private static func planIDPrefix(
        _ id: String,
        expectedOrdinal: Int
    ) -> String? {
        let components = id.split(separator: "-", omittingEmptySubsequences: false)
        let tokenComponents = components.dropFirst().dropLast()
        guard components.count >= 3,
              components.first == "plan",
              tokenComponents.allSatisfy({ component in
                  !component.isEmpty
                      && component.allSatisfy { $0.isLetter || $0.isNumber }
              }),
              components.last == Substring(String(expectedOrdinal)) else {
            return nil
        }
        return components.dropLast().joined(separator: "-")
    }

    private static func dependenciesAreAcyclic(
        _ points: [TerminalSessionPlanPoint]
    ) -> Bool {
        let dependencies = Dictionary(
            uniqueKeysWithValues: points.map { ($0.id, $0.dependsOn) }
        )
        var visiting = Set<String>()
        var visited = Set<String>()

        func visit(_ id: String) -> Bool {
            if visited.contains(id) { return true }
            guard visiting.insert(id).inserted else { return false }
            for dependency in dependencies[id] ?? [] {
                guard visit(dependency) else { return false }
            }
            visiting.remove(id)
            visited.insert(id)
            return true
        }

        return points.allSatisfy { visit($0.id) }
    }

    private static func implementationPoints(
        in text: String
    ) -> [DescribedImplementationPoint]? {
        var foundSpecifications = false
        var foundSection = false
        var points: [DescribedImplementationPoint] = []
        var textLines: [String] = []
        var dependencies: [Int]?

        func appendCurrentPoint() -> Bool {
            guard !textLines.isEmpty, let dependencies else { return false }
            points.append(
                DescribedImplementationPoint(
                    text: textLines.joined(separator: "\n"),
                    dependencyOrdinals: dependencies
                )
            )
            return true
        }

        for rawLine in text.split(
            separator: "\n",
            omittingEmptySubsequences: false
        ).map(String.init) {
            let trimmed = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            let normalizedHeading = trimmed
                .drop(while: { $0 == "#" || $0.isWhitespace })
                .trimmingCharacters(in: CharacterSet(charactersIn: ": "))
                .lowercased()
            if !foundSection {
                if normalizedHeading == "specifiche concordate" {
                    foundSpecifications = true
                } else if normalizedHeading == "implementation plan",
                          foundSpecifications {
                    foundSection = true
                }
                continue
            }
            if trimmed.hasPrefix("#"), !textLines.isEmpty {
                guard appendCurrentPoint() else { return nil }
                textLines.removeAll(keepingCapacity: false)
                break
            }
            let leadingSpaces = rawLine.prefix(while: { $0 == " " }).count
            if leadingSpaces <= 3,
               !rawLine.prefix(while: { $0.isWhitespace }).contains("\t"),
               let numbered = numberedPlanHeading(from: trimmed) {
                if !textLines.isEmpty {
                    guard appendCurrentPoint() else { return nil }
                    textLines.removeAll(keepingCapacity: true)
                    dependencies = nil
                }
                guard numbered.number == points.count + 1 else { return nil }
                textLines.append(numbered.text)
                continue
            }
            guard !textLines.isEmpty else { continue }
            if trimmed.lowercased().hasPrefix("dependencies:") {
                guard dependencies == nil,
                      let parsed = parsedPlanDependencies(from: trimmed) else {
                    return nil
                }
                dependencies = parsed
            } else if !trimmed.isEmpty {
                textLines.append(trimmed)
            }
        }
        if foundSection, !textLines.isEmpty {
            guard appendCurrentPoint() else { return nil }
        }
        return foundSection && !points.isEmpty ? points : nil
    }

    private static func parsedPlanDependencies(from line: String) -> [Int]? {
        guard let separator = line.firstIndex(of: ":") else { return nil }
        let rawValue = line[line.index(after: separator)...]
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let normalized = rawValue
            .trimmingCharacters(in: CharacterSet(charactersIn: ". "))
            .lowercased()
        if normalized == "none" || normalized == "[]" {
            return []
        }
        let cleaned = rawValue
            .replacingOccurrences(of: ",", with: " ")
            .filter { !"`[]().".contains($0) }
        let tokens = cleaned.split(whereSeparator: \Character.isWhitespace)
        let ordinals = tokens.compactMap { Int($0) }
        guard !tokens.isEmpty,
              ordinals.count == tokens.count,
              ordinals.allSatisfy({ $0 > 0 }),
              Set(ordinals).count == ordinals.count else {
            return nil
        }
        return ordinals
    }

    private static func numberedPlanHeading(
        from text: String
    ) -> (number: Int, text: String)? {
        guard let delimiter = text.firstIndex(where: { $0 == "." || $0 == ")" }),
              let number = Int(text[..<delimiter]) else {
            return nil
        }
        let remainder = text[text.index(after: delimiter)...]
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !remainder.isEmpty else { return nil }
        return (number, remainder)
    }

    private static func normalizedPlanComparisonText(_ text: String) -> String {
        let withoutNumber = numberedPlanHeading(
            from: text.trimmingCharacters(in: .whitespacesAndNewlines)
        )?.text ?? text
        return withoutNumber
            .split(whereSeparator: \Character.isWhitespace)
            .joined(separator: " ")
            .lowercased()
    }

    static func planPointUpdates(
        from toolCall: DirectAgentToolCall
    ) -> (points: [TerminalSessionPlanPoint], mode: DirectTodoTaskRuntime.TodoWriteMode)? {
        let request = DirectTodoTaskRuntime.normalizedToolRequest(for: toolCall)
        guard request.name == "todo.write",
              let todos = try? DirectTodoTaskRuntime.requestedTodos(from: request.arguments) else {
            return nil
        }
        let points = todos.compactMap { todo -> TerminalSessionPlanPoint? in
            let id = todo.id.trimmingCharacters(in: .whitespacesAndNewlines)
            let text = todo.content.trimmingCharacters(in: .whitespacesAndNewlines)
            guard id.hasPrefix("plan-"), !text.isEmpty else { return nil }
            let status: TerminalSessionPlanPointStatus
            switch todo.status {
            case .pending: status = .pending
            case .inProgress: status = .inProgress
            case .completed: status = .completed
            case .blocked: status = .blocked
            }
            return TerminalSessionPlanPoint(
                id: id,
                text: text,
                status: status,
                dependsOn: todo.dependsOn ?? [],
                hasExplicitDependencies: todo.dependsOn != nil
            )
        }
        guard !points.isEmpty, points.count == todos.count else { return nil }
        return (
            points,
            DirectTodoTaskRuntime.TodoWriteMode(
                rawValue: DirectTodoTaskRuntime.firstString(["mode"], in: request.arguments)
            )
        )
    }

    static func planID(from points: [TerminalSessionPlanPoint]) -> String {
        guard let firstID = points.first?.id.nilIfBlank else {
            return "plan-\(UUID().uuidString.lowercased())"
        }
        let components = firstID.split(separator: "-", omittingEmptySubsequences: false)
        if components.count > 1,
           components.last.flatMap({ Int($0) }) != nil {
            return components.dropLast().joined(separator: "-")
        }
        return "plan-\(UUID().uuidString.lowercased())"
    }

    static func taskDefinitions(
        for points: [TerminalSessionPlanPoint]
    ) -> [TaskDefinition] {
        points.enumerated().map { index, point in
            TaskDefinition(
                id: point.id,
                title: point.text,
                order: index + 1,
                dependsOn: point.dependsOn
            )
        }
    }
}

actor PlanningPointCollector {
    private var points: [TerminalSessionPlanPoint] = []
    private var completedPlan: TerminalSessionPlan?
    private var observedTodoWriteCount = 0
    private var hasInvalidTodoWrite = false

    func recordTodoWrite(
        _ update: (
            points: [TerminalSessionPlanPoint],
            mode: DirectTodoTaskRuntime.TodoWriteMode
        )?
    ) {
        observedTodoWriteCount += 1
        guard let update, case .upsert = update.mode else {
            hasInvalidTodoWrite = true
            return
        }
        apply(update.points, mode: update.mode)
    }

    func hasObservedTodoWrites() -> Bool {
        observedTodoWriteCount > 0
    }

    func validFinalPlanPoints() -> [TerminalSessionPlanPoint]? {
        guard observedTodoWriteCount == 1,
              !hasInvalidTodoWrite,
              !points.isEmpty else {
            return nil
        }
        return points
    }

    func apply(
        _ updates: [TerminalSessionPlanPoint],
        mode: DirectTodoTaskRuntime.TodoWriteMode
    ) {
        switch mode {
        case .replace:
            points = updates
        case .append:
            points.append(contentsOf: updates)
        case .upsert:
            var pointsByID = Dictionary(
                points.map { ($0.id, $0) },
                uniquingKeysWith: { current, _ in current }
            )
            for point in updates {
                pointsByID[point.id] = point
            }
            points = DirectTodoTaskRuntime.orderedValues(
                from: pointsByID,
                preserving: points.map(\.id) + updates.map(\.id)
            )
        }
    }

    func snapshot() -> [TerminalSessionPlanPoint] {
        points
    }

    func recordAutomaticCompletion(_ plan: TerminalSessionPlan) {
        completedPlan = plan
    }

    func automaticallyCompletedPlan() -> TerminalSessionPlan? {
        completedPlan
    }
}
