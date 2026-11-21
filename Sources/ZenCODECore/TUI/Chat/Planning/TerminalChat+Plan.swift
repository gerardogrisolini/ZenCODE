//
//  TerminalChat+Plan.swift
//  ZenCODE
//
//  Created by Gerardo Grisolini on 01/07/26.
//

import Foundation
import ToolCore
import ZenCODERuntime

extension TerminalChat {
    func abandonPlanBrainstorming(
        closeAllPlanAuthors: Bool = false,
        expectedCollectionID: UUID? = nil
    ) async {
        await chatSession.abandonPlanBrainstorming(
            closeAllPlanAuthors: closeAllPlanAuthors,
            expectedCollectionID: expectedCollectionID
        )
    }

    nonisolated static func planStatusTable(for plan: TerminalSessionPlan) -> String {
        PlanningCommandKernel.planStatusTable(for: plan, graph: nil)
    }
}
