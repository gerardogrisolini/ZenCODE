//
//  ChatSessionNoticeCommandTextTests.swift
//  ZenCODE
//
//  The channel (tone) of the shared slash-command notices (`/help`, `/plan`,
//  `/goal`, `/review`, `/tasks`, `/changes`, `/undo`, `/artifacts`, `/open`,
//  `/attach`), as the terminal chat wrote them.
//

import Foundation
import Testing
import ToolCore
@testable import ZenCODECore

@Suite("Chat session command texts", .serialized)
struct ChatSessionCommandTextTests {
    // MARK: - Fixtures

    private static let createdAt = Date(timeIntervalSince1970: 1_000)

    private static func plan(
        id: String = "plan-load",
        points: [TerminalSessionPlanPoint] = [
            TerminalSessionPlanPoint(id: "point-1", text: "Read the parser"),
        ],
        isApproved: Bool = false
    ) -> TerminalSessionPlan {
        TerminalSessionPlan(
            id: id,
            originalGoal: "Fix the parser",
            consolidatedText: "1. Read the parser.",
            createdAt: createdAt,
            isApproved: isApproved,
            points: points
        )
    }

    // MARK: - Channels

    @Test
    func eachCommandNoticeIsWrittenInTheToneTheTerminalWroteItIn() {
        let summary = TurnFileChangeSummary(entries: [])
        let view = TaskRecordView(
            graphID: "graph-1",
            graphRevision: 1,
            graphState: .active,
            task: TaskRecord(id: "task-1", title: "Read", order: 0),
            isRunnable: true,
            blockedBy: [],
            blockedReason: nil,
            dependents: []
        )
        let failures: [ChatSessionNotice] = [
            .subAgentToolsRequired(command: "/plan"),
            .agentRoleUnavailable(.planner),
            .planMissingGoal,
            .planDiscussionBlocksMutation,
            .planUnavailableForSaving,
            .activePlanAlreadyExists,
            .savedPlanUnavailable,
            .savedPlansAllCompleted,
            .savedPlanContextNotAdded,
            .planDeleteUsage,
            .savedPlanNotFound(availablePlanIDs: ["plan-a"]),
            .savedPlanAmbiguous(matches: ["plan-a"]),
            .planUnavailableForApproval,
            .workflowMissingGoal,
            .workflowBlockedByPlan,
            .workflowAlreadyActive(graphID: "workflow_1", pendingTaskCount: 1),
            .taskIDRequired(action: "show"),
            .unknownTasksAction(action: "frob"),
            .fileChangesUndoFailed(description: "boom"),
            .unknownCommand(line: "/undo now"),
            .artifactsTakeNoArguments,
            .openTargetNotFound(argument: "missing.txt"),
            .invalidAttachmentSelection(argument: "9"),
            .unterminatedAttachmentQuote,
        ]
        let markdown: [ChatSessionNotice] = [
            .savedPlanLoaded(Self.plan()),
            .savedPlans([]),
            .planStatus(Self.plan(), graph: nil),
            .queuedPlans([Self.plan()]),
            .taskDetail(view),
            .fileArtifacts([]),
        ]
        let system: [ChatSessionNotice] = [
            .help(commandHelp: []),
            .noSavedPlans,
            .planSaved(planID: "plan-a"),
            .planSequenceSaved(planIDs: ["plan-a", "plan-b"]),
            .savedPlansDeleted(planIDs: ["plan-a"], activePlanAffected: false),
            .planClarificationActive(goal: "Fix the parser"),
            .planAwaitingApprovalGoal,
            .noActivePlan,
            .planApprovalGoalPrompt,
            .planApproved,
            .planDiscussionCleared,
            .noPlanToClear,
            .activePlanCleared,
            .noChangesToReview,
            .noTaskGraph,
            .taskRetried(taskID: "task-1"),
            .taskCancelled(taskID: "task-1"),
            .taskGraphsCleared,
            .noTrackedFileChanges,
            .fileChangeSummary(summary, includesDiff: false),
            .fileChangesReverted,
            .fileChangesNotUndone(description: "Nothing to undo."),
            .noFileArtifacts,
            .noOpenCandidates,
            .nothingOpened,
            .opening(ChatOpenTarget(target: "/project/a.txt", kind: .file)),
            .requiresInteractiveHost(.openSelection(candidates: [])),
            .attachmentUsage,
            .attachmentDeleteUsage,
            .attachmentSelectionCancelled,
            .attachmentsAdded(addedCount: 1, pendingCount: 1),
            .noPendingAttachments,
            .pendingAttachments([]),
            .pendingAttachmentsRemoved,
            .attachmentRemoved(filename: "logo.png"),
            .attachmentDirectoryUnreadable(path: "/Users/me"),
            .noAttachableFiles(directoryPath: "/Users/me"),
            // `/attach` without a path wrote its refusal on the system channel.
            .requiresInteractiveHost(.attachmentSelection),
        ]

        #expect(failures.allSatisfy { $0.channel == .failure })
        #expect(markdown.allSatisfy { $0.channel == .markdown })
        #expect(system.allSatisfy { $0.channel == .system })
    }
}
