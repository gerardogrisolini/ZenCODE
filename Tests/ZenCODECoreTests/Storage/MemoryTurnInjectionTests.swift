//
//  MemoryTurnInjectionTests.swift
//  ZenCODECoreTests
//
//  Covers the request-assembly invariants of the automatic memory flow:
//  history purity, prompt-cache-key stability, the zero-regression (nil/blank)
//  contract, multimodal preservation, the every-round rebuild-from-fresh-
//  original rationale, and the task-local wiring. These are pure unit tests over
//  `RemoteGenerationClient.applyingCurrentTurnMemory(to:block:)` — the single
//  shared helper where recalled memory enters a provider request — plus the
//  cache-key computation in `AgentCoreAppSessionFactory`. No graph, no env, no
//  network.
//

import Foundation
import ToolCore
@testable import ZenCODECore
import Testing

@Suite
struct MemoryTurnInjectionTests {
    // MARK: - Invariant 1: the outgoing request carries the block, the input
    // array (the caller's value of `session.messages`) stays byte-identical.

    @Test
    func outgoingRequestCarriesBlockWhileInputArrayStaysPure() throws {
        let messages: [[String: Any]] = [
            ["role": "system", "content": "system prompt"],
            ["role": "user", "content": "what is the deploy command"]
        ]
        let originalSnapshot = try jsonSnapshot(messages)
        let block = "<project-memory>\nflange deploy\n</project-memory>"

        let outgoing = RemoteGenerationClient.applyingCurrentTurnMemory(
            to: messages,
            block: block
        )

        // The block reaches the outgoing copy, appended to the last user turn.
        #expect(outgoing.count == messages.count)
        let lastUser = outgoing.last { Self.role(of: $0) == "user" }
        let content = try #require(lastUser?["content"] as? String)
        #expect(content.contains("what is the deploy command"))
        #expect(content.contains("<project-memory>"))
        #expect(content.contains("flange deploy"))
        #expect(content.contains("</project-memory>"))

        // The caller's own array is untouched: history, snapshots and the cache
        // key are all derived from this value, so it must not be mutated in place.
        #expect(try jsonSnapshot(messages) == originalSnapshot)
        let untouchedUser = messages.last { Self.role(of: $0) == "user" }
        #expect((untouchedUser?["content"] as? String)?.contains("project-memory") == false)
    }

    // MARK: - Invariant 4: a nil or blank block yields a byte-identical request.

    @Test
    func nilOrBlankBlockProducesByteIdenticalRequest() throws {
        let messages: [[String: Any]] = [
            ["role": "system", "content": "system prompt"],
            ["role": "user", "content": "question"],
            ["role": "assistant", "content": "answer"],
            ["role": "user", "content": "follow-up"]
        ]
        let baseline = try jsonSnapshot(messages)

        for blank in [String?.none, "", "   ", "\n\t  \n"] {
            let outgoing = RemoteGenerationClient.applyingCurrentTurnMemory(
                to: messages,
                block: blank
            )
            #expect(try jsonSnapshot(outgoing) == baseline)
        }
    }

    // MARK: - Additional: multimodal content arrays survive injection.

    @Test
    func multimodalContentArraySurvivesInjection() throws {
        let imageItem: [String: Any] = [
            "type": "image_url",
            "image_url": ["url": "data:image/png;base64,iVBOR=="]
        ]
        let textItem: [String: Any] = [
            "type": "text",
            "text": "describe this screenshot"
        ]
        let messages: [[String: Any]] = [
            ["role": "user", "content": [textItem, imageItem]]
        ]
        let block = "<project-memory>\nscreenshot policy\n</project-memory>"

        let outgoing = RemoteGenerationClient.applyingCurrentTurnMemory(
            to: messages,
            block: block
        )
        let content = try #require(outgoing.first?["content"] as? [[String: Any]])

        // The image item is preserved verbatim and the block is appended as one
        // more text item, rather than clobbering the array with a string.
        #expect(content.count == 3)
        #expect(content[0]["type"] as? String == "text")
        #expect(content[1]["type"] as? String == "image_url")
        #expect((content[1]["image_url"] as? [String: Any])?["url"] as? String == "data:image/png;base64,iVBOR==")
        #expect(content[2]["type"] as? String == "text")
        #expect(content[2]["text"] as? String == block)
    }

