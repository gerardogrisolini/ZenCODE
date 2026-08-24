//
//  TerminalChatRenderCoordinator+Diagnostics.swift
//  ZenCODE
//

import Foundation

/// Test and diagnostics snapshots, capture retrieval, and flush barriers.
extension TerminalChatRenderCoordinator {
    // MARK: - Test and diagnostics snapshots

    func snapshot() -> Snapshot {
        let active = toolState.activeBlock.map { block in
            (block.id, block.rows)
        } ?? (nil, 0)
        return Snapshot(
            activeToolCallID: active.0,
            activeToolRenderedRowCount: active.1,
            deferredTaskGraphOverviewRender: overviewState.pending[.taskGraph] != nil,
            deferredSubAgentOverviewRender: overviewState.pending[.subAgents] != nil,
            lastRenderedTaskGraphOverviewSignature: overviewState.signatures[.taskGraph],
            lastRenderedSubAgentOverviewSignature: overviewState.signatures[.subAgents],
            isStreamingThoughtOutput: thoughtStreamingState.isStreaming,
            activeSubAgentOverviewRowCount: ownedSubAgentOverviewRowCount
        )
    }

    func capturedWriteEvents() -> [WriteEvent] {
        capturedWrites
    }

    func waitForScheduledStreamingFlush() async {
        let task = scheduledStreamingFlush
        await task?.value
    }
}
