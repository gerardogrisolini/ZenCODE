//
//  ChatStatusModel.swift
//  ZenCODE
//
//  Created by Gerardo Grisolini on 25/11/26.
//

import Foundation

/// What a status bar shows of the session's model before the runtime reports
/// anything about its context window: the model's name and the window the
/// settings configure for it.
///
/// ``ChatSessionController/statusModel()`` produces it, so every channel names
/// the model and sizes the window the same way (the terminal's `0.0k/1.0m`).
public struct ChatStatusModel: Sendable, Equatable {
    /// The model's name as a status bar shows it: the provider's model id
    /// (`claude-opus-5-5`), not the settings manifest's id
    /// (`claude:claude-opus-5-5`). `nil` when the session resolves no model.
    public let modelID: String?

    /// The configured window with no tokens used yet, flagged approximate.
    /// `nil` when the settings configure no limit for the model, or when the
    /// session resolves no model.
    public let contextWindow: DirectAgentContextWindowStatus?

    public init(
        modelID: String?,
        contextWindow: DirectAgentContextWindowStatus?
    ) {
        self.modelID = modelID
        self.contextWindow = contextWindow
    }
}