    // MARK: - Degradation: no user message to attach to leaves the request alone.

    @Test
    func noUserMessageLeavesRequestUntouched() throws {
        let messages: [[String: Any]] = [
            ["role": "system", "content": "system prompt"],
            ["role": "assistant", "content": "prior answer"],
            ["role": "tool", "name": "search", "content": "result"]
        ]
        let baseline = try jsonSnapshot(messages)

        let outgoing = RemoteGenerationClient.applyingCurrentTurnMemory(
            to: messages,
            block: "<project-memory>\nshould not appear\n</project-memory>"
        )
        #expect(try jsonSnapshot(outgoing) == baseline)
    }

    // MARK: - Task-local wiring: the default argument reads the turn-scoped block.

    @Test
    func currentTurnMemoryBlockTaskLocalFeedsDefaultArgument() throws {
        let messages: [[String: Any]] = [
            ["role": "user", "content": "prompt"]
        ]

        // With no block bound, the default argument is nil and the request is
        // returned unchanged.
        let unbound = RemoteGenerationClient.applyingCurrentTurnMemory(to: messages)
        #expect(try jsonSnapshot(unbound) == jsonSnapshot(messages))

        // With a block bound to the turn-scoped task-local, the default argument
        // picks it up without the caller threading it through every signature.
        let bound = MemoryTurnContext.$currentTurnMemoryBlock.withValue(
            "<project-memory>\nrecall\n</project-memory>"
        ) {
            RemoteGenerationClient.applyingCurrentTurnMemory(to: messages)
        }
        let content = try #require(bound.first?["content"] as? String)
        #expect(content.contains("<project-memory>"))
    }

    // MARK: - Every-round rationale: call sites rebuild from the fresh original.

    @Test
    func reapplyingToAnArrayThatAlreadyCarriesTheBlockAppendsAgain() throws {
        // The helper appends to whatever array it is given, so applying it to a
        // previous *outgoing* copy would accumulate the block. That is exactly
        // why the three concrete clients always rebuild from the current
        // `session.messages` value on every tool round — `session.messages`
        // never contains the block, so each round's outgoing payload carries it
        // exactly once. This test pins that helper semantic so a call site
        // cannot silently switch to feeding back the previous outgoing payload.
        let messages: [[String: Any]] = [
            ["role": "user", "content": "prompt"]
        ]
        let block = "<project-memory>\nrecall\n</project-memory>"

        let once = RemoteGenerationClient.applyingCurrentTurnMemory(
            to: messages,
            block: block
        )
        let twice = RemoteGenerationClient.applyingCurrentTurnMemory(
            to: once,
            block: block
        )

        let onceContent = try #require(once.first?["content"] as? String)
        let twiceContent = try #require(twice.first?["content"] as? String)
        #expect(onceContent.components(separatedBy: "<project-memory>").count == 2)
        #expect(twiceContent.components(separatedBy: "<project-memory>").count == 3)
    }

    // MARK: - Real-loop regression: every tool round is reconstructed from the
    // fresh `session.messages` value, which the injection never mutates.

