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

/// The MLX backend uses the shared `<think>` transcript splitter, including its
/// `visibleText`/`historyVisibleText`/`reasoningText` accumulators.
typealias MLXServerCoderTranscriptSplitter = TranscriptThinkSplitter

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
#endif
