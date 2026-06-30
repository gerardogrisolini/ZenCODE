//
//  MLXServerCoreTests.swift
//  ZenCODE
//
//  Created by Gerardo Grisolini on 25/05/26.
//
import Testing
@testable import MLXServerCore
import Foundation
import MLXLMCommon
import os

func testChatSessionCacheKey(
    sessionKey: String,
    modelID: String = "mlx-community/test-a",
    runtimeKind: MLXServerModelRuntimeKind = .llm,
    layout: String = "standard"
) -> MLXServerChatSessionCacheKey {
    MLXServerChatSessionCacheKey(
        sessionKey: sessionKey,
        modelID: modelID,
        runtimeKind: runtimeKind,
        cacheLayoutSignature: layout
    )
}

func testFingerprint(_ text: String) -> MLXServerChatTranscriptFingerprint {
    MLXServerChatMessage.user(text).transcriptFingerprint
}

final class DiskKVCacheIndexRebuildProbe: Sendable {
    private let rebuildCountStorage = OSAllocatedUnfairLock(initialState: 0)

    var rebuildCount: Int {
        rebuildCountStorage.withLock { count in
            count
        }
    }

    func recordRebuild() {
        rebuildCountStorage.withLock { count in
            count += 1
        }
    }
}

actor AsyncSignalCounter {
    private var count = 0

    func signal() {
        count += 1
    }

    func waitForCount(
        _ targetCount: Int,
        attempts: Int,
        intervalNanoseconds: UInt64 = 10_000_000
    ) async -> Bool {
        for _ in 0..<attempts {
            if count >= targetCount {
                return true
            }
            try? await Task.sleep(nanoseconds: intervalNanoseconds)
        }
        return count >= targetCount
    }
}

func testModel(
    id: String = "mlx-community/test-model",
    runtimeKind: MLXServerModelRuntimeKind = .llm,
    generationDefaults: MLXServerModelGenerationDefaults = .init(),
    thinking: MLXServerModelThinkingConfiguration = .disabled
) -> MLXServerModelDescriptor {
    MLXServerModelDescriptor(
        id: id,
        displayName: "Test Model",
        runtimeKind: runtimeKind,
        configuration: ModelConfiguration(id: id),
        generationDefaults: generationDefaults,
        thinking: thinking
    )
}

