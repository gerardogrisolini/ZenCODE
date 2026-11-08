import AppKit
import Foundation
import SwiftUI
import Testing
import ToolCore
import ZenAppTheme
import ZenCODECore

@testable import ZenAppTranscript

/// Lays every public view out in an `NSHostingView` in both color schemes,
/// with real payloads, so a view whose body traps at run time fails here.
@Suite("Transcript views render")
@MainActor
struct ZenTranscriptViewRenderTests {
    private func layOut(_ view: some View, scheme: ColorScheme) -> CGSize {
        let host = NSHostingView(rootView: view
            .environment(\.colorScheme, scheme)
            .frame(width: 560))
        host.layoutSubtreeIfNeeded()
        return host.fittingSize
    }

    private static let execCall = DirectAgentToolCall(
        id: "1",
        name: "local.exec",
        argumentsObject: ["command": "swift build"],
        argumentsJSON: "",
        presentation: ToolPresentationDefinition(
            title: "Command", action: "Run", kind: .execute, target: .argument(["command"], format: .command)
        )
    )

    private static let summary = TurnFileChangeSummary(entries: [
        .init(
            path: "a.swift", additions: 1, deletions: 1, status: .modified, isBinary: false,
            existedBefore: nil, beforeDataBase64: nil, patch: "@@ -1 +1 @@\n-x\n+y"
        )
    ])

    private static let artifactTurn = SessionFileArtifactHistory.Turn(number: 1, artifacts: [
        FileChangeArtifact(
            absolutePath: "/p/a.swift", displayPath: "a.swift", status: .modified,
            additions: 1, deletions: 1, oldText: "x\n", newText: "y\n"
        )
    ])

    private static var taskOverview: ChatTaskGraphOverview {
        let record = TaskRecord(id: "t1", title: "Task", order: 0, status: .inProgress, dependsOn: ["t0"])
        let graph = TaskGraphSnapshot(id: "g", source: .manual, state: .active, tasks: [record])
        return ChatTaskGraphOverview(graph: graph, tasks: [
            TaskRecordView(
                graphID: "g", graphRevision: 1, graphState: .active, task: record,
                isRunnable: false, blockedBy: ["t0"], blockedReason: nil, dependents: []
            )
        ])
    }

    /// A pending agent that reasons, with no tool running.
    private static var reasoningSubAgent: DirectSubAgentRuntime.AgentSnapshot {
        DirectSubAgentRuntime.AgentSnapshot(
            id: "a4", name: "planner", role: "Planner",
            status: .running, pending: true,
            currentActivity: "Reading", currentActivityKind: .thinking,
            currentThought: "Reading",
            latestOutput: nil, latestError: nil, createdAt: .now, updatedAt: .now
        )
    }

    /// A pending agent that writes its message after a tool completed: the
    /// snapshot keeps the call's name, but no tool runs.
    private static var writingAfterToolSubAgent: DirectSubAgentRuntime.AgentSnapshot {
        DirectSubAgentRuntime.AgentSnapshot(
            id: "a5", name: "writer", role: "Developer",
            status: .running, pending: true,
            currentToolName: "local.exec", currentToolTarget: "swift build", currentToolIsRunning: false,
            latestOutput: nil, latestError: nil, createdAt: .now, updatedAt: .now
        )
    }

    private static var subAgentOverview: ChatSubAgentOverview {
        ChatSubAgentOverview(snapshots: [
            DirectSubAgentRuntime.AgentSnapshot(
                id: "a1", taskID: "t1", taskAttemptOrdinal: 2, name: "dev", role: "Developer", profileName: "Developer",
                status: .running, pending: true, configuredModelID: "model",
                currentActivity: "Reading", currentActivityKind: .thinking,
                currentToolName: "local.exec", currentToolTarget: "swift build", currentToolIsRunning: true,
                latestMetrics: DirectAgentGenerationMetrics(promptTokenCount: 10, completionTokenCount: 5),
                latestOutput: nil, latestError: "boom", createdAt: .now, updatedAt: .now
            ),
            DirectSubAgentRuntime.AgentSnapshot(
                id: "a2", name: "reviewer", role: "Reviewer",
                status: .queued, pending: true,
                latestOutput: nil, latestError: nil, createdAt: .now, updatedAt: .now
            ),
            DirectSubAgentRuntime.AgentSnapshot(
                id: "a3", name: "builder", role: "Builder",
                status: .idle, pending: false,
                latestOutput: "Done.", latestError: nil, createdAt: .now, updatedAt: .now
            )
        ])
    }

    /// Sub-agents that all finished: the card has nothing to show.
    private static var finishedSubAgentOverview: ChatSubAgentOverview {
        ChatSubAgentOverview(snapshots: [
            DirectSubAgentRuntime.AgentSnapshot(
                id: "a3", name: "builder", role: "Builder",
                status: .idle, pending: false,
                latestOutput: "Done.", latestError: nil, createdAt: .now, updatedAt: .now
            ),
            DirectSubAgentRuntime.AgentSnapshot(
                id: "a4", name: "tester", role: "Tester",
                status: .failed, pending: false,
                latestOutput: nil, latestError: "The build failed.", createdAt: .now, updatedAt: .now
            )
        ])
    }

