import AppKit
import ApplicationServices
import CoreGraphics
import Foundation

/// Live reads of the frontmost app, and the wait that follows `activate_app`.
/// The rules (which source wins, when an app counts as active) are in the pure
/// `DesktopFrontmostPolicy` and `DesktopActivationPolicy`.
extension DesktopController {
    struct FrontmostApplication {
        let app: NSRunningApplication
        let source: DesktopFrontmostPolicy.Source

        var choice: DesktopFrontmostPolicy.Choice {
            DesktopFrontmostPolicy.Choice(pid: app.processIdentifier, source: source)
        }
    }

    /// The one place that reads the app in front, for everything that reports
    /// it or decides on it (system_info, list_windows, screenshot, zoom,
    /// activate_app, wait_for, and the default app of the window actions):
    /// with Accessibility granted, the focused application of the system-wide
    /// element, read with the usual messaging timeout; otherwise, or when that
    /// read fails, `NSWorkspace.shared.frontmostApplication`. The keyboard
    /// focus check does not use the fallback (`keyboardFocusPID`).
    static func currentFrontmost() -> FrontmostApplication? {
        var accessibilityApp: NSRunningApplication?
        if AXIsProcessTrusted() {
            prepareAXMessaging()
            accessibilityApp = systemFocusedApplicationPID().flatMap { NSRunningApplication(processIdentifier: $0) }
        }
        var workspaceApp: NSRunningApplication?
        guard let choice = DesktopFrontmostPolicy.choose(
            accessibilityPID: accessibilityApp?.processIdentifier,
            fallback: {
                workspaceApp = NSWorkspace.shared.frontmostApplication
                return workspaceApp?.processIdentifier
            }()
        ) else {
            return nil
        }
        guard let app = choice.source == .accessibility ? accessibilityApp : workspaceApp else { return nil }
        return FrontmostApplication(app: app, source: choice.source)
    }

    static func currentFrontmostApplication() -> NSRunningApplication? {
        currentFrontmost()?.app
    }

    /// The frontmost app as the output reports it. An app named by
    /// Accessibility is active by definition, whatever a stale
    /// NSRunningApplication says.
    static func appInfo(_ frontmost: FrontmostApplication) -> DesktopAppInfo {
        appInfo(frontmost.app, isActive: frontmost.source == .accessibility ? true : nil)
    }

    // MARK: Observation

    /// One observation of whether `pid` is the frontmost app. The subprocess
    /// probe (a fresh snapshot of NSRunningApplication) is read only when
    /// Accessibility did not name the frontmost app, since it alone decides
    /// then. With `includeWindowOrder`, also the owner of the first visible
    /// layer 0 window in Z order, and whether `pid` owns one.
    static func observeFrontmost(
        of pid: pid_t, includeWindowOrder: Bool, remaining: Double
    ) async throws -> (observation: DesktopActivationPolicy.Observation, probe: DesktopAppProbe?) {
        var observation = DesktopActivationPolicy.Observation()
        let frontmost = currentFrontmost()
        observation.frontmost = frontmost?.choice
        var probe: DesktopAppProbe?
        if frontmost?.source != .accessibility {
            let observed = try await applicationProbe(pid: pid, timeout: min(2, max(remaining, 0.5)))
            probe = observed
            observation.probeActive = observed.exists && observed.is_active
        }
        if includeWindowOrder {
            let stack = visibleWindowStack()
            observation.topWindowPID = stack.first?.pid
            observation.targetOwnsVisibleWindow = stack.contains { $0.pid == pid }
        }
        return (observation, probe)
    }

    /// The layer 0 windows visible on screen, front to back, as CGWindowList
    /// orders them; windows with no alpha are not visible.
    static func visibleWindowStack() -> [DesktopWindowInfo] {
        windowRecords(onScreenOnly: true, matching: DesktopRunInput(action: "list_windows"))
            .filter { $0.layer == 0 && $0.alpha > 0 }
    }

    // MARK: activate_app

    struct ActivationResult {
        let outcome: DesktopActivationPolicy.Outcome
        let observation: DesktopActivationPolicy.Observation
        /// The last probe of the app, for its hidden and terminated state.
        let probe: DesktopAppProbe?
    }

