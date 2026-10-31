//
//  ChatPlanningCommandError.swift
//  ZenCODE
//
//  Created by Gerardo Grisolini on 30/05/26.
//

import Foundation

/// Why a planning command (`/plan approve`, `/plan clear`, `/plan delete`) or
/// a `/tasks` action (`retry`, `cancel`, `clear`) could not change the task
/// graphs or the saved-plan library.
///
/// The controller reports it as ``ChatSessionNotice/operationFailed(description:)``.
/// No channel reaches it today: the terminal chat, the ACP bridge, and the
/// headless session all create their controller with a management runtime,
/// and the controller that only runs turns (the headless one-shot prompt)
/// runs no command.
enum ChatPlanningCommandError: LocalizedError, Equatable {
    /// The controller was created without a ``ChatSessionManagementRuntime``.
    case sessionOperationsUnavailable

    var errorDescription: String? {
        switch self {
        case .sessionOperationsUnavailable:
            return "this session cannot change task graphs or the saved-plan library: "
                + "its channel runs turns only."
        }
    }
}
