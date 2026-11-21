//
//  MockDS4Engine+Tokenizer.swift
//  ZenCODE
//
//  Deterministic tokenizer and renderer of the mock DS4 engine.
//

import Foundation
import Synchronization
import Testing
@testable import ZenCODECore
@testable import ZenCODERuntime

extension MockDS4Engine {
    // MARK: Tokenizer

    static func tokenCount(of operation: DS4TranscriptOperation) -> Int {
        func text(_ value: String) -> Int {
            (value.utf8.count + 3) / 4
        }
        switch operation {
        case .begin: return 1
        case .message(let role, let content): return 3 + text(role) + text(content)
        case .thinkPrefix: return 2
        case .assistantPrefix: return 2
        case .renderedChat(let value): return text(value)
        case .endOfSequence: return 1
        case .tokens(let ids): return ids.count
        case .multimodalMessage(let role, let parts, let images):
            return 3 + text(role) + parts.map(text).reduce(0, +) + 16 * images.count
        }
    }

    static func tokenCount(of transcript: [DS4TranscriptOperation]) -> Int {
        transcript.map(tokenCount(of:)).reduce(0, +)
    }
}
