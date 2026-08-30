//
//  TerminalChatRenderCoordinator.swift
//  ZenCODE
//

import Foundation

/// Serializes every stateful chat render operation.
///
/// Async work such as task-graph and sub-agent snapshots is deliberately kept
/// outside this actor. Each entry point receives an already prepared value and
/// performs no suspension while it mutates formatter or cursor-ownership state.
actor TerminalChatRenderCoordinator {
    enum OverviewKind: Hashable, Sendable {
        case taskGraph
        case subAgents
    }

    enum OverviewRenderResult: Sendable, Equatable {
        case rendered
        case deferred
        case unchanged
    }

    enum OutputChannel: Sendable, Equatable {
        case standardOutput
        case standardError
    }

    /// Describes whether stdout and stderr address one physical cursor.
    /// Terminal capability alone is insufficient: two independent TTYs have
    /// separate cursor positions and therefore must not share spacing state.
    enum CursorTopology: Sendable, Equatable {
        case shared
        case separate
    }

    struct WriteEvent: Sendable, Equatable {
        let sequence: UInt64
        let channel: OutputChannel
        let text: String
    }

    /// One completed sub-agent response waiting to be presented. `token` is a
    /// stable identity for that completion, allowing the overview metadata to
    /// be refreshed without printing the same model-authored response again.
    struct SubAgentMarkdownResponse: Sendable, Equatable {
        let token: String
        let heading: String
        let markdown: String
    }

    /// One assistant block that a sub-agent completed before starting a tool.
    /// The same block is shown as a 💬 row in the live overview and mirrored
    /// once to remote chat even when later refreshes redraw that row.
    struct SubAgentPartialResponse: Sendable, Equatable {
        let token: String
        let heading: String
        let markdown: String
    }

    struct Snapshot: Sendable, Equatable {
        let activeToolCallID: String?
        let activeToolRenderedRowCount: Int
        let deferredTaskGraphOverviewRender: Bool
        let deferredSubAgentOverviewRender: Bool
        let lastRenderedTaskGraphOverviewSignature: String?
        let lastRenderedSubAgentOverviewSignature: String?
        let isStreamingThoughtOutput: Bool
        /// Physical rows currently owned by the sub-agent overview, or `0` when
        /// no section can be rewritten in place.
        let activeSubAgentOverviewRowCount: Int
    }

    let standardOutput: FileHandle?
    let standardError: FileHandle?
    var standardOutputState: ChannelState
    var standardErrorState: ChannelState
    var sharedCursorState = CursorState()
    let cursorTopology: CursorTopology
    let lineInset: String
    let capturesWrites: Bool
    let streamingFlushDelay: Duration?
    /// Injectable monotonic clock used to decide when a leading-edge flush is
    /// safe. Tests pass a controllable closure so the idle-window check is
    /// deterministic; production uses `ContinuousClock`.
    let streamingNow: @Sendable () -> ContinuousClock.Instant
    /// Injectable monotonic clock used to measure the interval between a tool's
    /// start and completion. It is intentionally sampled only at those two
    /// lifecycle events: compact tool rows do not schedule periodic redraws.
    let toolNow: @Sendable () -> ContinuousClock.Instant
    /// Returns the current terminal column count. Overridable in tests to
    /// simulate a deterministic resize between tool start and completion.
    let columnWidthProvider: @Sendable () -> Int
    /// Reads the current width immediately before a destructive cursor clear.
    /// Production bypasses the short-lived width cache; injected providers keep
    /// their existing behavior unless an explicit fresh provider is supplied.
    let freshColumnWidthProvider: @Sendable () -> Int
    var nextWriteSequence: UInt64 = 0
    /// Counts every physical emission, whether or not writes are captured.
    /// Live tool and sub-agent blocks use it to detect output written after
    /// their section, which makes an in-place rewrite unsafe.
    var emittedWriteCount: UInt64 = 0
    var capturedWrites: [WriteEvent] = []
    var pendingStreamingWrites: [PendingWrite] = []
    var pendingStreamingByteCount = 0
    var scheduledStreamingFlush: Task<Void, Never>?
    var streamingFlushGeneration: UInt64 = 0
    /// Wall-clock (or injected) instant of the most recent streaming flush.
    /// Used by the leading-edge logic to suppress redundant immediate flushes
    /// while a burst is still active (trailing-edge coalescing window).
    var lastStreamingFlushInstant: ContinuousClock.Instant?

    var assistantStreamingState: StreamingContentState
    /// Whether the 💬 prefix still needs to be emitted at the leading edge
    /// of the next assistant response. Reset to `true` after each response
    /// finishes so every turn gets exactly one prefix.
    var assistantBubblePrefixPending = true
    var thoughtStreamingState: StreamingContentState
    /// A submitted prompt starts a transcript turn. The first prompt remains
    /// unadorned; every later one receives exactly one visual turn separator.
    var hasWrittenSubmittedPrompt = false

    var toolState = TerminalToolBlockAccounting<ActiveToolBlock>()
    var subAgentToolState = TerminalSubAgentToolPresentationState()
    var activeSubAgentOverviewBlock: ActiveOverviewBlock?
    /// Fences periodic overview publications while the status bar changes the
    /// transcript's scrolling region outside this coordinator.
    var isBottomOverlayTransitionActive = false
    var overviewState = TerminalOverviewArbitration<OverviewKind, PendingOverview>()

    /// Optional mirror invoked after publishable overview content is actually
    /// rendered locally. The typed notification excludes transient status,
    /// reasoning, tools, and metadata while including every model-authored 💬
    /// block and completed response.
    /// Deferred overviews flow through here too, once they become renderable,
    /// so remote mirrors (e.g. Telegram) cannot miss a section that only
    /// rendered after streaming finished.
    ///
    /// Notifications are queued on this actor in render order and delivered to
    /// the handler by a single drain task, so the remote channel observes the
    /// same section order as the terminal even though delivery is asynchronous
    /// and never blocks local rendering. Use
    /// ``waitForOverviewMirrorsToDrain()`` as an end-of-turn barrier.
    var overviewMirroringHandler: (@Sendable (
        _ notification: OverviewMirrorNotification,
        _ epoch: Int
    ) async -> Void)?

    var mirrorQueue = TerminalOverviewMirrorQueue<OverviewMirrorQueueEntry>()

    init(
        stdinIsTerminal: Bool,
        standardOutput: FileHandle? = AgentOutput.standardOutput,
        standardError: FileHandle? = AgentOutput.standardError,
        standardOutputIsTerminal: Bool = AgentOutput.standardOutputIsTerminal,
        standardErrorIsTerminal: Bool = AgentOutput.standardErrorIsTerminal,
        cursorTopology: CursorTopology? = nil,
        capturesWrites: Bool = false,
        streamingFlushDelay: Duration? = .milliseconds(32),
        streamingNow: @Sendable @escaping () -> ContinuousClock.Instant = {
            ContinuousClock().now
        },
        toolNow: @Sendable @escaping () -> ContinuousClock.Instant = {
            ContinuousClock().now
        },
        columnWidthProvider: (@Sendable () -> Int)? = nil,
        freshColumnWidthProvider: (@Sendable () -> Int)? = nil
    ) {
        self.standardOutput = standardOutput
        self.standardError = standardError
        self.standardOutputState = ChannelState(isTerminal: standardOutputIsTerminal)
        self.standardErrorState = ChannelState(isTerminal: standardErrorIsTerminal)
        self.cursorTopology = cursorTopology ?? Self.defaultCursorTopology(
            standardOutput: standardOutput,
            standardError: standardError,
            standardOutputIsTerminal: standardOutputIsTerminal,
            standardErrorIsTerminal: standardErrorIsTerminal
        )
        self.lineInset = stdinIsTerminal ? TerminalChatTextFormatting.chatLineInsetPrefix : ""
        self.capturesWrites = capturesWrites
        self.streamingFlushDelay = streamingFlushDelay
        self.streamingNow = streamingNow
        self.toolNow = toolNow
        if let columnWidthProvider {
            self.columnWidthProvider = columnWidthProvider
            self.freshColumnWidthProvider = freshColumnWidthProvider
                ?? columnWidthProvider
        } else {
            self.columnWidthProvider = {
                TerminalChat.terminalColumnCount()
            }
            self.freshColumnWidthProvider = freshColumnWidthProvider ?? {
                TerminalChat.terminalColumnCount(forceRefresh: true)
            }
        }
        self.assistantStreamingState = StreamingContentState(
            markdownFormatter: TerminalMarkdownStreamFormatter(
                isEnabled: standardOutputIsTerminal
            )
        )
        self.thoughtStreamingState = StreamingContentState(
            markdownFormatter: TerminalMarkdownStreamFormatter(
                isEnabled: standardErrorIsTerminal,
                removesUnbalancedStrongMarkers: true,
                usesTerminalWidthForStructuredContent: false
            )
        )
    }

    private static func defaultCursorTopology(
        standardOutput: FileHandle?,
        standardError: FileHandle?,
        standardOutputIsTerminal: Bool,
        standardErrorIsTerminal: Bool
    ) -> CursorTopology {
        guard standardOutputIsTerminal,
              standardErrorIsTerminal,
              let standardOutput,
              let standardError,
              TerminalWidth.sharesTerminalCursor(
                  first: standardOutput.fileDescriptor,
                  second: standardError.fileDescriptor
              ) == true else {
            return .separate
        }
        return .shared
    }
}
