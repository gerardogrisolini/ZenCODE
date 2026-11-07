//
//  ZenSubAgentDetailCard.swift
//  ZenApp
//
//  The views of a sub-agent tab from this package: the detail card at its
//  top and the live activity after its transcript.
//

import Foundation
import SwiftUI
import ZenAppTheme
import ZenCODECore

/// The detail of one sub-agent, at the top of its tab, on a content card: the
/// row of the sub-agent card (``ZenSubAgentsCard``) without the activity, so
/// its status color, name and badge, the elapsed time (live while the agent
/// works, else its duration), the role and profile, the task and attempt, the
/// model and token counters, and the latest error. The tab shows the activity
/// after the transcript instead (``ZenSubAgentLiveActivityView``).
public struct ZenSubAgentDetailCard: View {
    private let snapshot: DirectSubAgentRuntime.AgentSnapshot

    /// - Parameter snapshot: The agent's latest snapshot.
    public init(snapshot: DirectSubAgentRuntime.AgentSnapshot) {
        self.snapshot = snapshot
    }

    public var body: some View {
        // The row carries its own inset: the card adds the rest of its
        // padding.
        ZenSubAgentRow(snapshot: snapshot, showsActivity: false)
            .frame(maxWidth: .infinity, alignment: .leading)
            .zenContentCard(cornerRadius: 14, padding: 12 - ZenSubAgentRow.horizontalInset)
    }
}

/// What a sub-agent tab shows after the transcript while the agent works.
/// The row is never empty while the agent is pending, except while a tool
/// runs: the transcript already has the row of that call.
public enum ZenSubAgentLiveActivity: Equatable, Sendable {
    /// The reasoning in progress.
    case thought(String)
    /// The `🤔 thinking…` placeholder: the agent works without a reasoning
    /// paragraph to show (it reasons without one yet, writes a message, or
    /// is queued).
    case thinkingPlaceholder
    /// Nothing: the agent is not pending, or a tool runs.
    case none

    /// The live activity of `snapshot`: while it is pending and no tool
    /// runs (a tool the transcript hides does not count, and neither does
    /// one that completed: the snapshot keeps its name until the next model
    /// state), the reasoning paragraph during the thinking phase, else the
    /// placeholder, the message phase included; `.none` otherwise and
    /// without a snapshot.
    public init(_ snapshot: DirectSubAgentRuntime.AgentSnapshot?) {
        guard let snapshot, snapshot.pending, !ZenSubAgentActivity(snapshot).toolIsRunning else {
            self = .none
            return
        }
        if snapshot.currentActivityKind == .thinking,
           let paragraph = ZenTranscriptText.nonBlank(snapshot.currentActivity) {
            self = .thought(paragraph)
        } else {
            self = .thinkingPlaceholder
        }
    }
}

/// The live activity of a sub-agent, after the transcript of its tab
/// (``ZenSubAgentLiveActivity``): the reasoning in progress as a streaming
/// thinking block, or the `🤔 thinking…` placeholder. It draws nothing while
/// the agent is not pending or a tool runs.
public struct ZenSubAgentLiveActivityView: View {
    private let activity: ZenSubAgentLiveActivity

    @Environment(\.zenPalette) private var palette

    /// - Parameter snapshot: The agent's latest snapshot, if any.
    public init(snapshot: DirectSubAgentRuntime.AgentSnapshot?) {
        activity = ZenSubAgentLiveActivity(snapshot)
    }

    public var body: some View {
        switch activity {
        case let .thought(text):
            ZenThoughtView(text: text, isStreaming: true)
        case .thinkingPlaceholder:
            Text("🤔 thinking…")
                .italic()
                .foregroundStyle(palette.thinking)
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityLabel(Text("Thinking"))
        case .none:
            EmptyView()
        }
    }
}

#Preview("Sub-agent detail") {
    let now = Date.now
    VStack(alignment: .leading, spacing: 16) {
        ZenSubAgentDetailCard(snapshot: DirectSubAgentRuntime.AgentSnapshot(
            id: "agent_1",
            taskID: "transcript-views",
            taskAttemptOrdinal: 2,
            name: "transcript-dev",
            role: "Developer",
            profileName: "Developer",
            status: .running,
            pending: true,
            configuredModelID: "claude-opus",
            currentActivity: "Checking the palette usage in every view.",
            currentActivityKind: .thinking,
            latestMetrics: DirectAgentGenerationMetrics(
                promptTokenCount: 1_250,
                cachedPromptTokenCount: 48_000,
                completionTokenCount: 312
            ),
            latestOutput: nil,
            latestError: nil,
            createdAt: now.addingTimeInterval(-95),
            updatedAt: now
        ))
        ZenSubAgentDetailCard(snapshot: DirectSubAgentRuntime.AgentSnapshot(
            id: "agent_2",
            name: "tester",
            role: "Tester",
            status: .failed,
            pending: false,
            latestOutput: nil,
            latestError: "The build failed.",
            createdAt: now.addingTimeInterval(-400),
            updatedAt: now.addingTimeInterval(-30)
        ))
        ZenSubAgentLiveActivityView(snapshot: DirectSubAgentRuntime.AgentSnapshot(
            id: "agent_3",
            name: "planner",
            role: "Planner",
            status: .running,
            pending: true,
            currentActivity: "Reading the tab bar and the conversation list.",
            currentActivityKind: .thinking,
            latestOutput: nil,
            latestError: nil,
            createdAt: now,
            updatedAt: now
        ))
        ZenSubAgentLiveActivityView(snapshot: DirectSubAgentRuntime.AgentSnapshot(
            id: "agent_4",
            name: "reviewer",
            role: "Reviewer",
            status: .queued,
            pending: true,
            latestOutput: nil,
            latestError: nil,
            createdAt: now,
            updatedAt: now
        ))
    }
    .padding()
    .frame(width: 560)
}
