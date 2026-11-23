import CoreGraphics
import FeatureKit
import Foundation
import Testing

@testable import desktop_tools_feature

@Suite
struct DesktopBatchPolicyTests {
    private func input(_ json: String) throws -> DesktopRunInput {
        try JSONDecoder().decode(DesktopRunInput.self, from: Data(json.utf8))
    }

    private func batch(_ steps: [String], extra: String = "") throws -> DesktopRunInput {
        try input(#"{"action":"batch"\#(extra),"steps":[\#(steps.joined(separator: ","))]}"#)
    }

    private func object(_ json: String) throws -> [String: Any] {
        try #require(try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
    }

    /// The reason `plan` gives for refusing `steps`, or nil when it accepts them.
    private func planError(_ steps: [String]) throws -> String? {
        do {
            _ = try DesktopBatchPolicy.plan(try batch(steps))
            return nil
        } catch let error as DesktopControlError {
            return error.errorDescription
        }
    }

    // MARK: Allowlist

    @Test
    func allowlistIsClosedAndExcludesEveryGatedOrImageAction() {
        let excluded: Set<DesktopAction> = [
            .batch, .screenshot, .zoom, .requestPermissions, .open, .launchApp, .terminateApp, .pressKey
        ]
        #expect(DesktopBatchPolicy.allowedActions == Set(DesktopAction.allCases).subtracting(excluded))
        for action in excluded {
            let reason = DesktopBatchPolicy.actionRefusal(action)
            #expect(reason?.hasPrefix("is not allowed in a batch") == true, "\(action)")
        }
        for action in DesktopBatchPolicy.allowedActions {
            #expect(DesktopBatchPolicy.actionRefusal(action) == nil, "\(action)")
        }
        #expect(DesktopBatchPolicy.allowedActionNames == DesktopAction.allCases.filter(DesktopBatchPolicy.allowedActions.contains).map(\.rawValue))
    }

    @Test(arguments: ["open", "launch_app", "terminate_app", "press_key", "screenshot", "zoom", "request_permissions", "batch", " OPEN ", "Launch_App"])
    func refusedActionsNameTheStepAndTheReason(_ action: String) throws {
        let message = try #require(try planError([#"{"action":"wait","duration":0}"#, #"{"action":"\#(action)","target":"/tmp"}"#]))
        let name = DesktopAction.normalizedName(action)
        #expect(message.hasPrefix("Invalid argument 'steps': step 2 of 2 (\(name)) is not allowed in a batch"))
    }

    @Test
    func gatedActionsExplainTheConsentReason() throws {
        for action in ["open", "launch_app", "terminate_app"] {
            let message = try #require(try planError([#"{"action":"\#(action)"}"#]))
            #expect(message.contains("operator approval"))
            #expect(message.contains("on its own"))
        }
        #expect(try planError([#"{"action":"batch","steps":[{"action":"wait"}]}"#])?.contains("cannot be nested") == true)
    }

    @Test
    func pressKeyCannotBypassConsentWithReturnOrApplicationShortcuts() throws {
        for key in ["return", "keypad_enter", "q"] {
            let step = DesktopRunInput(action: "press_key", key: key, modifiers: key == "q" ? ["command"] : nil)
            let reason = try #require(DesktopBatchPolicy.refusal(of: step))
            #expect(reason.contains("is not allowed in a batch"))
            #expect(reason.contains("top-level gate"))
        }
        #expect(!DesktopBatchPolicy.allowedActions.contains(.pressKey))
        #expect(!DesktopBatchPolicy.allowedActionNames.contains("press_key"))
    }

    @Test
    func unknownAndEmptyActionsAreRefused() throws {
        #expect(try planError([#"{"action":"explode"}"#]) == "Invalid argument 'steps': step 1 of 1 has an unsupported action 'explode'.")
        #expect(try planError([#"{"action":"wait","duration":0}"#, #"{"action":"  "}"#]) == "Invalid argument 'steps': step 2 of 2 has an empty action.")
    }

    @Test
    func activateAppIsRefusedOnlyWithLaunchIfNeeded() throws {
        let message = try #require(try planError([#"{"action":"activate_app","app_name":"Calculator","launch_if_needed":true}"#]))
        #expect(message.hasPrefix("Invalid argument 'steps': step 1 of 1 (activate_app) must not set launch_if_needed=true"))
        #expect(try planError([#"{"action":"activate_app","app_name":"Calculator","launch_if_needed":false}"#]) == nil)
        #expect(try planError([#"{"action":"activate_app","app_name":"Calculator"}"#]) == nil)
    }

    @Test(arguments: ["ls\n", "ls\r", "a\r\nb", "\u{0F}", "rm\u{03}", "x\u{7F}", "\u{2028}", "\u{2029}", "\u{85}", "\u{0B}", "\u{1B}[A"])
    func typeTextRefusesLineBreaksAndControlCharacters(_ text: String) throws {
        let step = DesktopRunInput(action: "type_text", text: text)
        let reason = try #require(DesktopBatchPolicy.refusal(of: step))
        #expect(reason.hasPrefix("(type_text) must not type line breaks or control characters"))
        #expect(reason.contains("operator approval"))
    }

    @Test
    func typeTextAllowsTabsAndOrdinaryText() {
        for text in ["7*8=", "a\tb", "Café ☕️ 👩‍👩‍👧", ""] {
            #expect(DesktopBatchPolicy.refusal(of: DesktopRunInput(action: "type_text", text: text)) == nil, "\(text)")
        }
        #expect(DesktopBatchPolicy.refusal(of: DesktopRunInput(action: "type_text")) == nil)
        // set_value and write_clipboard never press keys: line breaks stay allowed there.
        #expect(DesktopBatchPolicy.refusal(of: DesktopRunInput(action: "set_value", text: "a\nb")) == nil)
        #expect(DesktopBatchPolicy.refusal(of: DesktopRunInput(action: "write_clipboard", text: "a\nb")) == nil)
    }

    @Test
    func stepsAreRefusedInsideAStep() throws {
        let message = try #require(try planError([#"{"action":"click","x":1,"y":2,"steps":[{"action":"wait"}]}"#]))
        #expect(message == "Invalid argument 'steps': step 1 of 1 (click) must not contain steps: only batch uses them, and batches cannot be nested.")
    }

    // MARK: Validation before execution

    @Test
    func stepCountIsBounded() throws {
        let wait = #"{"action":"wait","duration":0}"#
        #expect(try planError([wait]) == nil)
        #expect(try planError(Array(repeating: wait, count: 20)) == nil)
        let empty = try #require(try planError([]))
        #expect(empty.hasPrefix("Invalid argument 'steps': must contain between 1 and 20 steps (got 0)"))
        let tooMany = try #require(try planError(Array(repeating: wait, count: 21)))
        #expect(tooMany.hasPrefix("Invalid argument 'steps': must contain between 1 and 20 steps (got 21)"))
        let missing = #expect(throws: DesktopControlError.self) {
            try DesktopBatchPolicy.plan(try input(#"{"action":"batch"}"#))
        }
        #expect(missing?.errorDescription == "Action 'batch' requires argument 'steps'.")
    }

    @Test
    func everyStepIsValidatedBeforeTheFirstRuns() throws {
        // The refused step comes last; plan still refuses the whole batch.
        let steps = [
            #"{"action":"press_element","query":"7"}"#, #"{"action":"press_element","query":"×"}"#,
            #"{"action":"press_element","query":"8"}"#, #"{"action":"type_text","text":"=\n"}"#
        ]
        let message = try #require(try planError(steps))
        #expect(message.hasPrefix("Invalid argument 'steps': step 4 of 4 (type_text)"))
    }

    @Test @MainActor
    func executeThrowsForARefusedStepWithoutRunningAnyStep() async throws {
        let context = FeatureContext(workingDirectory: FileManager.default.temporaryDirectory)
        // Had the first step run, the call would return results instead of throwing.
        let refused = try batch([#"{"action":"wait","duration":0}"#, #"{"action":"zoom","x":0,"y":0,"width":10,"height":10}"#])
        let error = await #expect(throws: DesktopControlError.self) {
            try await DesktopController.execute(refused, context: context)
        }
        #expect(error?.errorDescription?.hasPrefix("Invalid argument 'steps': step 2 of 2 (zoom)") == true)
    }

    @Test @MainActor
    func stepsAreRefusedOnOtherActions() async throws {
        let context = FeatureContext(workingDirectory: FileManager.default.temporaryDirectory)
        let error = await #expect(throws: DesktopControlError.self) {
            try await DesktopController.execute(
                try input(#"{"action":"wait","duration":0,"steps":[{"action":"wait","duration":0}]}"#), context: context
            )
        }
        #expect(error?.errorDescription == "Invalid argument 'steps': is used only by action batch.")
    }

    // MARK: Execution (wait steps only: nothing touches the desktop)

    @Test @MainActor
    func aFailedStepStopsTheBatchWithoutFailingTheCall() async throws {
        let context = FeatureContext(workingDirectory: FileManager.default.temporaryDirectory)
        let output = try await DesktopController.execute(
            try batch([#"{"action":"wait","duration":0}"#, #"{"action":"wait"}"#, #"{"action":"wait","duration":0}"#]),
            context: context
        )
        #expect(output.ok)
        #expect(output.action == "batch")
        #expect(output.summary == "Stopped at step 2 of 3 (wait): Action 'wait' requires argument 'duration'; 1 step(s) skipped.")
        let steps = try #require(output.steps)
        #expect(steps.map(\.index) == [1, 2, 3])
        #expect(steps.map(\.ok) == [true, false, false])
        #expect(steps[0].summary == "Waited 0.00 second(s).")
        #expect(steps[1].error == "Action 'wait' requires argument 'duration'.")
        #expect(steps[1].summary == nil)
        #expect(steps[2].skipped == true)
        #expect(steps[2].note == "Skipped: step 2 failed and stop_on_error is true.")
        #expect(output.note == nil)
    }

    @Test @MainActor
    func stopOnErrorFalseRunsEveryStep() async throws {
        let context = FeatureContext(workingDirectory: FileManager.default.temporaryDirectory)
        let output = try await DesktopController.execute(
            try batch([#"{"action":"wait"}"#, #"{"action":"wait","duration":0}"#, #"{"action":" WAIT ","duration":-1}"#], extra: #","stop_on_error":false"#),
            context: context
        )
        #expect(output.summary == "Ran 3 of 3 step(s); 2 failed (steps 1, 3).")
        let steps = try #require(output.steps)
        #expect(steps.map(\.ok) == [false, true, false])
        #expect(steps.allSatisfy { $0.skipped == nil })
        #expect(steps[2].action == "wait")
    }

    // MARK: Inheritance

    @Test
    func appSelectorsAreInheritedOnlyByStepsWithoutAny() throws {
        let root = try input(#"{"action":"batch","pid":42,"bundle_id":"com.apple.calculator","app_name":"Calculator"}"#)
        let bare = DesktopBatchPolicy.inheriting(DesktopRunInput(action: "press_element"), from: root)
        #expect(bare.pid == 42 && bare.bundle_id == "com.apple.calculator" && bare.app_name == "Calculator")

        for own in [#"{"action":"click","pid":7}"#, #"{"action":"click","bundle_id":"com.other"}"#, #"{"action":"click","app_name":"Other"}"#] {
            let step = DesktopBatchPolicy.inheriting(try input(own), from: root)
            let selectors = [step.pid.map { "\($0)" }, step.bundle_id, step.app_name].compactMap { $0 }
            #expect(selectors.count == 1, "\(own)")
            #expect(step.pid != 42 && step.bundle_id != "com.apple.calculator" && step.app_name != "Calculator")
        }
        // A blank selector counts as absent.
        let blank = DesktopBatchPolicy.inheriting(try input(#"{"action":"click","app_name":"  "}"#), from: root)
        #expect(blank.pid == 42 && blank.app_name == "Calculator")
    }

    @Test
    func windowSelectorsAreInheritedOnlyWithoutWindowSelectorsOrElementRef() throws {
        let root = try input(#"{"action":"batch","window_id":99,"title":"Calculator"}"#)
        let bare = DesktopBatchPolicy.inheriting(DesktopRunInput(action: "list_elements"), from: root)
        #expect(bare.window_id == 99 && bare.title == "Calculator")

        let own = [
            #"{"action":"list_elements","window_id":5}"#, #"{"action":"list_elements","title":"Other"}"#,
            #"{"action":"list_elements","window_index":0}"#, #"{"action":"press_element","element_ref":"p1.w2:0:AXButton:fbbf52e3"}"#
        ]
        for json in own {
            let step = DesktopBatchPolicy.inheriting(try input(json), from: root)
            #expect(step.window_id != 99, "\(json)")
            #expect(step.title != "Calculator", "\(json)")
        }
        // App and window selectors are inherited independently.
        let withApp = DesktopBatchPolicy.inheriting(try input(#"{"action":"click","app_name":"Other"}"#), from: root)
        #expect(withApp.window_id == 99 && withApp.app_name == "Other")
        let withRef = DesktopBatchPolicy.inheriting(
            try input(#"{"action":"click","element_ref":"p1.w2:0:AXButton:fbbf52e3"}"#),
            from: try input(#"{"action":"batch","pid":1,"window_id":99}"#)
        )
        #expect(withRef.pid == 1 && withRef.window_id == nil)
    }

    @Test
    func nothingElseIsInherited() throws {
        let root = try input(#"{"action":"batch","text":"x\n","query":"7","identifier":"Seven","window_index":2,"element_ref":"p1.w2:0:AXButton:fbbf52e3","launch_if_needed":true,"stop_on_error":false}"#)
        let step = DesktopBatchPolicy.inheriting(DesktopRunInput(action: "type_text"), from: root)
        #expect(step.text == nil && step.query == nil && step.identifier == nil && step.window_index == nil)
        #expect(step.element_ref == nil && step.launch_if_needed == nil && step.stop_on_error == nil)
    }

    @Test
    func planReturnsTheInheritedSteps() throws {
        let planned = try DesktopBatchPolicy.plan(try batch(
            [#"{"action":"press_element","query":"7"}"#, #"{"action":"list_elements","app_name":"Other"}"#],
            extra: #","app_name":"Calculator","window_id":3"#
        ))
        #expect(planned.map(\.app_name) == ["Calculator", "Other"])
        #expect(planned.map(\.window_id) == [3, 3])
    }

    // MARK: Decoding

    @Test
    func stepsDecodeFromJSON() throws {
        let decoded = try input(#"""
        {"action":"batch","pid":42,"stop_on_error":false,"steps":[
          {"action":"press_element","query":"7","role":"button"},
          {"action":"press_element","identifier":"Multiply"},
          {"action":"type_text","text":"8","interval":0.02},
          {"action":"list_elements","include_details":true,"limit":5}
        ]}
        """#)
        #expect(decoded.action == "batch")
        #expect(decoded.pid == 42)
        #expect(decoded.stop_on_error == false)
        let steps = try #require(decoded.steps)
        #expect(steps.map(\.action) == ["press_element", "press_element", "type_text", "list_elements"])
        #expect(steps[0].query == "7" && steps[0].role == "button")
        #expect(steps[1].identifier == "Multiply")
        #expect(steps[2].text == "8" && steps[2].interval == 0.02)
        #expect(steps[3].include_details == true && steps[3].limit == 5)
        #expect(steps.allSatisfy { $0.steps == nil && $0.pid == nil })
    }

    // MARK: Time budget

    @Test
    func estimatedDurationCoversTypingWaitActivationAndPointerMovement() {
        func estimate(_ step: DesktopRunInput) -> Double { DesktopBatchPolicy.estimatedDuration(step) }
        #expect(abs(estimate(DesktopRunInput(action: "type_text", text: String(repeating: "a", count: 1000))) - 12) < 1e-9)
        #expect(abs(estimate(DesktopRunInput(action: "type_text", interval: 0.5, text: "abcd")) - 2.008) < 1e-9)
        #expect(estimate(DesktopRunInput(action: "wait", duration: 12)) == 12)
        #expect(estimate(DesktopRunInput(action: "activate_app")) == DesktopActivationPolicy.defaultTimeout)
        #expect(estimate(DesktopRunInput(action: "activate_app", timeout: 30)) == 30)
        #expect(estimate(DesktopRunInput(action: "wait")) == 0)
        for action in ["move_mouse", "click", "drag", "scroll"] {
            #expect(estimate(DesktopRunInput(action: action)) == 0.2)
            #expect(estimate(DesktopRunInput(action: action, duration: 3)) == 3)
        }
        // Invalid values count as zero; the step fails on its own validation.
        #expect(estimate(DesktopRunInput(action: "wait", duration: -5)) == 0)
        #expect(estimate(DesktopRunInput(action: "wait", duration: .infinity)) == 0)
        // delay belongs to screenshot and zoom only, which a batch refuses.
        #expect(estimate(DesktopRunInput(action: "list_elements", delay: 10)) == 0)
        #expect(estimate(DesktopRunInput(action: " TYPE_TEXT ", text: "ab")) > 0)
    }

    @Test
    func stepsEstimatedOverTheBudgetAreRefused() throws {
        let long = try #require(DesktopBatchPolicy.refusal(of: DesktopRunInput(action: "type_text", text: String(repeating: "a", count: 10_000))))
        #expect(long == "(type_text) is estimated to take 120 s, more than the batch's 60-second time budget. Call it on its own, or split it.")
        #expect(DesktopBatchPolicy.refusal(of: DesktopRunInput(action: "wait", duration: 30)) == nil)
        let huge = try #require(DesktopBatchPolicy.refusal(of: DesktopRunInput(action: "wait", duration: 1e20)))
        #expect(huge.contains("estimated to take"))
        #expect(!DesktopBatchPolicy.seconds(1e20).isEmpty)
        #expect(DesktopBatchPolicy.refusal(of: DesktopRunInput(action: "type_text", text: String(repeating: "a", count: 4_000))) == nil)
    }

    @Test
    func waitForIsAllowedInABatchAndEstimatedAtItsTimeout() throws {
        #expect(DesktopBatchPolicy.allowedActions.contains(.waitFor))
        #expect(DesktopBatchPolicy.actionRefusal(.waitFor) == nil)
        #expect(DesktopBatchPolicy.allowedActionNames.contains("wait_for"))
        func estimate(_ step: DesktopRunInput) -> Double { DesktopBatchPolicy.estimatedDuration(step) }
        // The estimate is the timeout, 5 s by default.
        #expect(estimate(DesktopRunInput(action: "wait_for")) == 5)
        #expect(estimate(DesktopRunInput(action: " WAIT_FOR ", timeout: 12)) == 12)
        #expect(estimate(DesktopRunInput(action: "wait_for", timeout: 0)) == 0)
        // An invalid timeout counts as zero here and fails on its own validation.
        #expect(estimate(DesktopRunInput(action: "wait_for", timeout: -1)) == 0)
        #expect(estimate(DesktopRunInput(action: "wait_for", timeout: .nan)) == 0)
        // duration belongs to wait and does not count for wait_for.
        #expect(estimate(DesktopRunInput(action: "wait_for", duration: 20)) == 5)
        #expect(DesktopBatchPolicy.refusal(of: DesktopRunInput(action: "wait_for", timeout: 30)) == nil)
        let tooLong = try #require(DesktopBatchPolicy.refusal(of: DesktopRunInput(action: "wait_for", timeout: 90)))
        #expect(tooLong.hasPrefix("(wait_for) is estimated to take 90 s, more than the batch's 60-second time budget."))

        // A batch plans wait_for steps and lets them inherit the app and window selectors.
        let planned = try DesktopBatchPolicy.plan(try batch(
            [#"{"action":"press_element","query":"Save"}"#, #"{"action":"wait_for","condition":"window_absent","timeout":3}"#],
            extra: #","app_name":"TextEdit","title":"Doc""#
        ))
        #expect(planned.map(\.action) == ["press_element", "wait_for"])
        #expect(planned[1].app_name == "TextEdit" && planned[1].title == "Doc" && planned[1].condition == "window_absent")
    }

    @Test
    func timeBudgetLeavesRoomOnlyForStepsThatFit() {
        #expect(DesktopBatchPolicy.fitsTimeBudget(estimate: 0, elapsed: 0))
        #expect(DesktopBatchPolicy.fitsTimeBudget(estimate: 60, elapsed: 0))
        #expect(DesktopBatchPolicy.fitsTimeBudget(estimate: 10, elapsed: 50))
        #expect(!DesktopBatchPolicy.fitsTimeBudget(estimate: 10.5, elapsed: 50))
        #expect(!DesktopBatchPolicy.fitsTimeBudget(estimate: 0, elapsed: 60))
        #expect(!DesktopBatchPolicy.fitsTimeBudget(estimate: 0, elapsed: 75))
    }

    // MARK: Summary and notes

    private func ran(_ index: Int, _ action: String = "press_element") -> DesktopBatchStepResult {
        DesktopBatchStepResult(index: index, action: action, ok: true, summary: "Done.")
    }

    private func failed(_ index: Int, _ action: String = "press_element", error: String = "Element reference is stale.") -> DesktopBatchStepResult {
        DesktopBatchStepResult(index: index, action: action, ok: false, error: error)
    }

    @Test
    func summaryCountsRunFailedAndSkippedSteps() {
        #expect(DesktopBatchPolicy.summary([ran(1), ran(2), ran(3), ran(4)], stop: nil) == "Ran 4 of 4 step(s).")
        #expect(DesktopBatchPolicy.summary([ran(1), failed(2), ran(3), failed(4)], stop: nil) == "Ran 4 of 4 step(s); 2 failed (steps 2, 4).")
        #expect(DesktopBatchPolicy.summary([ran(1), failed(2), ran(3)], stop: nil) == "Ran 3 of 3 step(s); 1 failed (step 2).")

        let stop = DesktopBatchPolicy.Stop.error(index: 3)
        let stopped = [ran(1), ran(2), failed(3)]
            + [4, 5].map { DesktopBatchPolicy.skipped(index: $0, action: "click", stop: stop) }
        #expect(DesktopBatchPolicy.summary(stopped, stop: stop)
            == "Stopped at step 3 of 5 (press_element): Element reference is stale; 2 step(s) skipped.")
        #expect(DesktopBatchPolicy.summary([ran(1), failed(2)], stop: .error(index: 2))
            == "Stopped at step 2 of 2 (press_element): Element reference is stale.")
    }

    @Test
    func timeBudgetStopIsSummarizedAndNoted() {
        let stop = DesktopBatchPolicy.Stop.timeBudget(index: 3, elapsed: 52, estimate: 12)
        let first = DesktopBatchPolicy.skipped(index: 3, action: "wait", stop: stop)
        let next = DesktopBatchPolicy.skipped(index: 4, action: "click", stop: stop)
        #expect(first.skipped == true && !first.ok)
        #expect(first.note == "Skipped: 8 s of the batch's 60-second time budget were left, less than the 12 s this step is estimated to take.")
        #expect(next.note == "Skipped: the batch stopped at its time budget before step 3.")
        let usedUp = DesktopBatchPolicy.skipped(index: 3, action: "wait", stop: .timeBudget(index: 3, elapsed: 61, estimate: 0))
        #expect(usedUp.note == "Skipped: the batch's 60-second time budget was used up.")
        #expect(DesktopBatchPolicy.summary([ran(1), failed(2), first, next], stop: stop)
            == "Ran 2 of 4 step(s); 1 failed (step 2); stopped before step 3 (wait) at the 60-second time budget; 2 step(s) skipped.")
        #expect(DesktopBatchPolicy.timeBudgetNote(stop) == "The batch stopped at its 60-second time budget before step 3; run the skipped steps in another call.")
        #expect(DesktopBatchPolicy.timeBudgetNote(.error(index: 1)) == nil)
        #expect(DesktopBatchPolicy.timeBudgetNote(nil) == nil)
    }

    @Test
    func resultKeepsTheUsefulPayloadsOfTheStep() {
        var output = DesktopRunOutput(action: "list_elements", summary: "Listed 1 element(s).")
        output.elements = [DesktopElementInfo(role: "AXButton")]
        output.count = 1
        output.next_offset = 1
        output.note = "More."
        output.pointer = DesktopPoint(.zero)
        output.permissions = DesktopPermissions(accessibility: true, screen_recording: true, event_posting: true)
        output.system = DesktopSystemInfo(
            os_version: "macOS", architecture: "arm64", process_id: 42,
            displays: [], pointer: DesktopPoint(.zero), frontmost_app: nil
        )
        let result = DesktopBatchPolicy.result(index: 2, output: output)
        #expect(result.index == 2 && result.action == "list_elements" && result.ok)
        #expect(result.summary == "Listed 1 element(s).")
        #expect(result.note == "More." && result.count == 1 && result.next_offset == 1)
        #expect(result.elements?.count == 1)
        #expect(result.error == nil && result.skipped == nil)
        #expect(result.permissions?.accessibility == true)
        #expect(result.system?.process_id == 42)

        var clipboard = DesktopBatchStepResult(index: 3, action: "read_clipboard", ok: true, summary: "Read clipboard.")
        clipboard.clipboard_text = String(repeating: "x", count: 8_000)
        let fitted = DesktopBatchPolicy.fitted([result, clipboard])
        #expect(fitted.steps[0].permissions?.accessibility == true)
        #expect(fitted.steps[0].system?.process_id == 42)
        #expect((fitted.steps[1].clipboard_text?.count ?? 8_000) < 8_000)

        let failure = DesktopBatchPolicy.failure(index: 3, action: "click", error: DesktopControlError.staleElementReference)
        #expect(!failure.ok && failure.summary == nil)
        #expect(failure.error == DesktopControlError.staleElementReference.errorDescription)
    }

    // MARK: Size budget

    private func element(_ label: String) -> DesktopElementInfo {
        DesktopElementPolicy.makeInfo(
            role: "AXButton", subrole: "AXSubrole", roleDescription: "button", title: label, description: label + " description",
            identifier: label + "-id", enabled: true, focused: false, valueSettable: false,
            frame: CGRect(x: 10, y: 20, width: 30, height: 40), actions: ["AXPress", "AXShowMenu", "AXScrollToVisible"],
            pid: 42, appName: "Calculator", windowTitle: "Calculator", ref: "p42.w7:0.\(label.count):AXButton:fbbf52e3"
        )
    }

    private func listing(_ index: Int, elements count: Int) -> DesktopBatchStepResult {
        var step = DesktopBatchStepResult(index: index, action: "list_elements", ok: true, summary: "Listed \(count) element(s).")
        step.elements = (0..<count).map { element("Item \($0)") }
        return step
    }

    private func total(_ steps: [DesktopBatchStepResult]) -> Int {
        steps.reduce(0) { $0 + DesktopListPaging.encodedLength($1) }
    }

    @Test
    func stepsWithinTheBudgetAreUnchanged() {
        let steps = [ran(1), listing(2, elements: 2)]
        let fitted = DesktopBatchPolicy.fitted(steps)
        #expect(fitted.note == nil)
        #expect(fitted.steps[1].elements?.count == 2)
    }

    @Test
    func earlierListsGoFirstThenTheLastStepOnes() throws {
        let steps = [listing(1, elements: 10), listing(2, elements: 10), listing(3, elements: 10)]
        let last = DesktopListPaging.encodedLength(steps[2])
        // Room for the last list only.
        let fitted = DesktopBatchPolicy.fitted(steps, budget: last + 400)
        #expect(fitted.steps[0].elements == nil && fitted.steps[1].elements == nil)
        #expect(fitted.steps[2].elements?.count == 10)
        #expect(fitted.steps.map(\.summary) == steps.map(\.summary))
        let note = try #require(fitted.note)
        #expect(note == "The steps were reduced to fit the response size budget: the elements, texts, windows, and apps of the earlier steps were omitted. Run a step on its own for its full output.")

        // Without room for it, the last list goes too, and only then.
        let tighter = DesktopBatchPolicy.fitted(steps, budget: 400)
        #expect(tighter.steps.allSatisfy { $0.elements == nil })
        #expect(tighter.note?.contains("the elements, texts, windows, and apps of the last step that ran were omitted") == true)
        #expect(total(tighter.steps) <= 400)
    }

    @Test
    func theLastStepIsTheLastOneThatRan() {
        let stop = DesktopBatchPolicy.Stop.error(index: 2)
        let steps = [listing(1, elements: 10), listing(2, elements: 10), DesktopBatchPolicy.skipped(index: 3, action: "click", stop: stop)]
        let fitted = DesktopBatchPolicy.fitted(steps, budget: DesktopListPaging.encodedLength(steps[1]) + 400)
        #expect(fitted.steps[0].elements == nil)
        #expect(fitted.steps[1].elements?.count == 10)
        #expect(fitted.steps[2].skipped == true)
    }

    @Test
    func elementsAreCompactedBeforeWindowAndAppAreDropped() throws {
        let app = DesktopAppInfo(
            pid: 42, name: "Calculator", bundle_id: "com.apple.calculator", bundle_path: "/System/Applications/Calculator.app",
            activation_policy: "regular", is_active: true, is_hidden: false, is_terminated: false
        )
        let steps = (1...4).map { index in
            DesktopBatchStepResult(
                index: index, action: "click", ok: true, summary: "Clicked.",
                element: element("Seven"), focused_element: element("Display"), app: app
            )
        }
        let compacted = steps.map { step in
            var copy = step
            copy.element = copy.element.map(DesktopElementPolicy.compact)
            copy.focused_element = copy.focused_element.map(DesktopElementPolicy.compact)
            return copy
        }
        let fitted = DesktopBatchPolicy.fitted(steps, budget: total(compacted))
        #expect(fitted.steps.allSatisfy { $0.element?.frame == nil && $0.element?.label == "Seven | Seven description" })
        #expect(fitted.steps.allSatisfy { $0.app != nil })
        let note = try #require(fitted.note)
        #expect(note.contains("element and focused_element of the earlier steps are compact"))
        #expect(note.contains("element and focused_element of the last step that ran are compact"))
        #expect(!note.contains("window and app"))

        // Less room: window and app of the earlier steps go, the last step keeps them.
        let tighter = DesktopBatchPolicy.fitted(steps, budget: total(compacted) - 300)
        #expect(tighter.steps.dropLast().allSatisfy { $0.app == nil })
        #expect(tighter.steps.last?.app != nil)
        #expect(tighter.note?.contains("window and app of the earlier steps were omitted") == true)
    }

    @Test
    func theOutputAlwaysEndsWithinTheBudget() throws {
        let error = String(repeating: "The element could not be pressed because the app did not answer. ", count: 20)
        var steps = (1...19).map { index -> DesktopBatchStepResult in
            var step = failed(index, error: error)
            step.note = String(repeating: "note ", count: 200)
            step.element = element("Item \(index)")
            step.clipboard_text = String(repeating: "c", count: 2_000)
            return step
        }
        var last = DesktopBatchStepResult(index: 20, action: "read_clipboard", ok: true, summary: "Read 50000 character(s) from the clipboard.")
        last.clipboard_text = String(repeating: "x", count: 50_000)
        steps.append(last)
        let budget = DesktopSafetyPolicy.maximumListPayloadCharacters
        let fitted = DesktopBatchPolicy.fitted(steps)
        #expect(total(fitted.steps) <= budget)
        #expect(fitted.steps.map(\.index) == Array(1...20))
        #expect(fitted.steps.map(\.action) == steps.map(\.action))
        #expect(fitted.steps.map(\.ok) == steps.map(\.ok))
        #expect(fitted.steps.dropLast().allSatisfy { $0.element == nil && $0.clipboard_text == nil })
        let note = try #require(fitted.note)
        #expect(note.contains("the earlier steps keep only index, action, ok, summary, error, note, skipped, permissions, and system"))
        #expect(note.contains("summaries, errors, and notes were shortened"))
        #expect(note.contains("the clipboard_text of the last step that ran was shortened"))
        #expect(note.hasSuffix("Run a step on its own for its full output."))
        // The earlier texts are cut first, so part of the last clipboard_text is kept.
        #expect(fitted.steps.dropLast().allSatisfy { ($0.error?.count ?? 0) <= 60 })
        let kept = fitted.steps.last?.clipboard_text?.count ?? 0
        #expect(kept > 0 && kept < 50_000)
        #expect(fitted.steps.last?.summary == last.summary)
    }

    @Test
    func manyLongErrorsStillFit() {
        let error = String(repeating: "é\u{1}", count: 2_000)
        let steps = (1...20).map { failed($0, error: error) }
        let fitted = DesktopBatchPolicy.fitted(steps)
        #expect(total(fitted.steps) <= DesktopSafetyPolicy.maximumListPayloadCharacters)
        #expect(fitted.steps.allSatisfy { !$0.ok })
    }

    @Test
    func shortenedCutsWithAnEllipsis() {
        #expect(DesktopBatchPolicy.shortened("abcdef", to: 10) == "abcdef")
        #expect(DesktopBatchPolicy.shortened("abcdefghijkl", to: 8) == "abcde...")
        #expect(DesktopBatchPolicy.shortened("abc", to: 0) == nil)
    }

    // MARK: Schema

    @Test
    func stepsSchemaMatchesTheAllowlist() throws {
        let properties = try #require(try object(DesktopRunTool.inputSchema)["properties"] as? [String: Any])
        let steps = try #require(properties["steps"] as? [String: Any])
        #expect(steps["type"] as? String == "array")
        #expect(steps["minItems"] as? Int == DesktopBatchPolicy.stepCountRange.lowerBound)
        #expect(steps["maxItems"] as? Int == DesktopBatchPolicy.maximumSteps)
        let items = try #require(steps["items"] as? [String: Any])
        #expect(items["type"] as? String == "object")
        #expect(items["required"] as? [String] == ["action"])
        #expect((items["description"] as? String)?.contains("nested schema constrains action") == true)
        #expect((items["description"] as? String)?.contains("top-level types") == true)
        let action = try #require((items["properties"] as? [String: Any])?["action"] as? [String: Any])
        #expect(action["enum"] as? [String] == DesktopBatchPolicy.allowedActionNames)
        let description = try #require(steps["description"] as? String)
        for excluded in ["batch", "press_key", "screenshot", "zoom", "request_permissions", "open", "launch_app", "terminate_app", "launch_if_needed=true", "line break"] {
            #expect(description.contains(excluded), "\(excluded)")
        }
        let stopOnError = try #require(properties["stop_on_error"] as? [String: Any])
        #expect(stopOnError["type"] as? String == "boolean")
        let rootActions = try #require((properties["action"] as? [String: Any])?["enum"] as? [String])
        #expect(rootActions.contains("batch"))
        #expect(rootActions.contains("read_text"))
        #expect(try planError([#"{"action":"read_text","role":"AXStaticText","limit":20}"#]) == nil)
    }

    @Test
    func outputSchemaDescribesBatchSteps() throws {
        let root = try object(try #require(DesktopRunTool.outputSchema))
        let properties = try #require(root["properties"] as? [String: Any])
        let steps = try #require(properties["steps"] as? [String: Any])
        #expect((steps["items"] as? [String: Any])?["$ref"] as? String == "#/$defs/batch_step")
        let defs = try #require(root["$defs"] as? [String: Any])
        let step = try #require(defs["batch_step"] as? [String: Any])
        #expect(step["required"] as? [String] == ["index", "action", "ok"])
        let schemaKeys = Set(try #require(step["properties"] as? [String: Any]).keys)

        var full = DesktopBatchStepResult(index: 1, action: "click", ok: false, summary: "s", error: "e", note: "n", skipped: true)
        full.element = DesktopElementInfo(role: "AXButton")
        full.focused_element = DesktopElementInfo(role: "AXTextField")
        full.app = DesktopAppInfo(pid: 1, name: nil, bundle_id: nil, bundle_path: nil, activation_policy: "regular", is_active: true, is_hidden: false, is_terminated: false)
        full.window = DesktopWindowInfo(window_id: 1, pid: 1, app_name: nil, bundle_id: nil, title: nil, bounds: DesktopRect(.zero), layer: 0, is_on_screen: true, alpha: 1, is_fullscreen: nil)
        full.elements = []
        full.texts = []
        full.permissions = DesktopPermissions(accessibility: true, screen_recording: true, event_posting: true)
        full.system = DesktopSystemInfo(
            os_version: "macOS", architecture: "arm64", process_id: 42,
            displays: [], pointer: DesktopPoint(.zero), frontmost_app: nil
        )
        full.windows = []
        full.apps = []
        full.clipboard_text = "c"
        full.count = 1
        full.next_offset = 2
        let encoded = try #require(try JSONSerialization.jsonObject(with: JSONEncoder().encode(full)) as? [String: Any])
        #expect(Set(encoded.keys) == schemaKeys)

        let minimal = try #require(try JSONSerialization.jsonObject(with: JSONEncoder().encode(DesktopBatchStepResult(index: 1, action: "wait", ok: true))) as? [String: Any])
        #expect(Set(minimal.keys) == ["index", "action", "ok"])
    }
}
