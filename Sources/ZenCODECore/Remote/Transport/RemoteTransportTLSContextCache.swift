//
//  RemoteTransportTLSContextCache.swift
//  ZenCODE
//

import Foundation
import NIOSSL
import Synchronization

/// Small, bounded, process-wide cache of client `NIOSSLContext`s.
///
/// A `NIOSSLContext` is thread-safe and shareable across channels on any event
/// loop, but building one is expensive: it may load and parse the platform
/// trust store. The transport opens a fresh connection for every request
/// (`Connection: close`, no pooling), so it reuses one context per trust
/// configuration and creates only the per-connection `NIOSSLClientHandler`,
/// which still carries that connection's SNI and verification hostname.
///
/// The key is the ordered list of additional PEM trust roots, the only part of
/// `RemoteTransportTLSConfiguration` that shapes the context; `serverName` is
/// applied per handler. A construction error is thrown and never cached, so a
/// later connection retries. The least recently used entry is evicted once
/// `capacity` distinct configurations are stored.
///
/// An entry expires `timeToLive` after its context was created, however often
/// it is used: on Linux NIOSSL reads the platform CA bundle when the context
/// is built, so a long-running process would otherwise never see changes to
/// the system trust store. An expired entry is rebuilt on its next request.
final class RemoteTransportTLSContextCache: Sendable {
    static let shared = RemoteTransportTLSContextCache()
    static let defaultCapacity = 8
    static let timeToLive: Duration = .seconds(10 * 60)

    private struct Entry: Sendable {
        let additionalTrustRootPEMs: [Data]
        let context: NIOSSLContext
        /// When construction of `context` started, on the monotonic clock.
        let createdAt: ContinuousClock.Instant
    }

    private let capacity: Int
    /// Monotonic clock deciding expiry; injected by tests.
    private let now: @Sendable () -> ContinuousClock.Instant
    /// Ordered from least to most recently used.
    private let entries: Mutex<[Entry]>

    init(
        capacity: Int = RemoteTransportTLSContextCache.defaultCapacity,
        now: @escaping @Sendable () -> ContinuousClock.Instant = { .now }
    ) {
        self.capacity = max(1, capacity)
        self.now = now
        entries = Mutex([])
    }

    /// Number of cached contexts.
    var count: Int {
        entries.withLock { $0.count }
    }

    func context(for tls: RemoteTransportTLSConfiguration) throws -> NIOSSLContext {
        let key = tls.additionalTrustRootPEMs
        if let cached = entries.withLock({ Self.touch(key, in: &$0, now: now()) }) {
            return cached
        }
        // Built outside the lock so that a slow trust-store load never blocks
        // other event loops. Concurrent misses may build duplicates; the first
        // stored context wins and every caller receives that one. The age is
        // counted from before the build, which is when the trust store is read.
        let createdAt = now()
        let context = try NIOSSLContext(
            configuration: Self.makeConfiguration(additionalTrustRootPEMs: key)
        )
        return entries.withLock { entries in
            if let existing = Self.touch(key, in: &entries, now: now()) {
                return existing
            }
            if entries.count >= capacity {
                entries.removeFirst(entries.count - capacity + 1)
            }
            entries.append(Entry(additionalTrustRootPEMs: key, context: context, createdAt: createdAt))
            return context
        }
    }

    /// The client configuration shared by every TLS connection of the
    /// transport.
    static func makeConfiguration(additionalTrustRootPEMs: [Data]) throws -> TLSConfiguration {
        var configuration = TLSConfiguration.makeClientConfiguration()
        // Make the secure default explicit: full certificate-chain and hostname
        // verification and platform trust roots. The per-connection handler
        // supplies the hostname used for both TLS SNI and certificate matching.
        configuration.certificateVerification = .fullVerification
        configuration.trustRoots = .default
        if !additionalTrustRootPEMs.isEmpty {
            let certificates = try additionalTrustRootPEMs.map {
                try NIOSSLCertificate(bytes: Array($0), format: .pem)
            }
            configuration.additionalTrustRoots = [.certificates(certificates)]
        }
        return configuration
    }

    /// Returns the cached context for `key`, marking it most recently used.
    /// An entry that expired by `now` is removed and reported as a miss.
    private static func touch(
        _ key: [Data],
        in entries: inout [Entry],
        now: ContinuousClock.Instant
    ) -> NIOSSLContext? {
        guard let index = entries.firstIndex(where: { $0.additionalTrustRootPEMs == key }) else {
            return nil
        }
        let entry = entries[index]
        guard entry.createdAt.duration(to: now) < timeToLive else {
            entries.remove(at: index)
            return nil
        }
        if index != entries.index(before: entries.endIndex) {
            entries.remove(at: index)
            entries.append(entry)
        }
        return entry.context
    }
}
