//
//  MLXServerRuntime+ChatSessions.swift
//  ZenCODE
//
//  Created by Gerardo Grisolini on 25/05/26.
//
import CryptoKit
import Foundation
import MLX
@preconcurrency import MLXLMCommon
import Tokenizers

extension MLXServerRuntime {
    // MARK: - Chat session resolution

    /// Finds or builds the `ChatSession` able to serve the request:
    /// in-memory continuation first, then a fresh session that prefills the
    /// whole transcript. Disk restore is only performed when a previously
    /// saved session is explicitly loaded.
    func resolveChatSession(
        request: MLXServerGenerationRequest,
        container: ModelContainer
    ) async -> ResolvedChatSession {
        let cacheKey = MLXServerChatSessionCacheKey(
            sessionKey: request.effectiveSessionKey,
            modelID: request.model.id,
            runtimeKind: request.runtimeKind,
            cacheLayoutSignature: MLXServerChatSessionCacheSignature.cacheLayout(request.parameters)
        )
        let requestFingerprints = request.messages.map(\.transcriptFingerprint)
        let toolsSignature = MLXServerChatSessionRequestSignature.tools(request.tools)
        let contextSignature = MLXServerChatSessionRequestSignature.additionalContext(
            request.additionalContext
        )
        let modelSessionCount = chatSessions.keys.count { $0.modelID == request.model.id }

        // 1. In-memory continuation via the live ChatSession.
        if let state = chatSessions[cacheKey] {
            if state.toolsSignature == toolsSignature,
               state.contextSignature == contextSignature,
               let suffixStartIndex = MLXServerChatSessionTranscript.continuationSuffixStartIndex(
                   stored: state.fingerprints,
                   request: requestFingerprints
               ) {
                // Check the session out of the registry for the duration of
                // the turn; it is re-inserted with updated fingerprints when
                // the turn finishes.
                chatSessions[cacheKey] = nil
                lastChatCacheEvent = MLXServerChatCacheEvent(
                    status: .memoryHit,
                    cachedSessionCount: 1,
                    modelSessionCount: modelSessionCount,
                    priorTranscriptCount: requestFingerprints.count,
                    bestCommonPrefixCount: suffixStartIndex,
                    bestCachedTranscriptCount: state.fingerprints.count,
                    cachedPromptTokenCount: state.contextTokenCount
                )
                return ResolvedChatSession(
                    cacheKey: cacheKey,
                    sessionTransfer: state.sessionTransfer,
                    cachedPrefixMessageCount: suffixStartIndex,
                    cachedPromptTokenCount: state.contextTokenCount
                )
            }
            // Same session key but incompatible signatures or a diverged
            // transcript: the cached session cannot serve this request.
            chatSessions[cacheKey] = nil
        }

        // 2. Fresh session: the whole transcript is prefilled this turn.
        let session = MLXServerRawChatSession(
            container,
            cache: nil
        )
        lastChatCacheEvent = MLXServerChatCacheEvent(
            status: .miss,
            cachedSessionCount: 0,
            modelSessionCount: modelSessionCount,
            priorTranscriptCount: requestFingerprints.count,
            bestCommonPrefixCount: 0,
            bestCachedTranscriptCount: 0
        )
        return ResolvedChatSession(
            cacheKey: cacheKey,
            sessionTransfer: ChatSessionTransfer(session: session),
            cachedPrefixMessageCount: 0,
            cachedPromptTokenCount: nil
        )
    }

    static func chatSessionCacheKey(
        for request: MLXServerGenerationRequest
    ) -> MLXServerChatSessionCacheKey {
        MLXServerChatSessionCacheKey(
            sessionKey: request.effectiveSessionKey,
            modelID: request.model.id,
            runtimeKind: request.runtimeKind,
            cacheLayoutSignature: MLXServerChatSessionCacheSignature.cacheLayout(request.parameters)
        )
    }

    /// Runs the explicit disk lookup off the actor executor so heavy
    /// safetensors reads do not block other runtime requests.
    static func diskChatSessionMatch(
        store: MLXServerDiskKVCacheStore?,
        key: MLXServerChatSessionCacheKey,
        toolsSignature: String,
        contextSignature: String,
        requestFingerprints: [MLXServerChatTranscriptFingerprint],
        acceptsCompleteMatch: Bool
    ) async -> MLXServerDiskChatSessionMatch? {
        guard let store, store.isEnabled else {
            return nil
        }
        return await Task.detached(priority: .userInitiated) {
            store.loadSession(
                for: key,
                toolsSignature: toolsSignature,
                contextSignature: contextSignature,
                requestFingerprints: requestFingerprints,
                acceptsCompleteMatch: acceptsCompleteMatch
            )
        }.value
    }

    /// Stores the session back into the registry at turn end.
    func finishChatSessionTurn(
        cacheKey: MLXServerChatSessionCacheKey,
        sessionTransfer: ChatSessionTransfer,
        requestFingerprints: [MLXServerChatTranscriptFingerprint],
        toolsSignature: String,
        contextSignature: String,
        cachedPromptTokenCount: Int?,
        completionInfo: GenerateCompletionInfo?
    ) {
        let fingerprints = requestFingerprints
            + [MLXServerChatTranscriptFingerprint.generatedAssistantPlaceholder]
        let contextTokenCount = Self.contextTokenCount(
            cachedPromptTokenCount: cachedPromptTokenCount,
            completionInfo: completionInfo
        )
        chatSessionAccessGeneration += 1
        let state = ChatSessionState(
            sessionTransfer: sessionTransfer,
            fingerprints: fingerprints,
            toolsSignature: toolsSignature,
            contextSignature: contextSignature,
            contextTokenCount: contextTokenCount,
            lastAccessGeneration: chatSessionAccessGeneration
        )
        chatSessions[cacheKey] = state
        evictChatSessionsBeyondLimit()
    }

