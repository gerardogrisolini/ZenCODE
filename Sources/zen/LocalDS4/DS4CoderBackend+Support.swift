//
//  DS4CoderBackend+Support.swift
//  ZenCODE
//

import DS4RuntimeShim
import Foundation
import ZenCODECore

/// The DS4 backend reuses the shared `<think>` transcript splitter. Its
/// accumulators are unused here — DS4 relies purely on the emitted `Part`s.
typealias DS4TranscriptSplitter = TranscriptThinkSplitter

struct DS4StreamingOutputFilter {
    private var splitter: DS4TranscriptSplitter
    private var contentToolCallSuppressor = DS4ToolCallStreamSuppressor()
    private var thoughtToolCallSuppressor = DS4ToolCallStreamSuppressor()

    private var isSuppressed: Bool {
        contentToolCallSuppressor.isSuppressed || thoughtToolCallSuppressor.isSuppressed
    }

    init(startsInThinking: Bool) {
        self.splitter = DS4TranscriptSplitter(startsInThinking: startsInThinking)
    }

    mutating func consume(_ chunk: String) -> [DS4TranscriptSplitter.Part] {
        var output: [DS4TranscriptSplitter.Part] = []
        append(splitter.consume(chunk), to: &output)
        return output
    }

    mutating func finish() -> [DS4TranscriptSplitter.Part] {
        var output: [DS4TranscriptSplitter.Part] = []
        append(splitter.finish(), to: &output)
        appendContent(contentToolCallSuppressor.flush(), to: &output)
        appendThought(thoughtToolCallSuppressor.flush(), to: &output)
        return output
    }

    private mutating func append(
        _ parts: [DS4TranscriptSplitter.Part],
        to output: inout [DS4TranscriptSplitter.Part]
    ) {
        for part in parts {
            guard !isSuppressed else {
                continue
            }
            switch part {
            case .content(let text):
                appendThought(thoughtToolCallSuppressor.flush(), to: &output)
                appendContent(contentToolCallSuppressor.consume(text), to: &output)
            case .thought(let text):
                appendContent(contentToolCallSuppressor.flush(), to: &output)
                appendThought(thoughtToolCallSuppressor.consume(text), to: &output)
            }
        }
    }

    private func appendContent(
        _ chunks: [String],
        to output: inout [DS4TranscriptSplitter.Part]
    ) {
        for chunk in chunks where !chunk.isEmpty {
            output.append(.content(chunk))
        }
    }

    private func appendThought(
        _ chunks: [String],
        to output: inout [DS4TranscriptSplitter.Part]
    ) {
        for chunk in chunks where !chunk.isEmpty {
            output.append(.thought(chunk))
        }
    }
}

private struct DS4ToolCallStreamSuppressor {
    private let markers = DS4ToolBridge.toolCallStartMarkers
    private var pending = ""
    private(set) var isSuppressed = false

    mutating func consume(_ chunk: String) -> [String] {
        guard !isSuppressed else {
            return []
        }
        pending += chunk
        var output: [String] = []

        while !pending.isEmpty {
            if let markerRange = pending.earliestRange(ofAny: markers) {
                let prefix = String(pending[..<markerRange.lowerBound])
                if !prefix.isEmpty {
                    output.append(prefix)
                }
                pending = ""
                isSuppressed = true
                return output
            }

            let safePrefix = pending.removingSuffixThatCanStartAny(markers)
            guard !safePrefix.isEmpty else {
                break
            }
            output.append(safePrefix)
            pending.removeFirst(safePrefix.count)
        }

        return output
    }

    mutating func flush() -> [String] {
        guard !pending.isEmpty else {
            return []
        }
        defer {
            pending = ""
        }
        guard !isSuppressed else {
            return []
        }
        return [pending]
    }
}

extension DS4CoderBackend {
    static func cThinkMode(from selection: AgentThinkingSelection?) -> zencode_ds4_think_mode {
        guard selection?.isEnabled != false else {
            return ZENCODE_DS4_THINK_NONE
        }
        if selection == .xhigh {
            return ZENCODE_DS4_THINK_MAX
        }
        return ZENCODE_DS4_THINK_HIGH
    }

    static func assistantReplayContent(from message: AgentRuntimeMessage) -> String {
        var content: String
        guard let reasoning = message.reasoningContent?.nilIfBlank else {
            content = message.content
            if !message.toolCalls.isEmpty {
                content += DS4ToolBridge.renderToolCalls(message.toolCalls)
            }
            return content
        }
        content = "<think>\(reasoning)</think>\(message.content)"
        if !message.toolCalls.isEmpty {
            content += DS4ToolBridge.renderToolCalls(message.toolCalls)
        }
        return content
    }

    static func finishReason(from rawValue: Int32) -> String {
        switch rawValue {
        case 1:
            return "length"
        case 2:
            return "error"
        case 3:
            return "tool_calls"
        case 4:
            return "cancelled"
        default:
            return "end_turn"
        }
    }

    static func generationSeed(base seed: UInt64, round: Int) -> UInt64 {
        guard seed != 0, round > 0 else {
            return seed
        }
        return seed &+ UInt64(round)
    }

    static func format(_ value: Float) -> String {
        String(format: "%.4g", Double(value))
    }
}

enum DS4CoderBackendError: LocalizedError {
    case missingSession
    case tooManyToolRounds(Int)

    var errorDescription: String? {
        switch self {
        case .missingSession:
            return "The DS4 direct session is no longer available."
        case .tooManyToolRounds(let rounds):
            return "DS4 local mode reached the maximum tool round limit (\(rounds))."
        }
    }
}
