import AppKit
import Darwin
import Foundation

/// macOS attributes TCC permissions to the app that launched zen (Terminal, an
/// editor hosting ACP, ...), so permission messages should name that app.
enum DesktopHostApplication {
    static let fallbackSubject = "the app that launched zen (usually your terminal)"

    /// The regular application that hosts this zen session (Terminal, iTerm,
    /// ZenApp, an editor running ACP, ...).
    struct Host: Equatable, Sendable {
        let pid: pid_t
        let name: String
    }

    static func firstApplicationAncestor(
        startingAt pid: pid_t,
        parentOf: (pid_t) -> pid_t?,
        applicationName: (pid_t) -> String?,
        maximumDepth: Int = 32
    ) -> String? {
        firstApplicationAncestorProcess(
            startingAt: pid, parentOf: parentOf, applicationName: applicationName, maximumDepth: maximumDepth
        )?.name
    }

    static func firstApplicationAncestorProcess(
        startingAt pid: pid_t,
        parentOf: (pid_t) -> pid_t?,
        applicationName: (pid_t) -> String?,
        maximumDepth: Int = 32
    ) -> Host? {
        var visited = Set<pid_t>()
        var current = pid
        var depth = 0
        while current > 1, depth < maximumDepth, visited.insert(current).inserted {
            if let name = applicationName(current) { return Host(pid: current, name: name) }
            guard let parent = parentOf(current) else { return nil }
            current = parent
            depth += 1
        }
        return nil
    }

    static func subject(for name: String?) -> String {
        name.map { "\($0) (the app that launched zen)" } ?? fallbackSubject
    }

    /// The environment variable through which macOS passes the bundle
    /// identifier of the launching app (for example com.apple.Terminal) to
    /// every process it starts; this worker inherits it from zen.
    static let bundleIdentifierEnvironmentKey = "__CFBundleIdentifier"

    /// The host of this zen session: the nearest regular-app ancestor, else
    /// the single running regular app whose bundle identifier is the one zen
    /// inherited in `__CFBundleIdentifier` (the walk finds no app when a
    /// process in between was detached from its parent, as under tmux).
    /// Several or no matching apps leave the host unknown.
    ///
    /// - Parameters:
    ///   - ancestor: the result of the parent-process walk.
    ///   - environmentBundleID: the inherited `__CFBundleIdentifier`, if any.
    ///   - regularApplications: the running regular apps with a bundle
    ///     identifier, compared without case.
    static func resolveHost(
        ancestor: Host?,
        environmentBundleID: String?,
        regularApplications: (String) -> [Host]
    ) -> Host? {
        if let ancestor { return ancestor }
        guard let bundleID = environmentBundleID?.trimmingCharacters(in: .whitespacesAndNewlines), !bundleID.isEmpty else {
            return nil
        }
        let matches = regularApplications(bundleID)
        return matches.count == 1 ? matches[0] : nil
    }

    @MainActor static func subject() -> String { subject(for: currentName()) }

    @MainActor static func currentName() -> String? {
        current()?.name
    }

    /// The worker is one-shot, so the host is resolved once per process.
    @MainActor private static var cachedHost: Host??

    /// The host app of this zen session, or nil when neither an ancestor nor
    /// the inherited bundle identifier identify a regular app (tmux, ssh,
    /// headless): then no host protection applies.
    @MainActor static func current() -> Host? {
        if let cachedHost { return cachedHost }
        let ancestor = firstApplicationAncestorProcess(
            startingAt: getppid(),
            parentOf: parentPID(of:),
            applicationName: { pid in
                guard let app = NSRunningApplication(processIdentifier: pid), app.activationPolicy == .regular else { return nil }
                return displayName(of: app)
            }
        )
        let host = resolveHost(
            ancestor: ancestor,
            environmentBundleID: ProcessInfo.processInfo.environment[bundleIdentifierEnvironmentKey],
            regularApplications: { bundleID in
                NSWorkspace.shared.runningApplications.compactMap { app in
                    guard !app.isTerminated, app.activationPolicy == .regular,
                          app.bundleIdentifier?.caseInsensitiveCompare(bundleID) == .orderedSame,
                          let name = displayName(of: app) else { return nil }
                    return Host(pid: app.processIdentifier, name: name)
                }
            }
        )
        cachedHost = .some(host)
        return host
    }

    /// The localized name, else the bundle file name; nil without a bundle.
    @MainActor private static func displayName(of app: NSRunningApplication) -> String? {
        guard let bundleURL = app.bundleURL else { return nil }
        if let name = app.localizedName, !name.isEmpty { return name }
        return bundleURL.deletingPathExtension().lastPathComponent
    }

    static func parentPID(of pid: pid_t) -> pid_t? {
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        guard sysctl(&mib, UInt32(mib.count), &info, &size, nil, 0) == 0, size > 0 else { return nil }
        return info.kp_eproc.e_ppid
    }
}
