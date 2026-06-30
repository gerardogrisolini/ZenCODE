//
//  DS4CoderBackend+Support.swift
//  ZenCODE
//

import DS4RuntimeShim
import Foundation
import ZenCODECore

struct DS4TranscriptSplitter {
    enum Part {
        case content(String)
        case thought(String)
    }

    private static let openTags = ["<think>", "<|channel>thought"]
    private static let closeTags = ["</think>", "<channel|>"]
    private var isThinking: Bool
    private var pending = ""

    init(startsInThinking: Bool) {
        self.isThinking = startsInThinking
    }

    mutating func consume(_ chunk: String) -> [Part] {
        pending += chunk
        var parts: [Part] = []

        while !pending.isEmpty {
            if isThinking {
                let closeRange = pending.earliestRange(ofAny: Self.closeTags)
                let openRange = pending.earliestRange(ofAny: Self.openTags)
                if let openRange,
                   closeRange == nil || openRange.lowerBound < closeRange!.lowerBound {
                    let thought = String(pending[..<openRange.lowerBound])
                    if !thought.isEmpty {
                        parts.append(.thought(thought))
                    }
                    pending.removeSubrange(pending.startIndex..<openRange.upperBound)
                    continue
                }
                if let closeRange {
                    let thought = String(pending[..<closeRange.lowerBound])
                    if !thought.isEmpty {
                        parts.append(.thought(thought))
                    }
                    pending.removeSubrange(pending.startIndex..<closeRange.upperBound)
                    isThinking = false
                    continue
                }
                let safePrefix = pending.removingSuffixThatCanStartAny(Self.closeTags + Self.openTags)
                guard !safePrefix.isEmpty else {
                    break
                }
                parts.append(.thought(safePrefix))
                pending.removeFirst(safePrefix.count)
            } else {
                if let openRange = pending.earliestRange(ofAny: Self.openTags) {
                    let content = String(pending[..<openRange.lowerBound])
                    if !content.isEmpty {
                        parts.append(.content(content))
                    }
                    pending.removeSubrange(pending.startIndex..<openRange.upperBound)
                    isThinking = true
                    continue
                }
                let safePrefix = pending.removingSuffixThatCanStartAny(Self.openTags)
                guard !safePrefix.isEmpty else {
                    break
                }
                parts.append(.content(safePrefix))
                pending.removeFirst(safePrefix.count)
            }
        }

        return parts
    }

    mutating func finish() -> [Part] {
        guard !pending.isEmpty else {
            return []
        }
        let value = pending
        pending = ""
        return [isThinking ? .thought(value) : .content(value)]
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
        default:
            return "end_turn"
        }
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

private extension String {
    func removingSuffixThatCanStart(_ marker: String) -> String {
        var suffixLength = min(count, max(marker.count - 1, 0))
        while suffixLength > 0 {
            let suffix = String(suffix(suffixLength))
            if marker.hasPrefix(suffix) {
                return String(dropLast(suffixLength))
            }
            suffixLength -= 1
        }
        return self
    }

    func earliestRange(ofAny markers: [String]) -> Range<String.Index>? {
        markers
            .compactMap { range(of: $0) }
            .min { $0.lowerBound < $1.lowerBound }
    }

    func removingSuffixThatCanStartAny(_ markers: [String]) -> String {
        var shortest = self
        for marker in markers {
            let trimmed = removingSuffixThatCanStart(marker)
            if trimmed.count < shortest.count {
                shortest = trimmed
            }
        }
        return self == shortest ? self : shortest
    }
}
