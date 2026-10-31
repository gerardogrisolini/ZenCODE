//
//  ChatSessionStateStore.swift
//  ZenCODE
//
//  Created by Gerardo Grisolini on 30/05/26.
//

import Foundation
import Synchronization

/// Lock-protected session state shared by a ``ChatSessionController`` and the
/// channel that drives it.
///
/// Channels whose command routing runs in another isolation domain (the ACP
/// bridge actor) must check their own fences and update the command state in
/// one synchronous step; the controller fences its writes on the same token.
/// Every read-check-write sequence must therefore run inside one
/// ``withLock(_:)`` call.
final class ChatSessionStateStore: Sendable {
    struct State: Sendable {
        var commandState = ChatCommandState()
        /// Identifies the running turn; `nil` when no turn may write back.
        var activeTurnToken: UUID?
    }

    private let state = Mutex(State())

    init() {}

    func withLock<Result: Sendable>(_ body: (inout State) -> Result) -> Result {
        state.withLock { state in
            body(&state)
        }
    }

    var commandState: ChatCommandState {
        get { withLock { $0.commandState } }
        set { withLock { $0.commandState = newValue } }
    }
}
