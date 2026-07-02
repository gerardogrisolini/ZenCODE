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

@Test
func serverSupportFilesDefaultToHomeMlxCoderMLXDirectory() {
    let supportDirectory = MLXServerUserHomeDirectory.current()
        .appendingPathComponent(".zencode", isDirectory: true)
        .appendingPathComponent("mlx", isDirectory: true)
        .standardizedFileURL

    #expect(MLXServerSettingsStore.defaultSupportDirectoryURL() == supportDirectory)
    #expect(MLXServerSettingsStore.settingsURL() == supportDirectory.appendingPathComponent("settings.json"))
    #expect(MLXServerModelsManifestStore.modelsURL() == supportDirectory.appendingPathComponent("models.json"))
}

@Test
func diskKVCacheDefaultsToBalancedLimit() {
    let configuration = MLXServerDiskKVCacheConfiguration()
    let supportDirectory = MLXServerSettingsStore.defaultSupportDirectoryURL()

    #expect(configuration.isEnabled)
    #expect(configuration.limitBytes == MLXServerDiskKVCacheConfiguration.defaultLimitBytes)
    #expect(configuration.directory == supportDirectory.appendingPathComponent("KVCaches", isDirectory: true))
}

@Test
func diskKVCacheRejectsUnreasonableLimit() {
    #expect(throws: MLXServerSettingsError.invalidDiskKVCacheLimit) {
        try MLXServerDiskKVCacheSettings(limitGB: -1).validated()
    }
    #expect(throws: MLXServerSettingsError.invalidDiskKVCacheLimit) {
        try MLXServerDiskKVCacheSettings(
            limitGB: MLXServerDiskKVCacheSettings.maximumLimitGB + 1
        ).validated()
    }
    #expect(throws: MLXServerSettingsError.invalidDiskKVCacheLimit) {
        try MLXServerDiskKVCacheSettings(limitGB: .infinity).validated()
    }
}

@Test
func diskKVCacheSessionKeyScopesEntryBySessionAndLayout() {
    let firstKey = testChatSessionCacheKey(sessionKey: "session-a", layout: "standard")
    let sameKey = testChatSessionCacheKey(sessionKey: "session-a", layout: "standard")
    let differentSessionKey = testChatSessionCacheKey(sessionKey: "session-b", layout: "standard")
    let differentLayoutKey = testChatSessionCacheKey(sessionKey: "session-a", layout: "quantized")

    #expect(firstKey.entryKey == sameKey.entryKey)
    #expect(firstKey.entryKey != differentSessionKey.entryKey)
    #expect(firstKey.entryKey != differentLayoutKey.entryKey)
}

@Test
func chatSessionTranscriptContinuationMatchesAssistantByRoleOnly() {
    let stored = [
        MLXServerChatMessage.system("You are concise.").transcriptFingerprint,
        MLXServerChatMessage.user("Hello").transcriptFingerprint,
        MLXServerChatTranscriptFingerprint.generatedAssistantPlaceholder
    ]
    let request = [
        MLXServerChatMessage.system("You are concise.").transcriptFingerprint,
        MLXServerChatMessage.user("Hello").transcriptFingerprint,
        MLXServerChatMessage.assistant("Client-side visible text only").transcriptFingerprint,
        MLXServerChatMessage.user("Continue").transcriptFingerprint
    ]

    #expect(
        MLXServerChatSessionTranscript.continuationSuffixStartIndex(
            stored: stored,
            request: request
        ) == 3
    )
}

@Test
func chatSessionTranscriptContinuationConsumesAssistantReplayRun() {
    let stored = [
        MLXServerChatMessage.system("You are concise.").transcriptFingerprint,
        MLXServerChatMessage.user("Hello").transcriptFingerprint,
        MLXServerChatTranscriptFingerprint.generatedAssistantPlaceholder
    ]
    let request = [
        MLXServerChatMessage.system("You are concise.").transcriptFingerprint,
        MLXServerChatMessage.user("Hello").transcriptFingerprint,
        MLXServerChatMessage.assistant("reasoning_summary:\n...").transcriptFingerprint,
        MLXServerChatMessage.assistant("Visible content").transcriptFingerprint,
        MLXServerChatMessage.user("Continue").transcriptFingerprint
    ]

    #expect(
        MLXServerChatSessionTranscript.continuationSuffixStartIndex(
            stored: stored,
            request: request
        ) == 4
    )
}

