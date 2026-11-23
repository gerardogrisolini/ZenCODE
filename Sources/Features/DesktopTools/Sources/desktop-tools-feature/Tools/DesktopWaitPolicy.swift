import Foundation
import ToolCore

/// The conditions `wait_for` can wait for.
enum DesktopWaitCondition: String, CaseIterable, Sendable {
    case appActive = "app_active"
    case windowPresent = "window_present"
    case windowAbsent = "window_absent"
    case elementPresent = "element_present"
    case elementAbsent = "element_absent"

    var isWindowCondition: Bool { self == .windowPresent || self == .windowAbsent }
    var isElementCondition: Bool { self == .elementPresent || self == .elementAbsent }

    /// "app_active, window_present, window_absent, element_present, element_absent".
    static var listing: String { allCases.map(\.rawValue).joined(separator: ", ") }
}

/// Pure rules of `wait_for`: the validation of its arguments, the decision of
/// one observation (satisfied, not yet, or impossible to decide), and the
/// texts of its summary and of the error it ends with. The live reads and the
/// polling loop are in `DesktopController.waitFor`.
enum DesktopWaitPolicy {
    /// Seconds to wait when `timeout` is omitted.
    static let defaultTimeout: Double = 5
    static let timeoutRange: ClosedRange<Double> = 0...30
    /// Time between two observations.
    static let pollSeconds = 0.25
    /// An element search always gets at least this many seconds, even when
    /// less time is left, so that the last observation is not an empty visit.
    static let minimumVisitBudget: Double = 2
    /// Matches an element search stops at: one is enough to say present.
    static let elementMatchLimit = 20
    static let defaultMaxDepth = 30
    static let maxDepthRange = 1...60

    /// The arguments of a `wait_for` call, validated.
    struct Request: Equatable, Sendable {
        let condition: DesktopWaitCondition
        let timeout: Double
        /// Empty unless the condition is an element condition.
        let elements: DesktopElementPolicy.ElementSelectors
        let roleFilter: String?
        let maxDepth: Int
        let interactiveOnly: Bool
        let includeDetails: Bool
    }

    // MARK: Validation

    static func hasAppSelectors(_ input: DesktopRunInput) -> Bool {
        input.pid != nil || input.bundle_id?.nilIfBlank != nil || input.app_name?.nilIfBlank != nil
    }

    static func hasWindowSelectors(_ input: DesktopRunInput) -> Bool {
        input.window_id != nil || input.title?.nilIfBlank != nil
    }

    /// The condition, the timeout (default 5, 0 to 30), and the selectors the
    /// condition needs: app_active an app (pid, bundle_id, or app_name);
    /// window_present and window_absent an app or a window (window_id or
    /// title); element_present and element_absent an element (element_ref,
    /// query, identifier, or role). Nothing is read from the desktop.
    static func validate(_ input: DesktopRunInput) throws -> Request {
        let action = DesktopAction.waitFor.rawValue
        guard let rawCondition = input.condition?.nilIfBlank else {
            throw DesktopControlError.missingArgument("condition", action)
        }
        guard let condition = DesktopWaitCondition(rawValue: DesktopAction.normalizedName(rawCondition)) else {
            throw DesktopControlError.invalidArgument("condition", "must be one of \(DesktopWaitCondition.listing).")
        }
        let timeout = input.timeout ?? defaultTimeout
        guard timeout.isFinite, timeoutRange.contains(timeout) else {
            throw DesktopControlError.invalidArgument(
                "timeout", "must be between \(timeoutRange.lowerBound) and \(timeoutRange.upperBound)."
            )
        }

        switch condition {
        case .appActive:
            guard hasAppSelectors(input) else {
                throw DesktopControlError.invalidArgument(
                    "pid/bundle_id/app_name", "\(condition.rawValue) needs the app to wait for: pass pid, bundle_id, or app_name."
                )
            }
        case .windowPresent, .windowAbsent:
            guard hasAppSelectors(input) || hasWindowSelectors(input) else {
                throw DesktopControlError.invalidArgument(
                    "pid/bundle_id/app_name/window_id/title",
                    "\(condition.rawValue) needs an app (pid, bundle_id, or app_name) or a window (window_id or title) to look for."
                )
            }
        case .elementPresent, .elementAbsent:
            break
        }

        guard condition.isElementCondition else {
            return Request(
                condition: condition, timeout: timeout, elements: .init(reference: nil, query: nil, identifier: nil),
                roleFilter: nil, maxDepth: defaultMaxDepth, interactiveOnly: true, includeDetails: false
            )
        }
        let elements = try DesktopElementPolicy.validatedElementSelectors(
            elementRef: input.element_ref, query: input.query, identifier: input.identifier
        )
        let roleFilter = try DesktopElementPolicy.normalizedRoleFilter(input.role)
        guard !elements.isEmpty || roleFilter != nil else {
            throw DesktopControlError.invalidArgument(
                "element_ref/query/identifier/role",
                "\(condition.rawValue) needs the element to look for: pass element_ref, query, identifier, or role."
            )
        }
        if let reference = elements.reference {
            _ = try DesktopElementReference(parsing: reference)
            try DesktopElementPolicy.validateReferenceSelectors(title: input.title, windowIndex: input.window_index)
        }
        let maxDepth = input.max_depth ?? defaultMaxDepth
        guard maxDepthRange.contains(maxDepth) else {
            throw DesktopControlError.invalidArgument(
                "max_depth", "must be between \(maxDepthRange.lowerBound) and \(maxDepthRange.upperBound)."
            )
        }
        return Request(
            condition: condition, timeout: timeout, elements: elements, roleFilter: roleFilter, maxDepth: maxDepth,
            interactiveOnly: input.interactive_only ?? true, includeDetails: input.include_details ?? false
        )
    }

