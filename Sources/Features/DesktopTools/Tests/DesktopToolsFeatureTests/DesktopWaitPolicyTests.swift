import CoreGraphics
import FeatureKit
import Foundation
import Testing

@testable import desktop_tools_feature

@Suite
struct DesktopWaitPolicyTests {
    private func input(_ json: String) throws -> DesktopRunInput {
        try JSONDecoder().decode(DesktopRunInput.self, from: Data(json.utf8))
    }

    private func validate(_ json: String) throws -> DesktopWaitPolicy.Request {
        try DesktopWaitPolicy.validate(try input(json))
    }

    /// The message of the error `validate` throws, or nil when it accepts the call.
    private func validationError(_ json: String) throws -> String? {
        do {
            _ = try validate(json)
            return nil
        } catch let error as DesktopControlError {
            return error.errorDescription
        }
    }

    private func object(_ json: String) throws -> [String: Any] {
        try #require(try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
    }

    /// A well-formed element_ref, as list_elements would return it.
    private func reference(window: DesktopElementReference.WindowAnchor = .windowID(2)) throws -> String {
        try #require(DesktopElementReference(pid: 1, window: window, path: [0], role: "AXButton", fingerprint: "fbbf52e3").encoded)
    }

    // MARK: Validation: condition and timeout

