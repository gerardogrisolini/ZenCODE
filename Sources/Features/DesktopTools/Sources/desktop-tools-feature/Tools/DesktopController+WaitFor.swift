import AppKit
import ApplicationServices
import CoreGraphics
import Foundation
import ToolCore

/// wait_for: polls the desktop every 0.25 s until a condition holds or the
/// timeout (default 5 s, 0 to 30) runs out. The validation, the decision of
/// each observation, and the texts are in the pure `DesktopWaitPolicy`; this
/// only reads the desktop, never changes it.
extension DesktopController {
    /// What one poll saw.
    struct WaitPoll {
        let observation: DesktopWaitPolicy.Observation
        /// The name of the app the call selects, when it is running.
        var appName: String?
        /// app_active: the app, active by the frontmost app that was read.
        var app: DesktopAppInfo?
        /// window conditions: the windows that match, front to back.
        var windows: [DesktopWindowInfo] = []
        /// element conditions: the element that was found.
        var element: ResolvedElement?
        /// element conditions: the window the element was searched in.
        var window: DesktopWindowInfo?
        /// element conditions: "window 'Doc' of TextEdit".
        var scopePhrase: String?
        var note: String?

        init(_ observation: DesktopWaitPolicy.Observation) {
            self.observation = observation
        }
    }

    static func waitFor(_ input: DesktopRunInput, action: String) async throws -> DesktopRunOutput {
        let request = try DesktopWaitPolicy.validate(input)
        let clock = ContinuousClock()
        let start = clock.now
        let deadline = start.advanced(by: .seconds(request.timeout))
        var appName: String?
        var scopePhrase: String?

        while true {
            try Task.checkCancellation()
            let poll = try await observeWait(
                request, input: input, remaining: max(seconds(clock.now.duration(to: deadline)), 0)
            )
            appName = poll.appName ?? appName
            scopePhrase = poll.scopePhrase ?? scopePhrase
            let subject = DesktopWaitPolicy.Subject(input, runningName: appName, scope: scopePhrase)
            let elapsed = seconds(start.duration(to: clock.now))

            if DesktopWaitPolicy.decide(request.condition, poll.observation) == .satisfied {
                return waitOutput(request, poll: poll, subject: subject, elapsed: elapsed, action: action)
            }
            let remaining = seconds(clock.now.duration(to: deadline))
            guard remaining > 0 else {
                let frontmost = currentFrontmostApplication()
                throw DesktopControlError.operationFailed(DesktopWaitPolicy.timeoutMessage(
                    request.condition, observation: poll.observation, subject: subject, elapsed: elapsed,
                    frontmostApp: frontmost?.localizedName ?? frontmost?.bundleIdentifier
                ))
            }
            try await Task.sleep(for: .seconds(min(DesktopWaitPolicy.pollSeconds, remaining)))
        }
    }

    /// The output of a satisfied call: the summary, `elapsed_ms`, and what was
    /// found (the app, the first matching window, or the element in compact
    /// form unless include_details).
    private static func waitOutput(
        _ request: DesktopWaitPolicy.Request, poll: WaitPoll, subject: DesktopWaitPolicy.Subject, elapsed: Double, action: String
    ) -> DesktopRunOutput {
        let milliseconds = Int((elapsed * 1_000).rounded())
        var found: String?
        var app: DesktopAppInfo?
        var window: DesktopWindowInfo?
        var element: DesktopElementInfo?
        var note: String?
        switch request.condition {
        case .appActive:
            app = poll.app
            found = poll.app?.name ?? subject.app
        case .windowPresent:
            window = foundWindow(poll.windows)
            found = window.map { DesktopWaitPolicy.windowLabel(title: $0.title, app: $0.app_name) }
        case .elementPresent:
            if let resolved = poll.element {
                found = DesktopElementPolicy.locationPhrase(resolved.info)
                element = DesktopElementPolicy.projected(resolved.info, includeDetails: request.includeDetails)
                window = poll.window ?? resolved.scope.window.map {
                    axWindowInfo(AXWindowSelection(element: $0, pid: resolved.pid, expected: nil))
                }
                note = poll.note
            }
        case .windowAbsent, .elementAbsent:
            break
        }
        var output = DesktopRunOutput(
            action: action,
            summary: DesktopWaitPolicy.successSummary(
                request.condition, subject: subject, found: found, elapsedMilliseconds: milliseconds
            ),
            elapsed_ms: milliseconds
        )
        output.app = app
        output.window = window
        output.element = element
        output.note = note
        return output
    }

    /// The first of the matching windows (the frontmost of them), marked as the
    /// frontmost app's when it is, and with the Accessibility attributes of
    /// list_windows.
    private static func foundWindow(_ windows: [DesktopWindowInfo]) -> DesktopWindowInfo? {
        guard var first = windows.first else { return nil }
        if first.pid == currentFrontmostApplication()?.processIdentifier { first.is_frontmost_app = true }
        return enrichedWithAccessibility([first], candidates: windows).windows.first ?? first
    }

    // MARK: Observation

    private static func observeWait(
        _ request: DesktopWaitPolicy.Request, input: DesktopRunInput, remaining: Double
    ) async throws -> WaitPoll {
        switch request.condition {
        case .appActive:
            return try await observeApp(input, remaining: remaining)
        case .windowPresent, .windowAbsent:
            return observeWindows(input)
        case .elementPresent, .elementAbsent:
            return try observeElement(request, input: input, remaining: remaining)
        }
    }

