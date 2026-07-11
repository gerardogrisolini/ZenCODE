//
//  MLXServerChatSessionCheckpointTests.swift
//  ZenCODE
//

import MLX
import MLXLMCommon
import Testing
@testable import MLXServerCore

@Test
func chatSessionCheckpointTrimsCacheToCommittedOffset() throws {
    let layer = TestKVCache(offset: 3, isTrimmable: true)
    let checkpoint = MLXServerChatSessionKVCheckpoint(cache: [layer])

    layer.advance(by: 2)
    #expect(layer.offset == 5)

    var cache: [KVCache]? = [layer]
    #expect(checkpoint.restore(cache: &cache))
    let restoredLayer = try #require(cache?.first)
    #expect(restoredLayer.offset == 3)
    #expect(ObjectIdentifier(restoredLayer as AnyObject) == ObjectIdentifier(layer))
}

@Test
func chatSessionCheckpointRestoresIndependentCopyForUntrimmableCache() throws {
    let layer = TestKVCache(offset: 3, isTrimmable: false)
    let checkpoint = MLXServerChatSessionKVCheckpoint(cache: [layer])

    layer.advance(by: 2)
    #expect(layer.offset == 5)

    var cache: [KVCache]? = [layer]
    #expect(checkpoint.restore(cache: &cache))
    let restoredLayer = try #require(cache?.first)
    #expect(restoredLayer.offset == 3)
    #expect(ObjectIdentifier(restoredLayer as AnyObject) != ObjectIdentifier(layer))
}

@Test
func chatSessionTransactionSerializesTheSameRuntimeCache() async throws {
    let runtime = MLXServerRuntime()
    let request = MLXServerGenerationRequest(
        model: testModel(),
        messages: [.user("opening")],
        sessionID: "shared-session"
    )
    let first = try await runtime.beginChatSessionTransaction(request: request)
    let secondAcquired = AsyncSignalCounter()
    let secondTask = Task {
        let transaction = try await runtime.beginChatSessionTransaction(request: request)
        await secondAcquired.signal()
        return transaction
    }

    #expect(!(await secondAcquired.waitForCount(1, attempts: 10)))
    await runtime.commitChatSessionTransaction(first)
    #expect(await secondAcquired.waitForCount(1, attempts: 200))

    let second = try await secondTask.value
    await runtime.commitChatSessionTransaction(second)
}

private final class TestKVCache: KVCache {
    var offset: Int
    var maxSize: Int? { nil }
    var state: [MLXArray] = []
    var metaState: [String] = []
    private let canTrim: Bool

    init(offset: Int, isTrimmable: Bool) {
        self.offset = offset
        self.canTrim = isTrimmable
    }

    var isTrimmable: Bool {
        canTrim
    }

    func update(keys: MLXArray, values: MLXArray) -> (MLXArray, MLXArray) {
        (keys, values)
    }

    func trim(_ count: Int) -> Int {
        guard canTrim else {
            return 0
        }
        let trimmed = min(offset, count)
        offset -= trimmed
        return trimmed
    }

    func copy() -> any KVCache {
        TestKVCache(offset: offset, isTrimmable: canTrim)
    }

    func makeMask(
        n _: Int,
        windowSize _: Int?,
        returnArray _: Bool
    ) -> MLXFast.ScaledDotProductAttentionMaskMode {
        .none
    }

    func innerState() -> [MLXArray] {
        []
    }

    func advance(by count: Int) {
        offset += count
    }
}
