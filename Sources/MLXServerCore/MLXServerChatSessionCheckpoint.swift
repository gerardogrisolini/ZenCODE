//
//  MLXServerChatSessionCheckpoint.swift
//  ZenCODE
//

import Foundation
@preconcurrency import MLXLMCommon

/// Transaction checkpoint for a live chat-session KV cache.
///
/// Standard and quantized caches can be restored cheaply by trimming them back
/// to their committed offsets. Other cache layouts (for example rotating or
/// recurrent caches) retain an independent copy because they cannot always be
/// truncated after generation has advanced them.
struct MLXServerChatSessionKVCheckpoint: @unchecked Sendable {
    private enum Storage {
        case offsets([Int])
        case copies([KVCache])
    }

    private let storage: Storage

    init(cache: [KVCache]) {
        let canUseOffsets = cache.allSatisfy { layer in
            layer.isTrimmable
                && layer.maxSize == nil
                && !(layer is CacheList)
        }
        if canUseOffsets {
            storage = .offsets(cache.map(\.offset))
        } else {
            storage = .copies(cache.map { $0.copy() })
        }
    }

    func restore(cache: inout [KVCache]?) -> Bool {
        switch storage {
        case .offsets(let offsets):
            guard let cache,
                  cache.count == offsets.count,
                  zip(cache, offsets).allSatisfy({ pair in
                      pair.0.isTrimmable && pair.0.offset >= pair.1
                  }) else {
                return false
            }

            for (layer, offset) in zip(cache, offsets) {
                layer.trim(layer.offset - offset)
            }
            return zip(cache, offsets).allSatisfy { pair in
                pair.0.offset == pair.1
            }

        case .copies(let copies):
            cache = copies
            return true
        }
    }
}

extension MLXServerRawChatSession {
    func makeKVCheckpoint() -> MLXServerChatSessionKVCheckpoint? {
        guard let cache, !cache.isEmpty else {
            return nil
        }
        return MLXServerChatSessionKVCheckpoint(cache: cache)
    }

    func restoreKVCheckpoint(
        _ checkpoint: MLXServerChatSessionKVCheckpoint
    ) -> Bool {
        checkpoint.restore(cache: &cache)
    }
}
