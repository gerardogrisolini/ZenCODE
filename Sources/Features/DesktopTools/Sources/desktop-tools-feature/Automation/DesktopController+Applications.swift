//  Created by Gerardo Grisolini on 30/05/26.
//
import AppKit
import ApplicationServices
import CoreGraphics
import FeatureKit
import Foundation
import ToolCore

extension DesktopController {

    static func runningApps(matching input: DesktopRunInput) -> [NSRunningApplication] {
        let apps = NSWorkspace.shared.runningApplications.filter { !$0.isTerminated }
        let filtered = apps.filter { app in
            if let pid = input.pid, app.processIdentifier != pid { return false }
            if let bundleID = input.bundle_id?.nilIfBlank,
               app.bundleIdentifier?.caseInsensitiveCompare(bundleID) != .orderedSame { return false }
            if let name = input.app_name?.nilIfBlank,
               app.localizedName?.localizedCaseInsensitiveContains(name) != true { return false }
            return true
        }
        return filtered.sorted { lhs, rhs in
            if lhs.isActive != rhs.isActive { return lhs.isActive }
            let left = lhs.localizedName ?? lhs.bundleIdentifier ?? ""
            let right = rhs.localizedName ?? rhs.bundleIdentifier ?? ""
            return left.localizedCaseInsensitiveCompare(right) == .orderedAscending
        }
    }

    static func matchingRunningApp(
        _ input: DesktopRunInput,
        defaultToFrontmost: Bool,
        allowPartialName: Bool = true
    ) -> NSRunningApplication? {
        if let pid = input.pid {
            return NSRunningApplication(processIdentifier: pid)
        }
        let apps = NSWorkspace.shared.runningApplications.filter { !$0.isTerminated }
        if let bundleID = input.bundle_id?.nilIfBlank {
            return apps.first { $0.bundleIdentifier?.caseInsensitiveCompare(bundleID) == .orderedSame }
        }
        if let name = input.app_name?.nilIfBlank {
            return apps.first { $0.localizedName?.caseInsensitiveCompare(name) == .orderedSame }
                ?? (allowPartialName ? apps.first { $0.localizedName?.localizedCaseInsensitiveContains(name) == true } : nil)
        }
        return defaultToFrontmost ? NSWorkspace.shared.frontmostApplication : nil
    }

    static func selectedRunningApp(_ input: DesktopRunInput, allowPartialName: Bool = true) throws -> NSRunningApplication {
        guard let app = matchingRunningApp(input, defaultToFrontmost: false, allowPartialName: allowPartialName) else {
            throw DesktopControlError.appNotFound
        }
        return app
    }

    /// Cooperative activation (macOS 14+) often ignores `activate` from background
    /// processes, so fall back to setting AXFrontmost when Accessibility is trusted.
    static func activateApplication(_ app: NSRunningApplication) async throws -> DesktopAppProbe? {
        let pid = app.processIdentifier
        _ = app.activate(options: [.activateAllWindows])
        if let probe = try await waitForApplicationProbe(pid: pid, timeout: 1, where: { $0.exists && $0.is_active }) {
            return probe
        }
        guard AXIsProcessTrusted() else { return nil }
        _ = AXUIElementSetAttributeValue(
            AXUIElementCreateApplication(pid), kAXFrontmostAttribute as CFString, kCFBooleanTrue
        )
        return try await waitForApplicationProbe(pid: pid, timeout: 2, where: { $0.exists && $0.is_active })
    }

    /// Waits for the process to exit; a zero timeout still performs exactly one probe.
    static func waitForApplicationExit(pid: pid_t, timeout: TimeInterval) async throws -> DesktopAppProbe? {
        if DesktopProbePolicy.isSingleObservation(timeout: timeout) {
            let probe = try await applicationProbe(pid: pid)
            return probe.exists ? nil : probe
        }
        return try await waitForApplicationProbe(pid: pid, timeout: timeout, where: { !$0.exists })
    }

