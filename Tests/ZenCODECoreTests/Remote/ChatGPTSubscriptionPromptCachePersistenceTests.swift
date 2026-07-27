//
//  ChatGPTSubscriptionPromptCachePersistenceTests.swift
//  ZenCODE
//

import Foundation
import Testing
@testable import ZenCODECore

@Suite
struct ChatGPTSubscriptionPromptCachePersistenceTests {
    @Test
    func persistenceKeyIsFixedSizeAndDoesNotEmbedTheSystemPrompt() {
        let prompt = String(repeating: "private system prompt ", count: 2_000)
        let identity = makeIdentity(sessionKey: "session-a", systemPrompt: prompt)
        let otherIdentity = makeIdentity(sessionKey: "session-b", systemPrompt: prompt)

        #expect(identity.promptCachePersistenceKey.utf8.count == 71)
        #expect(identity.promptCachePersistenceKey.hasPrefix("sha256:"))
        #expect(!identity.promptCachePersistenceKey.contains(prompt))
        #expect(identity.promptCachePersistenceKey != otherIdentity.promptCachePersistenceKey)
        #expect(
            ChatGPTSubscriptionGenerationClient.SessionIdentity
                .isPromptCachePersistenceKey(identity.promptCachePersistenceKey)
        )
        let uppercaseDigest = "sha256:"
            + identity.promptCachePersistenceKey.dropFirst("sha256:".count).uppercased()
        #expect(
            !ChatGPTSubscriptionGenerationClient.SessionIdentity
                .isPromptCachePersistenceKey(uppercaseDigest)
        )
    }

    @Test
    func persistenceKeyUsesSwiftStringCanonicalEquivalence() {
        let composed = makeIdentity(
            sessionKey: "caf\u{00E9}",
            systemPrompt: "r\u{00E9}sum\u{00E9}"
        )
        let decomposed = makeIdentity(
            sessionKey: "cafe\u{0301}",
            systemPrompt: "re\u{0301}sume\u{0301}"
        )

        #expect(composed == decomposed)
        #expect(composed.promptCachePersistenceKey == decomposed.promptCachePersistenceKey)
    }

    @Test
    func legacyPromptCacheKeysAreMigratedWithoutChangingTheirValues() throws {
        let suiteName = "ChatGPTSubscriptionPromptCachePersistenceTests.\(UUID().uuidString)"
        let userDefaults = try #require(UserDefaults(suiteName: suiteName))
        defer { userDefaults.removePersistentDomain(forName: suiteName) }

        let identity = makeIdentity(
            sessionKey: "legacy-session",
            systemPrompt: String(repeating: "large prompt ", count: 2_000),
            allowedToolNames: nil
        )
        let promptCacheKey = UUID().uuidString
        let legacyStorageKey = legacyStorageKey(for: identity)
        #expect(legacyStorageKey != identity.storageKey)
        userDefaults.set(
            [legacyStorageKey: promptCacheKey],
            forKey: ChatGPTSubscriptionGenerationClient.promptCacheKeyStoreUserDefaultsKey
        )

        let loaded = ChatGPTSubscriptionGenerationClient.loadStoredPromptCacheKeys(
            userDefaults: userDefaults
        )
        let persisted = try #require(
            userDefaults.dictionary(
                forKey: ChatGPTSubscriptionGenerationClient.promptCacheKeyStoreUserDefaultsKey
            ) as? [String: String]
        )

        #expect(loaded == [identity.promptCachePersistenceKey: promptCacheKey])
        #expect(persisted == loaded)
        #expect(persisted[legacyStorageKey] == nil)
        #expect(persisted.keys.allSatisfy { $0.utf8.count == 71 })
    }

    @Test
    func malformedEntriesAreDroppedWithoutDiscardingValidCacheKeys() throws {
        let suiteName = "ChatGPTSubscriptionPromptCachePersistenceTests.\(UUID().uuidString)"
        let userDefaults = try #require(UserDefaults(suiteName: suiteName))
        defer { userDefaults.removePersistentDomain(forName: suiteName) }

        let legacyIdentity = makeIdentity(
            sessionKey: "legacy-valid",
            systemPrompt: "legacy prompt",
            allowedToolNames: nil
        )
        let currentIdentity = makeIdentity(
            sessionKey: "current-valid",
            systemPrompt: "current prompt"
        )
        let oversizedIdentity = makeIdentity(
            sessionKey: "oversized",
            systemPrompt: "oversized prompt"
        )
        let legacyValue = UUID().uuidString
        let currentValue = UUID().uuidString
        let uppercaseDigest = "sha256:"
            + currentIdentity.promptCachePersistenceKey
                .dropFirst("sha256:".count)
                .uppercased()
        let rawValues: [String: Any] = [
            legacyStorageKey(for: legacyIdentity): legacyValue,
            currentIdentity.promptCachePersistenceKey: currentValue,
            oversizedIdentity.promptCachePersistenceKey: String(
                repeating: "x",
                count: ChatGPTSubscriptionGenerationClient
                    .maximumStoredPromptCacheValueByteCount + 1
            ),
            uppercaseDigest: UUID().uuidString,
            "not-a-session-identity": UUID().uuidString,
            "wrong-value-type": 42
        ]
        userDefaults.set(
            rawValues,
            forKey: ChatGPTSubscriptionGenerationClient.promptCacheKeyStoreUserDefaultsKey
        )

        let loaded = ChatGPTSubscriptionGenerationClient.loadStoredPromptCacheKeys(
            userDefaults: userDefaults
        )
        let persisted = try #require(
            userDefaults.dictionary(
                forKey: ChatGPTSubscriptionGenerationClient.promptCacheKeyStoreUserDefaultsKey
            ) as? [String: String]
        )

        #expect(
            loaded == [
                legacyIdentity.promptCachePersistenceKey: legacyValue,
                currentIdentity.promptCachePersistenceKey: currentValue
            ]
        )
        #expect(persisted == loaded)
    }

    @Test
    func persistedPromptCacheIsBoundedByCountAndSerializedSize() throws {
        let limit = ChatGPTSubscriptionGenerationClient.maximumStoredPromptCacheKeyCount
        let maximumValue = String(
            repeating: "x",
            count: ChatGPTSubscriptionGenerationClient.maximumStoredPromptCacheValueByteCount
        )
        var values: [String: String] = [:]
        var requiredKey = ""

        for index in 0..<(limit + 50) {
            let identity = makeIdentity(
                sessionKey: "session-\(index)",
                systemPrompt: "prompt-\(index)"
            )
            values[identity.promptCachePersistenceKey] = maximumValue
            if index == 0 {
                requiredKey = identity.promptCachePersistenceKey
            }
        }

        let bounded = ChatGPTSubscriptionGenerationClient.boundedStoredPromptCacheKeys(
            values,
            preserving: requiredKey
        )

        #expect(bounded.count == limit)
        #expect(bounded[requiredKey] == maximumValue)

        let serialized = try PropertyListSerialization.data(
            fromPropertyList: [
                ChatGPTSubscriptionGenerationClient.promptCacheKeyStoreUserDefaultsKey: bounded
            ],
            format: .binary,
            options: 0
        )
        #expect(serialized.count < 1_000_000)
    }

    @Test
    func concurrentProcessLocalMergesDoNotLoseCacheKeys() async throws {
        let suiteName = "ChatGPTSubscriptionPromptCachePersistenceTests.\(UUID().uuidString)"
        let userDefaults = try #require(UserDefaults(suiteName: suiteName))
        defer { userDefaults.removePersistentDomain(forName: suiteName) }

        let entries = (0..<32).map { index in
            (
                makeIdentity(
                    sessionKey: "concurrent-\(index)",
                    systemPrompt: "prompt-\(index)"
                ).promptCachePersistenceKey,
                UUID().uuidString
            )
        }

        await withTaskGroup(of: Void.self) { group in
            for entry in entries {
                group.addTask {
                    guard let taskUserDefaults = UserDefaults(suiteName: suiteName) else {
                        return
                    }
                    _ = ChatGPTSubscriptionGenerationClient.resolveAndStorePromptCacheKey(
                        entry.1,
                        for: entry.0,
                        userDefaults: taskUserDefaults
                    )
                }
            }
        }

        let loaded = ChatGPTSubscriptionGenerationClient.loadStoredPromptCacheKeys(
            userDefaults: userDefaults
        )
        #expect(loaded.count == entries.count)
        for entry in entries {
            #expect(loaded[entry.0] == entry.1)
        }
    }

    @Test
    func concurrentProcessLocalResolutionReusesOneValueForTheSameIdentity() async throws {
        let suiteName = "ChatGPTSubscriptionPromptCachePersistenceTests.\(UUID().uuidString)"
        let userDefaults = try #require(UserDefaults(suiteName: suiteName))
        defer { userDefaults.removePersistentDomain(forName: suiteName) }

        let persistenceKey = makeIdentity(
            sessionKey: "shared-concurrent-session",
            systemPrompt: "shared prompt"
        ).promptCachePersistenceKey
        let proposals = (0..<32).map { _ in UUID().uuidString }

        let resolvedValues = await withTaskGroup(
            of: String.self,
            returning: [String].self
        ) { group in
            for proposal in proposals {
                group.addTask {
                    guard let taskUserDefaults = UserDefaults(suiteName: suiteName) else {
                        return ""
                    }
                    return ChatGPTSubscriptionGenerationClient.resolveAndStorePromptCacheKey(
                        proposal,
                        for: persistenceKey,
                        userDefaults: taskUserDefaults
                    ).promptCacheKey
                }
            }

            var values: [String] = []
            for await value in group {
                values.append(value)
            }
            return values
        }

        let resolvedValue = try #require(resolvedValues.first)
        #expect(Set(resolvedValues) == Set([resolvedValue]))
        #expect(proposals.contains(resolvedValue))
        #expect(
            ChatGPTSubscriptionGenerationClient.loadStoredPromptCacheKeys(
                userDefaults: userDefaults
            )[persistenceKey] == resolvedValue
        )
    }

    private func makeIdentity(
        sessionKey: String,
        systemPrompt: String,
        allowedToolNames: Set<String>? = ["local.exec", "swift.test"]
    ) -> ChatGPTSubscriptionGenerationClient.SessionIdentity {
        ChatGPTSubscriptionGenerationClient.SessionIdentity(
            configuration: ChatGPTSubscriptionGenerationClient.RequestConfiguration(
                modelID: "gpt-5.6",
                workingDirectory: "/tmp/project",
                systemPrompt: systemPrompt,
                sessionKey: sessionKey,
                connectionScopeID: nil,
                history: [],
                allowedToolNames: allowedToolNames,
                thinkingSelection: nil,
                appMode: false
            )
        )
    }

    /// Reproduces the reversible Base64 JSON format written before the digest
    /// migration without calling the new `storageKey` encoder. The deliberately
    /// non-sorted field order makes this a genuine legacy fixture.
    private func legacyStorageKey(
        for identity: ChatGPTSubscriptionGenerationClient.SessionIdentity
    ) -> String {
        let json = """
        {"systemPrompt":"\(identity.systemPrompt)","sessionKey":"\(identity.sessionKey)","workingDirectory":"\(identity.workingDirectory)","modelID":"\(identity.modelID)","appMode":\(identity.appMode)}
        """
        return Data(json.utf8).base64EncodedString()
    }
}
