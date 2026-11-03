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

    private static var subAgentOverview: ChatSubAgentOverview {
        ChatSubAgentOverview(snapshots: [
            DirectSubAgentRuntime.AgentSnapshot(
                id: "a1", name: "dev", role: "Developer", profileName: "Developer",
                status: .running, pending: true, configuredModelID: "model",
                currentActivity: "Reading", currentActivityKind: .thinking,
                currentToolName: "local.exec", currentToolTarget: "swift build",
                latestMetrics: DirectAgentGenerationMetrics(promptTokenCount: 10, completionTokenCount: 5),
                latestOutput: nil, latestError: "boom", createdAt: .now, updatedAt: .now
            )
        ])
    }

    @Test("every public view lays out in light and dark", arguments: [ColorScheme.light, .dark])
    func everyViewLaysOut(scheme: ColorScheme) {
        let views: [AnyView] = [
            AnyView(ZenUserPromptView(
                text: "Hello",
                attachments: [AgentRuntimeAttachment(kind: .image, originalFilename: "a.png")],
                origin: .telegram
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
            AnyView(ZenWelcomeView(workspace: URL(fileURLWithPath: "/tmp"), modelID: "model")),
            AnyView(ZenDiffRowsView(rows: ZenToolCallFormatting.lineDiff(old: "a\nb", new: "a\nc"))),
            AnyView(ZenCodeLinesView(content: "let a = 1\nlet b = 2")),
            AnyView(ZenPatchLinesView(lines: ZenFileChangeFormatting.patchLines("@@ -1 +1 @@\n-x\n+y")))
        ]
        for view in views {
            let size = layOut(view, scheme: scheme)
            #expect(size.height > 0)
        }
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
}