    static func applicationProbe(pid: pid_t, timeout: TimeInterval = 2) async throws -> DesktopAppProbe {
        guard let executableURL = Bundle.main.executableURL else {
            throw DesktopControlError.operationFailed("Could not locate the desktop feature executable for an application-state probe.")
        }
        let result = try await DesktopProcess.run(
            executableURL: executableURL,
            arguments: [DesktopInternalCommand.appProbeFlag, String(pid)],
            timeout: timeout, maximumOutputBytes: 65_536
        )
        guard result.exitCode == 0 else {
            let detail = String(decoding: result.stderrData, as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            throw DesktopControlError.operationFailed(
                detail.isEmpty
                    ? "The application-state probe exited with status \(result.exitCode)."
                    : "The application-state probe failed: \(detail)"
            )
        }
        do {
            return try JSONDecoder().decode(DesktopAppProbe.self, from: result.stdoutData)
        } catch {
            throw DesktopControlError.operationFailed(
                "The application-state probe returned invalid data: \(error.localizedDescription)"
            )
        }
    }

    static func waitForApplicationProbe(
        pid: pid_t,
        timeout: TimeInterval,
        where condition: (DesktopAppProbe) -> Bool
    ) async throws -> DesktopAppProbe? {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(timeout))
        var attempt = 0
        while let childTimeout = DesktopProbePolicy.childTimeout(remaining: seconds(clock.now.duration(to: deadline))) {
            try Task.checkCancellation()
            let probe = try await applicationProbe(pid: pid, timeout: childTimeout)
            if condition(probe) { return probe }
            let delay = DesktopProbePolicy.retryDelay(attempt: attempt, remaining: seconds(clock.now.duration(to: deadline)))
            if delay <= 0 { break }
            try await Task.sleep(for: .seconds(delay))
            attempt += 1
        }
        return nil
    }

    static func seconds(_ duration: Duration) -> Double {
        Double(duration.components.seconds) + Double(duration.components.attoseconds) / 1e18
    }

    static func appInfo(
        _ app: NSRunningApplication,
        probe: DesktopAppProbe? = nil
    ) -> DesktopAppInfo {
        let policy: String
        switch app.activationPolicy {
        case .regular: policy = "regular"
        case .accessory: policy = "accessory"
        case .prohibited: policy = "prohibited"
        @unknown default: policy = "unknown"
        }
        return DesktopAppInfo(
            pid: app.processIdentifier,
            name: app.localizedName,
            bundle_id: app.bundleIdentifier,
            bundle_path: app.bundleURL?.path,
            activation_policy: policy,
            is_active: probe?.is_active ?? app.isActive,
            is_hidden: probe?.is_hidden ?? app.isHidden,
            is_terminated: probe?.is_terminated ?? app.isTerminated
        )
    }

    static func appSelectorArguments(_ input: DesktopRunInput) -> [String] {
        if let bundleID = input.bundle_id?.nilIfBlank { return ["-b", bundleID] }
        if let appName = input.app_name?.nilIfBlank { return ["-a", appName] }
        return []
    }

    static func launchApp(_ input: DesktopRunInput, context: FeatureContext) async throws -> NSRunningApplication {
        let arguments: [String]
        let launchedBundleURL: URL?
        if let appPath = input.app_path?.nilIfBlank {
            let resolved = context.resolvePath(appPath)
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: resolved.path, isDirectory: &isDirectory),
                  isDirectory.boolValue,
                  resolved.pathExtension.caseInsensitiveCompare("app") == .orderedSame else {
                throw DesktopControlError.invalidArgument("app_path", "must identify an existing .app bundle.")
            }
            arguments = [resolved.path]
            launchedBundleURL = resolved.standardizedFileURL
        } else {
            arguments = appSelectorArguments(input)
            launchedBundleURL = nil
            guard !arguments.isEmpty else {
                throw DesktopControlError.missingArgument("app_path, bundle_id, or app_name", "launch_app")
            }
        }

