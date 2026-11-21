//
//  DirectAgentToolCallPreview.swift
//  ZenCODE
//
//  Created by Gerardo Grisolini on 15/11/26.
//

/// A fragment of a tool call the model is still writing, for live
/// presentation only.
///
/// The fragments arrive in stream order while the call is generated, before
/// its ``DirectAgentEvent/toolCallStarted(_:)``. They are never recorded in the
/// transcript, the session history, or any wire or persisted format, and a
/// consumer that does not render them ignores them. Only the in-process DS4
/// engine emits them.
public enum DirectAgentToolCallPreview: Sendable, Equatable {
    /// The model named the tool of the call it started writing. A new
    /// `toolStarted` while a call is open means the previous call ended.
    case toolStarted(name: String)
    /// The model opened the argument `name` of the current call.
    case parameterStarted(name: String)
    /// The next piece of the open argument's raw text, in stream order.
    case parameterText(String)
    /// The open argument ended.
    case parameterEnded
    /// The tool-call block ended: completed, malformed, or cut short.
    case ended
}
