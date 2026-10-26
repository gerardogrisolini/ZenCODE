// Saved-plan selection and preparation without persistence or ownership changes.

import Foundation
import ToolCore

extension PlanningCommandKernel {
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
        let originalGoal = planGoal(
            in: messages,
            beforeAssistantAt: assistantIndex
        ) ?? "Saved plan"
        // A promoted answer that passes the strict Planner parser keeps every
        // point and dependency, exactly like a plan created by `/plan`. Any
        // other text stays text-only and receives one generic task at approval.
        if let points = planPoints(derivedFromFinalText: content) {
            return TerminalSessionPlan(
                id: planID(from: points),
                originalGoal: originalGoal,
                consolidatedText: content,
                createdAt: createdAt,
                points: points
            )
        }
        return TerminalSessionPlan(
            originalGoal: originalGoal,
            consolidatedText: content,
            createdAt: createdAt
        )
    }

    /// Finds the request that originated a text-only plan. A Planner may ask
    /// one or more clarification questions before the final response; the
    /// latest user message in that exchange is therefore often only a reply
    /// (for example, an approval to prepare the plan), not the plan's goal.
    /// Keep the extraction based on the existing Planner protocol when it is
    /// present, while retaining a conservative fallback for older or ordinary
    /// conversations that do not contain its heading.
    private static func planGoal(
        in messages: [AgentRuntimeMessage],
        beforeAssistantAt assistantIndex: Int
    ) -> String? {
        let questionIndices = messages.indices.filter { index in
            guard index < assistantIndex,
                  messages[index].role == .assistant,
                  let content = messages[index].content.nilIfBlank else {
                return false
            }
            return isPlannerQuestionResponse(content)
        }

        if let latestQuestionIndex = questionIndices.last,
           !messages[(latestQuestionIndex + 1)..<assistantIndex].contains(where: { message in
               message.role == .assistant && message.content.nilIfBlank != nil
           }) {
            var firstQuestionIndex = latestQuestionIndex
            for questionIndex in questionIndices.dropLast().reversed() {
                let containsOtherAssistantOutput = messages[(questionIndex + 1)..<firstQuestionIndex]
                    .contains { message in
                        message.role == .assistant
                            && message.content.nilIfBlank != nil
                            && !isPlannerQuestionResponse(message.content)
                    }
                guard !containsOtherAssistantOutput else { break }
                firstQuestionIndex = questionIndex
            }

            if let goal = messages[..<firstQuestionIndex]
                .reversed()
                .first(where: { message in
                    message.role == .user && message.content.nilIfBlank != nil
                })?
                .content
                .nilIfBlank {
                return goal
            }
        }

        return messages[..<assistantIndex]
            .reversed()
            .first(where: { message in
                message.role == .user
                    && message.content.nilIfBlank != nil
                    && !isPlanConfirmation(message.content)
            })?
            .content
            .nilIfBlank
    }

    /// Replies that only acknowledge the preceding planning exchange should
    /// not replace its original request when recovering a text-only plan. This
    /// deliberately recognizes only generic acknowledgements or explicit plan
    /// continuation requests; substantive constraints remain valid candidates.
    private static func isPlanConfirmation(_ text: String) -> Bool {
        let normalized = text
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .replacingOccurrences(of: "[.!?,:;]+", with: " ", options: .regularExpression)
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else { return true }

        let standaloneAcknowledgements = [
            "ok", "okay", "yes", "yep", "sure", "perfect", "great", "confirmed",
            "si", "sì", "va bene", "perfetto", "bene", "d'accordo", "confermo",
        ]
        if standaloneAcknowledgements.contains(normalized) {
            return true
        }

        let acknowledgementPrefixes = standaloneAcknowledgements.map { $0 + " " }
        guard let prefix = acknowledgementPrefixes.first(where: {
            normalized.hasPrefix($0)
        }) else {
            return false
        }
        let remainder = String(normalized.dropFirst(prefix.count))
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !remainder.isEmpty else { return true }

        let continuationPhrases = [
            "go ahead", "proceed", "continue", "do it", "prepare the plan",
            "prepare an implementation plan", "prepare the implementation plan",
            "create the plan", "make the plan",
            "prepara il piano", "prepara un piano", "prepara il piano da implementare",
            "crea il piano", "fai il piano", "continua", "procedi",
        ]
        return continuationPhrases.contains { phrase in
            remainder == phrase || remainder.hasPrefix(phrase + " ")
        }
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
        var plan = planPreparedForSaving(sourcePlan)
        guard !savedPlan.graph.tasks.isEmpty else { return plan }
        let savedPointsByID = Dictionary(
            sourcePlan.points.map { ($0.id, $0) },
            uniquingKeysWith: { current, _ in current }
        )
        plan.points = savedPlan.graph.tasks
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
        return plan
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
}
