//
//  TerminalChatRenderCoordinator+Diagnostics.swift
//  ZenCODE
//

import Foundation

/// Test and diagnostics snapshots, capture retrieval, and flush barriers.
extension TerminalChatRenderCoordinator {
    // MARK: - Test and diagnostics snapshots

    func snapshot() -> Snapshot {
        return Snapshot(
            activeToolCallID: nil,
            activeToolRenderedRowCount: 0,
            deferredTaskGraphOverviewRender: overviewState.pending[.taskGraph] != nil,
            deferredSubAgentOverviewRender: overviewState.pending[.subAgents] != nil,
            lastRenderedTaskGraphOverviewSignature: overviewState.signatures[.taskGraph],
            lastRenderedSubAgentOverviewSignature: overviewState.signatures[.subAgents],
            isStreamingThoughtOutput: thoughtStreamingState.isStreaming,
            activeSubAgentOverviewRowCount: 0
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
