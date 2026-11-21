//
//  DirectSubAgentRuntime+AgentRecord.swift
//  ZenCODE
//
//  The status, activity, and per-agent record types of the sub-agent runtime,
//  including the bounded tool-call durations and the state that agent waits
//  observe.
//

import Foundation
import ToolCore

extension DirectSubAgentRuntime {
    public enum Status: String, Sendable {
        case queued
        case running
        case idle
        case standby
        case failed
        case closed

        public var isPending: Bool {
            self == .queued || self == .running
        }
    }

    /// Which model phase produced `currentActivity`. Presentation selects the
    /// thinking affordance from this value instead of sniffing a marker prefix
    /// out of the activity text, so model-authored content that happens to
    /// start with "🤔 " is never mistaken for reasoning.
    public enum ActivityKind: String, Sendable, Equatable {
        /// Streamed reasoning. `currentActivity` holds the paragraph in
        /// progress, or nil while no non-blank paragraph exists yet; the
        /// reasoning of the whole phase is in `currentThought`.
        case thinking
        /// A completed assistant message projected into the overview.
        case content
    }

    /// What a wait for agents observes of one record; see
    /// ``AgentRecord/waitObservedState``.
    struct WaitObservedState: Equatable {
        let status: Status
        let hasWorkInFlight: Bool
        let pendingRelease: Bool
        let isSuperseded: Bool
        let isStandbyResident: Bool
    }

    /// The durations of an agent's completed tool calls, as the tool executor
    /// measured them, by tool call id, bounded to the `limit` most recent
    /// ones. A repeated id overwrites its duration and becomes the most
    /// recent; beyond the limit the oldest are evicted first. Kept in memory
    /// only, in the agent's record: never persisted, snapshotted, or
    /// checkpointed.
    struct ToolCallDurations {
        let limit: Int
        /// The durations, by tool call id.
        private(set) var byCallID: [String: Duration] = [:]
        /// The ids of ``byCallID``, oldest first.
        private var order: [String] = []

        init(limit: Int = DirectSubAgentRuntime.maximumRetainedToolCallDurationsPerAgent) {
            self.limit = max(0, limit)
        }

        mutating func record(_ duration: Duration, forCallID callID: String) {
            if byCallID.updateValue(duration, forKey: callID) != nil {
                order.removeAll { $0 == callID }
            }
            order.append(callID)
            while order.count > limit {
                byCallID.removeValue(forKey: order.removeFirst())
            }
        }
    }

    struct AgentRecord {
        public let id: String
        public let sessionID: String
        public let rootSessionID: String
        public let taskID: String?
        public let taskAttemptID: String?
        public let taskAttemptOrdinal: Int?
        var tasklessDelegationReservationID: UUID?
        public let name: String
        public let profileID: String?
        public let profileName: String?
        /// Role of the profile the agent was created from.
        public let profileRole: AgentProfileRole
        /// Identity of the transient overview "wave" this agent belongs to.
        /// Mutable because an agent that receives new work through
        /// `agent.message` re-joins the wave that is currently on screen.
        var overviewBatchID: UUID
        public let backend: any AgentRuntimeBackend
        public let createdAt: Date
        public var updatedAt: Date
        public var status: Status
        public var pendingPrompts: [String]
        /// Kept index-aligned with `pendingPrompts`. A true entry means the turn
        /// was created by a direct human-operator message and therefore needs a
        /// runtime fallback reply if the model does not call `agent.message`.
        var pendingOperatorReplyFlags: [Bool] = []
        var currentTurnRepliesToOperator = false
        var currentTurnSentOperatorMessage = false
        public var latestOutput: String?
        /// Monotonic identity of the latest completed response for transient
        /// presentation. Unlike `updatedAt`, this does not change when the agent
        /// is merely closed or otherwise receives a metadata-only update.
        /// Monotonic identity of the actual runtime turn, not the output history.
        public var executionRevision: UInt64 = 0
        public var completedExecutionRevision: UInt64 = 0
        public var latestOutputRevision: UInt64 = 0
        public var latestError: String?
        /// Stable configured model reference selected for this agent. Providers
        /// may later report a less-specific runtime model identifier, so the TUI
        /// uses this value to retain the binding's human-readable title.
        public let configuredModelID: String?
        public var modelID: String? = nil
        public var currentActivity: String? = nil
        /// Typed provenance of `currentActivity`; nil when there is no activity.
        public var currentActivityKind: ActivityKind? = nil
        /// Monotonic identity of assistant content promoted into
        /// `currentActivity` at a tool boundary. It lets the presenters
        /// publish every visible 💬 block exactly once across overview refreshes.
        public var currentActivityRevision: UInt64 = 0
        /// The incomplete thinking paragraph currently being streamed, kept in
        /// its raw stream form (a trailing CR is preserved so a CRLF split
        /// across deltas is not mistaken for a paragraph break). Completed
        /// paragraphs are deliberately discarded: the overview owns one rewrite
        /// slot and presents only the latest paragraph.
        var pendingThoughtParagraph: String? = nil
        /// The reasoning of the thinking phase in progress, every paragraph
        /// included, for the live detail of the agent; see
        /// ``AgentSnapshot/currentThought``.
        public var currentThought: String? = nil
        /// The reasoning of the thinking phase in progress as
        /// ``DirectSubAgentRuntime/accumulatedThought(appending:to:)`` keeps
        /// it: line endings normalized, and a trailing CR kept verbatim while
        /// its LF may still arrive. `nil` once the phase ended (a message or a
        /// tool call started), so the next reasoning starts a new phase.
        var pendingThought: String? = nil
        var pendingContentBuffer: String? = nil
        public var currentToolName: String? = nil
        public var currentToolTarget: String? = nil
        /// Whether the call `currentToolName` names is still running; see
        /// ``AgentSnapshot/currentToolIsRunning``.
        public var currentToolIsRunning = false
        /// Generation metrics accumulated for the turn in progress, folded with
        /// the same semantics the status bar uses for the root session.
        public var latestMetrics: DirectAgentGenerationMetrics? = nil
        /// Set when a new turn starts. The previous turn's counters stay
        /// visible until the first metrics event of the new turn arrives, which
        /// then replaces them instead of accumulating across turns. This
        /// mirrors `TerminalStatusBar.beginRequest()`.
        var shouldReplaceMetricsOnNextUpdate = false
        public var latestContentPreview: String? = nil
        public var latestEventAt: Date? = nil
        /// The durations of the agent's latest completed tool calls, as the
        /// tool executor measured them (``DirectAgentToolResult/elapsed``),
        /// for its transcript (``ChatSubAgentTranscript/toolDurations``),
        /// which is rebuilt from the history and so has no result's time.
        /// They survive the turns and ``prepareForTerminalRetention()``: a
        /// read after the agent ended may still return a transcript, and it
        /// must keep its times. The store is bounded
        /// (``DirectSubAgentRuntime/maximumRetainedToolCallDurationsPerAgent``)
        /// and in memory only.
        var toolCallDurations = ToolCallDurations()
        public var runTask: Task<Void, Never>?
        /// Single-flight guard for the shared-chat mailbox drain. Only one
        /// drain loop may be active per agent, so a burst of wake-up callbacks
        /// cannot start overlapping loops that double-queue the same batch.
        var isDrainingSharedChatMailbox = false