    // MARK: Observations and decision

    enum AppState: Equatable, Sendable {
        /// No running application matches the selectors.
        case notRunning
        case running(isFrontmost: Bool)
    }

    enum WindowState: Equatable, Sendable {
        /// No window matches. `titleUnreadable`: the call selects by title but
        /// Screen Recording is not granted, so titles of other apps' windows
        /// are hidden and "no match" does not mean the window is not there.
        case none(titleUnreadable: Bool)
        case present(count: Int)
    }

    enum ElementState: Equatable, Sendable {
        /// At least one element matches (`count` of them were seen).
        case found(count: Int)
        /// No element matches; `incompleteBecause` says why the search did not
        /// cover the whole window (budget, nodes that did not respond), nil
        /// when it did.
        case notFound(incompleteBecause: String?)
        /// The app or the window to search does not exist (any more).
        case windowMissing
        /// The window could not be read: the app does not answer, or
        /// Accessibility failed.
        case unreadable(reason: String)
    }

    enum Observation: Equatable, Sendable {
        case app(AppState)
        case windows(WindowState)
        case element(ElementState)
    }

    enum Decision: Equatable, Sendable {
        case satisfied
        /// Not satisfied, and it may be later.
        case notYet
        /// An absence that the observation cannot confirm, whatever it shows:
        /// the search was incomplete, or what it needs cannot be read. Polling
        /// continues, and the error at the end says why.
        case undecidable
    }

    /// Whether one observation satisfies the condition. A "present"
    /// condition is satisfied by what is seen. An "absent" one only by an
    /// observation that could have seen it: a visit cut short, or one that
    /// skipped nodes that did not respond, or titles that cannot be read, never
    /// prove an absence. The window or app of an element search being gone
    /// does prove it.
    static func decide(_ condition: DesktopWaitCondition, _ observation: Observation) -> Decision {
        switch (condition, observation) {
        case (.appActive, .app(.running(isFrontmost: true))):
            return .satisfied
        case (.appActive, .app):
            return .notYet
        case (.windowPresent, .windows(.present)):
            return .satisfied
        case (.windowPresent, .windows):
            return .notYet
        case (.windowAbsent, .windows(.present)):
            return .notYet
        case (.windowAbsent, .windows(.none(titleUnreadable: false))):
            return .satisfied
        case (.windowAbsent, .windows(.none(titleUnreadable: true))):
            return .undecidable
        case (.elementPresent, .element(.found)):
            return .satisfied
        case (.elementPresent, .element):
            return .notYet
        case (.elementAbsent, .element(.found)):
            return .notYet
        case (.elementAbsent, .element(.notFound(incompleteBecause: nil))), (.elementAbsent, .element(.windowMissing)):
            return .satisfied
        case (.elementAbsent, .element(.notFound)), (.elementAbsent, .element(.unreadable)):
            return .undecidable
        default:
            // An observation of another kind than the condition's: nothing was seen.
            return .notYet
        }
    }

