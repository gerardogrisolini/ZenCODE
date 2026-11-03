//
//  ZenMarkdownCache.swift
//  ZenApp
//
//  A small thread-safe memo used to parse each distinct Markdown string, and
//  highlight each distinct code block, only once.
//

import Foundation
import Synchronization

/// A bounded, thread-safe memo table. When full, the least recently used
/// entry is evicted (linear scan, which is cheap at the small capacities used
/// here).
final class ZenMarkdownCache<Key: Hashable & Sendable, Value: Sendable>: Sendable {
    private struct Entry {
        var value: Value
        var stamp: UInt64
    }

    private struct Storage {
        var entries: [Key: Entry] = [:]
        var clock: UInt64 = 0
    }

    /// The maximum number of entries kept.
    let capacity: Int
    private let storage = Mutex(Storage())

    init(capacity: Int) {
        self.capacity = max(1, capacity)
    }

    /// The number of entries currently stored.
    var count: Int {
        storage.withLock { $0.entries.count }
    }

    /// The cached value for `key`, refreshing its recency.
    func value(for key: Key) -> Value? {
        storage.withLock { storage in
            guard var entry = storage.entries[key] else {
                return nil
            }
            storage.clock &+= 1
            entry.stamp = storage.clock
            storage.entries[key] = entry
            return entry.value
        }
    }

    /// Stores `value` for `key`, evicting the least recently used entry when
    /// the table is full.
    func insert(_ value: Value, for key: Key) {
        storage.withLock { storage in
            storage.clock &+= 1
            if storage.entries[key] == nil,
               storage.entries.count >= capacity,
               let oldest = storage.entries.min(by: { $0.value.stamp < $1.value.stamp })?.key {
                storage.entries.removeValue(forKey: oldest)
            }
            storage.entries[key] = Entry(value: value, stamp: storage.clock)
        }
    }

    /// Returns the cached value for `key`, computing and storing it on a miss.
    func value(for key: Key, compute: () -> Value) -> Value {
        if let cached = value(for: key) {
            return cached
        }
        let computed = compute()
        insert(computed, for: key)
        return computed
    }

    /// Removes every entry.
    func removeAll() {
        storage.withLock { $0.entries.removeAll() }
    }
}
