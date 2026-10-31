//
//  ChatSessionNoticeCommandTextTests.swift
//  ZenCODE
//
//  The texts of the shared slash-command notices (`/help`, `/plan`, `/goal`,
//  `/review`, `/tasks`, `/changes`, `/undo`, `/artifacts`, `/open`,
//  `/attach`), compared with what the terminal chat wrote before the wording
//  moved to `ChatSessionNoticeText`.
//

import Foundation
import Testing
import ToolCore
@testable import ZenCODECore

/// The expectations are literal strings taken from the terminal chat of that
/// time, not calls to the functions that now produce the notice text. The
/// terminal's `static` members that once kept their own copy of a text (the
/// `/attach` and `/open` texts) now forward to these, and are checked against
/// the same literals.
@Suite("Chat session command texts", .serialized)
struct ChatSessionCommandTextTests {
    private func text(_ notice: ChatSessionNotice) -> String {
        ChatSessionNoticeText.text(for: notice)
    }

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

    private static let attachmentUsage = """
        Usage: /attach                    Open the terminal attachment picker
               /attach <image-or-video-file> [file ...]
               /attach list
               /attach delete [all|attachment-number]

        """

    // MARK: - /help

    @Test
    func helpWrapsTheCommandLinesWithTheFixedLines() {
        #expect(
            text(.help(commandHelp: ["/help  Show this help", "/exit  Quit"]))
                == "Type a prompt and press return.\n"
                + "/help  Show this help\n"
                + "/exit  Quit\n"
                + "Live chat: @coordinator <message>, @all <message>, or an @agent-name handle.\n"
                + "Ctrl+G toggles default/full access for local.exec approvals in the interactive panel.\n"
                + "Editing: Ctrl+A/Ctrl+E line start/end, Alt+</Alt+> draft start/end, "
                + "Alt+←/→ (or ESC b / ESC f) word motion.\n\n"
        )
    }

    // MARK: - Sub-agent requirements

    @Test
    func subAgentRequirementNotices() {
        #expect(
            text(.subAgentToolsRequired(command: "/plan"))
                == "ZenCODE: /plan requires the sub-agents tool group. "
                + "Enable it from the ZenCODE TUI with /tools (or switch to an agent that includes it) and try again.\n"
        )
        #expect(
            text(.subAgentToolsRequired(command: "/review"))
                == "ZenCODE: /review requires the sub-agents tool group. "
                + "Enable it from the ZenCODE TUI with /tools (or switch to an agent that includes it) and try again.\n"
        )
        #expect(
            text(.agentRoleUnavailable(.planner))
                == "ZenCODE: no agent profile with the planner role is available for this project. "
                + "Tick one with /agents.\n"
        )
        #expect(
            text(.agentRoleUnavailable(.reviewer))
                == "ZenCODE: no agent profile with the reviewer role is available for this project. "
                + "Tick one with /agents.\n"
        )
    }

    // MARK: - /plan

    @Test
    func planRefusals() {
        #expect(
            text(.planMissingGoal)
                == "ZenCODE: /plan requires a goal. Use /plan <goal> to describe what should "
                + "be planned, or a subcommand: save, load, list, delete, status, approve, clear.\n"
        )
        #expect(
            text(.planDiscussionBlocksMutation)
                == "ZenCODE: finish the current Planner clarification or Goal request, or use /plan clear before "
                + "approving, saving, or loading a plan.\n"
        )
        #expect(
            text(.planUnavailableForSaving)
                == "ZenCODE: no plan is available to save. Run /plan <goal>, or ask an agent "
                + "to produce a plan before using /plan save.\n"
        )
        #expect(
            text(.activePlanAlreadyExists)
                == "ZenCODE: an active plan already exists. Use /plan clear before loading a saved plan.\n"
        )
        #expect(
            text(.savedPlanUnavailable)
                == "ZenCODE: no saved plan is available for this project. Use /plan save first.\n"
        )
        #expect(text(.noSavedPlans) == text(.savedPlanUnavailable))
        #expect(
            text(.savedPlansAllCompleted)
                == "ZenCODE: every saved plan for this project is already completed. "
                + "Use /plan list to review them or /plan delete <plan|all> to remove them.\n"
        )
        #expect(
            text(.savedPlanContextNotAdded)
                == "ZenCODE: the saved plan could not be added to the current session context.\n"
        )
        #expect(
            text(.planDeleteUsage)
                == "ZenCODE: /plan delete requires a plan id, a unique id prefix, or all. "
                + "Use /plan list to review saved plans.\n"
        )
        #expect(
            text(.savedPlanNotFound(availablePlanIDs: ["plan-a", "plan-b"]))
                == "ZenCODE: no saved plan matches. Available plans: plan-a, plan-b.\n"
        )
        #expect(
            text(.savedPlanAmbiguous(matches: ["plan-ab", "plan-ac"]))
                == "ZenCODE: the plan id prefix is ambiguous: plan-ab, plan-ac. Provide more characters.\n"
        )
        #expect(
            text(.planUnavailableForApproval)
                == "ZenCODE: no completed plan is available to approve. "
                + "Run /plan <goal> and wait for it to finish successfully.\n"
        )
    }

    @Test
    func planOutcomes() {
        #expect(
            text(.planSaved(planID: "plan-save"))
                == "Saved plan: plan-save. Use /plan load in a new session to review or revise it.\n"
        )
        #expect(
            text(.savedPlanLoaded(Self.plan()))
                == "Loaded saved plan `plan-load` as an unapproved active plan.\n\n"
                + "1. Read the parser."
                + "\n\nUse /plan approve when it is ready to implement."
        )
        #expect(
            text(.savedPlansDeleted(planIDs: ["plan-a"], activePlanAffected: false))
                == "Deleted saved plan `plan-a`.\n"
        )
        #expect(
            text(.savedPlansDeleted(planIDs: ["plan-a", "plan-b"], activePlanAffected: true))
                == "Deleted 2 saved plans.\n"
                + "The active plan in this session is unaffected; use /plan clear to discard it.\n"
        )
        #expect(
            text(.planClarificationActive(goal: "Fix the parser"))
                == "Planner clarification is active for: Fix the parser\n"
        )
        #expect(
            text(.planAwaitingApprovalGoal)
                == "A descriptive Goal is required before plan approval can continue.\n"
        )
        #expect(text(.noActivePlan) == "No active plan.\n")
        #expect(
            text(.planApprovalGoalPrompt)
                == "Before approving this plan, enter a descriptive Goal for the work it represents.\n"
        )
        #expect(
            text(.planApproved)
                == "Approved the active plan and activated its task graph. "
                + "Starting implementation now; /review will verify task claims against real files.\n\n"
        )
        #expect(text(.planDiscussionCleared) == "Cleared the unfinished planning discussion.\n")
        #expect(text(.noPlanToClear) == "No active plan or planning discussion to clear.\n")
        #expect(
            text(.activePlanCleared)
                == "Cleared the active plan and archived its task graph in this session. "
                + "Saved-plan library copies are unaffected; use /plan delete to remove those.\n"
        )
    }

    @Test
    func planStatusIsTheTableOfThePlanItems() {
        let plan = Self.plan(
            points: [
                TerminalSessionPlanPoint(id: "point-1", text: "Read the parser"),
                TerminalSessionPlanPoint(id: "point-2", text: "Fix a | b", status: .completed),
            ],
            isApproved: true
        )
        #expect(
            text(.planStatus(plan, graph: nil))
                == "## Plan status\n"
                + "\n"
                + "**Goal:** Fix the parser\n"
                + "\n"
                + "**Overall status:** `pending`\n"
                + "\n"
                + "| # | Plan item | Status |\n"
                + "|---:|---|---|\n"
                + "| 1 | Read the parser | `pending` |\n"
                + "| 2 | Fix a \\| b | `completed` |\n"
        )
    }

    @Test
    func savedPlansAreListedAsATable() {
        let savedAt = Date(timeIntervalSince1970: 1_800_000_000)
        let graph = TaskGraphSnapshot(
            id: "plan-1234567890ab",
            source: .plan(planID: "plan-1234567890ab"),
            state: .draft,
            tasks: [
                TaskRecord(id: "task-1", title: "Read", order: 0, status: .completed),
                TaskRecord(id: "task-2", title: "Fix", order: 1),
            ]
        )
        let saved = SavedTaskPlan(
            librarySessionID: "saved-plans-project",
            graph: graph,
            snapshot: TaskGraphSavedPlan(plan: Self.plan(id: "plan-1234567890ab"), savedAt: savedAt)
        )
        // The date is the only part the terminal formats with the locale.
        let savedAtText = savedAt.formatted(date: .abbreviated, time: .shortened)
        #expect(
            text(.savedPlans([saved]))
                == "## Saved plans\n"
                + "\n"
                + "**Total:** 1\n"
                + "\n"
                + "| Plan | Saved | Status | Items done | Goal |\n"
                + "|---|---|---|---:|---|\n"
                + "| `plan-12345678` | \(savedAtText) | `draft` | 1/2 | Fix the parser |\n"
                + "\n"
                + "Use /plan load to restore the newest draft, or /plan delete <plan|prefix|all> to remove saved plans.\n"
        )
    }

    // MARK: - /goal and /review

    @Test
    func workflowAndReviewNotices() {
        #expect(
            text(.workflowMissingGoal)
                == "ZenCODE: /goal requires a goal. Use /goal <goal> to describe the outcome to achieve.\n"
        )
        #expect(
            text(.workflowBlockedByPlan)
                == "ZenCODE: /goal cannot start while an active plan or planning discussion exists. "
                + "Finish it or use /plan clear before starting a workflow.\n"
        )
        #expect(
            text(.workflowAlreadyActive(graphID: "workflow_1", pendingTaskCount: 1))
                == "ZenCODE: a goal workflow is already running (workflow_1, 1 task still open). "
                + "Reply in chat to continue it while it is waiting for you, review it with /tasks, "
                + "or run /tasks clear before starting another /goal.\n"
        )
        #expect(
            text(.workflowAlreadyActive(graphID: "workflow_1", pendingTaskCount: 3))
                == "ZenCODE: a goal workflow is already running (workflow_1, 3 tasks still open). "
                + "Reply in chat to continue it while it is waiting for you, review it with /tasks, "
                + "or run /tasks clear before starting another /goal.\n"
        )
        #expect(text(.noChangesToReview) == "No tracked session file changes to review.\n")
    }

    /// The `/plan` and `/goal` constants moved to the notice text; the
    /// terminal's members of the same name forward to them unchanged.
    @Test
    func theTerminalPlanAndGoalConstantsForwardTheSameTexts() {
        #expect(TerminalChat.planMissingGoalMessage == text(.planMissingGoal))
        #expect(TerminalChat.planUnavailableForApprovalMessage == text(.planUnavailableForApproval))
        #expect(TerminalChat.planDiscussionBlocksMutationMessage == text(.planDiscussionBlocksMutation))
        #expect(TerminalChat.planUnavailableForSavingMessage == text(.planUnavailableForSaving))
        #expect(TerminalChat.savedPlanUnavailableMessage == text(.savedPlanUnavailable))
        #expect(TerminalChat.savedPlansAllTerminalMessage == text(.savedPlansAllCompleted))
        #expect(TerminalChat.planDeleteUsageMessage == text(.planDeleteUsage))
        #expect(TerminalChat.workflowMissingGoalMessage == text(.workflowMissingGoal))
        #expect(TerminalChat.workflowActivePlanMessage == text(.workflowBlockedByPlan))
        #expect(
            TerminalChat.workflowAlreadyActiveMessage(graphID: "workflow_1", pendingTaskCount: 2)
                == text(.workflowAlreadyActive(graphID: "workflow_1", pendingTaskCount: 2))
        )
        #expect(
            TerminalChat.workflowStillOpenMessage(graphID: "workflow_1", pendingTaskCount: 2)
                == "Workflow \"workflow_1\" asked a question and is still open (2 tasks open). "
                + "Your next message answers it on the same task graph; "
                + "use /tasks to review or /tasks clear to stop it.\n"
        )
        #expect(
            TerminalChat.workflowOpenWithoutQuestionMessage(graphID: "workflow_1", pendingTaskCount: 1)
                == "Workflow \"workflow_1\" is still open (1 task open) "
                + "but it is not waiting for an answer, so your next message is an ordinary "
                + "message. Use /tasks to review it or /tasks clear to stop it.\n"
        )
        #expect(
            TerminalChat.workflowRecoverableFailureMessage(graphID: "workflow_1", pendingTaskCount: 2)
                == "Workflow \"workflow_1\" was interrupted and its task graph was kept (2 tasks open). "
                + "Your next message resumes it on the same task graph; "
                + "use /tasks to review or /tasks clear to stop it.\n"
        )
    }

    // MARK: - /tasks

    @Test
    func tasksNotices() {
        #expect(text(.taskIDRequired(action: "show")) == "ZenCODE: /tasks show requires a task id.\n")
        #expect(
            text(.unknownTasksAction(action: "frob"))
                == "ZenCODE: Unknown /tasks action 'frob'. Use status, show, retry, cancel, or clear.\n"
        )
        #expect(text(.noTaskGraph) == "No task graph for this session.\n")
        #expect(text(.taskRetried(taskID: "task-1")) == "Retried task task-1.\n")
        #expect(text(.taskCancelled(taskID: "task-1")) == "Cancelled task task-1.\n")
        #expect(text(.taskGraphsCleared) == "Cleared the session task graphs.\n")
    }

    @Test
    func taskDetailIsTheTaskMarkdown() {
        let task = TaskRecord(
            id: "task-1",
            title: "Parse\nflags",
            details: "Read the\r\nparser",
            order: 0,
            status: .inProgress,
            priority: .high,
            dependsOn: ["task-0"],
            acceptanceCriteria: ["Flags parse", "Tests pass"],
            attempts: [
                TaskAttempt(
                    id: "attempt-1",
                    ordinal: 1,
                    agentID: "agent-a",
                    executor: .subAgent,
                    status: .failed,
                    startedAt: Self.createdAt,
                    output: "partial",
                    error: "timeout\nhit"
                ),
            ],
            result: TaskResult(evidence: [
                TaskEvidence(
                    id: "evidence-1",
                    kind: "test",
                    summary: "swift test passed",
                    location: "Tests/A.swift",
                    createdAt: Self.createdAt
                ),
            ]),
            revision: 3,
            complexity: 7
        )
        let view = TaskRecordView(
            graphID: "graph-1",
            graphRevision: 4,
            graphState: .active,
            task: task,
            isRunnable: false,
            blockedBy: [],
            blockedReason: "waiting on task-0",
            dependents: ["task-2"]
        )
        let expected = "## Task `task-1`\n"
            + "\n"
            + "**Title:** Parse flags\n"
            + "\n"
            + "**Status:** `in_progress` · **priority:** `high` · **complexity:** `7/10` · **revision:** 3\n"
            + "\n"
            + "**Runnable:** `false`\n"
            + "**Runnable reason:** waiting on task-0\n"
            + "\n"
            + "Read the parser\n"
            + "\n"
            + "**Dependencies:** `task-0`\n"
            + "\n"
            + "**Dependents:** `task-2`\n"
            + "\n"
            + "### Acceptance criteria\n"
            + "- Flags parse\n"
            + "- Tests pass\n"
            + "\n"
            + "### Attempts\n"
            + "- **#1** `failed` · agent `agent-a` · `attempt-1`\n"
            + "  - output: partial\n"
            + "  - error: timeout hit\n"
            + "\n"
            + "### Evidence\n"
            + "- `test` (`Tests/A.swift`): swift test passed\n"
        #expect(text(.taskDetail(view)) == expected)
        #expect(TerminalChat.taskDetailMarkdown(view) == expected)
    }

    // MARK: - /changes, /undo, and /artifacts

    @Test
    func fileChangeNotices() {
        let summary = TurnFileChangeSummary(entries: [
            .init(
                path: "Sources/New.swift", additions: 2, deletions: 0, status: .added,
                isBinary: false, existedBefore: false, beforeDataBase64: nil, patch: nil
            ),
            .init(
                path: "assets/logo.png", additions: 0, deletions: 0, status: .modified,
                isBinary: true, existedBefore: nil, beforeDataBase64: nil, patch: nil
            ),
        ])
        let expectedSummary = "\n🪬 Summary: 2 files  +2 -0\n"
            + "  added Sources/New.swift  +2 -0\n"
            + "  modified assets/logo.png (binary)\n"
            + "Undo is not available for this summary.\n"
        #expect(text(.noTrackedFileChanges) == "No tracked file changes.\n")
        #expect(text(.fileChangeSummary(summary, includesDiff: false)) == expectedSummary)
        #expect(text(.fileChangeSummary(summary, includesDiff: true)) == expectedSummary)
        #expect(TerminalChat.renderFileChangeSummary(summary) == expectedSummary)
        #expect(text(.fileChangesReverted) == "File changes reverted.\n")
        #expect(
            text(.fileChangesNotUndone(description: "No file changes to undo."))
                == "No file changes to undo.\n"
        )
        #expect(
            text(.fileChangesUndoFailed(description: "Permission denied."))
                == "ZenCODE: unable to undo file changes: Permission denied.\n"
        )
        // `/undo` with arguments fell to the unknown-command branch.
        #expect(text(.unknownCommand(line: "/undo now")) == "ZenCODE: unknown command '/undo'.\n")
        #expect(text(.unknownCommand(line: "  /undo  ")) == "ZenCODE: unknown command '/undo'.\n")
    }

    @Test
    func artifactNotices() {
        let turns: [SessionFileArtifactHistory.Turn] = [
            .init(number: 1, artifacts: [
                FileChangeArtifact(
                    absolutePath: "/project/assets/logo.png",
                    displayPath: "assets/logo.png",
                    status: .added,
                    hasLineCounts: false,
                    isBinary: true
                ),
                FileChangeArtifact(
                    absolutePath: "/project/README.md",
                    displayPath: "README.md",
                    status: .modified,
                    additions: 3,
                    deletions: 1,
                    explanation: "Document the flag."
                ),
            ]),
            .init(number: 2, artifacts: [
                FileChangeArtifact(
                    absolutePath: "/project/a`b.txt",
                    displayPath: "",
                    status: .deleted,
                    deletions: 2
                ),
            ]),
        ]
        let expected = "\n🪬 Artifacts\n"
            + "\n"
            + "### Turn 1 — 2 files\n"
            + "\n"
            + "**added `assets/logo.png`** (binary)\n"
            + "\n"
            + "**modified `README.md`**  +3 -1\n"
            + "Explanation: Document the flag.\n"
            + "\n"
            + "### Turn 2 — 1 file\n"
            + "\n"
            + "**deleted `/project/a\\`b.txt`**  +0 -2\n"
        #expect(text(.noFileArtifacts) == "No file artifacts in the current session.\n")
        #expect(text(.fileArtifacts(turns)) == expected)
        // Without any diff to draw, the terminal's `/artifacts` Markdown is the
        // same text.
        #expect(TerminalChat.renderFileArtifacts(turns, includeHistoryHeadings: true) == expected)
        #expect(text(.artifactsTakeNoArguments) == "ZenCODE: /artifacts does not accept arguments.\n")
    }

    // MARK: - /open

    @Test
    func openNotices() {
        let candidates = [
            ChatOpenCandidate(target: "/project/a.txt", display: "a.txt", kind: .file),
            ChatOpenCandidate(target: "https://example.com", display: "https://example.com", kind: .url),
        ]
        let list = "Files and URLs in this conversation:\n"
            + "  1. a.txt (file)\n"
            + "  2. https://example.com (url)\n"
        #expect(text(.openTargetNotFound(argument: "missing.txt")) == "ZenCODE: file not found: missing.txt\n")
        #expect(text(.noOpenCandidates) == "No files or URLs found in this conversation.\n")
        #expect(text(.nothingOpened) == "Nothing opened.\n")
        #expect(
            text(.opening(ChatOpenTarget(target: "/project/a.txt", kind: .file)))
                == "Opening /project/a.txt\n"
        )
        #expect(
            text(.opening(ChatOpenTarget(target: "https://example.com", kind: .url)))
                == "Opening https://example.com\n"
        )
        #expect(candidates[1].openTarget == ChatOpenTarget(target: "https://example.com", kind: .url))
        #expect(
            text(.requiresInteractiveHost(.openSelection(candidates: candidates)))
                == list + "Selecting an item to open requires an interactive terminal.\n"
        )
        // The terminal's list forwards to the same text.
        #expect(
            TerminalChat.renderOpenCandidateList([
                TerminalOpenCandidate(target: "/project/a.txt", display: "a.txt", kind: .file),
                TerminalOpenCandidate(target: "https://example.com", display: "https://example.com", kind: .url),
            ]) == list
        )
    }

    // MARK: - /attach

    @Test
    func attachmentUsageNotices() {
        #expect(text(.attachmentUsage) == Self.attachmentUsage)
        #expect(text(.attachmentDeleteUsage) == "Usage: /attach delete [all|attachment-number]\n")
        #expect(
            text(.requiresInteractiveHost(.attachmentSelection))
                == "ZenCODE: /attach without a path requires an interactive terminal.\n" + Self.attachmentUsage
        )
        // The terminal's usage texts forward to the same texts.
        #expect(TerminalChat.renderAttachmentUsage() == Self.attachmentUsage)
        #expect(TerminalChat.renderAttachmentDeleteUsage() == "Usage: /attach delete [all|attachment-number]\n")
    }

    @Test
    func attachmentNotices() {
        let attachments = [
            AgentRuntimeAttachment(kind: .image, contentType: "image/png", originalFilename: "logo.png"),
            AgentRuntimeAttachment(kind: .video, originalFilename: "clip.mov"),
        ]
        #expect(text(.attachmentSelectionCancelled) == "Attachment selection cancelled.\n")
        #expect(text(.attachmentsAdded(addedCount: 1, pendingCount: 1)) == "Added 1 attachment. 1 pending.\n")
        #expect(text(.attachmentsAdded(addedCount: 2, pendingCount: 3)) == "Added 2 attachments. 3 pending.\n")
        #expect(text(.noPendingAttachments) == "No pending attachments.\n")
        #expect(text(.pendingAttachments([])) == "No pending attachments.\n")
        #expect(
            text(.pendingAttachments(attachments))
                == "Pending attachments:\n"
                + "  1. logo.png (image, image/png)\n"
                + "  2. clip.mov (video)\n"
                + "Send a prompt to include them, or press return on an empty prompt.\n"
        )
        #expect(text(.pendingAttachmentsRemoved) == "Removed all pending attachments.\n")
        #expect(text(.attachmentRemoved(filename: "logo.png")) == "Removed attachment: logo.png\n")
        #expect(
            text(.invalidAttachmentSelection(argument: "9"))
                == "ZenCODE: Invalid attachment selection: 9.\n"
        )
        #expect(text(.unterminatedAttachmentQuote) == "ZenCODE: Unterminated quoted attachment path.\n")
        #expect(
            text(.attachmentDirectoryUnreadable(path: "/Users/me"))
                == "Unable to read attachment directory: /Users/me.\n"
                + "Grant ZenCODE access in System Settings > Privacy & Security > Files and Folders.\n"
        )
        #expect(
            text(.noAttachableFiles(directoryPath: "/Users/me"))
                == "No image or video files found in /Users/me.\n"
        )
    }

    /// The size of an attachment is formatted with the locale, so the size in
    /// the expected line is formatted the way the terminal formatted it.
    @Test
    func theAttachmentLineNamesTheKindTheTypeAndTheSize() {
        let attachments = [
            AgentRuntimeAttachment(
                kind: .image,
                data: Data(repeating: 0, count: 2_048),
                contentType: "image/png",
                originalFilename: "logo.png"
            ),
            AgentRuntimeAttachment(kind: .video, originalFilename: "clip.mov"),
        ]
        let size = ByteCountFormatter.string(fromByteCount: 2_048, countStyle: .file)
        let expected = [
            "  1. logo.png (image, image/png, \(size))",
            "  2. clip.mov (video)",
        ]
        for (index, attachment) in attachments.enumerated() {
            #expect(
                ChatSessionNoticeText.attachmentLine(number: index + 1, attachment: attachment)
                    == expected[index]
            )
            // The terminal's line forwards to the same text.
            #expect(
                TerminalChat.renderAttachmentLine(number: index + 1, attachment: attachment)
                    == expected[index]
            )
        }
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
            .taskDetail(view),
            .fileArtifacts([]),
        ]
        let system: [ChatSessionNotice] = [
            .help(commandHelp: []),
            .noSavedPlans,
            .planSaved(planID: "plan-a"),
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