    static func contextTokenCount(
        cachedPromptTokenCount: Int?,
        completionInfo: GenerateCompletionInfo?
    ) -> Int? {
        guard let completionInfo else {
            return cachedPromptTokenCount
        }
        return (cachedPromptTokenCount ?? 0)
            + completionInfo.promptTokenCount
            + completionInfo.generationTokenCount
    }

    func discardChatSession(for cacheKey: MLXServerChatSessionCacheKey) {
        chatSessions[cacheKey] = nil
    }

    /// Evicts least-recently-used sessions beyond the registry bound. Each
    /// resident session retains a full KV cache in unified memory.
    func evictChatSessionsBeyondLimit() {
        while chatSessions.count > maxChatSessionCount {
            guard let victim = chatSessions.min(by: {
                $0.value.lastAccessGeneration < $1.value.lastAccessGeneration
            }) else {
                return
            }
            chatSessions[victim.key] = nil
        }
    }

    // MARK: - Disk persistence

    /// Persists the live cache for one session. This is intentionally only
    /// called by the saved-session flow.
    public func saveChatSessionCacheToDisk(
        request: MLXServerGenerationRequest
    ) async -> Bool {
        guard diskKVCacheStore != nil,
              request.messages.allSatisfy({ $0.imageURLs.isEmpty && $0.videoURLs.isEmpty })
        else {
            return false
        }

        let cacheKey = Self.chatSessionCacheKey(for: request)
        guard let state = chatSessions[cacheKey] else {
            return false
        }
        return await persistChatSessionToDisk(
            cacheKey: cacheKey,
            sessionTransfer: state.sessionTransfer,
            fingerprints: state.fingerprints,
            toolsSignature: state.toolsSignature,
            contextSignature: state.contextSignature,
            contextTokenCount: state.contextTokenCount
        )
    }

    /// Restores the cache for a saved session into the in-memory registry.
    /// Normal generation never calls this; the next prompt after a saved
    /// session load can then continue from memory.
    public func restoreChatSessionCacheFromDisk(
        request: MLXServerGenerationRequest,
        progressHandler: @Sendable @escaping (Progress) -> Void = { _ in }
    ) async throws -> Bool {
        guard diskKVCacheStore != nil,
              !request.messages.isEmpty,
              request.messages.allSatisfy({ $0.imageURLs.isEmpty && $0.videoURLs.isEmpty })
        else {
            return false
        }

        let cacheKey = Self.chatSessionCacheKey(for: request)
        let requestFingerprints = request.messages.map(\.transcriptFingerprint)
        let toolsSignature = MLXServerChatSessionRequestSignature.tools(request.tools)
        let contextSignature = MLXServerChatSessionRequestSignature.additionalContext(
            request.additionalContext
        )
        guard let diskMatch = await Self.diskChatSessionMatch(
            store: diskKVCacheStore,
            key: cacheKey,
            toolsSignature: toolsSignature,
            contextSignature: contextSignature,
            requestFingerprints: requestFingerprints,
            acceptsCompleteMatch: true
        ) else {
            return false
        }

        let container = try await container(
            for: request.model,
            runtimeKind: request.runtimeKind,
            parameters: request.parameters,
            progressHandler: progressHandler
        )
        let session = MLXServerRawChatSession(
            container,
            cache: diskMatch.cache
        )
        chatSessionAccessGeneration += 1
        chatSessions[cacheKey] = ChatSessionState(
            sessionTransfer: ChatSessionTransfer(session: session),
            fingerprints: diskMatch.fingerprints,
            toolsSignature: toolsSignature,
            contextSignature: contextSignature,
            contextTokenCount: diskMatch.contextTokenCount,
            lastAccessGeneration: chatSessionAccessGeneration
        )
        evictChatSessionsBeyondLimit()
        lastChatCacheEvent = MLXServerChatCacheEvent(
            status: .diskHit,
            cachedSessionCount: chatSessions.count,
            modelSessionCount: chatSessions.keys.count { $0.modelID == request.model.id },
            priorTranscriptCount: requestFingerprints.count,
            bestCommonPrefixCount: diskMatch.matchedPrefixEndIndex,
            bestCachedTranscriptCount: diskMatch.fingerprints.count,
            restoredPromptPrefixTokenCount: diskMatch.contextTokenCount,
            cachedPromptTokenCount: diskMatch.contextTokenCount
        )
        return true
    }

    func persistChatSessionToDisk(
        cacheKey: MLXServerChatSessionCacheKey,
        sessionTransfer: ChatSessionTransfer,
        fingerprints: [MLXServerChatTranscriptFingerprint],
        toolsSignature: String,
        contextSignature: String,
        contextTokenCount: Int?
    ) async -> Bool {
        guard let diskKVCacheStore else {
            return false
        }
        guard diskKVCacheStore.needsPersistence(
            for: cacheKey,
            fingerprints: fingerprints
        ) else {
            return true
        }
        guard let target = try? diskKVCacheStore.preparePersistenceTarget(for: cacheKey) else {
            return false
        }

        return await Task.detached(priority: .utility) {
            do {
                try await sessionTransfer.session.saveCache(to: target.temporaryURL)
                try diskKVCacheStore.commitPersistedSession(
                    key: cacheKey,
                    toolsSignature: toolsSignature,
                    contextSignature: contextSignature,
                    fingerprints: fingerprints,
                    contextTokenCount: contextTokenCount,
                    target: target
                )
                return true
            } catch {
                diskKVCacheStore.discardPersistenceTarget(target)
                return false
            }
        }.value
    }
}
