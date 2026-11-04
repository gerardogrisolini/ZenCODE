//
//  ZenSavedSessionLoadStep.swift
//  ZenApp
//
//  The step a saved session the sidebar loads is at, for the loading
//  indicator of the conversation.
//

import Foundation
import ZenCODECore

/// The step of a saved session the sidebar loads
/// (``ZenWindowSession/loadingSavedSessionStep``). The load starts at
/// ``reading``; the steps of the slot's hooks (``ChatIncarnationChange``)
/// move it on, and it never moves back.
public enum ZenSavedSessionLoadStep: Int, Sendable, Comparable, CaseIterable {
    /// From the click to `.savedSessionWillLoad`: the saved session is read
    /// from the store.
    case reading
    /// To `.savedSessionWillRestore`: the current session is closed and the
    /// saved one installed.
    case closing
    /// To `.savedSessionDidRestore`: the model is loaded, and the runtime
    /// session (its tools) and the task graph are restored.
    case restoring
    /// Until the window shows the restored conversation.
    case presenting

    /// The line the loading indicator shows under the session's name.
    public var text: String {
        switch self {
        case .reading: "Reading the saved session…"
        case .closing: "Closing the current session…"
        case .restoring: "Loading the model and tools…"
        case .presenting: "Restoring the conversation…"
        }
    }

    /// The step a hook of a saved-session load starts; `nil` for the steps
    /// of the other operations.
    init?(_ change: ChatIncarnationChange) {
        switch change {
        case .savedSessionWillLoad:
            self = .closing
        case .savedSessionWillRestore:
            self = .restoring
        case .savedSessionDidRestore:
            self = .presenting
        case .newSessionWillStart, .newSessionDidStart, .sessionDidCompact:
            return nil
        }
    }

    public static func < (lhs: ZenSavedSessionLoadStep, rhs: ZenSavedSessionLoadStep) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}