    @Test("every public view lays out in light and dark", arguments: [ColorScheme.light, .dark])
    func everyViewLaysOut(scheme: ColorScheme) throws {
        let views: [AnyView] = [
            AnyView(ZenUserPromptView(
                text: "Hello",
                attachments: [AgentRuntimeAttachment(kind: .image, originalFilename: "a.png")],
                origin: .telegram
            )),
            AnyView(ZenUserPromptView(
                text: "Look",
                attachments: [
                    AgentRuntimeAttachment(
                        kind: .image,
                        data: try ZenTestImages.png(width: 800, height: 400),
                        originalFilename: "shot.png"
                    ),
                    AgentRuntimeAttachment(kind: .video, originalFilename: "clip.mov")
                ],
                origin: .app
            )),
            AnyView(ZenCommandLineView(text: "/tasks show t1")),
            AnyView(ZenAssistantTextView(text: "**Done**", isStreaming: true)),
            AnyView(ZenThoughtView(text: "Thinking hard", isStreaming: false)),
            AnyView(ZenToolCallView(call: Self.execCall, result: nil)),
            AnyView(ZenToolCallView(
                call: Self.execCall,
                result: DirectAgentToolResult(output: "exit_code: 1\nstderr:\nboom", summary: "exit_code: 1"),
                duration: .milliseconds(12)
            )),
            AnyView(ZenToolCallDetailsView(
                call: Self.execCall,
                result: DirectAgentToolResult(output: "exit_code: 0", summary: "exit_code: 0")
            )),
            AnyView(ZenFileArtifactsView(turn: Self.artifactTurn, agentID: "agent_1")),
            AnyView(ZenFileArtifactCard(artifact: Self.artifactTurn.artifacts[0], agentID: nil)),
            AnyView(ZenFileArtifactCard(artifact: Self.artifactTurn.artifacts[0], agentID: "agent_1")),
            AnyView(ZenFileArtifactCard(
                artifact: FileChangeArtifact(
                    absolutePath: "/p/logo.png", displayPath: "logo.png", status: .added,
                    hasLineCounts: false, isBinary: true
                ),
                agentID: nil
            )),
            AnyView(ZenNoticeView(notice: .sessionSaved(name: "s", messageCount: 2))),
            AnyView(ZenNoticeView(notice: .operationFailed(description: "boom"))),
            AnyView(ZenNoticeView(notice: .fileChangeSummary(Self.summary, includesDiff: true))),
            AnyView(ZenNoticeView(notice: .fileArtifacts([Self.artifactTurn]))),
            AnyView(ZenWorkflowNoticeView(notice: .blocked(graphID: "g", message: "stuck"))),
            AnyView(ZenFileChangeSummaryView(summary: Self.summary, includesDiff: false)),
            AnyView(ZenLocalMessageView(text: "Saved.\n", isFailure: false)),
            AnyView(ZenTaskGraphCard(overview: Self.taskOverview)),
            AnyView(ZenSubAgentsCard(overview: Self.subAgentOverview)),
            AnyView(ZenSubAgentsCard(overview: Self.subAgentOverview, onSelect: { _ in })),
            AnyView(ZenSubAgentDetailCard(snapshot: Self.subAgentOverview.snapshots[0])),
            AnyView(ZenSubAgentDetailCard(snapshot: Self.finishedSubAgentOverview.snapshots[1])),
            // Reasoning in progress, then the placeholder of a queued agent.
            AnyView(ZenSubAgentLiveActivityView(snapshot: Self.reasoningSubAgent)),
            AnyView(ZenSubAgentLiveActivityView(snapshot: Self.subAgentOverview.snapshots[1])),
            AnyView(ZenSubAgentLiveActivityView(snapshot: Self.writingAfterToolSubAgent)),
            AnyView(ZenSubAgentsCard(overview: ChatSubAgentOverview(snapshots: [Self.writingAfterToolSubAgent]))),
            AnyView(ZenWelcomeView(workspace: URL(fileURLWithPath: "/tmp"))),
            AnyView(ZenWelcomeView(
                workspace: URL(fileURLWithPath: "/tmp"),
                agentName: "Developer",
                activeTools: ChatActiveToolsSummary(groups: [.init(title: "Shell", toolCount: 2)]),
                activeSkills: [],
                commands: ["/help", "/exit"]
            )),
            AnyView(ZenSessionLoadingView(name: "session")),
            AnyView(ZenSessionLoadingView(name: "session", step: "Loading the model and tools…")),
            AnyView(ZenDiffRowsView(rows: ZenToolCallFormatting.lineDiff(old: "a\nb", new: "a\nc"))),
            AnyView(ZenCodeLinesView(content: "let a = 1\nlet b = 2")),
            AnyView(ZenPatchLinesView(lines: ZenFileChangeFormatting.patchLines("@@ -1 +1 @@\n-x\n+y")))
        ]
        for view in views {
            let size = layOut(view, scheme: scheme)
            #expect(size.height > 0)
        }
    }