    // MARK: Visit

    /// Seconds an element search may take: what is left of the timeout, but
    /// never less than `minimumVisitBudget` and never more than the usual
    /// budget of a visit.
    static func visitBudget(remaining: Double) -> Double {
        min(DesktopElementPolicy.visitTimeBudget, max(remaining, minimumVisitBudget))
    }

    /// Why an element search did not cover the whole window; nil when it did.
    static func incompleteReason(
        stoppedByTimeBudget: Bool, stoppedByNodeBudget: Bool, unresponsiveNodes: Int, visited: Int, timeBudget: Double
    ) -> String? {
        var reasons: [String] = []
        if stoppedByTimeBudget {
            reasons.append("the Accessibility tree visit stopped at its \(DesktopBatchPolicy.seconds(timeBudget))-second time budget after \(visited) node(s)")
        }
        if stoppedByNodeBudget {
            reasons.append("the Accessibility tree visit stopped at the \(DesktopElementPolicy.visitNodeBudget)-node budget")
        }
        if unresponsiveNodes > 0 {
            reasons.append("\(unresponsiveNodes) node(s) did not respond to Accessibility requests")
        }
        return reasons.isEmpty ? nil : reasons.joined(separator: "; ")
    }

    /// For an element_ref: its window could not be searched completely.
    static let incompleteReferenceReason = "the search of the element_ref's window was cut short, skipped nodes that did not respond, or found elements that cannot be taken for it"

    static let titleUnreadableReason = "window titles are not readable without Screen Recording permission"

    // MARK: Texts

    /// What the call waits for, in the words of its selectors.
    struct Subject: Equatable, Sendable {
        var app: String?
        var windowTitle: String?
        var windowID: UInt32?
        var query: String?
        var identifier: String?
        var role: String?
        var hasElementRef = false
        /// "window 'Doc' of TextEdit", as the last element search reported it.
        var scope: String?

        /// The selectors of a call, naming the app by `runningName` when it is known.
        init(_ input: DesktopRunInput, runningName: String? = nil, scope: String? = nil) {
            app = runningName
                ?? input.app_name?.nilIfBlank
                ?? input.bundle_id?.nilIfBlank
                ?? input.pid.map { "pid \($0)" }
            windowTitle = input.title?.nilIfBlank
            windowID = input.window_id
            query = input.query?.nilIfBlank
            identifier = input.identifier?.nilIfBlank
            role = input.role?.nilIfBlank
            hasElementRef = input.element_ref?.nilIfBlank != nil
            self.scope = scope
        }

        /// "window matching title 'Save' of TextEdit", "window of TextEdit".
        var windowPhrase: String {
            let criteria = [windowID.map { "window_id \($0)" }, windowTitle.map { "title '\($0)'" }]
                .compactMap { $0 }.joined(separator: " and ")
            var phrase = criteria.isEmpty ? "window" : "window matching \(criteria)"
            if let app { phrase += " of \(app)" }
            return phrase
        }

        /// "element matching query 'Save' and role AXButton in window 'Doc' of TextEdit".
        var elementPhrase: String {
            var phrase: String
            if hasElementRef {
                phrase = "element of the given element_ref"
            } else {
                let criteria = [query.map { "query '\($0)'" }, identifier.map { "identifier '\($0)'" }, role.map { "role \($0)" }]
                    .compactMap { $0 }.joined(separator: " and ")
                phrase = criteria.isEmpty ? "element" : "element matching \(criteria)"
            }
            if let scope {
                phrase += " in \(scope)"
            } else if let app {
                phrase += " in \(app)"
            }
            return phrase
        }
    }

    /// "window 'Save' of TextEdit", "the untitled window of TextEdit".
    static func windowLabel(title: String?, app: String?) -> String {
        var label = title?.nilIfBlank.map { "window '\($0)'" } ?? "the untitled window"
        if let app { label += " of \(app)" }
        return label
    }

    /// "340 ms", "1.2 s".
    static func elapsedText(milliseconds: Int) -> String {
        milliseconds < 1_000 ? "\(milliseconds) ms" : "\(DesktopBatchPolicy.seconds(Double(milliseconds) / 1_000)) s"
    }