    @Test
    func theConditionIsRequired() throws {
        #expect(try validationError(#"{"action":"wait_for","app_name":"TextEdit"}"#)
            == "Action 'wait_for' requires argument 'condition'.")
        #expect(try validationError(#"{"action":"wait_for","condition":"  ","app_name":"TextEdit"}"#)
            == "Action 'wait_for' requires argument 'condition'.")
    }

    @Test
    func anUnknownConditionListsTheValidOnes() throws {
        let message = try #require(try validationError(#"{"action":"wait_for","condition":"app_visible","app_name":"TextEdit"}"#))
        #expect(message == "Invalid argument 'condition': must be one of app_active, window_present, window_absent, element_present, element_absent.")
    }

    @Test
    func theConditionIsTrimmedAndCaseInsensitive() throws {
        let request = try validate(#"{"action":"wait_for","condition":" App_Active ","app_name":"TextEdit"}"#)
        #expect(request.condition == .appActive)
    }

    @Test
    func theTimeoutDefaultsToFiveSecondsAndIsBoundedToZeroToThirty() throws {
        #expect(try validate(#"{"action":"wait_for","condition":"app_active","pid":1}"#).timeout == 5)
        #expect(try validate(#"{"action":"wait_for","condition":"app_active","pid":1,"timeout":0}"#).timeout == 0)
        #expect(try validate(#"{"action":"wait_for","condition":"app_active","pid":1,"timeout":30}"#).timeout == 30)
        for bad in ["-0.5", "30.5", "100"] {
            #expect(try validationError(#"{"action":"wait_for","condition":"app_active","pid":1,"timeout":\#(bad)}"#)
                == "Invalid argument 'timeout': must be between 0.0 and 30.0.", "\(bad)")
        }
        // JSON cannot carry NaN, but the model can be built from code.
        var built = DesktopRunInput(action: "wait_for", pid: 1, timeout: .nan)
        built.condition = "app_active"
        let nan = built
        #expect(throws: DesktopControlError.self) { try DesktopWaitPolicy.validate(nan) }
    }

    @Test
    func theDefaultTimeoutIsTheDocumentedOne() {
        #expect(DesktopWaitPolicy.defaultTimeout == 5)
        #expect(DesktopWaitPolicy.timeoutRange == 0...30)
        #expect(DesktopWaitPolicy.pollSeconds == 0.25)
    }

    // MARK: Validation: selectors

    @Test
    func appActiveNeedsAnAppSelector() throws {
        let message = try #require(try validationError(#"{"action":"wait_for","condition":"app_active"}"#))
        #expect(message.hasPrefix("Invalid argument 'pid/bundle_id/app_name': app_active needs the app to wait for"))
        // A window or an element selector is not an app selector.
        #expect(try validationError(#"{"action":"wait_for","condition":"app_active","title":"Save","query":"OK"}"#) != nil)
        #expect(try validationError(#"{"action":"wait_for","condition":"app_active","app_name":"  "}"#) != nil)
        for selector in [#""pid":42"#, #""bundle_id":"com.apple.TextEdit""#, #""app_name":"TextEdit""#] {
            #expect(try validationError(#"{"action":"wait_for","condition":"app_active",\#(selector)}"#) == nil, "\(selector)")
        }
    }

    @Test
    func windowConditionsNeedAnAppOrAWindowSelector() throws {
        for condition in ["window_present", "window_absent"] {
            let message = try #require(try validationError(#"{"action":"wait_for","condition":"\#(condition)"}"#))
            #expect(message.hasPrefix("Invalid argument 'pid/bundle_id/app_name/window_id/title': \(condition) needs an app"))
            // An element selector does not select a window.
            #expect(try validationError(#"{"action":"wait_for","condition":"\#(condition)","query":"Save"}"#) != nil)
            for selector in [#""pid":42"#, #""bundle_id":"com.apple.TextEdit""#, #""app_name":"TextEdit""#, #""window_id":7"#, #""title":"Save""#] {
                #expect(try validationError(#"{"action":"wait_for","condition":"\#(condition)",\#(selector)}"#) == nil, "\(condition) \(selector)")
            }
        }
        #expect(try validationError(#"{"action":"wait_for","condition":"window_present","title":"   "}"#) != nil)
    }

    @Test
    func elementConditionsNeedAnElementSelector() throws {
        for condition in ["element_present", "element_absent"] {
            let message = try #require(try validationError(#"{"action":"wait_for","condition":"\#(condition)","app_name":"TextEdit"}"#))
            #expect(message.hasPrefix("Invalid argument 'element_ref/query/identifier/role': \(condition) needs the element to look for"))
            let ref = try reference()
            for selector in [#""query":"Save""#, #""identifier":"save-button""#, #""role":"AXSheet""#, #""element_ref":"\#(ref)""#] {
                #expect(try validationError(#"{"action":"wait_for","condition":"\#(condition)",\#(selector)}"#) == nil, "\(condition) \(selector)")
            }
        }
    }

    @Test
    func elementSelectorsFollowTheRulesOfTheElementActions() throws {
        // element_ref alone, or query and identifier: never both.
        let ref = try reference()
        let both = try #require(try validationError(#"{"action":"wait_for","condition":"element_present","element_ref":"\#(ref)","query":"Save"}"#))
        #expect(both.contains("pass either element_ref, or query and/or identifier, not both"))
        // A well-formed element_ref passes.
        #expect(try validationError(#"{"action":"wait_for","condition":"element_absent","element_ref":"\#(ref)"}"#) == nil)
        // A malformed element_ref fails at once instead of polling.
        #expect(try validationError(#"{"action":"wait_for","condition":"element_absent","element_ref":"garbage"}"#) != nil)
        // An element_ref carries its window: title and window_index contradict it.
        #expect(try validationError(#"{"action":"wait_for","condition":"element_absent","element_ref":"\#(ref)","title":"Doc"}"#) != nil)
        #expect(try validationError(#"{"action":"wait_for","condition":"element_absent","element_ref":"\#(ref)","window_index":1}"#) != nil)
        #expect(try validationError(#"{"action":"wait_for","condition":"element_present","query":"Save","role":"bad role!"}"#) != nil)
        let long = String(repeating: "q", count: 201)
        #expect(try validationError(#"{"action":"wait_for","condition":"element_present","query":"\#(long)"}"#) != nil)
    }

    @Test
    func elementRequestsCarryTheNormalizedSelectorsAndDefaults() throws {
        let request = try validate(#"{"action":"wait_for","condition":"element_present","query":" Save ","identifier":"save","role":"Button"}"#)
        #expect(request.elements.query == "Save")
        #expect(request.elements.identifier == "save")
        #expect(request.elements.reference == nil)
        #expect(request.roleFilter == "button")
        #expect(request.maxDepth == 30)
        #expect(request.interactiveOnly)
        #expect(!request.includeDetails)

        let custom = try validate(#"{"action":"wait_for","condition":"element_absent","role":"AXSheet","interactive_only":false,"max_depth":3,"include_details":true,"timeout":2}"#)
        #expect(custom.roleFilter == "axsheet")
        #expect(custom.maxDepth == 3)
        #expect(!custom.interactiveOnly)
        #expect(custom.includeDetails)
        #expect(custom.timeout == 2)
    }

    @Test
    func maxDepthIsBounded() throws {
        for depth in ["0", "61"] {
            #expect(try validationError(#"{"action":"wait_for","condition":"element_present","query":"x","max_depth":\#(depth)}"#)
                == "Invalid argument 'max_depth': must be between 1 and 60.", "\(depth)")
        }
        #expect(try validate(#"{"action":"wait_for","condition":"element_present","query":"x","max_depth":60}"#).maxDepth == 60)
    }

    @Test
    func nonElementRequestsIgnoreTheElementFields() throws {
        let request = try validate(#"{"action":"wait_for","condition":"window_present","title":"Save","max_depth":99,"role":"bad role!"}"#)
        #expect(request.condition == .windowPresent)
        #expect(request.elements.isEmpty)
        #expect(request.roleFilter == nil)
    }

    // MARK: Decision

    private typealias Observation = DesktopWaitPolicy.Observation

    private func decide(_ condition: DesktopWaitCondition, _ observation: Observation) -> DesktopWaitPolicy.Decision {
        DesktopWaitPolicy.decide(condition, observation)
    }

    @Test
    func appActiveIsSatisfiedOnlyByTheFrontmostApp() {
        #expect(decide(.appActive, .app(.running(isFrontmost: true))) == .satisfied)
        #expect(decide(.appActive, .app(.running(isFrontmost: false))) == .notYet)
        #expect(decide(.appActive, .app(.notRunning)) == .notYet)
    }

    @Test
    func windowPresentIsSatisfiedByAnyMatchingWindow() {
        #expect(decide(.windowPresent, .windows(.present(count: 1))) == .satisfied)
        #expect(decide(.windowPresent, .windows(.present(count: 3))) == .satisfied)
        #expect(decide(.windowPresent, .windows(.none(titleUnreadable: false))) == .notYet)
        // Without Screen Recording a title never matches: not yet, and not satisfiable.
        #expect(decide(.windowPresent, .windows(.none(titleUnreadable: true))) == .notYet)
    }

    @Test
    func windowAbsentIsNotProvenByTitlesThatCannotBeRead() {
        #expect(decide(.windowAbsent, .windows(.none(titleUnreadable: false))) == .satisfied)
        #expect(decide(.windowAbsent, .windows(.present(count: 1))) == .notYet)
        #expect(decide(.windowAbsent, .windows(.none(titleUnreadable: true))) == .undecidable)
    }

    @Test
    func elementPresentIsSatisfiedByWhatIsFound() {
        #expect(decide(.elementPresent, .element(.found(count: 1))) == .satisfied)
        #expect(decide(.elementPresent, .element(.found(count: 20))) == .satisfied)
        #expect(decide(.elementPresent, .element(.notFound(incompleteBecause: nil))) == .notYet)
        #expect(decide(.elementPresent, .element(.notFound(incompleteBecause: "cut short"))) == .notYet)
        #expect(decide(.elementPresent, .element(.windowMissing)) == .notYet)
        #expect(decide(.elementPresent, .element(.unreadable(reason: "busy"))) == .notYet)
    }

    @Test
    func elementAbsentIsSatisfiedOnlyByACompleteVisitOrAMissingWindow() {
        #expect(decide(.elementAbsent, .element(.notFound(incompleteBecause: nil))) == .satisfied)
        #expect(decide(.elementAbsent, .element(.windowMissing)) == .satisfied)
        #expect(decide(.elementAbsent, .element(.found(count: 1))) == .notYet)
        // A visit cut short by a budget, or that skipped nodes that did not respond, proves nothing.
        #expect(decide(.elementAbsent, .element(.notFound(incompleteBecause: "the visit stopped at its budget"))) == .undecidable)
        #expect(decide(.elementAbsent, .element(.unreadable(reason: "Safari is not responding"))) == .undecidable)
    }

    @Test
    func anObservationOfAnotherKindSatisfiesNothing() {
        #expect(decide(.appActive, .windows(.present(count: 1))) == .notYet)
        #expect(decide(.windowAbsent, .element(.windowMissing)) == .notYet)
        #expect(decide(.elementAbsent, .app(.notRunning)) == .notYet)
    }

    // MARK: Visit

    @Test
    func theVisitGetsTheTimeLeftBetweenTheMinimumAndTheUsualBudget() {
        #expect(DesktopWaitPolicy.visitBudget(remaining: 0) == DesktopWaitPolicy.minimumVisitBudget)
        #expect(DesktopWaitPolicy.visitBudget(remaining: 0.5) == DesktopWaitPolicy.minimumVisitBudget)
        #expect(DesktopWaitPolicy.visitBudget(remaining: 4) == 4)
        #expect(DesktopWaitPolicy.visitBudget(remaining: 30) == DesktopElementPolicy.visitTimeBudget)
    }

    @Test
    func anIncompleteVisitSaysWhy() {
        #expect(DesktopWaitPolicy.incompleteReason(
            stoppedByTimeBudget: false, stoppedByNodeBudget: false, unresponsiveNodes: 0, visited: 120, timeBudget: 5
        ) == nil)
        #expect(DesktopWaitPolicy.incompleteReason(
            stoppedByTimeBudget: true, stoppedByNodeBudget: false, unresponsiveNodes: 0, visited: 812, timeBudget: 2
        ) == "the Accessibility tree visit stopped at its 2-second time budget after 812 node(s)")
        #expect(DesktopWaitPolicy.incompleteReason(
            stoppedByTimeBudget: false, stoppedByNodeBudget: true, unresponsiveNodes: 3, visited: 4000, timeBudget: 8
        ) == "the Accessibility tree visit stopped at the 4000-node budget; 3 node(s) did not respond to Accessibility requests")
        #expect(DesktopWaitPolicy.incompleteReason(
            stoppedByTimeBudget: false, stoppedByNodeBudget: false, unresponsiveNodes: 1, visited: 9, timeBudget: 8
        ) == "1 node(s) did not respond to Accessibility requests")
    }

    // MARK: Texts

    private func subject(_ json: String, runningName: String? = nil, scope: String? = nil) throws -> DesktopWaitPolicy.Subject {
        DesktopWaitPolicy.Subject(try input(json), runningName: runningName, scope: scope)
    }

    @Test
    func theTimeoutErrorOfAWindowNamesWhatWasLookedForAndTheFrontmostApp() throws {
        let subject = try subject(#"{"action":"wait_for","condition":"window_present","app_name":"TextEdit","title":"Save"}"#)
        let message = DesktopWaitPolicy.timeoutMessage(
            .windowPresent, observation: .windows(.none(titleUnreadable: false)), subject: subject, elapsed: 5.003, frontmostApp: "Safari"
        )
        #expect(message == "window_present: no window matching title 'Save' of TextEdit after 5 s; frontmost app is Safari.")
    }

    @Test
    func theTimeoutErrorOfWindowPresentExplainsUnreadableTitles() throws {
        let subject = try subject(#"{"action":"wait_for","condition":"window_present","title":"Save"}"#)
        let message = DesktopWaitPolicy.timeoutMessage(
            .windowPresent, observation: .windows(.none(titleUnreadable: true)), subject: subject, elapsed: 5, frontmostApp: nil
        )
        #expect(message == "window_present: no window matching title 'Save' after 5 s (window titles are not readable without Screen Recording permission).")
    }

    @Test
    func theTimeoutErrorOfWindowAbsentSaysWhatIsStillThere() throws {
        let subject = try subject(#"{"action":"wait_for","condition":"window_absent","window_id":12,"pid":42}"#, runningName: "TextEdit")
        let present = DesktopWaitPolicy.timeoutMessage(
            .windowAbsent, observation: .windows(.present(count: 2)), subject: subject, elapsed: 3.2, frontmostApp: "TextEdit"
        )
        #expect(present == "window_absent: a window matching window_id 12 of TextEdit is still present after 3.2 s (2 windows); frontmost app is TextEdit.")
        let unreadable = DesktopWaitPolicy.timeoutMessage(
            .windowAbsent, observation: .windows(.none(titleUnreadable: true)), subject: subject, elapsed: 5, frontmostApp: nil
        )
        #expect(unreadable.contains("cannot confirm that no window matching window_id 12 of TextEdit exists after 5 s"))
        #expect(unreadable.contains("window titles are not readable without Screen Recording permission"))
    }

    @Test
    func theTimeoutErrorOfAppActiveSaysWhetherTheAppIsRunning() throws {
        let subject = try subject(#"{"action":"wait_for","condition":"app_active","app_name":"TextEdit"}"#)
        #expect(DesktopWaitPolicy.timeoutMessage(
            .appActive, observation: .app(.running(isFrontmost: false)), subject: subject, elapsed: 5, frontmostApp: "Safari"
        ) == "app_active: TextEdit is not the frontmost app after 5 s; frontmost app is Safari.")
        #expect(DesktopWaitPolicy.timeoutMessage(
            .appActive, observation: .app(.notRunning), subject: subject, elapsed: 5, frontmostApp: "Safari"
        ) == "app_active: no running application matches 'TextEdit' after 5 s; frontmost app is Safari.")
    }

    @Test
    func theTimeoutErrorOfAnElementNamesTheSelectorsAndTheWindow() throws {
        let subject = try subject(
            #"{"action":"wait_for","condition":"element_present","query":"Save","role":"AXButton"}"#,
            runningName: "TextEdit", scope: "window 'Doc' of TextEdit"
        )
        #expect(DesktopWaitPolicy.timeoutMessage(
            .elementPresent, observation: .element(.notFound(incompleteBecause: nil)), subject: subject, elapsed: 5, frontmostApp: "Safari"
        ) == "element_present: no element matching query 'Save' and role AXButton in window 'Doc' of TextEdit after 5 s; frontmost app is Safari.")
        #expect(DesktopWaitPolicy.timeoutMessage(
            .elementPresent, observation: .element(.notFound(incompleteBecause: "1 node(s) did not respond to Accessibility requests")),
            subject: subject, elapsed: 5, frontmostApp: nil
        ) == "element_present: no element matching query 'Save' and role AXButton in window 'Doc' of TextEdit after 5 s; the search did not cover the whole window: 1 node(s) did not respond to Accessibility requests.")
        #expect(DesktopWaitPolicy.timeoutMessage(
            .elementPresent, observation: .element(.windowMissing), subject: subject, elapsed: 5, frontmostApp: nil
        ).contains("no window to search"))
        #expect(DesktopWaitPolicy.timeoutMessage(
            .elementPresent, observation: .element(.unreadable(reason: "TextEdit is not responding to Accessibility requests")),
            subject: subject, elapsed: 5, frontmostApp: nil
        ) == "element_present: the window could not be read after 5 s: TextEdit is not responding to Accessibility requests.")
    }

    @Test
    func theTimeoutErrorOfElementAbsentExplainsAnIncompleteVisit() throws {
        let subject = try subject(
            #"{"action":"wait_for","condition":"element_absent","identifier":"save-button"}"#,
            runningName: "TextEdit", scope: "window 'Doc' of TextEdit"
        )
        let incomplete = DesktopWaitPolicy.timeoutMessage(
            .elementAbsent,
            observation: .element(.notFound(incompleteBecause: "the Accessibility tree visit stopped at its 2-second time budget after 812 node(s)")),
            subject: subject, elapsed: 5, frontmostApp: "TextEdit"
        )
        #expect(incomplete == "element_absent: cannot confirm that no element matching identifier 'save-button' in window 'Doc' of TextEdit exists after 5 s: the Accessibility tree visit stopped at its 2-second time budget after 812 node(s); frontmost app is TextEdit.")
        let still = DesktopWaitPolicy.timeoutMessage(
            .elementAbsent, observation: .element(.found(count: 2)), subject: subject, elapsed: 5, frontmostApp: nil
        )
        #expect(still == "element_absent: an element matching identifier 'save-button' in window 'Doc' of TextEdit is still present after 5 s (2 matches).")
        let unreadable = DesktopWaitPolicy.timeoutMessage(
            .elementAbsent, observation: .element(.unreadable(reason: "Accessibility error -25204 while reading the window")),
            subject: subject, elapsed: 5, frontmostApp: nil
        )
        #expect(unreadable.contains("cannot confirm that no element matching identifier 'save-button'"))
        #expect(unreadable.contains("the window could not be read (Accessibility error -25204 while reading the window)"))
    }

    @Test
    func anElementRefIsNamedWithoutRepeatingItsValue() throws {
        let ref = try reference()
        let subject = try subject(#"{"action":"wait_for","condition":"element_absent","element_ref":"\#(ref)"}"#, runningName: "TextEdit")
        #expect(subject.elementPhrase == "element of the given element_ref in TextEdit")
        #expect(!subject.elementPhrase.contains(ref))
    }

    @Test
    func theSubjectNamesTheAppByTheMostSpecificSelector() throws {
        #expect(try subject(#"{"action":"wait_for","pid":42}"#).app == "pid 42")
        #expect(try subject(#"{"action":"wait_for","pid":42,"bundle_id":"com.apple.TextEdit"}"#).app == "com.apple.TextEdit")
        #expect(try subject(#"{"action":"wait_for","bundle_id":"com.apple.TextEdit","app_name":"TextEdit"}"#).app == "TextEdit")
        #expect(try subject(#"{"action":"wait_for","app_name":"edit"}"#, runningName: "TextEdit").app == "TextEdit")
        #expect(try subject(#"{"action":"wait_for","title":"x"}"#).app == nil)
        #expect(try subject(#"{"action":"wait_for","title":"Save"}"#).windowPhrase == "window matching title 'Save'")
        #expect(try subject(#"{"action":"wait_for","app_name":"TextEdit"}"#).windowPhrase == "window of TextEdit")
    }

    @Test
    func successSummariesNameWhatWasFoundAndTheTimeItTook() throws {
        let app = try subject(#"{"action":"wait_for","condition":"app_active","app_name":"Calculator"}"#)
        #expect(DesktopWaitPolicy.successSummary(.appActive, subject: app, found: "Calculator", elapsedMilliseconds: 340)
            == "app_active: Calculator is the frontmost app (after 340 ms).")

        let window = try subject(#"{"action":"wait_for","condition":"window_present","app_name":"TextEdit","title":"Save"}"#)
        #expect(DesktopWaitPolicy.successSummary(
            .windowPresent, subject: window, found: DesktopWaitPolicy.windowLabel(title: "Save", app: "TextEdit"), elapsedMilliseconds: 1_240
        ) == "window_present: window 'Save' of TextEdit is present (after 1.2 s).")
        #expect(DesktopWaitPolicy.successSummary(.windowAbsent, subject: window, found: nil, elapsedMilliseconds: 0)
            == "window_absent: no window matching title 'Save' of TextEdit (after 0 ms).")

        let element = try subject(
            #"{"action":"wait_for","condition":"element_absent","query":"Save"}"#, runningName: "TextEdit", scope: "window 'Doc' of TextEdit"
        )
        #expect(DesktopWaitPolicy.successSummary(.elementAbsent, subject: element, found: nil, elapsedMilliseconds: 2_000)
            == "element_absent: no element matching query 'Save' in window 'Doc' of TextEdit (after 2 s).")
        var info = DesktopElementInfo(role: "AXButton")
        info.title = "Save"
        info.app_name = "TextEdit"
        info.window_title = "Doc"
        #expect(DesktopWaitPolicy.successSummary(
            .elementPresent, subject: element, found: DesktopElementPolicy.locationPhrase(info), elapsedMilliseconds: 80
        ) == "element_present: AXButton 'Save' in TextEdit — window 'Doc' is present (after 80 ms).")
    }

    @Test
    func theWindowLabelNamesTheTitleOrTheUntitledWindow() {
        #expect(DesktopWaitPolicy.windowLabel(title: "Save", app: "TextEdit") == "window 'Save' of TextEdit")
        #expect(DesktopWaitPolicy.windowLabel(title: nil, app: "TextEdit") == "the untitled window of TextEdit")
        #expect(DesktopWaitPolicy.windowLabel(title: "  ", app: nil) == "the untitled window")
    }

    @Test
    func severalMatchesAreNoted() {
        #expect(DesktopWaitPolicy.multipleMatchesNote(count: 3, complete: true).hasPrefix("3 elements match;"))
        #expect(DesktopWaitPolicy.multipleMatchesNote(count: 20, complete: false).hasPrefix("20 or more elements match;"))
    }

    // MARK: Schema

    @Test
    func theConditionEnumOfTheSchemaMatchesTheConditions() throws {
        let properties = try #require(try object(DesktopRunTool.inputSchema)["properties"] as? [String: Any])
        let condition = try #require(properties["condition"] as? [String: Any])
        #expect(condition["type"] as? String == "string")
        let values = try #require(condition["enum"] as? [String])
        #expect(values == DesktopWaitCondition.allCases.map(\.rawValue))
        #expect(values.count == Set(values).count)
        for value in values {
            #expect((condition["description"] as? String)?.contains(value) == true, "\(value)")
        }
        let root = try #require(try object(DesktopRunTool.inputSchema)["required"] as? [String])
        #expect(root == ["action"])
    }

    @Test
    func waitForIsDeclaredEverywhereItBelongs() throws {
        let properties = try #require(try object(DesktopRunTool.inputSchema)["properties"] as? [String: Any])
        let action = try #require(properties["action"] as? [String: Any])
        let actions = try #require(action["enum"] as? [String])
        #expect(actions.contains("wait_for"))
        #expect(Set(actions) == Set(DesktopAction.allCases.map(\.rawValue)))
        #expect(DesktopAction(rawValue: "wait_for") == .waitFor)
        let actionDescription = try #require(action["description"] as? String)
        for term in ["wait_for", "activate_app waits", "frontmost_app", "elapsed_ms"] {
            #expect(actionDescription.contains(term), "\(term)")
        }
        // Allowed in a batch, so listed in the steps' enum.
        let steps = try #require(properties["steps"] as? [String: Any])
        let stepAction = try #require(((steps["items"] as? [String: Any])?["properties"] as? [String: Any])?["action"] as? [String: Any])
        #expect((stepAction["enum"] as? [String])?.contains("wait_for") == true)
        #expect((steps["description"] as? String)?.contains("A wait_for step is estimated at its timeout (default 5 s).") == true)

        #expect(DesktopRunTool.description.contains("action=wait_for"))
        #expect(DesktopRunTool.description.contains("activate_app waits up to timeout (default 5 s)"))
    }

    @Test
    func theTimeoutDescriptionNamesEveryActionThatUsesIt() throws {
        let properties = try #require(try object(DesktopRunTool.inputSchema)["properties"] as? [String: Any])
        let timeout = try #require(properties["timeout"] as? [String: Any])
        #expect(timeout["minimum"] as? Int == 0)
        #expect(timeout["maximum"] as? Int == 30)
        let description = try #require(timeout["description"] as? String)
        for term in ["launch_app", "activate_app", "terminate_app", "wait_for", "defaulting to 5"] {
            #expect(description.contains(term), "\(term)")
        }
    }

    @Test
    func theOutputSchemaCoversTheFieldsOfWaitFor() throws {
        let root = try object(try #require(DesktopRunTool.outputSchema))
        let properties = try #require(root["properties"] as? [String: Any])
        for key in ["app", "window", "element", "elapsed_ms", "note", "frontmost_app"] {
            #expect(properties[key] != nil, "\(key)")
        }
        let elapsed = try #require(properties["elapsed_ms"] as? [String: Any])
        #expect((elapsed["description"] as? String)?.contains("wait_for") == true)
    }

    @Test
    func waitForOutputEncodesTheFoundThing() throws {
        var output = DesktopRunOutput(action: "wait_for", summary: "window_present: ...", elapsed_ms: 1_240)
        output.window = DesktopWindowInfo(
            window_id: 5, pid: 1, app_name: "TextEdit", bundle_id: nil, title: "Save", bounds: DesktopRect(.zero),
            layer: 0, is_on_screen: true, alpha: 1, is_fullscreen: nil
        )
        let encoded = try #require(try JSONSerialization.jsonObject(with: JSONEncoder().encode(output)) as? [String: Any])
        #expect(encoded["elapsed_ms"] as? Int == 1_240)
        #expect((encoded["window"] as? [String: Any])?["title"] as? String == "Save")
        #expect(encoded["element"] == nil && encoded["app"] == nil)
    }

    // MARK: Execution (validation only: nothing touches the desktop)

    @Test @MainActor
    func executeRefusesAnInvalidWaitForBeforeReadingTheDesktop() async throws {
        let context = FeatureContext(workingDirectory: FileManager.default.temporaryDirectory)
        for json in [
            #"{"action":"wait_for"}"#,
            #"{"action":"wait_for","condition":"app_active"}"#,
            #"{"action":"wait_for","condition":"element_present","app_name":"TextEdit"}"#,
            #"{"action":"wait_for","condition":"window_absent","pid":1,"timeout":99}"#
        ] {
            let error = await #expect(throws: DesktopControlError.self) {
                try await DesktopController.execute(try input(json), context: context)
            }
            #expect(error?.errorDescription?.isEmpty == false, "\(json)")
        }
    }

    @Test @MainActor
    func cancellationPropagatesBeforeAnyObservation() async {
        let context = FeatureContext(workingDirectory: FileManager.default.temporaryDirectory)
        let call = DesktopRunInput(action: "wait_for", title: "never-open-window", timeout: 30, condition: "window_present")
        // The task cannot start before cancel(): this test holds the main actor until it awaits.
        let task = Task { @MainActor in try await DesktopController.execute(call, context: context) }
        task.cancel()
        let result = await task.result
        guard case let .failure(error) = result else {
            Issue.record("the cancelled wait_for returned a result")
            return
        }
        #expect(error is CancellationError)
    }

    @Test @MainActor
    func aWaitForStepFailsOnItsOwnWithoutFailingTheBatch() async throws {
        let context = FeatureContext(workingDirectory: FileManager.default.temporaryDirectory)
        let output = try await DesktopController.execute(
            try input(#"{"action":"batch","steps":[{"action":"wait","duration":0},{"action":"wait_for","condition":"app_active"},{"action":"wait","duration":0}]}"#),
            context: context
        )
        #expect(output.summary.hasPrefix("Stopped at step 2 of 3 (wait_for): Invalid argument 'pid/bundle_id/app_name'"))
        let steps = try #require(output.steps)
        #expect(steps.map(\.ok) == [true, false, false])
        #expect(steps[1].action == "wait_for")
        #expect(steps[2].skipped == true)
    }
}