    @Test
    func everyToolRoundRebuildsPayloadFromFreshSessionMessages() throws {
        // Mirrors the tool loop of the three generation clients. At the start
        // of every round the session value is pure (the block never enters it);
        // the only mutations are the round's own commits — an assistant message
        // with tool calls, then one tool result per call.
        let block = "<project-memory>\nflange deploy\n</project-memory>"
        var sessionMessages: [[String: Any]] = [
            ["role": "system", "content": "system prompt"],
            ["role": "user", "content": "what is the deploy command"]
        ]

        for round in 0..<3 {
            // The outgoing request for this round is rebuilt from the fresh
            // original, so the block appears exactly once on every round — not
            // once per session and not once per accumulated round.
            let beforeInjection = try jsonSnapshot(sessionMessages)
            let outgoing = RemoteGenerationClient.applyingCurrentTurnMemory(
                to: sessionMessages,
                block: block
            )
            #expect(outgoing.count == sessionMessages.count)
            let lastUser = outgoing.last { Self.role(of: $0) == "user" }
            let content = try #require(lastUser?["content"] as? String)
            #expect(content.components(separatedBy: "<project-memory>").count == 2)
            #expect(content.contains("what is the deploy command"))
            #expect(content.hasSuffix(block))

            // The injection left the caller's array byte-identical at the
            // moment it was applied: history, snapshots and the cache key are
            // all derived from this value, so it must never be mutated in place.
            #expect(try jsonSnapshot(sessionMessages) == beforeInjection)
            let sessionUser = sessionMessages.last { Self.role(of: $0) == "user" }
            #expect((sessionUser?["content"] as? String)?.contains("project-memory") == false)

            // The round's own effect on the conversation, exactly as the
            // clients commit it after streaming. None of it carries the block.
            sessionMessages.append([
                "role": "assistant",
                "content": "checking",
                "tool_calls": [[
                    "id": "call_\(round)",
                    "type": "function",
                    "function": ["name": "local.readFile", "arguments": "{}"]
                ]]
            ])
            sessionMessages.append([
                "role": "tool",
                "tool_call_id": "call_\(round)",
                "content": "flange.yaml declares the deploy command"
            ])
        }

        // End of the loop: the block never entered the conversation, so a
        // saved session or a later cache-key computation sees only the
        // real transcript.
        let finalSnapshot = try jsonSnapshot(sessionMessages)
        #expect(String(data: finalSnapshot, encoding: .utf8)?.contains("project-memory") == false)
    }

    // MARK: - Invariant 2: the session cache key is identical with and without a
    // memory block. The block travels out-of-band (a task-local read inside the
    // generation clients) precisely so it never participates in cache identity.

    @Test
    func sessionCacheKeyIsIdenticalWithAndWithoutMemoryBlock() throws {
        let supportDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("zencode-memory-cache-key-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: supportDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: supportDirectory) }

        try AppStorageDirectory.withSupportDirectoryURL(supportDirectory) {
            try AgentSettingsManifestStore.save(AgentSettingsManifest(models: []))
            try AgentProfileStore.save(AgentProfileStore.defaultProfiles())

            let request = AgentCoreAppSessionRequest(
                sessionID: "memory-cache-session",
                workingDirectory: URL(fileURLWithPath: "/tmp/zencode-memory-cache-key"),
                cacheKey: "shared-cache-seed",
                history: [AgentRuntimeMessage(role: .user, content: "question")],
                allowedToolNames: ["local.readFile"]
            )

            let keyWithoutBlock = try AgentCoreAppSessionFactory.makeConfiguration(request: request).cacheKey

            // The block is bound for the duration of the second computation only.
            // If it ever leaked into the system prompt, cache seed, tool set, or
            // any other identity input, the two keys would diverge.
            let keyWithBlock = try MemoryTurnContext.$currentTurnMemoryBlock.withValue(
                "<project-memory>\nthis must not rotate the cache key\n</project-memory>"
            ) {
                try AgentCoreAppSessionFactory.makeConfiguration(request: request).cacheKey
            }

            #expect(keyWithoutBlock?.nilIfBlank != nil)
            #expect(keyWithoutBlock == keyWithBlock)
        }
    }

    // MARK: - Helpers

    /// Stable byte snapshot of a `[[String: Any]]` payload for identity checks.
    /// `[String: Any]` is not `Equatable`, so the request arrays are round-tripped
    /// through canonical JSON and compared as data.
    private func jsonSnapshot(_ messages: [[String: Any]]) throws -> Data {
        let sorted = try JSONSerialization.data(
            withJSONObject: messages.map { Self.canonicalize($0) },
            options: [.sortedKeys]
        )
        return sorted
    }

    private static func canonicalize(_ value: Any) -> Any {
        if let dictionary = value as? [String: Any] {
            return dictionary.mapValues(canonicalize)
        }
        if let array = value as? [Any] {
            return array.map(canonicalize)
        }
        return value
    }

    private static func role(of message: [String: Any]) -> String? {
        (message["role"] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
    }
}
