//
//  TerminalChatRenderState.swift
//  ZenCODE
//
//  Created by Gerardo Grisolini on 30/05/26.
//

/// Actor-confined bookkeeping for tool-row ownership.
/// The coordinator remains the sole mutator; this value only groups invariants
/// that must advance together when ownership transfers between tool calls.
/// A call's elapsed time is not measured here: it comes with its result
/// (``DirectAgentToolResult/elapsed``).
struct TerminalToolBlockAccounting<ActiveBlock> {
    var activeBlock: ActiveBlock?
    var activeBlockIsSubAgentTool = false
}

/// Actor-confined latest-tool projection for the live sub-agent overview.
/// One entry per agent preserves the historical presentation contract: a new
/// call replaces that agent's previous call instead of becoming transcript.
struct TerminalSubAgentToolPresentationState {
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
    /// Once an assistant turn has reached its final transcript tail, automatic
    /// task/sub-agent updates continue through their runtime paths but must
    /// not append local terminal text below that response.
    var isAutomaticTerminalOverviewRenderingSuppressed = false
    /// Tokens already printed into the local transcript, so a later refresh
    /// does not print the same model-authored sub-agent content again.
    var consumedResponseTokens = Set<String>()
    var consumedPartialResponseTokens = Set<String>()
}

extension TerminalChatRenderCoordinator {
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

    struct ActiveToolBlock: Sendable {
        let toolCall: DirectAgentToolCall
        let id: String
        let rows: Int
        let columnWidth: Int
        let maximumInPlaceRows: Int?
        let cursorStateBeforeRender: CursorState
        let writeSequence: UInt64
        var screenAnchor: TerminalPrimaryScreen.Anchor? = nil
    }

    struct DeferredToolRender: Sendable {
        let toolCall: DirectAgentToolCall
        let lifecycle: ToolBlockLifecycle
        let isSubAgentTool: Bool
        /// `true` for a tool that genuinely started during the transition. A
        /// detached block already owns its transcript spacing and is reanchored
        /// without adding another separator.
        let preparesOutput: Bool
        /// Known row count for a detached block. A reduced transcript must fit
        /// every row before that presentation can be safely republished.
        let requiredRows: Int?
    }

    struct CursorState: Sendable {
        var spacing = TerminalChatTextFormatting.ChatSpacingState()
        var lineInset = TerminalChatTextFormatting.ChatLineInsetState()
    }

    struct ActiveOverviewBlock: Sendable {
        let rows: Int
        /// Blank transcript rows between the end of this block and the current
        /// output cursor. Shrinking a bottom overlay moves the cursor down but
        /// deliberately leaves existing transcript content in place.
        var cursorGapRows: Int
        let columnWidth: Int
        let maximumInPlaceRows: Int?
        let cursorStateBeforeRender: CursorState
        let writeSequence: UInt64
        var screenAnchor: TerminalPrimaryScreen.Anchor? = nil
    }

    enum OverviewContent: Sendable {
        case markdown(String)
        case subAgents(
            text: String,
            partialResponses: [SubAgentPartialResponse],
            responses: [SubAgentMarkdownResponse],
            overviewBatchID: String?,
            maximumInPlaceRows: Int?
        )
    }

    struct PendingOverview: Sendable {
        let kind: OverviewKind
        let origin: OverviewPublicationOrigin
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
