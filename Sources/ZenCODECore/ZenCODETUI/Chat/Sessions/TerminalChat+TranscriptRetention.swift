//
//  TerminalChat+TranscriptRetention.swift
//  ZenCODE
//

import Foundation

extension TerminalChat {
    /// The runtime conversation has its own context-window compaction, but the
    /// presentation/save transcript historically retained every detailed tool and
    /// reasoning block forever. Keep that secondary copy bounded independently.
    nonisolated static let maximumActiveSessionTranscriptBytes = 128 * 1_024 * 1_024

    private nonisolated static let transcriptTruncationNotice =
        "[Earlier detailed transcript omitted to keep session memory bounded.]"

    func replaceActiveSessionTranscript(with messages: [AgentRuntimeMessage]) {
        activeSessionTranscript = Self.boundedActiveSessionTranscript(messages)
        synchronizeActiveSessionTranscriptByteCount()
    }

    func appendActiveSessionTranscript(_ message: AgentRuntimeMessage) {
        appendActiveSessionTranscript(contentsOf: [message])
    }

    func appendActiveSessionTranscript(contentsOf messages: [AgentRuntimeMessage]) {
        guard !messages.isEmpty else { return }
        synchronizeActiveSessionTranscriptByteCountIfNeeded()
        activeSessionTranscript.append(contentsOf: messages)
        activeSessionTranscriptRetainedByteCount = Self.saturatingSum(
            activeSessionTranscriptRetainedByteCount,
            Self.transcriptRetainedByteCount(messages)
        )
        activeSessionTranscriptCountedMessageCount = activeSessionTranscript.count

        guard activeSessionTranscriptRetainedByteCount
            > Self.maximumActiveSessionTranscriptBytes else {
            return
        }
        activeSessionTranscript = Self.boundedActiveSessionTranscript(
            activeSessionTranscript
        )
        synchronizeActiveSessionTranscriptByteCount()
    }

    nonisolated static func boundedActiveSessionTranscript(
        _ messages: [AgentRuntimeMessage],
        maximumBytes: Int = maximumActiveSessionTranscriptBytes
    ) -> [AgentRuntimeMessage] {
        let maximumBytes = max(1, maximumBytes)
        guard transcriptRetainedByteCount(messages) > maximumBytes else {
            return messages
        }

        let notice = AgentRuntimeMessage(
            role: .system,
            content: transcriptTruncationNotice
        )
        let noticeBytes = transcriptRetainedByteCount(notice)
        var remainingBytes = max(0, maximumBytes - noticeBytes)
        var retainedNewestFirst: [AgentRuntimeMessage] = []

        for message in messages.reversed() {
            // Rebounding an already-truncated transcript replaces its old marker
            // rather than stacking another marker every time the cap is reached.
            if message.role == .system,
               message.content == transcriptTruncationNotice {
                continue
            }
            let messageBytes = transcriptRetainedByteCount(message)
            guard messageBytes <= remainingBytes else { break }
            retainedNewestFirst.append(message)
            remainingBytes -= messageBytes
        }

        return [notice] + Array(retainedNewestFirst.reversed())
    }

    nonisolated static func transcriptRetainedByteCount(
        _ messages: [AgentRuntimeMessage]
    ) -> Int {
        messages.reduce(0) { partial, message in
            saturatingSum(partial, transcriptRetainedByteCount(message))
        }
    }

    nonisolated static func transcriptRetainedByteCount(
        _ message: AgentRuntimeMessage
    ) -> Int {
        var total = 256 // Value/array storage overhead; deliberately conservative.
        addRetainedBytes(message.content, to: &total)
        addRetainedBytes(message.reasoningContent, to: &total)
        addRetainedBytes(message.reasoningItemsJSON, to: &total)
        addRetainedBytes(message.thinkingBlocksJSON, to: &total)
        addRetainedBytes(message.anthropicContentBlocksJSON, to: &total)
        addRetainedBytes(message.providerResponseID, to: &total)
        addRetainedBytes(message.toolCallID, to: &total)
        addRetainedBytes(message.toolName, to: &total)

        for attachment in message.attachments {
            total = saturatingSum(total, 128)
            total = saturatingSum(total, attachment.data?.count ?? 0)
            addRetainedBytes(attachment.fileURL?.path, to: &total)
            addRetainedBytes(attachment.contentType, to: &total)
            addRetainedBytes(attachment.originalFilename, to: &total)
        }
        for toolCall in message.toolCalls {
            total = saturatingSum(total, 96)
            addRetainedBytes(toolCall.id, to: &total)
            addRetainedBytes(toolCall.name, to: &total)
            addRetainedBytes(toolCall.argumentsJSON, to: &total)
        }
        return total
    }

    private func synchronizeActiveSessionTranscriptByteCountIfNeeded() {
        guard activeSessionTranscriptCountedMessageCount
            != activeSessionTranscript.count else {
            return
        }
        synchronizeActiveSessionTranscriptByteCount()
    }

    private func synchronizeActiveSessionTranscriptByteCount() {
        activeSessionTranscriptRetainedByteCount = Self.transcriptRetainedByteCount(
            activeSessionTranscript
        )
        activeSessionTranscriptCountedMessageCount = activeSessionTranscript.count
    }

    private nonisolated static func addRetainedBytes(_ text: String?, to total: inout Int) {
        total = saturatingSum(total, text?.utf8.count ?? 0)
    }

    private nonisolated static func saturatingSum(_ lhs: Int, _ rhs: Int) -> Int {
        guard rhs <= Int.max - lhs else { return Int.max }
        return lhs + rhs
    }
}