@Test
func rawChatSessionUsesOnlySuffixMessagesForCachedContinuation() {
    let request = MLXServerGenerationRequest(
        model: testModel(),
        messages: [
            .user("Find the file"),
            .assistant(
                "Found it.",
                toolCalls: [
                    MLXServerChatToolCall(
                        id: "call_1",
                        name: "local.readFile",
                        arguments: ["path": "File.swift"]
                    )
                ]
            ),
            .tool("contents", toolCallID: "call_1", toolName: "local.readFile")
        ],
        tools: [
            [
                "type": "function",
                "function": [
                    "name": "local.readFile"
                ] as [String: any Sendable]
            ] as [String: any Sendable]
        ],
        sessionID: "session"
    )

    let suffix = MLXServerRawChatSession.suffixChatMessages(
        request: request,
        cachedPrefixMessageCount: 2
    )

    #expect(suffix.count == 1)
    #expect(suffix.first?.role == .tool)
    #expect(suffix.first?.content == "contents")
}

@Test
func rawChatSessionUsesCachedMessageOnlyAsTemplateContextForContinuation() throws {
    let request = MLXServerGenerationRequest(
        model: testModel(),
        messages: [
            .user("Find the file"),
            .assistant(
                "Found it.",
                toolCalls: [
                    MLXServerChatToolCall(
                        id: "call_1",
                        name: "local.readFile",
                        arguments: ["path": "File.swift"]
                    )
                ]
            ),
            .tool("contents", toolCallID: "call_1", toolName: "local.readFile")
        ],
        tools: [
            [
                "type": "function",
                "function": [
                    "name": "local.readFile"
                ] as [String: any Sendable]
            ] as [String: any Sendable]
        ],
        sessionID: "session"
    )

    let slice = MLXServerRawChatSession.cachedContinuationTemplateSlice(
        request: request,
        cachedPrefixMessageCount: 2
    )

    #expect(slice.cachedContextMessages.count == 2)
    #expect(slice.cachedContextMessages.first?["role"] as? String == "user")
    #expect(slice.cachedContextMessages.last?["role"] as? String == "assistant")
    #expect(slice.continuationContextMessages.count == 3)
    #expect(slice.continuationContextMessages.first?["role"] as? String == "user")
    #expect(slice.continuationContextMessages.dropFirst().first?["role"] as? String == "assistant")
    #expect(slice.continuationContextMessages.last?["role"] as? String == "tool")
    #expect(slice.continuationContextMessages.last?["content"] as? String == "contents")

    let toolCalls = try #require(
        slice.continuationContextMessages.dropFirst().first?["tool_calls"]
            as? [[String: any Sendable]]
    )
    let toolCall = try #require(toolCalls.first)
    let function = try #require(toolCall["function"] as? [String: any Sendable])
    #expect(function["name"] as? String == "local.readFile")
}

@Test
func chatSessionTranscriptStoredPrefixAcceptsExactSavedSessionReplay() {
    let stored = [
        MLXServerChatMessage.system("You are concise.").transcriptFingerprint,
        MLXServerChatMessage.user("Hello").transcriptFingerprint,
        MLXServerChatTranscriptFingerprint.generatedAssistantPlaceholder
    ]
    let request = [
        MLXServerChatMessage.system("You are concise.").transcriptFingerprint,
        MLXServerChatMessage.user("Hello").transcriptFingerprint,
        MLXServerChatMessage.assistant("Saved visible answer").transcriptFingerprint
    ]

    #expect(
        MLXServerChatSessionTranscript.storedPrefixEndIndex(
            stored: stored,
            request: request
        ) == 3
    )
    #expect(
        MLXServerChatSessionTranscript.continuationSuffixStartIndex(
            stored: stored,
            request: request
        ) == nil
    )
}

