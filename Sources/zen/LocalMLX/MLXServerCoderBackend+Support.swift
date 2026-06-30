#if ZENCODE_LOCAL_MLX
//
//  MLXServerCoderBackend+Support.swift
//  ZenCODE
//

import Foundation
import ZenCODECore
@preconcurrency import MLXLMCommon
import MLXServerCore

extension ZenCODECore.JSONValue {
    var sendableValue: any Sendable {
        switch self {
        case let .string(value):
            return value
        case let .number(value):
            return value
        case let .object(value):
            return value.mapValues(\.sendableValue)
        case let .array(value):
            return value.map(\.sendableValue)
        case let .bool(value):
            return value
        case .null:
            return NSNull()
        }
    }
}

struct MLXServerCoderTranscriptSplitter {
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

                // Drop stray opening markers (e.g. gemma-4's
                // `<|channel>thought`) that appear inside thinking output.
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

                let safePrefix = pending.removingSuffixThatCanStartAny(
                    Self.closeTags + Self.openTags
                )
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

enum MLXServerCoderBackendError: LocalizedError {
    case missingSession
    case tooManyToolRounds(Int)

    var errorDescription: String? {
        switch self {
        case .missingSession:
            return "The ZenCODE direct session is no longer available."
        case .tooManyToolRounds(let rounds):
            return "Stopped after \(rounds) tool rounds without a final assistant response."
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
        return shortest
    }
}

#endif
