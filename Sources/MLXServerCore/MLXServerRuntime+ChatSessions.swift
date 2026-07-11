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
                let turnCheckpoint = state.sessionTransfer.session.makeKVCheckpoint().map {
                    ChatSessionTurnCheckpoint(
                        kvCheckpoint: $0,
                        fingerprints: state.fingerprints,
                        toolsSignature: state.toolsSignature,
                        contextSignature: state.contextSignature,
                        contextTokenCount: state.contextTokenCount
                    )
                }
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
                    cachedPromptTokenCount: state.contextTokenCount,
                    turnCheckpoint: turnCheckpoint
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
            cachedPromptTokenCount: nil,
            turnCheckpoint: nil
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

    /// Acquires exclusive ownership of one live chat-session cache for the
    /// whole user turn, including time spent executing tools between model
    /// generations.
    package func beginChatSessionTransaction(
        request: MLXServerGenerationRequest
    ) async throws -> MLXServerChatSessionTransaction {
        let cacheKey = Self.chatSessionCacheKey(for: request)
        let lease = try await chatSessionTransactionGate.acquire(key: cacheKey)
        do {
            try Task.checkCancellation()
        } catch {
            await lease.release()
            throw error
        }

        let token = MLXServerChatSessionTransaction()
        chatSessionTransactions[token.id] = ChatSessionTransactionState(
            cacheKey: cacheKey,
            sessionTransfer: nil,
            checkpoint: nil,
            lease: lease
        )
        return token
    }

    /// Captures the committed KV state after the caller has acquired the turn
    /// transaction and refreshed its application-level session snapshot.
    package func captureChatSessionTransactionCheckpoint(
        _ transaction: MLXServerChatSessionTransaction,
        request: MLXServerGenerationRequest
    ) {
        guard var transactionState = chatSessionTransactions[transaction.id],
              transactionState.cacheKey == Self.chatSessionCacheKey(for: request),
              let state = chatSessions[transactionState.cacheKey],
              state.toolsSignature == MLXServerChatSessionRequestSignature.tools(request.tools),
              state.contextSignature == MLXServerChatSessionRequestSignature.additionalContext(
                  request.additionalContext
              ),
              MLXServerChatSessionTranscript.storedPrefixEndIndex(
                  stored: state.fingerprints,
                  request: request.messages.map(\.transcriptFingerprint)
              ) != nil,
              let kvCheckpoint = state.sessionTransfer.session.makeKVCheckpoint() else {
            return
        }

        transactionState.sessionTransfer = state.sessionTransfer
        transactionState.checkpoint = ChatSessionTurnCheckpoint(
            kvCheckpoint: kvCheckpoint,
            fingerprints: state.fingerprints,
            toolsSignature: state.toolsSignature,
            contextSignature: state.contextSignature,
            contextTokenCount: state.contextTokenCount
        )
        chatSessionTransactions[transaction.id] = transactionState
    }

    package func commitChatSessionTransaction(
        _ transaction: MLXServerChatSessionTransaction
    ) async {
        guard let state = chatSessionTransactions.removeValue(forKey: transaction.id) else {
            return
        }
        await state.lease.release()
    }

    package func rollbackChatSessionTransaction(
        _ transaction: MLXServerChatSessionTransaction
    ) async {
        guard let state = chatSessionTransactions.removeValue(forKey: transaction.id) else {
            return
        }
        if let sessionTransfer = state.sessionTransfer,
           let checkpoint = state.checkpoint {
            restoreChatSessionTurn(
                cacheKey: state.cacheKey,
                sessionTransfer: sessionTransfer,
                checkpoint: checkpoint
            )
        }
        await state.lease.release()
    }

    func invalidateChatSessionTransactions(
        where shouldInvalidate: (MLXServerChatSessionCacheKey) -> Bool
    ) {
        for (id, var state) in chatSessionTransactions
        where shouldInvalidate(state.cacheKey) {
            state.sessionTransfer = nil
            state.checkpoint = nil
            chatSessionTransactions[id] = state
        }
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

    /// Restores the committed session state checked out before an interrupted
    /// turn. The generated prompt/output suffix is removed from the live KV
    /// cache while the prior transcript fingerprints remain authoritative.
    func restoreChatSessionTurn(
        cacheKey: MLXServerChatSessionCacheKey,
        sessionTransfer: ChatSessionTransfer,
        checkpoint: ChatSessionTurnCheckpoint?
    ) {
        guard let checkpoint,
              sessionTransfer.session.restoreKVCheckpoint(checkpoint.kvCheckpoint) else {
            discardChatSession(for: cacheKey)
            return
        }

        chatSessionAccessGeneration += 1
        chatSessions[cacheKey] = ChatSessionState(
            sessionTransfer: sessionTransfer,
            fingerprints: checkpoint.fingerprints,
            toolsSignature: checkpoint.toolsSignature,
            contextSignature: checkpoint.contextSignature,
            contextTokenCount: checkpoint.contextTokenCount,
            lastAccessGeneration: chatSessionAccessGeneration
        )
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
        guard let target = try? await diskKVCacheStore.preparePersistenceTarget(for: cacheKey) else {
            return false
        }

        return await Task.detached(priority: .utility) {
            do {
                try await sessionTransfer.session.saveCache(to: target.temporaryURL)
                try await diskKVCacheStore.commitPersistedSession(
                    key: cacheKey,
                    toolsSignature: toolsSignature,
                    contextSignature: contextSignature,
                    fingerprints: fingerprints,
                    contextTokenCount: contextTokenCount,
                    target: target
                )
                return true
            } catch {
                await diskKVCacheStore.discardPersistenceTarget(target)
                return false
            }
        }.value
    }
}
