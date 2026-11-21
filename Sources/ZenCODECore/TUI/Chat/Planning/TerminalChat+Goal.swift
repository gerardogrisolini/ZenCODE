//
//  TerminalChat+Goal.swift
//  ZenCODE
//
//  Created by Gerardo Grisolini on 30/05/26.
//

import Foundation
import ToolCore
import ZenCODERuntime

extension TerminalChat {
    nonisolated static func workflowStillOpenMessage(
        graphID: String,
        pendingTaskCount: Int
    ) -> String {
        ChatSessionNoticeText.workflowStillOpenMessage(
            graphID: graphID,
            pendingTaskCount: pendingTaskCount
        )
    }

    /// Notice for a workflow turn that ended without the explicit clarification
    /// block. The graph stays open, but nothing is waiting for a reply.
    nonisolated static func workflowOpenWithoutQuestionMessage(
        graphID: String,
        pendingTaskCount: Int
    ) -> String {
        ChatSessionNoticeText.workflowOpenWithoutQuestionMessage(
            graphID: graphID,
            pendingTaskCount: pendingTaskCount
        )
    }

    /// Notice for a failed or cancelled workflow turn whose graph was preserved.
    nonisolated static func workflowRecoverableFailureMessage(
        graphID: String,
        pendingTaskCount: Int
    ) -> String {
        ChatSessionNoticeText.workflowRecoverableFailureMessage(
            graphID: graphID,
            pendingTaskCount: pendingTaskCount
        )
    }
}