    /// Activates `app` and waits, up to `timeout` seconds (zero means one
    /// observation), until the frontmost app (`currentFrontmost`) is `app` and,
    /// when it has windows visible on screen, until the first one in Z order is
    /// its own. After `DesktopActivationPolicy.accessibilityFallbackDelay`
    /// without success, the app is also asked to become frontmost through
    /// Accessibility. At the end the last observation says whether the app is
    /// confirmed, active but not confirmed (the sources disagree), or not active.
    static func activateAndConfirm(_ app: NSRunningApplication, timeout: Double) async throws -> ActivationResult {
        let pid = app.processIdentifier
        let clock = ContinuousClock()
        let started = clock.now
        let deadline = started.advanced(by: .seconds(timeout))
        _ = app.activate(options: [.activateAllWindows])

        var requestedAccessibilityFrontmost = false
        var latest: (observation: DesktopActivationPolicy.Observation, probe: DesktopAppProbe?)
        while true {
            try Task.checkCancellation()
            latest = try await observeFrontmost(
                of: pid, includeWindowOrder: true, remaining: seconds(clock.now.duration(to: deadline))
            )
            if DesktopActivationPolicy.isSettled(latest.observation, target: pid) { break }
            if !requestedAccessibilityFrontmost, AXIsProcessTrusted(),
               seconds(started.duration(to: clock.now)) >= DesktopActivationPolicy.accessibilityFallbackDelay(timeout: timeout) {
                requestedAccessibilityFrontmost = true
                _ = AXUIElementSetAttributeValue(
                    AXUIElementCreateApplication(pid), kAXFrontmostAttribute as CFString, kCFBooleanTrue
                )
            }
            let remaining = seconds(clock.now.duration(to: deadline))
            guard remaining > 0 else { break }
            try await Task.sleep(for: .seconds(min(remaining, seconds(DesktopActivationPolicy.pollInterval))))
        }

        var observation = latest.observation
        var probe = latest.probe
        if probe == nil {
            // Fresh state of the app, and the second source when the sources disagree.
            do {
                probe = try await applicationProbe(pid: pid)
            } catch let cancellation as CancellationError {
                throw cancellation
            } catch {
                probe = nil
            }
            observation.probeActive = probe.map { $0.exists && $0.is_active }
        }
        let outcome = DesktopActivationPolicy.outcome(
            observation,
            target: pid,
            targetName: applicationName(of: pid),
            frontmostName: observation.frontmost.map { applicationName(of: $0.pid) },
            topWindowName: observation.topWindowPID.map(applicationName(of:))
        )
        return ActivationResult(outcome: outcome, observation: observation, probe: probe)
    }

    /// activate_app: activates the app, waits for it to be frontmost
    /// (`activateAndConfirm`), and returns it with its main or focused window.
    /// When it is active but the sources do not agree, the note says so and
    /// `frontmost_app` names the app they report; when it is not active at all,
    /// it fails.
    static func activateAppAndConfirm(_ app: NSRunningApplication, timeout: Double, action: String) async throws -> DesktopRunOutput {
        let result = try await activateAndConfirm(app, timeout: timeout)
        let name = app.localizedName ?? app.bundleIdentifier ?? "application"
        let pid = app.processIdentifier
        if result.outcome == .notActive {
            throw DesktopControlError.operationFailed(
                "The selected application did not become active before timeout."
                    + (AXIsProcessTrusted() ? "" : " Granting Accessibility permission lets desktop.run use a fallback.")
            )
        }
        var output = DesktopRunOutput(
            action: action,
            summary: DesktopActivationPolicy.summary(result.outcome, name: name),
            app: appInfo(
                app, probe: result.probe,
                isActive: DesktopActivationPolicy.isFrontmost(result.observation, target: pid)
            ),
            window: principalWindow(of: pid)
        )
        if case let .unconfirmed(note) = result.outcome {
            output.note = note
            if let frontmost = currentFrontmost(), frontmost.app.processIdentifier != pid {
                output.frontmost_app = appInfo(frontmost)
            }
        }
        return output
    }

    /// The window of the app that is its focused window, else its main window
    /// (Accessibility); without Accessibility, or when it names none, the
    /// app's first window visible on screen. Nil when the app has no such window.
    static func principalWindow(of pid: pid_t) -> DesktopWindowInfo? {
        if AXIsProcessTrusted() {
            let application = AXUIElementCreateApplication(pid)
            prepareAXMessaging(application)
            for attribute in [kAXFocusedWindowAttribute, kAXMainWindowAttribute] {
                if let window = try? copyAXElement(application, attribute: attribute as CFString, operation: "read window") {
                    return axWindowInfo(AXWindowSelection(element: window, pid: pid, expected: nil))
                }
            }
        }
        return windowRecords(
            onScreenOnly: true, matching: DesktopRunInput(action: "list_windows", pid: pid),
            frontmostPID: currentFrontmostApplication()?.processIdentifier
        ).first
    }
}
