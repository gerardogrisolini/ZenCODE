//
//  MockDS4Engine+Types.swift
//  ZenCODE
//
//  Nested value types of the mock DS4 engine: recorded calls, simulated image
//  encodes and scripted generations.
//

import Foundation
import Synchronization
import Testing
@testable import ZenCODECore

extension MockDS4Engine {
    enum Call: Sendable, Hashable {
        case tokenCount
        case prepare
        case renderText
        case thinkModeForContext(mode: Int32, contextSize: Int)
        case sync(sessionID: String, cached: Int, suffix: Int)
        case generate(sessionID: String)
        case stats(sessionID: String)
        case setPower(sessionID: String, percent: Int)
        case setSteeringFFN(sessionID: String, scale: Double)
        case saveCheckpoint(sessionID: String, url: URL)
        case loadCheckpoint(sessionID: String, url: URL)
        case releaseSession(String)
        case evicted(String)
        case close
    }

    /// One simulated image encode.
    struct ImageEncode: Sendable, Hashable {
        let path: String
        let byteCount: Int
        /// Permissions of the file's directory (octal), when readable.
        let directoryPermissions: Int?
    }

    struct ScriptedGeneration: Sendable {
        var chunks: [String]
        /// Outcome when every chunk was emitted without a caller stop.
        var outcome: DS4GenerateOutcome = .stop
        /// Thrown instead of generating (after the gate, before any chunk).
        var error: DS4EngineError?
        /// Ids of the tokens, one per chunk. `nil`: fresh ids from the engine's counter.
        var tokens: [Int32]?
        /// Thrown once every chunk was emitted without a caller stop: a
        /// generation that fails midway.
        var errorAfterChunks: DS4EngineError?
    }
}
