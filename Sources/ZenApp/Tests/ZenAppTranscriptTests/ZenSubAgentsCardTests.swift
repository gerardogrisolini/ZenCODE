//
//  ZenSubAgentsCardTests.swift
//  ZenAppTranscriptTests
//
//  Tests of the sub-agents card of the transcript: the visible snapshots, the
//  summary, the metadata, the activity phases and the live activity.
//

import Foundation
import SwiftUI
import Testing
import ToolCore
import ZenAppTheme
import ZenCODECore

@testable import ZenAppTranscript

@Suite("Sub-agents card")
struct ZenSubAgentsCardTests {
    private let palette = ZenPalette.dark

    private func snapshot(
        id: String = "agent",
        name: String = "agent",
        profileName: String? = nil,
        taskID: String? = nil,
        taskAttemptOrdinal: Int? = nil,
        status: DirectSubAgentRuntime.Status = .running,
        configuredModelID: String? = nil,
        modelID: String? = nil,
        activity: String? = nil,
        activityKind: DirectSubAgentRuntime.ActivityKind? = nil,
        thought: String? = nil,
        toolName: String? = nil,
        toolIsRunning: Bool = false,
        metrics: DirectAgentGenerationMetrics? = nil,
        output: String? = nil
    ) -> DirectSubAgentRuntime.AgentSnapshot {
        DirectSubAgentRuntime.AgentSnapshot(
            id: id,
            taskID: taskID,
            taskAttemptOrdinal: taskAttemptOrdinal,
            name: name,
            profileName: profileName,
            status: status,
            pending: status.isPending,
            configuredModelID: configuredModelID,
            modelID: modelID,
            currentActivity: activity,
            currentActivityKind: activityKind,
            currentThought: thought,
            currentToolName: toolName,
            currentToolIsRunning: toolIsRunning,
            latestMetrics: metrics,
            latestOutput: output,
            latestError: nil,
            createdAt: .now,
            updatedAt: .now
        )
    }

    /// The metadata lines as plain text.
    private func metadata(_ snapshot: DirectSubAgentRuntime.AgentSnapshot) -> [String] {
        ZenSubAgentRow.metadataLines(for: snapshot, palette: palette).map { $0.map(\.text).joined() }
    }

    @Test("only the agents in progress are shown, in the given order")
    func visibleSnapshotsKeepOnlyPending() {
        let snapshots = [
            snapshot(id: "a", status: .running),
            snapshot(id: "b", status: .idle, output: "done"),
            snapshot(id: "c", status: .queued),
            snapshot(id: "d", status: .failed),
            snapshot(id: "e", status: .standby),
            snapshot(id: "f", status: .closed),
            snapshot(id: "g", status: .running)
        ]
        #expect(ZenSubAgentsCard.visibleSnapshots(snapshots).map(\.id) == ["a", "c", "g"])
        #expect(ZenSubAgentsCard.visibleSnapshots([]).isEmpty)
        #expect(ZenSubAgentsCard.visibleSnapshots([snapshot(status: .idle)]).isEmpty)
    }

    @Test("the summary counts the agents in progress")
    func summaryCountsVisibleAgents() {
        let visible = ZenSubAgentsCard.visibleSnapshots([
            snapshot(id: "a", status: .running),
            snapshot(id: "b", status: .queued),
            snapshot(id: "c", status: .idle)
        ])
        let segments = ZenSubAgentsCard.summarySegments(visible)
        #expect(segments.map(\.text) == ["2 in progress"])
        #expect(segments.map(\.role) == [nil])
    }

