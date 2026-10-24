// Hidden coordination prompts; their text is shared by every frontend.

import ToolCore

extension PlanningCommandKernel {
    /// Shared wait rule for every hidden planning prompt: the Planner can take
    /// longer than the default `agent.wait` timeout, and the coordinator must
    /// not end its turn while the Planner is still working.
    static let plannerWaitInstruction = """
        Call agent.wait with timeoutSeconds 900. If agent.wait times out or reports the Planner \
        still running, queued, or pending, call agent.wait again; never end the turn while the \
        Planner is still working.
        """

    static func planStartPrompt(goal: String, planner: AgentProfile) -> String {
        """
        You are only the coordinator for this planning pass. Stay on your current agent \
        profile, but do not author, draft, consolidate, rewrite, or improve the plan \
        yourself. The Planner agent is the sole author of the final plan and of every question.

        Planning goal requested by the user: \(goal)
        Plan only this requested activity unless the conversation clearly provides required constraints.

        Delegate and coordinate:
        - Create exactly one sub-agent with agent.create. Use name \
        "\(planAuthorAgentName)", role "Planner", and profile "\(planner.id)".
        - Give that Planner the complete requested goal and every relevant constraint from the \
        conversation. Its runtime profile policy owns the brainstorming and plan-authoring protocol.
        - Wait for the Planner with agent.wait. It returns early when the Planner \
        asks you a question in chat: answer with agent.message, using only facts and constraints already \
        present in the conversation, then call agent.wait again. Material decisions that belong to the \
        operator must not be answered by you; tell the Planner in chat to put them in its \
        "Planner questions" block. \(plannerWaitInstruction)
        - The initial turn is valid only when the Planner returns the required "Planner questions" \
        block. If it returns a final plan instead, use agent.message to require the same Planner to \
        replace it with its required focused question block, then wait again.
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
            using agent id "\(plannerAgentID)", then wait for that same agent. \(plannerWaitInstruction) \
            Do not reinterpret, summarize, or answer the reply yourself. If and only if that agent no \
            longer exists, recreate exactly one agent named "\(planAuthorAgentName)" with role "Planner" and \
            profile "\(planner.id)", give it the original goal and the complete transcript below, \
            and wait for it the same way.
            """
        } else {
            routing = """
            Recreate exactly one agent named "\(planAuthorAgentName)" with role "Planner" and \
            profile "\(planner.id)", give it the original goal and complete transcript below, \
            and wait for it. \(plannerWaitInstruction) Do not reinterpret, summarize, or answer the \
            operator replies yourself.
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
}