    @Test("the sub-agents card draws nothing without agents in progress", arguments: [ColorScheme.light, .dark])
    func subAgentsCardIsEmptyWithoutPendingAgents(scheme: ColorScheme) {
        #expect(layOut(ZenSubAgentsCard(overview: ChatSubAgentOverview(snapshots: [])), scheme: scheme).height == 0)
        #expect(layOut(ZenSubAgentsCard(overview: Self.finishedSubAgentOverview), scheme: scheme).height == 0)
        #expect(layOut(
            ZenSubAgentsCard(overview: Self.finishedSubAgentOverview, onSelect: { _ in }),
            scheme: scheme
        ).height == 0)
        #expect(layOut(ZenSubAgentsCard(overview: Self.subAgentOverview), scheme: scheme).height > 0)
    }

    @Test("the live activity of a sub-agent tab draws nothing for an agent that is not pending or runs a tool", arguments: [ColorScheme.light, .dark])
    func liveActivityIsEmptyWhenNotPending(scheme: ColorScheme) {
        for snapshot in Self.finishedSubAgentOverview.snapshots {
            #expect(layOut(ZenSubAgentLiveActivityView(snapshot: snapshot), scheme: scheme).height == 0)
        }
        #expect(layOut(ZenSubAgentLiveActivityView(snapshot: nil), scheme: scheme).height == 0)
        // Reasoning while `local.exec` runs: the transcript has the call's row.
        #expect(layOut(ZenSubAgentLiveActivityView(snapshot: Self.subAgentOverview.snapshots[0]), scheme: scheme).height == 0)
    }

    @Test("the live activity of a sub-agent tab draws the placeholder once the last tool completed", arguments: [ColorScheme.light, .dark])
    func liveActivityShowsThePlaceholderAfterATool(scheme: ColorScheme) {
        #expect(layOut(ZenSubAgentLiveActivityView(snapshot: Self.writingAfterToolSubAgent), scheme: scheme).height > 0)
    }

    @Test("an artifact card splits its path into the file name and the folder before it")
    func artifactCardNameAndDirectory() {
        let cases: [(path: String, name: String, directory: String?)] = [
            ("Sources/App/App.swift", "App.swift", "Sources/App"),
            ("/tmp/a.txt", "a.txt", "/tmp"),
            ("/a.txt", "a.txt", "/"),
            ("README.md", "README.md", nil),
            ("/", "/", nil),
        ]
        for (path, name, directory) in cases {
            let split = ZenFileArtifactCard.nameAndDirectory(of: path)
            #expect(split.name == name, "\(path)")
            #expect(split.directory == directory, "\(path)")
        }
    }

    @Test("an artifact's diff and patch color their source with the environment's highlighter", arguments: [ColorScheme.light, .dark])
    func artifactDiffUsesTheHighlighter(scheme: ColorScheme) {
        let recorder = ZenHighlightRecorder()
        let highlighter = ZenCodeHighlighter { line, language, _ in
            recorder.record(line: line, language: language)
            return AttributedString(line)
        }
        let modified = FileChangeArtifact(
            absolutePath: "/p/Sources/App.swift", displayPath: "Sources/App.swift", status: .modified,
            additions: 1, deletions: 1, oldText: "let a = 1\n", newText: "let a = 2\n"
        )
        let patched = FileChangeArtifact(
            absolutePath: "/p/Sources/Tool.py", displayPath: "Sources/Tool.py", status: .modified,
            additions: 1, deletions: 1, patch: "@@ -1 +1 @@\n-x = 1\n+x = 2\n"
        )
        let notes = FileChangeArtifact(
            absolutePath: "/p/README.md", displayPath: "README.md", status: .modified,
            additions: 1, deletions: 1, oldText: "# Old\n", newText: "# New\n"
        )
        for artifact in [modified, patched, notes] {
            let size = layOut(
                ZenFileArtifactDetails(artifact: artifact, explanation: nil)
                    .environment(\.zenCodeHighlighter, highlighter),
                scheme: scheme
            )
            #expect(size.height > 0)
        }
        let calls = recorder.calls
        #expect(calls.contains(.init(line: "let a = 2", language: "swift")))
        #expect(calls.contains(.init(line: "let a = 1", language: "swift")))
        // The patch hands over the source without its marker.
        #expect(calls.contains(.init(line: "x = 2", language: "python")))
        #expect(calls.contains(.init(line: "x = 1", language: "python")))
        #expect(!calls.contains { $0.line.hasPrefix("@@") })
        // A Markdown file has no language: nothing is highlighted.
        #expect(!calls.contains { $0.line.contains("Old") || $0.line.contains("New") })
    }
}

/// The lines a test highlighter was asked to color.
private final class ZenHighlightRecorder: @unchecked Sendable {
    struct Call: Equatable {
        let line: String
        let language: String
    }

    private let lock = NSLock()
    private var recorded: [Call] = []

    var calls: [Call] {
        lock.withLock { recorded }
    }

    func record(line: String, language: String) {
        lock.withLock { recorded.append(Call(line: line, language: language)) }
    }
}
