//  Policy-free system DNS resolution to numeric addresses.

import Foundation

#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

/// Neutral failure of ``FeatureSystemHostResolver``. Each feature maps it onto
/// its own user-facing errors, so their messages stay feature-specific. The
/// associated value is the host exactly as it was passed to the resolver.
public enum FeatureHostResolutionError: Error, Equatable, Sendable {
    /// The host is empty after normalization or the system resolver failed.
    case unresolvedHost(String)
    /// The system resolver answered without any numeric address.
    case noResolvedAddresses(String)
}

/// Synchronous system resolver that turns a host into the sorted, de-duplicated
/// numeric addresses returned by `getaddrinfo`/`getnameinfo`.
///
/// It trims whitespace, IPv6 brackets, and leading or trailing dots before
/// resolving. `localhost` and any `.localhost` name (RFC 6761) resolve to
/// `127.0.0.1` and `::1` without asking the platform resolver, which avoids
/// platform differences. It does not apply any policy: it never decides
/// whether a host or address may be contacted, and it does not check that
/// loopback names resolve only to loopback. It blocks the calling thread;
/// use ``FeatureBlockingOperation/run(qos:_:)`` to call it from async code.
public struct FeatureSystemHostResolver: Sendable {
    public init() {}

    public func resolve(host: String) throws(FeatureHostResolutionError) -> [String] {
        let normalizedHost = host
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
            .trimmingCharacters(in: CharacterSet(charactersIn: "."))
        guard !normalizedHost.isEmpty else { throw .unresolvedHost(host) }
        if normalizedHost.caseInsensitiveCompare("localhost") == .orderedSame
            || normalizedHost.lowercased().hasSuffix(".localhost")
        {
            return ["127.0.0.1", "::1"]
        }

        var hints = addrinfo()
        hints.ai_family = AF_UNSPEC
        var rawResults: UnsafeMutablePointer<addrinfo>?
        let status = normalizedHost.withCString { hostPointer in
            getaddrinfo(hostPointer, nil, &hints, &rawResults)
        }
        guard status == 0, let firstResult = rawResults else { throw .unresolvedHost(host) }
        defer { freeaddrinfo(firstResult) }

        var addresses = Set<String>()
        var current: UnsafeMutablePointer<addrinfo>? = firstResult
        while let entry = current {
            let info = entry.pointee
            if let socketAddress = info.ai_addr {
                var buffer = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                let nameStatus = getnameinfo(
                    socketAddress,
                    info.ai_addrlen,
                    &buffer,
                    socklen_t(buffer.count),
                    nil,
                    0,
                    NI_NUMERICHOST
                )
                if nameStatus == 0 {
                    let nullTerminator = buffer.firstIndex(of: 0) ?? buffer.endIndex
                    let address = String(
                        decoding: buffer[..<nullTerminator].map(UInt8.init(bitPattern:)),
                        as: UTF8.self
                    )
                    addresses.insert(address)
                }
            }
            current = info.ai_next
        }
        let values = addresses.sorted()
        guard !values.isEmpty else { throw .noResolvedAddresses(host) }
        return values
    }
}
