//
//  TerminalTaskCommandError.swift
//  ZenCODE
//
//  Created by Gerardo Grisolini on 30/05/26.
//

import Foundation

/// Why a `/tasks` command line could not run.
///
/// The controller reports it as ``ChatSessionNotice/taskIDRequired(action:)``
/// or ``ChatSessionNotice/unknownTasksAction(action:)``, whose text is
/// `ZenCODE: ` followed by ``errorDescription``.
enum TerminalTaskCommandError: LocalizedError {
    case missingTaskID(String)
    case unknownAction(String)

    var errorDescription: String? {
        switch self {
        case let .missingTaskID(action):
            return "/tasks \(action) requires a task id."
        case let .unknownAction(action):
            return "Unknown /tasks action '\(action)'. Use status, show, retry, cancel, or clear."
        }
    }
}
