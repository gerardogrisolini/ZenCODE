//
//  TerminalChatRenderState.swift
//  ZenCODE
//

import Foundation

/// Actor-confined bookkeeping for tool-row ownership and lifecycle timing.
/// The coordinator remains the sole mutator; this value only groups invariants
/// that must advance together when ownership transfers between tool calls.
struct TerminalToolBlockAccounting<ActiveBlock> {
    var detailLevel: ToolOutputDetailLevel = .minimal
    var activeBlock: ActiveBlock?
    var startInstants: [String: ContinuousClock.Instant] = [:]
    var activeBlockIsSubAgentTool = false
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
    struct OverviewMirrorNotification: Sendable {
        let kind: OverviewKind
        let signature: String
        let text: String
        let epoch: Int
    }

    enum ToolBlockStyle: Sendable, Equatable {
        case minimal
        case standard
        case detailed
    }

    enum ToolBlockLifecycle {
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
    }

    struct ActiveToolBlock: Sendable, Equatable {
        let id: String
        let style: ToolBlockStyle
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
}
