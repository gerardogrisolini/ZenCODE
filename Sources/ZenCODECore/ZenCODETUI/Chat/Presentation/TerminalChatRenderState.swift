//
//  TerminalChatRenderState.swift
//  ZenCODE
//

import Foundation

/// Actor-confined bookkeeping for tool-row ownership and lifecycle timing.
/// The coordinator remains the sole mutator; this value only groups invariants
/// that must advance together when ownership transfers between tool calls.
struct TerminalToolBlockAccounting<ActiveBlock> {
    var activeBlock: ActiveBlock?
    var startInstants: [String: ContinuousClock.Instant] = [:]
    var activeBlockIsSubAgentTool = false
}

/// Actor-confined latest-tool projection for the live sub-agent overview.
/// One entry per agent preserves the historical presentation contract: a new
/// call replaces that agent's previous call instead of becoming transcript.
struct TerminalSubAgentToolPresentationState {
    var startInstants: [String: ContinuousClock.Instant] = [:]
    var presentationsByAgentID: [
        String: TerminalChatRenderCoordinator.SubAgentToolPresentation
    ] = [:]
    var revision: UInt64 = 0
}

/// Actor-confined overview revision/signature arbitration state.
struct TerminalOverviewArbitration<Kind: Hashable, Pending> {
    var pending: [Kind: Pending] = [:]
    var nextSequence: UInt64 = 0
    var signatures: [Kind: String] = [:]
    var revisions: [Kind: Int] = [:]
    var publicationCounters: [Kind: Int] = [:]
    var isSuspended = false
    var consumedResponseTokens = Set<String>()
}

/// Actor-confined FIFO mirror queue state. Keeping continuations beside the
/// drain flag makes the quiescence hand-off a single state transition.
struct TerminalOverviewMirrorQueue<Notification> {
    var pending: [Notification] = []
    var isDraining = false
    var drainWaiters: [CheckedContinuation<Void, Never>] = []
    var epoch = 0
}

extension TerminalChatRenderCoordinator {
    /// Remote-renderable overview output. Keeping this sum type narrow makes it
    /// impossible to accidentally mirror transient sub-agent status, thinking,
    /// tools, or metadata as a generic overview snapshot.
    enum OverviewMirrorNotification: Sendable, Equatable {
        case taskGraph(signature: String, markdown: String)
        case subAgentResponse(SubAgentMarkdownResponse)
    }

    /// Epoch is transport fencing rather than overview content, so it remains
    /// outside the typed notification payload.
    struct OverviewMirrorQueueEntry: Sendable {
        let notification: OverviewMirrorNotification
        let epoch: Int
    }

    enum ToolBlockLifecycle: Sendable {
        case started
        case completed(
            result: DirectAgentToolResult,
            compactStatusDetail: String?,
            elapsed: Duration?
        )

        var isCompletion: Bool {
            if case .completed = self { return true }
            return false
        }

        var compactStatusDetail: String? {
            if case let .completed(_, compactStatusDetail, _) = self {
                return compactStatusDetail
            }
            return nil
        }
    }

    struct SubAgentToolPresentation: Sendable {
        let agentID: String
        let agentName: String
        let toolCall: DirectAgentToolCall
        let lifecycle: ToolBlockLifecycle
    }

    struct SubAgentToolPresentationSnapshot: Sendable {
        let revision: UInt64
        let presentationsByAgentID: [String: SubAgentToolPresentation]
    }

    struct ActiveToolBlock: Sendable, Equatable {
        let id: String
        let rows: Int
        let columnWidth: Int
        let maximumInPlaceRows: Int?
    }

    struct CursorState: Sendable {
        var spacing = TerminalChatTextFormatting.ChatSpacingState()
        var lineInset = TerminalChatTextFormatting.ChatLineInsetState()
    }

    struct ActiveOverviewBlock: Sendable {
        let rows: Int
        let columnWidth: Int
        let maximumInPlaceRows: Int?
        let cursorStateBeforeRender: CursorState
        let writeSequence: UInt64
    }

    enum OverviewContent: Sendable {
        case markdown(String)
        case subAgents(
            text: String,
            responses: [SubAgentMarkdownResponse],
            overviewBatchID: String?,
            maximumInPlaceRows: Int?
        )
    }

    struct PendingOverview: Sendable {
        let kind: OverviewKind
        let signature: String
        let revision: Int?
        let force: Bool
        let rememberSignature: Bool
        let rememberedSignature: String
        let content: OverviewContent
        let sequence: UInt64
    }

    /// One pending buffered streaming write, coalesced per channel.
    struct PendingWrite: Sendable {
        let channel: OutputChannel
        var text: String
    }

    /// Channel-level terminal and cursor state for one output channel.
    struct ChannelState: Sendable {
        let isTerminal: Bool
        var cursor = CursorState()
        var hasContent = false
    }

    /// Mutable formatting state for one independently streamed content flow.
    struct StreamingContentState {
        var boldBreakState = TerminalChatBoldBreakState()
        var markdownFormatter: TerminalMarkdownStreamFormatter
        var isStreaming = false

        init(markdownFormatter: TerminalMarkdownStreamFormatter) {
            self.markdownFormatter = markdownFormatter
        }
    }
}
