//
//  ChatPlanGenerationError.swift
//  ZenCODE
//
//  Created by Gerardo Grisolini on 30/05/26.
//

import Foundation

/// Why a `/plan` turn could not record the Planner's output.
enum ChatPlanGenerationError: LocalizedError {
    case plannerOutputUnavailable
    case sessionHistoryUnavailable
    case structuredTasksUnavailable
    case unexpectedStructuredTasksForQuestions

    var errorDescription: String? {
        switch self {
        case .plannerOutputUnavailable:
            return "The Planner agent did not produce fresh output for this planning turn. The current agent "
                + "was not allowed to substitute its own plan; run /plan <goal> again."
        case .sessionHistoryUnavailable:
            return "The Planner produced a plan, but ZenCODE could not replace the current "
                + "agent's response in the session history. The plan was not recorded."
        case .structuredTasksUnavailable:
            return "The Planner produced text but did not register a valid structured task list; "
                + "the previous plan and task graph were left unchanged."
        case .unexpectedStructuredTasksForQuestions:
            return "The Planner asked clarification questions, but the coordinator also registered plan tasks; "
                + "the previous plan and task graph were left unchanged."
        }
    }
}

/// Compatibility name used by the terminal chat.
typealias TerminalPlanGenerationError = ChatPlanGenerationError
