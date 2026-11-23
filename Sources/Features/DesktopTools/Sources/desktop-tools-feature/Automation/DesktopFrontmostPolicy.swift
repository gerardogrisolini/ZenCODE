import Foundation

/// Pure rules for naming the frontmost app, shared by everything that reports
/// it or decides on it: which source wins (`choose`), what activation has to
/// show before `activate_app` calls an app active (`DesktopActivationPolicy`).
/// The live reads are in `DesktopController.currentFrontmost()`.
///
/// This one-shot worker cannot trust `NSWorkspace.frontmostApplication`, which
/// can be stale for the whole life of the process (right after `activate_app`
/// it kept naming the previous app while the menu bar already showed the new
/// one), so Accessibility's system-wide focused application comes first.
enum DesktopFrontmostPolicy {
    enum Source: String, Equatable, Sendable {
        /// The focused application of the system-wide Accessibility element.
        case accessibility
        /// `NSWorkspace.shared.frontmostApplication`, possibly stale.
        case workspace

        /// How messages name the source.
        var label: String {
            switch self {
            case .accessibility: return "Accessibility"
            case .workspace: return "NSWorkspace"
            }
        }
    }

    struct Choice: Equatable, Sendable {
        let pid: pid_t
        let source: Source
    }

    /// The Accessibility pid when there is one: nil when Accessibility is not
    /// granted or the read failed. Otherwise `fallback`, the NSWorkspace pid,
    /// read only then. Nil when neither source names an app.
    static func choose(accessibilityPID: pid_t?, fallback: @autoclosure () -> pid_t?) -> Choice? {
        if let accessibilityPID, accessibilityPID > 0 {
            return Choice(pid: accessibilityPID, source: .accessibility)
        }
        if let workspacePID = fallback(), workspacePID > 0 {
            return Choice(pid: workspacePID, source: .workspace)
        }
        return nil
    }
}

/// Pure rules of the wait that follows `activate_app`: when the app counts as
/// frontmost, when the wait is over, how it ended, and what to tell the model
/// when the sources disagree.
enum DesktopActivationPolicy {
    /// Seconds activate_app waits when `timeout` is omitted.
    static let defaultTimeout: Double = 5
    static let timeoutRange: ClosedRange<Double> = 0...30
    /// Time between two observations while waiting.
    static let pollInterval: Duration = .milliseconds(100)

    /// What the sources say at one moment about an app being activated.
    struct Observation: Equatable, Sendable {
        /// The frontmost app and the source that named it (`DesktopFrontmostPolicy.choose`).
        var frontmost: DesktopFrontmostPolicy.Choice?
        /// The fresh subprocess probe reports the app active; nil when it was not asked.
        var probeActive: Bool?
        /// The owner of the first on-screen layer 0 window in Z order (front to back); nil when none or not read.
        var topWindowPID: pid_t?
        /// The app owns a layer 0 window visible on screen.
        var targetOwnsVisibleWindow = false
    }

    /// Whether the sources name `target` as the frontmost app. Accessibility
    /// decides alone; when it did not answer, the NSWorkspace fallback is not
    /// trusted over the probe, which reads a fresh snapshot, so the probe
    /// decides.
    static func isFrontmost(_ observation: Observation, target: pid_t) -> Bool {
        if let frontmost = observation.frontmost, frontmost.source == .accessibility {
            return frontmost.pid == target
        }
        if let probeActive = observation.probeActive { return probeActive }
        return observation.frontmost?.pid == target
    }

    /// The wait is over: the app is frontmost and, when it has windows visible
    /// on screen, the first one in Z order is its own.
    static func isSettled(_ observation: Observation, target: pid_t) -> Bool {
        guard isFrontmost(observation, target: target) else { return false }
        return !observation.targetOwnsVisibleWindow || observation.topWindowPID == target
    }

    /// After this many seconds without success the app is also asked to become
    /// frontmost through Accessibility (cooperative activation often ignores
    /// `activate` from a background process): one second, or half the timeout
    /// when that is shorter.
    static func accessibilityFallbackDelay(timeout: Double) -> Double {
        min(1, max(timeout, 0) / 2)
    }

    enum Outcome: Equatable {
        /// The app is frontmost and its windows are in front.
        case confirmed
        /// The app is active but the sources do not agree; the note says how.
        case unconfirmed(note: String)
        /// No source reports the app as active.
        case notActive
    }

    /// How the wait ended, from its last observation. The names are those of
    /// the target, of the app reported as frontmost, and of the owner of the
    /// first window in Z order.
    static func outcome(
        _ observation: Observation,
        target: pid_t,
        targetName: String,
        frontmostName: String?,
        topWindowName: String?
    ) -> Outcome {
        if isSettled(observation, target: target) { return .confirmed }
        if isFrontmost(observation, target: target) {
            return .unconfirmed(note: "\(targetName) is reported as the frontmost app, but the first window in the on-screen order belongs to \(topWindowName ?? "another app"), so its windows may not be in front yet. Check with list_windows or a screenshot before acting.")
        }
        guard observation.probeActive == true else { return .notActive }
        let source = observation.frontmost?.source.label ?? DesktopFrontmostPolicy.Source.accessibility.label
        let reported = frontmostName.map { "\($0) as the frontmost app" } ?? "no frontmost app"
        return .unconfirmed(note: "The application-state probe reports \(targetName) as active, but \(source) reports \(reported), so the activation may not have taken effect. Check with list_windows or a screenshot before acting.")
    }

    /// "Activated Calculator." when confirmed, otherwise a summary that does
    /// not claim more than is known.
    static func summary(_ outcome: Outcome, name: String) -> String {
        switch outcome {
        case .confirmed: return "Activated \(name)."
        case .unconfirmed: return "Requested the activation of \(name); it is not confirmed as the frontmost app."
        case .notActive: return "\(name) did not become active."
        }
    }
}