    @Test("metadata shows agent, task, attempt, model, and tokens when present")
    func metadataWithEverything() {
        let lines = metadata(snapshot(
            profileName: "Builder",
            taskID: "transcript-views",
            taskAttemptOrdinal: 2,
            configuredModelID: "claude-opus",
            modelID: "claude-opus-4",
            metrics: DirectAgentGenerationMetrics(
                promptTokenCount: 1_250,
                cachedPromptTokenCount: 48_000,
                completionTokenCount: 312
            )
        ))
        #expect(lines == [
            "agent: Builder",
            "task: transcript-views  ·  attempt: 2",
            "model: claude-opus  ·  c:48.0k p:1.2k g:312"
        ])
        #expect(!lines.joined().contains("id:"))
    }

    @Test("metadata leaves out what the snapshot does not have")
    func metadataOmitsMissingValues() {
        // No profile, task, model, or metrics: nothing.
        #expect(metadata(snapshot()).isEmpty)
        // A blank profile is not shown.
        #expect(metadata(snapshot(profileName: "  ")).isEmpty)
        // An attempt without a task is not shown.
        #expect(metadata(snapshot(taskAttemptOrdinal: 3)).isEmpty)
        // A task without an attempt.
        #expect(metadata(snapshot(taskID: "t1")) == ["task: t1"])
        // Only the agent profile.
        #expect(metadata(snapshot(profileName: "Tester")) == ["agent: Tester"])
    }

    @Test("the model falls back to the reported one and the counters can stand alone")
    func metadataModelAndTokens() {
        #expect(metadata(snapshot(modelID: "gpt-5")) == ["model: gpt-5"])
        #expect(metadata(snapshot(configuredModelID: " ", modelID: "gpt-5")) == ["model: gpt-5"])
        // Only some of the counters.
        let partial = DirectAgentGenerationMetrics(promptTokenCount: 10, completionTokenCount: 5)
        #expect(metadata(snapshot(configuredModelID: "m", metrics: partial)) == ["model: m  ·  p:10 g:5"])
        // Counters without a model.
        #expect(metadata(snapshot(metrics: partial)) == ["p:10 g:5"])
        // Metrics without any counter.
        #expect(metadata(snapshot(
            metrics: DirectAgentGenerationMetrics(promptTokenCount: nil, completionTokenCount: nil)
        )).isEmpty)
    }

    @Test("metadata labels are muted and values use the inline-code color")
    func metadataColors() {
        let lines = ZenSubAgentRow.metadataLines(
            for: snapshot(
                profileName: "Developer",
                taskID: "t1",
                taskAttemptOrdinal: 1,
                configuredModelID: "m",
                metrics: DirectAgentGenerationMetrics(promptTokenCount: 10, completionTokenCount: nil)
            ),
            palette: palette
        )
        #expect(lines.count == 3)
        let labels: Set<String> = ["agent: ", "task: ", "attempt: ", "model: ", "  ·  ", "p:"]
        for run in lines.flatMap(\.self) {
            if labels.contains(run.text) {
                #expect(run.color == palette.textMuted, "\(run.text)")
            } else {
                #expect(run.color == palette.inlineCodeForeground, "\(run.text)")
            }
        }
    }

    @Test("the activity follows the terminal: reasoning, message, tool, or the placeholder")
    func activityPhases() {
        let thinking = ZenSubAgentActivity(snapshot(
            activity: "Checking\nthe palette.", activityKind: .thinking
        ))
        #expect(thinking.phase == .thinking(paragraph: "Checking the palette."))
        #expect(!thinking.showsThinkingPlaceholder)

        // Reasoning without a paragraph yet is still the thinking row.
        let bare = ZenSubAgentActivity(snapshot(activityKind: .thinking))
        #expect(bare.phase == .thinking(paragraph: nil))
        #expect(!bare.showsThinkingPlaceholder)

        let message = ZenSubAgentActivity(snapshot(activity: "Writing the file.", activityKind: .content))
        #expect(message.phase == .message("Writing the file."))
        #expect(ZenSubAgentActivity(snapshot(activity: "No kind.")).phase == .message("No kind."))

        let tool = ZenSubAgentActivity(snapshot(toolName: "local.exec", toolIsRunning: true))
        #expect(tool.phase == .none)
        #expect(tool.toolName == "local.exec")
        #expect(tool.toolIsRunning)
        #expect(!tool.showsThinkingPlaceholder)

        // A tool that completed keeps its row (the overview shows the last
        // call) but no longer runs: the agent writes its next message, so the
        // placeholder is back.
        let completed = ZenSubAgentActivity(snapshot(toolName: "local.exec", toolIsRunning: false))
        #expect(completed.phase == .none)
        #expect(completed.toolName == "local.exec")
        #expect(!completed.toolIsRunning)
        #expect(completed.showsThinkingPlaceholder)

        // With the message text of the agent the overview shows the message
        // row, not the placeholder, as before.
        let writing = ZenSubAgentActivity(snapshot(
            activity: "Writing the file.", activityKind: .content, toolName: "local.exec"
        ))
        #expect(writing.phase == .message("Writing the file."))
        #expect(writing.toolName == "local.exec")
        #expect(!writing.showsThinkingPlaceholder)

        // A pending agent with nothing to show holds the thinking placeholder.
        let idleWork = ZenSubAgentActivity(snapshot(status: .queued))
        #expect(idleWork.phase == .none)
        #expect(idleWork.toolName == nil)
        #expect(!idleWork.toolIsRunning)
        #expect(idleWork.showsThinkingPlaceholder)
    }

    @Test("a hidden tool is left out and does not stop the placeholder, running or not")
    func hiddenToolIsExcluded() {
        for isRunning in [true, false] {
            let hidden = ZenSubAgentActivity(snapshot(toolName: "agent.message", toolIsRunning: isRunning))
            #expect(hidden.toolName == nil)
            #expect(!hidden.toolIsRunning)
            #expect(hidden.showsThinkingPlaceholder)
        }

        let blank = ZenSubAgentActivity(snapshot(activity: "  \n ", toolName: "  ", toolIsRunning: true))
        #expect(blank.phase == .none)
        #expect(blank.toolName == nil)
        #expect(!blank.toolIsRunning)
        #expect(blank.showsThinkingPlaceholder)

        // A finished agent has no placeholder.
        #expect(!ZenSubAgentActivity(snapshot(status: .idle)).showsThinkingPlaceholder)
    }

    @Test("the live activity of a tab: never empty while pending, except while a tool runs")
    func liveActivity() {
        #expect(ZenSubAgentLiveActivity(snapshot(
            activityKind: .thinking, thought: "Checking\nthe palette."
        )) == .thought("Checking\nthe palette."))
        // The whole reasoning of the phase, also once its paragraph in
        // progress ended.
        #expect(ZenSubAgentLiveActivity(snapshot(
            activity: "Second.", activityKind: .thinking, thought: "First.\n\nSecond."
        )) == .thought("First.\n\nSecond."))
        #expect(ZenSubAgentLiveActivity(snapshot(
            activityKind: .thinking, thought: "First.\n\nSecond."
        )) == .thought("First.\n\nSecond."))
        // Reasoning without a paragraph yet.
        #expect(ZenSubAgentLiveActivity(snapshot(activityKind: .thinking)) == .thinkingPlaceholder)
        #expect(ZenSubAgentLiveActivity(snapshot(activityKind: .thinking, thought: " \n")) == .thinkingPlaceholder)
        // The paragraph in progress alone (`currentActivity`) is not the
        // reasoning: without `currentThought` the placeholder shows.
        #expect(ZenSubAgentLiveActivity(snapshot(activity: "Only the paragraph.", activityKind: .thinking)) == .thinkingPlaceholder)
        // The message phase shows the placeholder too, with its text or not.
        #expect(ZenSubAgentLiveActivity(snapshot(activity: "Writing.", activityKind: .content)) == .thinkingPlaceholder)
        #expect(ZenSubAgentLiveActivity(snapshot(activityKind: .content)) == .thinkingPlaceholder)
        // Nothing else to show: queued, or a tool the transcript hides (it
        // runs, but its row is not in the transcript).
        #expect(ZenSubAgentLiveActivity(snapshot(status: .queued)) == .thinkingPlaceholder)
        #expect(ZenSubAgentLiveActivity(snapshot(toolName: "agent.message", toolIsRunning: true)) == .thinkingPlaceholder)
        #expect(ZenSubAgentLiveActivity(snapshot(toolName: "agent.message")) == .thinkingPlaceholder)
        // A tool that completed leaves its name in the snapshot while the
        // agent writes its next message (a model without reasoning): the
        // placeholder shows, with the message text or not.
        #expect(ZenSubAgentLiveActivity(snapshot(toolName: "local.exec", toolIsRunning: false)) == .thinkingPlaceholder)
        #expect(ZenSubAgentLiveActivity(snapshot(
            activity: "Writing.", activityKind: .content, toolName: "local.exec", toolIsRunning: false
        )) == .thinkingPlaceholder)
        // Reasoning after a completed tool shows the paragraph.
        #expect(ZenSubAgentLiveActivity(snapshot(
            activityKind: .thinking, thought: "Reading the output.", toolName: "local.exec", toolIsRunning: false
        )) == .thought("Reading the output."))
        // A running tool has its row in the transcript: nothing, while
        // reasoning too.
        #expect(ZenSubAgentLiveActivity(snapshot(toolName: "local.exec", toolIsRunning: true)) == .none)
        #expect(ZenSubAgentLiveActivity(snapshot(
            activityKind: .thinking, thought: "Reading the output.", toolName: "local.exec", toolIsRunning: true
        )) == .none)
        // Not pending, or no snapshot: nothing.
        #expect(ZenSubAgentLiveActivity(snapshot(
            status: .idle, activityKind: .thinking, thought: "Old thought", output: "Done."
        )) == .none)
        #expect(ZenSubAgentLiveActivity(snapshot(
            status: .idle, toolName: "local.exec", toolIsRunning: false, output: "Done."
        )) == .none)
        #expect(ZenSubAgentLiveActivity(snapshot(status: .failed)) == .none)
        #expect(ZenSubAgentLiveActivity(nil) == .none)
    }
}
