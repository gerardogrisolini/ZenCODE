//
//  MLXServerToolCallStreamProcessor.swift
//  ZenCODE
//
//  Created by Gerardo Grisolini on 25/05/26.
//
import CryptoKit
import Foundation
import MLX
@preconcurrency import MLXLMCommon
import Tokenizers

struct MLXServerToolCallStreamProcessor {
    private enum State {
        case normal
        case potentialTaggedToolCall
        case collectingTaggedToolCall
        case collectingJSONToolCall
    }

    private let parser: any ToolCallParser
    private let tools: [[String: any Sendable]]?
    private let supportsBareJSONFallback: Bool
    private let jsonObjectScanner = MLXServerJSONLeadingObjectScanner(startCharacter: "{")
    private var fallbackProcessor: ToolCallProcessor?
    private var fallbackToolCallDrainIndex = 0
    private var state = State.normal
    private var buffer = ""
    private var toolCalls: [ToolCall] = []

    init(format: ToolCallFormat, tools: [[String: any Sendable]]? = nil) {
        let parser = format.createParser()
        self.parser = parser
        self.tools = tools
        supportsBareJSONFallback = format == .json
        if parser.startTag == nil {
            fallbackProcessor = ToolCallProcessor(format: format, tools: tools)
        }
    }

    mutating func processChunk(_ chunk: String) -> String? {
        if let fallbackProcessor {
            return fallbackProcessor.processChunk(chunk)
        }
        return processTaggedChunk(chunk)
    }

    mutating func processEOS(returnBufferedText: Bool = true) -> String? {
        if let fallbackProcessor {
            return fallbackProcessor.processEOS(returnBufferedText: returnBufferedText)
        }

        guard !buffer.isEmpty else {
            state = .normal
            return nil
        }

        let buffered = buffer
        buffer = ""
        let parsedCalls: [ToolCall]
        switch state {
        case .normal, .potentialTaggedToolCall:
            parsedCalls = []
        case .collectingTaggedToolCall, .collectingJSONToolCall:
            parsedCalls = parser.parseEOS(buffered, tools: tools)
        }
        state = .normal
        toolCalls.append(contentsOf: parsedCalls)

        return returnBufferedText && parsedCalls.isEmpty ? buffered : nil
    }

    mutating func drainToolCalls() -> [ToolCall] {
        if let fallbackProcessor {
            let calls = Array(fallbackProcessor.toolCalls.dropFirst(fallbackToolCallDrainIndex))
            fallbackToolCallDrainIndex += calls.count
            return calls
        }

        guard !toolCalls.isEmpty else {
            return []
        }
        let drained = toolCalls
        toolCalls.removeAll(keepingCapacity: true)
        return drained
    }

    private mutating func processTaggedChunk(_ chunk: String) -> String? {
        buffer += chunk
        var emitted = ""

        scanLoop: while !buffer.isEmpty {
            switch state {
            case .normal:
                guard let startIndex = potentialStartIndex(in: buffer) else {
                    emitted += buffer
                    buffer = ""
                    continue
                }
                if startIndex > buffer.startIndex {
                    emitted += buffer[..<startIndex]
                    buffer.removeSubrange(buffer.startIndex..<startIndex)
                }
                if supportsBareJSONFallback,
                   buffer.first == jsonObjectScanner.startCharacter {
                    state = .collectingJSONToolCall
                } else {
                    state = .potentialTaggedToolCall
                }

            case .potentialTaggedToolCall:
                guard let startTag = parser.startTag else {
                    emitted += buffer
                    buffer = ""
                    state = .normal
                    continue
                }
                if buffer.hasPrefix(startTag) {
                    state = .collectingTaggedToolCall
                    continue
                }
                if startTag.hasPrefix(buffer) {
                    break scanLoop
                }
                emitted.append(buffer.removeFirst())
                state = .normal

            case .collectingTaggedToolCall:
                guard let endTag = parser.endTag,
                      let endRange = buffer.range(of: endTag) else {
                    break scanLoop
                }

                let taggedToolCall = String(buffer[..<endRange.upperBound])
                if let toolCall = parser.parse(content: taggedToolCall, tools: tools) {
                    toolCalls.append(toolCall)
                } else {
                    emitted += taggedToolCall
                }
                buffer.removeSubrange(buffer.startIndex..<endRange.upperBound)
                state = .normal

            case .collectingJSONToolCall:
                switch jsonObjectScanner.evaluatePrefix(in: buffer) {
                case .invalidObject:
                    emitted.append(buffer.removeFirst())
                    state = .normal
                case .needsMore:
                    break scanLoop
                case .validObject:
                    guard let split = jsonObjectScanner.splitLeadingObject(from: buffer) else {
                        break scanLoop
                    }
                    if let toolCall = parser.parse(content: split.object, tools: tools) {
                        toolCalls.append(toolCall)
                    } else {
                        emitted += split.object
                    }
                    buffer = split.trailing
                    state = .normal
                }
            }

        }

        return emitted.isEmpty ? nil : emitted
    }

    private func potentialStartIndex(in text: String) -> String.Index? {
        var indexes: [String.Index] = []
        if let startChar = parser.startTag?.first,
           let index = text.firstIndex(of: startChar) {
            indexes.append(index)
        }
        if supportsBareJSONFallback,
           let index = text.firstIndex(of: jsonObjectScanner.startCharacter) {
            indexes.append(index)
        }
        return indexes.min()
    }
}

private struct MLXServerJSONLeadingObjectScanner {
    enum PrefixState {
        case needsMore
        case validObject
        case invalidObject
    }

    let startCharacter: Character

    func evaluatePrefix(in buffer: String) -> PrefixState {
        guard let start = buffer.firstIndex(where: { !$0.isWhitespace }) else {
            return .invalidObject
        }
        return evaluatePrefix(in: buffer, from: start)
    }

    func evaluatePrefix(in buffer: String, from start: String.Index) -> PrefixState {
        var openingIndex = start
        while openingIndex < buffer.endIndex, buffer[openingIndex].isWhitespace {
            openingIndex = buffer.index(after: openingIndex)
        }
        guard openingIndex < buffer.endIndex,
              buffer[openingIndex] == startCharacter else {
            return .invalidObject
        }

        var index = buffer.index(after: openingIndex)
        while index < buffer.endIndex, buffer[index].isWhitespace {
            index = buffer.index(after: index)
        }
        guard index < buffer.endIndex else {
            return .needsMore
        }

        let firstToken = buffer[index]
        return firstToken == "\"" || firstToken == "}"
            ? .validObject
            : .invalidObject
    }

    func splitLeadingObject(from buffer: String) -> (object: String, trailing: String)? {
        guard let openingIndex = buffer.firstIndex(where: { !$0.isWhitespace }) else {
            return nil
        }
        guard buffer[openingIndex] == startCharacter else {
            return nil
        }

        var depth = 0
        var isEscaped = false
        var isInString = false
        var index = openingIndex
        while index < buffer.endIndex {
            let character = buffer[index]
            if isEscaped {
                isEscaped = false
                        } else if character == "\\" {
                isEscaped = isInString
            } else if character == "\"" {
                isInString.toggle()
            } else if !isInString {
                if character == startCharacter {
                    depth += 1
                } else if character == "}" {
                    depth -= 1
                    if depth == 0 {
                        let end = buffer.index(after: index)
                        return (
                            String(buffer[..<end]),
                            String(buffer[end...])
                        )
                    }
                }
            }
            index = buffer.index(after: index)
        }

        return nil
    }
}

/// The raw session owns a KV cache; the wrapper lets the runtime pass it
/// between the actor and detached persistence work.