    /// The summary of a satisfied call. `found` names what was seen: the app,
    /// the window label, or the element; nil falls back to the selectors.
    static func successSummary(
        _ condition: DesktopWaitCondition, subject: Subject, found: String?, elapsedMilliseconds: Int
    ) -> String {
        let after = "(after \(elapsedText(milliseconds: elapsedMilliseconds)))"
        switch condition {
        case .appActive:
            return "app_active: \(found ?? subject.app ?? "the app") is the frontmost app \(after)."
        case .windowPresent:
            return "window_present: \(found ?? "a \(subject.windowPhrase)") is present \(after)."
        case .windowAbsent:
            return "window_absent: no \(subject.windowPhrase) \(after)."
        case .elementPresent:
            return "element_present: \(found ?? "an \(subject.elementPhrase)") is present \(after)."
        case .elementAbsent:
            return "element_absent: no \(subject.elementPhrase) \(after)."
        }
    }

    /// The error of a call that ran out of time: the condition, what the last
    /// observation showed, the time waited, and the frontmost app, for example
    /// "window_present: no window matching title 'Save' of TextEdit after 5 s;
    /// frontmost app is Safari.".
    static func timeoutMessage(
        _ condition: DesktopWaitCondition,
        observation: Observation,
        subject: Subject,
        elapsed: Double,
        frontmostApp: String?
    ) -> String {
        let waited = "after \(DesktopBatchPolicy.seconds(elapsed)) s"
        var state: String
        switch (condition, observation) {
        case (.appActive, .app(.notRunning)):
            state = "no running application matches \(subject.app.map { "'\($0)'" } ?? "the selectors") \(waited)"
        case (.appActive, _):
            state = "\(subject.app ?? "the app") is not the frontmost app \(waited)"
        case (.windowPresent, .windows(.none(titleUnreadable: let unreadable))):
            state = "no \(subject.windowPhrase) \(waited)" + (unreadable ? " (\(titleUnreadableReason))" : "")
        case (.windowPresent, _):
            state = "no \(subject.windowPhrase) \(waited)"
        case (.windowAbsent, .windows(.none(titleUnreadable: true))):
            state = "cannot confirm that no \(subject.windowPhrase) exists \(waited): \(titleUnreadableReason)"
        case (.windowAbsent, .windows(.present(count: let count))):
            state = "a \(subject.windowPhrase) is still present \(waited)" + (count > 1 ? " (\(count) windows)" : "")
        case (.windowAbsent, _):
            state = "a \(subject.windowPhrase) is still present \(waited)"
        case (.elementPresent, .element(.notFound(incompleteBecause: let reason?))):
            state = "no \(subject.elementPhrase) \(waited); the search did not cover the whole window: \(reason)"
        case (.elementPresent, .element(.windowMissing)):
            state = "no window to search for the \(subject.elementPhrase) \(waited)"
        case (.elementPresent, .element(.unreadable(reason: let reason))):
            state = "the window could not be read \(waited): \(reason)"
        case (.elementPresent, _):
            state = "no \(subject.elementPhrase) \(waited)"
        case (.elementAbsent, .element(.notFound(incompleteBecause: let reason?))):
            state = "cannot confirm that no \(subject.elementPhrase) exists \(waited): \(reason)"
        case (.elementAbsent, .element(.unreadable(reason: let reason))):
            state = "cannot confirm that no \(subject.elementPhrase) exists \(waited): the window could not be read (\(reason))"
        case (.elementAbsent, .element(.found(count: let count))):
            state = "an \(subject.elementPhrase) is still present \(waited)" + (count > 1 ? " (\(count) matches)" : "")
        case (.elementAbsent, _):
            state = "an \(subject.elementPhrase) is still present \(waited)"
        }
        if let frontmostApp = frontmostApp?.nilIfBlank { state += "; frontmost app is \(frontmostApp)" }
        return "\(condition.rawValue): \(state)."
    }

    /// The note of an element_present that found several elements.
    static func multipleMatchesNote(count: Int, complete: Bool) -> String {
        "\(count)\(complete ? "" : " or more") elements match; the one reported is the best (an exact title, description, or placeholder match first, then tree order). Pass its ref as element_ref to act on that one."
    }
}