@Test
func chatSessionTranscriptRejectsDivergedUserPrefix() {
    let stored = [
        MLXServerChatMessage.system("You are concise.").transcriptFingerprint,
        MLXServerChatMessage.user("Hello").transcriptFingerprint
    ]
    let request = [
        MLXServerChatMessage.system("You are concise.").transcriptFingerprint,
        MLXServerChatMessage.user("Different").transcriptFingerprint,
        MLXServerChatMessage.user("Continue").transcriptFingerprint
    ]

    #expect(
        MLXServerChatSessionTranscript.continuationSuffixStartIndex(
            stored: stored,
            request: request
        ) == nil
    )
}

@Test
func diskKVCacheEvictsLeastRecentlyUsedSessionEntries() throws {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("mlx-server-tests-\(UUID().uuidString)", isDirectory: true)
    defer {
        try? FileManager.default.removeItem(at: directory)
    }

    let store = MLXServerDiskKVCacheStore(
        configuration: MLXServerDiskKVCacheConfiguration(
            directory: directory,
            limitBytes: 24
        )
    )
    let firstKey = testChatSessionCacheKey(sessionKey: "session-a")
    let secondKey = testChatSessionCacheKey(sessionKey: "session-b")

    let firstTarget = try #require(try store.preparePersistenceTarget(for: firstKey))
    try Data(repeating: 1, count: 32).write(to: firstTarget.temporaryURL)
    try store.commitPersistedSession(
        key: firstKey,
        toolsSignature: "none",
        contextSignature: "none",
        fingerprints: [testFingerprint("first")],
        target: firstTarget
    )

    let secondTarget = try #require(try store.preparePersistenceTarget(for: secondKey))
    try Data(repeating: 2, count: 32).write(to: secondTarget.temporaryURL)
    try store.commitPersistedSession(
        key: secondKey,
        toolsSignature: "none",
        contextSignature: "none",
        fingerprints: [testFingerprint("second")],
        target: secondTarget
    )

    #expect(!FileManager.default.fileExists(atPath: firstTarget.cacheURL.path))
    #expect(!FileManager.default.fileExists(atPath: firstTarget.metadataURL.path))
    #expect(FileManager.default.fileExists(atPath: secondTarget.cacheURL.path))
    #expect(FileManager.default.fileExists(atPath: secondTarget.metadataURL.path))
}

@Test
func diskKVCacheSkipsPersistenceForUnchangedSessionTranscript() throws {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("mlx-server-dedup-\(UUID().uuidString)", isDirectory: true)
    defer {
        try? FileManager.default.removeItem(at: directory)
    }

    let store = MLXServerDiskKVCacheStore(
        configuration: MLXServerDiskKVCacheConfiguration(
            directory: directory,
            limitBytes: 1_000_000
        )
    )
    let key = testChatSessionCacheKey(sessionKey: "session-a")
    let fingerprints = [testFingerprint("first")]

    let target = try #require(try store.preparePersistenceTarget(for: key))
    try Data(repeating: 1, count: 16).write(to: target.temporaryURL)
    try store.commitPersistedSession(
        key: key,
        toolsSignature: "none",
        contextSignature: "none",
        fingerprints: fingerprints,
        target: target
    )

    #expect(!store.needsPersistence(for: key, fingerprints: fingerprints))
    #expect(store.needsPersistence(for: key, fingerprints: fingerprints + [testFingerprint("second")]))
    #expect(store.needsPersistence(for: testChatSessionCacheKey(sessionKey: "other"), fingerprints: fingerprints))
}

@Test
func diskKVCacheCommitPersistsContextTokenCount() throws {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("mlx-server-context-tokens-\(UUID().uuidString)", isDirectory: true)
    defer {
        try? FileManager.default.removeItem(at: directory)
    }

    let store = MLXServerDiskKVCacheStore(
        configuration: MLXServerDiskKVCacheConfiguration(
            directory: directory,
            limitBytes: 1_000_000
        )
    )
    let key = testChatSessionCacheKey(sessionKey: "session-a")
    let target = try #require(try store.preparePersistenceTarget(for: key))
    try Data(repeating: 1, count: 16).write(to: target.temporaryURL)

    try store.commitPersistedSession(
        key: key,
        toolsSignature: "none",
        contextSignature: "none",
        fingerprints: [testFingerprint("first")],
        contextTokenCount: 42,
        target: target
    )

    let metadata = try JSONDecoder().decode(
        MLXServerPersistedChatSessionMetadata.self,
        from: Data(contentsOf: target.metadataURL)
    )
    #expect(metadata.contextTokenCount == 42)
}

