//
//  PlanningCommandKernel.swift
//  ZenCODE
//
//  Created by Gerardo Grisolini on 30/05/26.
//
//  Shared Planner identity, output freshness, and coordinator history projection.
//

import Foundation
import ToolCore

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
        let lines = text.components(separatedBy: .newlines)
        guard let firstContentIndex = lines.firstIndex(where: { $0.nilIfBlank != nil }),
              isPlannerQuestionsHeading(lines[firstContentIndex]) else {
            return false
        }
        guard lines.filter({ isPlannerQuestionsHeadingLike($0) }).count == 1 else {
            return false
        }
        guard !lines.contains(where: { isPlannerPlanHeading($0) }) else {
            return false
        }
        return lines[(firstContentIndex + 1)...].contains(where: { line in
            line.trimmingCharacters(in: .whitespacesAndNewlines).range(
                of: #"^\d+[.)]\s+\S"#,
                options: .regularExpression
            ) != nil
        })
    }

    private static func normalizedPlannerHeading(_ line: String) -> String {
        String(
            line.trimmingCharacters(in: .whitespacesAndNewlines)
                .drop(while: { $0 == "#" || $0.isWhitespace })
        )
        .trimmingCharacters(in: .whitespacesAndNewlines)
        .lowercased()
    }

    private static func isPlannerQuestionsHeading(_ line: String) -> Bool {
        let heading = normalizedPlannerHeading(line)
        return heading == "planner questions" || heading == "planner questions:"
    }

    private static func isPlannerQuestionsHeadingLike(_ line: String) -> Bool {
        let heading = normalizedPlannerHeading(line)
        return heading == "planner questions" || heading.hasPrefix("planner questions:")
    }

    private static func isPlannerPlanHeading(_ line: String) -> Bool {
        let heading = normalizedPlannerHeading(line)
        return heading == "specifiche concordate"
            || heading == "specifiche concordate:"
            || heading == "implementation plan"
            || heading == "implementation plan:"
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
}
