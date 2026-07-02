//
//  MLXServerRuntime.swift
//  ZenCODE
//
//  Created by Gerardo Grisolini on 25/05/26.
//

import CryptoKit
import Foundation
import MLX
@preconcurrency import MLXLMCommon
import Tokenizers

public actor MLXServerRuntime {
    var containers: [LoadedModelKey: ModelContainer] = [:]
    var loadingTasks: [LoadedModelKey: ModelLoadingTask] = [:]

    /// In-memory chat sessions, keyed by session identity. The KV cache for
    /// each session is owned by MLXLMCommon's `ChatSession`; the runtime
    /// only tracks which transcript each session represents.
    var chatSessions: [MLXServerChatSessionCacheKey: ChatSessionState] = [:]
    var chatSessionAccessGeneration: UInt64 = 0
    let maxChatSessionCount: Int

    let generationGates = MLXServerPerModelGenerationGate()
    let diskKVCacheStore: MLXServerDiskKVCacheStore?
    let modelLoadLogger: (@Sendable (MLXServerModelLoadEvent) -> Void)?
    let modelUnloadLogger: (@Sendable (MLXServerModelUnloadEvent) -> Void)?
    var lastChatCacheEvent: MLXServerChatCacheEvent?

    /// Default bound on resident chat sessions. Each session retains a full
    /// KV cache in unified memory, so the registry stays intentionally
    /// small. Disk persistence is explicit and tied to saved sessions.
    public static let defaultMaxChatSessionCount = 4

    public init(
        diskKVCacheConfiguration: MLXServerDiskKVCacheConfiguration = .init(),
        maxChatSessionCount: Int = MLXServerRuntime.defaultMaxChatSessionCount,
        modelLoadLogger: (@Sendable (MLXServerModelLoadEvent) -> Void)? = nil,
        modelUnloadLogger: (@Sendable (MLXServerModelUnloadEvent) -> Void)? = nil
    ) {
        self.maxChatSessionCount = max(1, maxChatSessionCount)
        if diskKVCacheConfiguration.isEnabled {
            self.diskKVCacheStore = MLXServerDiskKVCacheStore(configuration: diskKVCacheConfiguration)
        } else {
            self.diskKVCacheStore = nil
        }
        self.modelLoadLogger = modelLoadLogger
        self.modelUnloadLogger = modelUnloadLogger
    }

    public var loadedModelIDs: [String] {
        containers.keys.map(\.displayName).sorted()
    }

    struct ChatSessionState {
        var sessionTransfer: ChatSessionTransfer
        var fingerprints: [MLXServerChatTranscriptFingerprint]
        var toolsSignature: String
        var contextSignature: String
        var contextTokenCount: Int?
        var lastAccessGeneration: UInt64
    }

    struct ResolvedChatSession {
        var cacheKey: MLXServerChatSessionCacheKey
        var sessionTransfer: ChatSessionTransfer
        var cachedPrefixMessageCount: Int
        var cachedPromptTokenCount: Int?
    }
}