@Test
func diskKVCacheCommitOverwritesSameSessionEntry() throws {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("mlx-server-overwrite-\(UUID().uuidString)", isDirectory: true)
    defer {
        try? FileManager.default.removeItem(at: directory)
    }

    let store = MLXServerDiskKVCacheStore(
        configuration: MLXServerDiskKVCacheConfiguration(
            directory: directory,
            limitBytes: 1_000_000
        )
    )
    let key = testChatSessionCacheKey(sessionKey: "session-a")

    let firstTarget = try #require(try store.preparePersistenceTarget(for: key))
    try Data(repeating: 1, count: 16).write(to: firstTarget.temporaryURL)
    try store.commitPersistedSession(
        key: key,
        toolsSignature: "none",
        contextSignature: "none",
        fingerprints: [testFingerprint("first")],
        target: firstTarget
    )

    let secondTarget = try #require(try store.preparePersistenceTarget(for: key))
    try Data(repeating: 2, count: 32).write(to: secondTarget.temporaryURL)
    try store.commitPersistedSession(
        key: key,
        toolsSignature: "none",
        contextSignature: "none",
        fingerprints: [testFingerprint("first"), testFingerprint("second")],
        target: secondTarget
    )

    #expect(firstTarget.cacheURL == secondTarget.cacheURL)
    let attributes = try FileManager.default.attributesOfItem(atPath: firstTarget.cacheURL.path)
    #expect((attributes[.size] as? NSNumber)?.intValue == 32)
}

@Test
func diskKVCacheIndexRebuildRemovesOrphanedCacheFiles() throws {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("mlx-server-orphans-\(UUID().uuidString)", isDirectory: true)
    defer {
        try? FileManager.default.removeItem(at: directory)
    }

    let store = MLXServerDiskKVCacheStore(
        configuration: MLXServerDiskKVCacheConfiguration(
            directory: directory,
            limitBytes: 1_000_000
        )
    )
    let key = testChatSessionCacheKey(sessionKey: "session-a")

    let target = try #require(try store.preparePersistenceTarget(for: key))
    try Data(repeating: 1, count: 16).write(to: target.temporaryURL)
    try store.commitPersistedSession(
        key: key,
        toolsSignature: "none",
        contextSignature: "none",
        fingerprints: [testFingerprint("first")],
        target: target
    )

    let modelDirectory = target.cacheURL.deletingLastPathComponent()
    let orphanedCacheURL = modelDirectory.appendingPathComponent("orphan.safetensors")
    try Data(repeating: 2, count: 16).write(to: orphanedCacheURL)
    let staleTemporaryURL = modelDirectory.appendingPathComponent("stale.tmp.safetensors")
    try Data(repeating: 3, count: 16).write(to: staleTemporaryURL)
    try FileManager.default.setAttributes(
        [.modificationDate: Date(timeIntervalSinceNow: -3 * 60 * 60)],
        ofItemAtPath: staleTemporaryURL.path
    )
    let freshTemporaryURL = modelDirectory.appendingPathComponent("fresh.tmp.safetensors")
    try Data(repeating: 4, count: 16).write(to: freshTemporaryURL)

    // Disk-limit enforcement enumerates entries and cleans orphan payloads up.
    let freshStore = MLXServerDiskKVCacheStore(
        configuration: MLXServerDiskKVCacheConfiguration(
            directory: directory,
            limitBytes: 1_000_000
        )
    )
    freshStore.enforceDiskLimit()

    #expect(FileManager.default.fileExists(atPath: target.cacheURL.path))
    #expect(FileManager.default.fileExists(atPath: target.metadataURL.path))
    #expect(!FileManager.default.fileExists(atPath: orphanedCacheURL.path))
    #expect(!FileManager.default.fileExists(atPath: staleTemporaryURL.path))
    #expect(FileManager.default.fileExists(atPath: freshTemporaryURL.path))
}

