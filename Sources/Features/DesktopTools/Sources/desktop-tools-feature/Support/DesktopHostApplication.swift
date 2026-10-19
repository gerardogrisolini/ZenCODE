import AppKit
import Darwin
import Foundation

/// macOS attributes TCC permissions to the app that launched zen (Terminal, an
/// editor hosting ACP, ...), so permission messages should name that app.
enum DesktopHostApplication {
    static let fallbackSubject = "the app that launched zen (usually your terminal)"

    static func firstApplicationAncestor(
        startingAt pid: pid_t,
        parentOf: (pid_t) -> pid_t?,
        applicationName: (pid_t) -> String?,
        maximumDepth: Int = 32
    ) -> String? {
        var visited = Set<pid_t>()
        var current = pid
        var depth = 0
        while current > 1, depth < maximumDepth, visited.insert(current).inserted {
            if let name = applicationName(current) { return name }
            guard let parent = parentOf(current) else { return nil }
            current = parent
            depth += 1
        }
        return nil
    }

    static func subject(for name: String?) -> String {
        name.map { "\($0) (the app that launched zen)" } ?? fallbackSubject
    }

    @MainActor static func subject() -> String { subject(for: currentName()) }

    @MainActor static func currentName() -> String? {
        firstApplicationAncestor(
            startingAt: getppid(),
            parentOf: parentPID(of:),
            applicationName: { pid in
                guard let app = NSRunningApplication(processIdentifier: pid),
                      let bundleURL = app.bundleURL, app.activationPolicy == .regular else { return nil }
                if let name = app.localizedName, !name.isEmpty { return name }
                return bundleURL.deletingPathExtension().lastPathComponent
            }
        )
    }

    static func parentPID(of pid: pid_t) -> pid_t? {
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        guard sysctl(&mib, UInt32(mib.count), &info, &size, nil, 0) == 0, size > 0 else { return nil }
        return info.kp_eproc.e_ppid
    }
}
