//
//  TerminalChatRenderCoordinator+Diagnostics.swift
//  ZenCODE
//

import Foundation

/// Test and diagnostics snapshots, capture retrieval, and flush barriers.
extension TerminalChatRenderCoordinator {
    // MARK: - Test and diagnostics snapshots

    func snapshot() -> Snapshot {
        let compact: (String?, Int)
        let detailed: (String?, Int)
        if let activeBlock = toolState.activeBlock {
            switch activeBlock.style {
            case .minimal:
                compact = (activeBlock.id, activeBlock.rows)
                detailed = (nil, 0)
            case .standard, .detailed:
                compact = (nil, 0)
                detailed = (activeBlock.id, activeBlock.rows)
            }
        } else {
            compact = (nil, 0)
            detailed = (nil, 0)
        }
        return Snapshot(
            toolOutputDetailLevel: toolState.detailLevel,
            activeCompactToolCallID: compact.0,
            activeCompactToolRenderedRowCount: compact.1,
            activeDetailedToolCallID: detailed.0,
            activeDetailedToolRenderedRowCount: detailed.1,
            deferredTaskGraphOverviewRender: overviewState.pending[.taskGraph] != nil,
            deferredSubAgentOverviewRender: overviewState.pending[.subAgents] != nil,
            lastRenderedTaskGraphOverviewSignature: overviewState.signatures[.taskGraph],
            lastRenderedSubAgentOverviewSignature: overviewState.signatures[.subAgents],
            isStreamingThoughtOutput: thoughtStreamingState.isStreaming,
            activeSubAgentOverviewRowCount: ownedSubAgentOverviewRowCount
        )
    }

    func setToolOutputDetailLevel(_ level: ToolOutputDetailLevel) {
        toolState.detailLevel = level
    }

    func capturedWriteEvents() -> [WriteEvent] {
        capturedWrites
    }

    func waitForScheduledStreamingFlush() async {
        let task = scheduledStreamingFlush
        await task?.value
    }
}
