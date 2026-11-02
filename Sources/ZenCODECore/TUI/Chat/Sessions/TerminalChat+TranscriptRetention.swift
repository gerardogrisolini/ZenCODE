//
//  TerminalChat+TranscriptRetention.swift
//  ZenCODE
//
//  Created by Gerardo Grisolini on 30/05/26.
//

import Foundation

/// The bounded presentation/save transcript lives in the shared session
/// controller; these names remain for the terminal chat and its callers.
extension TerminalChat {
    nonisolated static var maximumActiveSessionTranscriptBytes: Int {
        ChatSessionController.maximumTranscriptBytes
    }

    func replaceActiveSessionTranscript(with messages: [AgentRuntimeMessage]) {
        chatSession.replaceTranscript(with: messages)
    }

    func appendActiveSessionTranscript(_ message: AgentRuntimeMessage) {
        chatSession.appendTranscript(message)
    }

    func appendActiveSessionTranscript(contentsOf messages: [AgentRuntimeMessage]) {
        chatSession.appendTranscript(contentsOf: messages)
    }

    nonisolated static func boundedActiveSessionTranscript(
        _ messages: [AgentRuntimeMessage],
        maximumBytes: Int = ChatSessionController.maximumTranscriptBytes
    ) -> [AgentRuntimeMessage] {
        ChatSessionController.boundedTranscript(messages, maximumBytes: maximumBytes)
    }

    nonisolated static func transcriptRetainedByteCount(
        _ messages: [AgentRuntimeMessage]
    ) -> Int {
        ChatSessionController.transcriptRetainedByteCount(messages)
    }

    nonisolated static func transcriptRetainedByteCount(
        _ message: AgentRuntimeMessage
    ) -> Int {
        ChatSessionController.transcriptRetainedByteCount(message)
    }
}