    /// app_active: whether the selected app is the frontmost one, as
    /// `DesktopActivationPolicy.isFrontmost` reads the sources.
    private static func observeApp(_ input: DesktopRunInput, remaining: Double) async throws -> WaitPoll {
        guard let app = matchingRunningApp(input, defaultToFrontmost: false), !app.isTerminated else {
            return WaitPoll(.app(.notRunning))
        }
        let (observation, probe) = try await observeFrontmost(
            of: app.processIdentifier, includeWindowOrder: false, remaining: remaining
        )
        let isFrontmost = DesktopActivationPolicy.isFrontmost(observation, target: app.processIdentifier)
        var poll = WaitPoll(.app(.running(isFrontmost: isFrontmost)))
        poll.appName = app.localizedName ?? app.bundleIdentifier
        poll.app = appInfo(app, probe: probe, isActive: isFrontmost)
        return poll
    }

    /// window_present and window_absent: the layer 0 windows that match the app
    /// and window selectors, on screen or not. A title cannot be matched
    /// without Screen Recording, which the decision takes into account.
    private static func observeWindows(_ input: DesktopRunInput) -> WaitPoll {
        let records = windowRecords(onScreenOnly: false, matching: input)
        let titleUnreadable = input.title?.nilIfBlank != nil && !CGPreflightScreenCaptureAccess()
        var poll = WaitPoll(.windows(
            records.isEmpty ? .none(titleUnreadable: titleUnreadable) : .present(count: records.count)
        ))
        poll.windows = records
        if DesktopWaitPolicy.hasAppSelectors(input), let app = matchingRunningApp(input, defaultToFrontmost: false) {
            poll.appName = app.localizedName ?? app.bundleIdentifier
        }
        return poll
    }

    /// element_present and element_absent: the elements of the selected window
    /// (the focused window of the frontmost app by default) that match, or the
    /// element of an element_ref. A window or app that does not exist is an
    /// observation of its own; a window that cannot be read is reported as
    /// such, and neither is thrown, since the next poll may see it.
    private static func observeElement(
        _ request: DesktopWaitPolicy.Request, input: DesktopRunInput, remaining: Double
    ) throws -> WaitPoll {
        try requireAccessibility()
        prepareAXMessaging()
        let budget = DesktopWaitPolicy.visitBudget(remaining: remaining)

        if let rawReference = request.elements.reference {
            let reference = try DesktopElementReference(parsing: rawReference)
            do {
                try validateReference(reference, against: input)
                switch try lookUpReference(reference, visitBudget: budget) {
                case let .found(resolved):
                    return foundElement(resolved, count: 1, window: nil)
                case let .gone(visitIsComplete):
                    return WaitPoll(.element(.notFound(
                        incompleteBecause: visitIsComplete ? nil : DesktopWaitPolicy.incompleteReferenceReason
                    )))
                }
            } catch DesktopControlError.appNotFound {
                return WaitPoll(.element(.windowMissing))
            } catch let DesktopControlError.applicationNotResponding(app) {
                return WaitPoll(.element(.unreadable(reason: "\(app) is not responding to Accessibility requests")))
            }
        }

        let selection: AXWindowSelection
        do {
            selection = try elementWindowSelection(input)
        } catch DesktopControlError.appNotFound, DesktopControlError.windowNotFound {
            return WaitPoll(.element(.windowMissing))
        } catch let DesktopControlError.applicationNotResponding(app) {
            return WaitPoll(.element(.unreadable(reason: "\(app) is not responding to Accessibility requests")))
        } catch let DesktopControlError.accessibilityFailed(_, error) {
            let reason = error == .cannotComplete
                ? "\(selectedApplicationLabel(input)) is not responding to Accessibility requests"
                : "Accessibility error \(error.rawValue) while reading the window"
            return WaitPoll(.element(.unreadable(reason: reason)))
        }

        let (scope, window) = elementScope(for: selection)
        let visit = visitElements(
            in: scope, maxDepth: request.maxDepth, interactiveOnly: request.interactiveOnly,
            roleFilter: request.roleFilter, query: request.elements.query, identifier: request.elements.identifier,
            timeBudget: budget, includeFrameless: true, limit: DesktopWaitPolicy.elementMatchLimit
        )
        guard !visit.matches.isEmpty else {
            var poll = WaitPoll(.element(.notFound(incompleteBecause: DesktopWaitPolicy.incompleteReason(
                stoppedByTimeBudget: visit.stoppedByTimeBudget, stoppedByNodeBudget: visit.stoppedByNodeBudget,
                unresponsiveNodes: visit.unresponsiveNodes, visited: visit.visited, timeBudget: budget
            ))))
            poll.scopePhrase = scope.phrase
            poll.appName = scope.appName
            return poll
        }
        let candidates = visit.matches.map(\.info)
        let chosen: Int
        switch DesktopElementPolicy.choose(candidates, query: request.elements.query, visitIsComplete: visit.isComplete) {
        case let .unique(index):
            chosen = index
        case let .ambiguous(ordered), let .incomplete(ordered):
            chosen = ordered.first ?? 0
        case .noMatch:
            chosen = 0
        }
        var poll = foundElement(visit.matches[chosen], count: candidates.count, window: window)
        poll.note = DesktopListPaging.joined([
            visit.matches[chosen].relocationNote,
            candidates.count > 1
                ? DesktopWaitPolicy.multipleMatchesNote(count: candidates.count, complete: visit.isComplete)
                : nil
        ])
        return poll
    }

    private static func foundElement(_ element: ResolvedElement, count: Int, window: DesktopWindowInfo?) -> WaitPoll {
        var poll = WaitPoll(.element(.found(count: count)))
        poll.element = element
        poll.window = window
        poll.scopePhrase = element.scope.phrase
        poll.appName = element.scope.appName
        poll.note = element.relocationNote
        return poll
    }
}
