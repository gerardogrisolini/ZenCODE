//
//  TerminalWidth.swift
//  ZenCODE
//

#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif
import Foundation
import Synchronization

/// Shared, short-lived terminal-width lookup.
///
/// Cache entries are scoped to the exact descriptor order used for the probe.
/// That keeps call sites with different output channels independent while still
/// avoiding repeated `ioctl` calls during streaming rendering.
enum TerminalWidth {
    private struct CachedTerminalWidth {
        let value: Int?
        let timestamp: ContinuousClock.Instant
    }

    private struct ProbeConfiguration: Hashable {
        let descriptors: [Int32]
    }

    /// Keeps width responsive to terminal resizes while avoiding one `ioctl`
    /// per rendered line.
    private static let cacheTTL: Duration = .milliseconds(250)
    private static let cache = Mutex<[ProbeConfiguration: CachedTerminalWidth]>([:])

    typealias Measurement = @Sendable ([Int32]) -> Int?

    /// Returns the terminal width measured through `descriptors`, in the given
    /// order, or `fallback` when none reports a positive column count.
    ///
    /// A failed probe is cached as well, but the fallback remains a call-site
    /// concern so callers with different fallbacks preserve their behavior.
    static func current(
        descriptors: [Int32],
        fallback: Int,
        forceRefresh: Bool = false,
        now: ContinuousClock.Instant? = nil,
        measure: Measurement? = nil
    ) -> Int {
        let now = now ?? ContinuousClock().now
        let configuration = ProbeConfiguration(descriptors: descriptors)
        if !forceRefresh,
           let cached = cache.withLock({ cache -> CachedTerminalWidth? in
               guard let cached = cache[configuration],
                     now - cached.timestamp < Self.cacheTTL else {
                   return nil
               }
               return cached
           }) {
            return cached.value ?? fallback
        }

        let measured: Int?
        if let measure {
            measured = measure(descriptors)
        } else {
            measured = Self.measure(descriptors: descriptors)
        }
        cache.withLock { cache in
            cache[configuration] = CachedTerminalWidth(
                value: measured,
                timestamp: now
            )
        }
        return measured ?? fallback
    }

    /// Returns whether two descriptors address the same terminal device.
    /// `nil` means the platform could not identify either terminal; callers
    /// should require an explicit topology rather than guessing from `isatty`.
    static func sharesTerminalCursor(first: Int32, second: Int32) -> Bool? {
        guard first != second else {
            return true
        }
        guard isatty(first) == 1, isatty(second) == 1 else {
            return false
        }
        guard let firstName = ttyname(first) else {
            return nil
        }
        // `ttyname` may reuse static storage, so materialize the first path
        // before asking for the second descriptor.
        let firstPath = String(cString: firstName)
        guard let secondName = ttyname(second) else {
            return nil
        }
        return firstPath == String(cString: secondName)
    }

    private static func measure(descriptors: [Int32]) -> Int? {
        var size = winsize()
        for descriptor in descriptors {
            if ioctl(descriptor, TIOCGWINSZ, &size) == 0, size.ws_col > 0 {
                return Int(size.ws_col)
            }
        }
        return nil
    }
}