        /// The graph ID that authorizes this agent's standby. When nil the
        /// agent is not in standby.
        var standbyGraphID: String?
        /// Timestamp of the most recent standby activity (turn or entry).
        var standbySince: Date?
        /// Number of standby turns completed so far.
        var standbyTurns: Int = 0
        /// Set when a newer attempt claims the same task, signalling that
        /// this standby agent must be superseded.
        var supersededByAttemptID: String?
        /// Flagged by `releaseStandbyAgents` (and by the supersede path) while a
        /// standby turn is still running, so `recordStandbyTurnCompletion` and
        /// `concludeTaskBoundTurn` complete the release after the in-flight
        /// response finishes instead of returning the agent to `.standby`.
        var pendingRelease = false
        /// The reason reported when the flagged release is completed.
        var pendingReleaseReason: String?

        /// True while the agent still owes work: it is queued or running, or it
        /// has prompts waiting for its work loop. The transient overview keeps
        /// every such agent visible. Standby agents are intentionally NOT
        /// included: `agent.wait` must return when only standby agents remain.
        var hasWorkInFlight: Bool {
            status.isPending || !pendingPrompts.isEmpty
        }

        /// The part of the record that `agent.wait` and an `awaitReply` wait
        /// decide on. A write that changes it wakes those waits at once
        /// instead of at their next polling interval; see
        /// ``DirectSubAgentRuntime/signalWakeWaiters()``.
        var waitObservedState: WaitObservedState {
            WaitObservedState(
                status: status,
                hasWorkInFlight: hasWorkInFlight,
                pendingRelease: pendingRelease,
                isSuperseded: supersededByAttemptID != nil,
                isStandbyResident: standbyGraphID != nil
            )
        }

        /// Clears every in-flight model-phase projection: the visible activity
        /// and its kind plus the private thinking/content buffers and the tool
        /// row. Lifecycle transitions call this so no partial paragraph,
        /// buffered message, or open tool call can survive into the next turn
        /// or into a closed agent. The measured durations of completed calls
        /// are kept.
        mutating func resetActivityState() {
            currentActivity = nil
            currentActivityKind = nil
            pendingThoughtParagraph = nil
            currentThought = nil
            pendingThought = nil
            pendingContentBuffer = nil
            currentToolName = nil
            currentToolTarget = nil
            currentToolIsRunning = false
        }

        /// Hands the work-loop ownership token back from inside the loop; see
        /// ``DirectSubAgentRuntime/releaseWorkLoopOwnership(agentID:)``.
        mutating func releaseWorkLoop() {
            runTask = nil
        }

        /// Takes the work-loop ownership token from a loop that is cancelled
        /// with the agent, and returns that loop so the caller can cancel it
        /// once the record is written.
        mutating func revokeWorkLoop() -> Task<Void, Never>? {
            defer { runTask = nil }
            return runTask
        }

        /// Drops heavyweight report prefixes before this inactive record enters
        /// the bounded terminal-history cache. The latest tail is retained because
        /// it contains the final answer and validation summary callers need most.
        /// The tool-call durations are deliberately kept: they are bounded,
        /// and a transcript read after the agent ended must not lose them.
        mutating func prepareForTerminalRetention() {
            latestOutput = DirectSubAgentRuntime.boundedTerminalOutput(latestOutput)
            latestContentPreview = DirectSubAgentRuntime.boundedTerminalOutput(latestContentPreview)
            resetActivityState()
        }
    }
}