        let timeout = try boundedDouble(input.timeout ?? 5, name: "timeout", range: 0...30)
        let result = try await runProcess(executable: "/usr/bin/open", arguments: arguments)
        guard result.status == 0 else {
            throw DesktopControlError.processFailed("Could not launch the application: \(result.message)")
        }

        var observedApp: NSRunningApplication?
        let ready = try await DesktopProbePolicy.waitForLaunch(timeout: timeout, observe: { childTimeout in
            let matchedApp = matchingRunningApp(input, defaultToFrontmost: false)
                ?? launchedBundleURL.flatMap { expectedURL in
                    NSWorkspace.shared.runningApplications.first {
                        $0.bundleURL?.standardizedFileURL == expectedURL
                    }
                }
            guard let matchedApp else { return false }
            observedApp = matchedApp
            let probe = try await applicationProbe(pid: matchedApp.processIdentifier, timeout: childTimeout)
            return probe.exists && probe.is_finished_launching
        })
        if ready, let observedApp { return observedApp }

        if observedApp != nil {
            throw DesktopControlError.operationFailed(
                "The application process appeared, but it did not finish launching before timeout."
            )
        }
        throw DesktopControlError.operationFailed(
            "The application launch command succeeded, but no matching running application appeared before timeout."
        )
    }

    static func openTarget(_ input: DesktopRunInput, context: FeatureContext) async throws {
        let target = try requiredNonempty(input.target, name: "target", action: "open")
        let resolvedTarget: String
        switch try DesktopOpenTarget.resolve(target, context: context, fileExists: { FileManager.default.fileExists(atPath: $0) }) {
        case .url(let url): resolvedTarget = url
        case .file(let path): resolvedTarget = path
        }
        let arguments = appSelectorArguments(input) + [resolvedTarget]
        let result = try await runProcess(executable: "/usr/bin/open", arguments: arguments)
        guard result.status == 0 else {
            throw DesktopControlError.processFailed("Could not open the target: \(result.message)")
        }
    }

}

enum DesktopOpenTarget: Equatable {
    case url(String)
    case file(String)

    static func resolve(_ raw: String, context: FeatureContext, fileExists: (String) -> Bool) throws -> DesktopOpenTarget {
        let path: String
        if let url = URL(string: raw), let scheme = url.scheme, !scheme.isEmpty {
            guard !(["javascript", "data"].contains(scheme.lowercased())) else {
                throw DesktopControlError.invalidArgument("target", "the \(scheme) URL scheme is not allowed.")
            }
            guard url.isFileURL else { return .url(raw) }
            // A relative file URL (`file:doc.txt`) must resolve against the session
            // working directory, never the feature process cwd, so the path the
            // operator approved in the host is the path that gets opened.
            let urlPath = url.path
            guard !urlPath.isEmpty else {
                throw DesktopControlError.invalidArgument("target", "file URL has no path.")
            }
            path = urlPath.hasPrefix("/") ? url.standardizedFileURL.path : context.resolvePath(urlPath).path
        } else {
            path = context.resolvePath(raw).path
        }
        guard fileExists(path) else {
            throw DesktopControlError.invalidArgument("target", "file does not exist: \(path)")
        }
        return .file(path)
    }
}

enum DesktopInternalCommand {
    static let appProbeFlag = "--desktop-internal-app-probe"

    static func runIfRequested(arguments: [String] = CommandLine.arguments) -> Bool {
        guard arguments.count == 3, arguments[1] == appProbeFlag else {
            return false
        }

        let app = Int32(arguments[2]).flatMap { pid in
            pid > 0 ? NSRunningApplication(processIdentifier: pid) : nil
        }
        let probe = DesktopAppProbe(
            exists: app != nil && app?.isTerminated == false,
            is_active: app?.isActive ?? false,
            is_hidden: app?.isHidden ?? false,
            is_terminated: app?.isTerminated ?? true,
            is_finished_launching: app?.isFinishedLaunching ?? false
        )
        if let data = try? JSONEncoder().encode(probe) {
            FileHandle.standardOutput.write(data)
        }
        return true
    }
}
