import CoreGraphics
import Foundation

/// Pure, conservative policies shared by validation and deterministic tests.
enum DesktopSafetyPolicy {
    struct WindowIdentity {
        let title: String?
        let frame: CGRect?
    }

    static func validateSelectors(windowID: UInt32?, windowIndex: Int?) throws {
        if windowID != nil, windowIndex != nil {
            throw DesktopControlError.invalidArgument("window_index", "must be omitted when window_id is supplied.")
        }
    }

    static func matches(_ candidate: WindowIdentity, _ expected: WindowIdentity) -> Bool {
        guard let left = candidate.frame, let right = expected.frame,
              validFrame(left), validFrame(right) else { return false }
        if let title = expected.title, !title.isEmpty, candidate.title != title { return false }
        // Public AX has no supported Quartz window-ID accessor. Require absolute
        // agreement, never merely a better score than unrelated candidates.
        return abs(left.minX - right.minX) <= 2
            && abs(left.minY - right.minY) <= 2
            && abs(left.width - right.width) <= 2
            && abs(left.height - right.height) <= 2
    }

    static func uniqueMatch(_ candidates: [WindowIdentity], expected: WindowIdentity) throws -> Int {
        let matchingIndices = candidates.indices.filter { matches(candidates[$0], expected) }
        guard !matchingIndices.isEmpty else { throw DesktopControlError.windowNotFound }
        guard matchingIndices.count == 1 else {
            throw DesktopControlError.operationFailed("Window association is ambiguous; refresh list_windows and use a distinguishable window.")
        }
        return matchingIndices[0]
    }

    private static func validFrame(_ frame: CGRect) -> Bool {
        frame.origin.x.isFinite && frame.origin.y.isFinite
            && frame.width.isFinite && frame.height.isFinite
            && frame.width > 0 && frame.height > 0
    }

    static func contains(_ point: CGPoint, displays: [CGRect]) -> Bool {
        point.x.isFinite && point.y.isFinite && displays.contains { $0.contains(point) }
    }

    static func intersects(_ region: CGRect, displays: [CGRect]) -> Bool {
        validFrame(region) && displays.contains {
            let overlap = $0.intersection(region)
            return !overlap.isNull && overlap.width > 0 && overlap.height > 0
        }
    }

    struct CaptureRegion {
        let x: Int
        let y: Int
        let width: Int
        let height: Int
        var rect: CGRect { CGRect(x: x, y: y, width: width, height: height) }
        var argument: String { "-R\(x),\(y),\(width),\(height)" }
    }

    static func captureRegion(x: Double, y: Double, width: Double, height: Double) throws -> CaptureRegion {
        // screencapture consumes signed integer coordinates/dimensions. Bound to
        // Int32 even on 64-bit hosts; exact conversion also avoids Double(Int.max)
        // rounding up to an unrepresentable value.
        func rounded(_ value: Double) throws -> Int {
            guard value.isFinite, let integer = Int32(exactly: value.rounded()) else {
                throw DesktopControlError.invalidArgument("x/y/width/height", "rounded region values must fit signed 32-bit integers.")
            }
            return Int(integer)
        }
        let result = try CaptureRegion(x: rounded(x), y: rounded(y), width: rounded(width), height: rounded(height))
        guard width > 0, height > 0, result.width > 0, result.height > 0,
              Int32(exactly: result.x + result.width) != nil,
              Int32(exactly: result.y + result.height) != nil else {
            throw DesktopControlError.invalidArgument("width/height", "rounded dimensions must be positive and region endpoints must fit signed 32-bit integers.")
        }
        return result
    }

    static func validateTypingBudget(characterCount: Int, interval: Double) throws {
        // 180s feature deadline: reserve 30s for startup/scheduling and charge
        // 2ms per event pair, in addition to every sleep (including the last).
        guard (0...10_000).contains(characterCount), interval.isFinite,
              (0...1).contains(interval), Double(characterCount) * (interval + 0.002) <= 150 else {
            throw DesktopControlError.invalidArgument("text/interval", "typing exceeds the safe 150-second budget; split the request or explicitly choose a shorter interval.")
        }
    }
}

/// Each attempt remains a fresh one-shot AppKit snapshot. No cached state or
/// persistent helper is introduced; only unsuccessful retries are slowed down.
enum DesktopProbePolicy {
    static func retryDelay(attempt: Int, remaining: TimeInterval) -> TimeInterval {
        guard remaining.isFinite, remaining > 0 else { return 0 }
        let delays: [TimeInterval] = [0.1, 0.2, 0.4, 0.5]
        return min(remaining, delays[min(max(attempt, 0), delays.count - 1)])
    }

    /// Zero means one immediate fresh observation, not an unbounded child.
    /// Positive timeouts keep charging child execution and backoff to one clock.
    /// Inherit the caller's isolation so AppKit observations never leave MainActor.
    nonisolated(nonsending) static func waitForLaunch(
        timeout: TimeInterval,
        observe: (TimeInterval) async throws -> Bool,
        sleep: (TimeInterval) async throws -> Void = { try await Task.sleep(for: .seconds($0)) }
    ) async throws -> Bool {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(timeout))
        func remaining() -> TimeInterval {
            let duration = clock.now.duration(to: deadline)
            return Double(duration.components.seconds) + Double(duration.components.attoseconds) / 1e18
        }
        var attempt = 0
        repeat {
            try Task.checkCancellation()
            // A zero outer wait still permits the original first fresh snapshot.
            guard let probeTimeout = timeout == 0 ? 2 : childTimeout(remaining: remaining()) else { return false }
            if try await observe(probeTimeout) { return true }
            if timeout == 0 { return false }
            let delay = retryDelay(attempt: attempt, remaining: remaining())
            if delay <= 0 { return false }
            try await sleep(delay)
            attempt += 1
        } while true
    }

    static func childTimeout(remaining: TimeInterval) -> TimeInterval? {
        guard remaining.isFinite, remaining > 0 else { return nil }
        return min(2, remaining)
    }
}
