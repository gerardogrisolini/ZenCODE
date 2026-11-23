import Foundation
import ToolCore

/// Pure rules of `batch`, which runs up to 20 desktop.run calls in order in
/// one tool call: which actions a step may run, the validation of every step
/// before any runs, the selectors a step inherits from the batch, the time
/// budget, the summary, and the reduction of the steps to the response size
/// budget. `DesktopController.runBatch` only runs the steps.
///
/// ZenCODE asks for the operator's consent by looking only at the top-level
/// `action` of a desktop.run call and at its arguments
/// (`DirectToolExecutor+DesktopGating.swift` in the runtime): a batch is seen
/// there as `batch`, never as its steps. So a step must never run an action or
/// a shape that the gate stops, or that could ever need consent: the
/// allowlist is closed, and the shapes it refuses stay refused even where the
/// gate would let them through.
enum DesktopBatchPolicy {
    static let maximumSteps = 20
    static let stepCountRange = 1...maximumSteps
    /// Total seconds of a batch, checked before every step against the
    /// elapsed time plus the step's `estimatedDuration`. The runtime ends a
    /// feature call after 180 s, so a batch must end well before that.
    static let timeBudget: Double = 60
    /// Seconds charged for every key event pair, as
    /// `DesktopSafetyPolicy.validateTypingBudget` does.
    static let secondsPerKeyEvent = 0.002

    // MARK: Allowlist

    /// The actions a step may run. Closed: only the actions listed here run in
    /// a step, so an action added to `DesktopAction` stays out of batch until
    /// it is added here on purpose. Every one of them runs without operator
    /// consent in every shape a step accepts (`refusal(of:)` removes the
    /// shapes that would not). wait_for and read_text only read the desktop, so
    /// they are allowed: the runtime gate (`DirectToolExecutor+DesktopGating`)
    /// stops neither.
    static let allowedActions: Set<DesktopAction> = [
        .permissions, .systemInfo, .listApps, .listWindows, .listElements, .readText,
        .pressElement, .focusElement, .setValue,
        .moveMouse, .click, .drag, .scroll, .typeText,
        .activateApp, .hideApp, .unhideApp,
        .focusWindow, .moveWindow, .resizeWindow, .minimizeWindow, .setFullscreen, .closeWindow,
        .readClipboard, .writeClipboard, .wait, .waitFor
    ]

    /// The allowed action names in the order of `DesktopAction`, as the input
    /// schema lists them for `steps.items.action`.
    static var allowedActionNames: [String] {
        DesktopAction.allCases.filter(allowedActions.contains).map(\.rawValue)
    }

    /// Why an action is never allowed in a step; nil for an allowed one.
    static func actionRefusal(_ action: DesktopAction) -> String? {
        guard !allowedActions.contains(action) else { return nil }
        switch action {
        case .batch:
            return "is not allowed in a batch: batches cannot be nested."
        case .open, .launchApp, .terminateApp:
            return "is not allowed in a batch: it may require operator approval, which ZenCODE asks only for a top-level desktop.run call. Call it on its own."
        case .pressKey:
            return "is not allowed in a batch: Return or a shortcut such as Command-Q can submit a command or terminate an app, which must not be hidden from the top-level gate inside a batch. Review and call press_key on its own."
        case .screenshot, .zoom:
            return "is not allowed in a batch: its PNG can be attached only to a top-level desktop.run call. Call it on its own."
        case .requestPermissions:
            return "is not allowed in a batch: it may show macOS consent prompts. Call it on its own."
        default:
            return "is not allowed in a batch. Call it on its own."
        }
    }

    /// Characters a type_text step must not contain: line breaks press Return,
    /// which can submit a command and is gated like local.exec at the top level,
    /// and the other control characters are sent as text that a terminal may
    /// take as a key that submits or edits the line (Control-O runs it in
    /// bash). Tabs stay allowed.
    static func isRefusedInTypedText(_ scalar: Unicode.Scalar) -> Bool {
        if scalar == "\t" { return false }
        if scalar.properties.generalCategory == .control { return true }
        return scalar == "\u{2028}" || scalar == "\u{2029}" || scalar == "\u{85}"
    }

    /// Why a step is refused before the batch runs anything; nil when it may
    /// run. Checks the action against the allowlist, the shapes that are
    /// refused (`steps` in a step, activate_app with launch_if_needed=true,
    /// type_text with line breaks or control characters), and the estimated
    /// duration against the whole time budget.
    static func refusal(of step: DesktopRunInput) -> String? {
        let name = DesktopAction.normalizedName(step.action)
        guard !name.isEmpty else { return "has an empty action." }
        guard let action = DesktopAction(rawValue: name) else { return "has an unsupported action '\(name)'." }
        if let reason = actionRefusal(action) { return "(\(name)) \(reason)" }
        if step.steps != nil {
            return "(\(name)) must not contain steps: only batch uses them, and batches cannot be nested."
        }
        switch action {
        case .activateApp where step.launch_if_needed == true:
            return "(activate_app) must not set launch_if_needed=true in a batch: launching an app may require operator approval. Call launch_app or activate_app on its own."
        case .typeText where step.text?.unicodeScalars.contains(where: isRefusedInTypedText) == true:
            return "(type_text) must not type line breaks or control characters in a batch: a line break presses Return, which may submit a command and requires operator approval. Call type_text on its own, or press_key on its own after it."
        default:
            break
        }
        let estimate = estimatedDuration(step)
        if estimate > timeBudget {
            return "(\(name)) is estimated to take \(seconds(estimate)) s, more than the batch's \(seconds(timeBudget))-second time budget. Call it on its own, or split it."
        }
        return nil
    }

    // MARK: Validation and inheritance

    /// Validates every step before any runs, and returns the steps with the
    /// selectors inherited from the batch. Throws on the first refused step,
    /// naming its 1-based index and the reason; nothing has run then.
    static func plan(_ batch: DesktopRunInput) throws -> [DesktopRunInput] {
        guard let steps = batch.steps else {
            throw DesktopControlError.missingArgument("steps", DesktopAction.batch.rawValue)
        }
        guard stepCountRange.contains(steps.count) else {
            throw DesktopControlError.invalidArgument(
                "steps",
                "must contain between \(stepCountRange.lowerBound) and \(stepCountRange.upperBound) steps (got \(steps.count)); split longer sequences into several batch calls."
            )
        }
        let planned = steps.map { inheriting($0, from: batch) }
        for (offset, step) in planned.enumerated() {
            if let reason = refusal(of: step) {
                throw DesktopControlError.invalidArgument("steps", "step \(offset + 1) of \(planned.count) \(reason)")
            }
        }
        return planned
    }

    /// The step with the selectors of the batch it lacks: pid, bundle_id, and
    /// app_name when the step has none of the three; window_id and title when
    /// the step has none of window_id, title, window_index, and element_ref.
    /// Blank texts count as absent. Nothing else is inherited.
    static func inheriting(_ step: DesktopRunInput, from batch: DesktopRunInput) -> DesktopRunInput {
        var step = step
        if step.pid == nil, step.bundle_id?.nilIfBlank == nil, step.app_name?.nilIfBlank == nil {
            step.pid = batch.pid
            step.bundle_id = batch.bundle_id
            step.app_name = batch.app_name
        }
        if step.window_id == nil, step.title?.nilIfBlank == nil, step.window_index == nil,
           step.element_ref?.nilIfBlank == nil {
            step.window_id = batch.window_id
            step.title = batch.title
        }
        return step
    }

    // MARK: Time budget

    /// The seconds a step takes at least, from its own arguments: the typing
    /// of type_text (characters times interval, default 0.01, plus the cost
    /// of a key event), the duration of wait, the timeout of wait_for and
    /// activate_app (default 5), and the pointer movement of move_mouse,
    /// click, drag, and scroll (duration, default 0.2). No allowed action uses
    /// `delay`. A value that is not a finite positive number counts as zero:
    /// the step then fails on its own validation when it runs.
    static func estimatedDuration(_ step: DesktopRunInput) -> Double {
        func positive(_ value: Double?, default fallback: Double) -> Double {
            let value = value ?? fallback
            return value.isFinite && value > 0 ? value : 0
        }
        switch DesktopAction(rawValue: DesktopAction.normalizedName(step.action)) {
        case .typeText:
            return Double(step.text?.count ?? 0) * (positive(step.interval, default: 0.01) + secondsPerKeyEvent)
        case .wait:
            return positive(step.duration, default: 0)
        case .waitFor:
            return positive(step.timeout, default: DesktopWaitPolicy.defaultTimeout)
        case .activateApp:
            return positive(step.timeout, default: DesktopActivationPolicy.defaultTimeout)
        case .moveMouse, .click, .drag, .scroll:
            return positive(step.duration, default: 0.2)
        default:
            return 0
        }
    }

    /// Whether a step estimated at `estimate` seconds may start after
    /// `elapsed` seconds of the batch: the budget is not used up and the step
    /// fits in what is left.
    static func fitsTimeBudget(estimate: Double, elapsed: Double) -> Bool {
        elapsed < timeBudget && estimate <= timeBudget - elapsed
    }

    // MARK: Step results

    /// Why a batch stopped before its last step.
    enum Stop: Equatable {
        /// A step failed with stop_on_error true.
        case error(index: Int)
        /// The time budget had no room left for the step at `index`.
        case timeBudget(index: Int, elapsed: Double, estimate: Double)

        var index: Int {
            switch self {
            case let .error(index), let .timeBudget(index, _, _): return index
            }
        }
    }

    static func result(index: Int, output: DesktopRunOutput) -> DesktopBatchStepResult {
        DesktopBatchStepResult(
            index: index, action: output.action, ok: true, summary: output.summary, note: output.note,
            permissions: output.permissions, system: output.system,
            element: output.element, focused_element: output.focused_element, app: output.app,
            window: output.window, elements: output.elements, texts: output.texts, windows: output.windows,
            apps: output.apps, clipboard_text: output.clipboard_text, count: output.count, next_offset: output.next_offset
        )
    }

    static func failure(index: Int, action: String, error: any Error) -> DesktopBatchStepResult {
        DesktopBatchStepResult(index: index, action: action, ok: false, error: error.localizedDescription)
    }

    /// A step that did not run because of `stop`.
    static func skipped(index: Int, action: String, stop: Stop) -> DesktopBatchStepResult {
        let note: String
        switch stop {
        case .error(let failed):
            note = "Skipped: step \(failed) failed and stop_on_error is true."
        case let .timeBudget(first, elapsed, estimate) where first == index:
            let left = max(timeBudget - elapsed, 0)
            note = left > 0
                ? "Skipped: \(seconds(left)) s of the batch's \(seconds(timeBudget))-second time budget were left, less than the \(seconds(estimate)) s this step is estimated to take."
                : "Skipped: the batch's \(seconds(timeBudget))-second time budget was used up."
        case .timeBudget(let first, _, _):
            note = "Skipped: the batch stopped at its time budget before step \(first)."
        }
        return DesktopBatchStepResult(index: index, action: action, ok: false, note: note, skipped: true)
    }

    /// "Ran 4 of 4 step(s).", "Ran 5 of 5 step(s); 2 failed (steps 2, 4).",
    /// "Stopped at step 3 of 5 (press_element): <error>; 2 step(s) skipped.",
    /// or "Ran 3 of 5 step(s); stopped before step 4 (wait) at the 60-second
    /// time budget; 2 step(s) skipped."
    static func summary(_ results: [DesktopBatchStepResult], stop: Stop?) -> String {
        let total = results.count
        let skipped = results.filter { $0.skipped == true }.count
        let ran = total - skipped
        let failed = results.filter { $0.skipped != true && !$0.ok }.map(\.index)
        let skippedText = skipped > 0 ? "; \(skipped) step(s) skipped" : ""
        switch stop {
        case let .error(index):
            let step = results.first { $0.index == index }
            var error = step?.error ?? "the step failed"
            if error.hasSuffix(".") { error.removeLast() }
            return "Stopped at step \(index) of \(total) (\(step?.action ?? "step")): \(error)\(skippedText)."
        case let .timeBudget(index, _, _):
            let action = results.first { $0.index == index }?.action ?? "step"
            return "Ran \(ran) of \(total) step(s)\(failedText(failed)); stopped before step \(index) (\(action)) at the \(seconds(timeBudget))-second time budget\(skippedText)."
        case nil:
            return "Ran \(ran) of \(total) step(s)\(failedText(failed))."
        }
    }

    /// The note of a batch that stopped at its time budget; nil otherwise.
    static func timeBudgetNote(_ stop: Stop?) -> String? {
        guard case let .timeBudget(index, _, _) = stop else { return nil }
        return "The batch stopped at its \(seconds(timeBudget))-second time budget before step \(index); run the skipped steps in another call."
    }

    private static func failedText(_ failed: [Int]) -> String {
        guard !failed.isEmpty else { return "" }
        let list = failed.map(String.init).joined(separator: ", ")
        return "; \(failed.count) failed (step\(failed.count == 1 ? "" : "s") \(list))"
    }

    /// "12", "3.5": at most one decimal.
    static func seconds(_ value: Double) -> String {
        let rounded = (value * 10).rounded() / 10
        // Format integral values without Int conversion: a syntactically valid
        // JSON number can exceed Int.max and must still be refused, not trap.
        return rounded == rounded.rounded() ? String(format: "%.0f", rounded) : String(format: "%.1f", rounded)
    }

    // MARK: Response size budget

    /// Text caps of the earlier steps, tried in order after they keep only
    /// their essential fields.
    static let earlierTextCaps = [240, 120, 60]
    /// Text caps of every step, the last resort: 0 removes the text.
    static let textCaps = [240, 120, 60, 30, 0]

    /// The steps reduced until their JSON, measured like the entries of a list
    /// (`DesktopListPaging.encodedLength`), fits `budget`, and the note that
    /// says what was reduced (nil when nothing was). The "last step" is the
    /// last one that ran; the "earlier steps" are all the others. Reductions,
    /// in order, each applied only while the steps do not fit:
    /// 1. elements, texts, windows, and apps of the earlier steps;
    /// 2. the same of the last step;
    /// 3. element and focused_element in compact form, earlier steps first;
    /// 4. window and app of the earlier steps;
    /// 5. the earlier steps keep index, action, ok, summary, error, note, skipped, permissions, and system;
    /// 6. summary, error, and note of the earlier steps shortened (`earlierTextCaps`);
    /// 7. clipboard_text of the last step shortened;
    /// 8. the last step keeps only the same fields as in 5;
    /// 9. summary, error, and note of every step shortened (`textCaps`);
    /// 10. permissions and system omitted only as a last resort. With the
    ///    default budget, 20 steps always fit once their texts are removed.
    static func fitted(
        _ steps: [DesktopBatchStepResult],
        budget: Int = DesktopSafetyPolicy.maximumListPayloadCharacters,
        size: (DesktopBatchStepResult) -> Int = { DesktopListPaging.encodedLength($0) }
    ) -> (steps: [DesktopBatchStepResult], note: String?) {
        var steps = steps
        func total() -> Int { steps.reduce(0) { $0 + size($1) } }
        guard total() > budget else { return (steps, nil) }

        let last = steps.lastIndex { $0.skipped != true }
        let earlier = steps.indices.filter { $0 != last }
        let lastOnly = last.map { [$0] } ?? []
        var reductions: [String] = []

        /// Applies `change` to a copy of each step at `indices` (so `change`
        /// may read `total()`), and records `description` when the steps got
        /// smaller. Returns true once they fit.
        func reduce(_ indices: [Int], _ description: String, _ change: (inout DesktopBatchStepResult) -> Void) -> Bool {
            let before = total()
            for index in indices {
                var step = steps[index]
                change(&step)
                steps[index] = step
            }
            let after = total()
            if after < before, !reductions.contains(description) { reductions.append(description) }
            return after <= budget
        }
        func dropLists(_ step: inout DesktopBatchStepResult) {
            step.elements = nil
            step.texts = nil
            step.windows = nil
            step.apps = nil
        }
        func compactElements(_ step: inout DesktopBatchStepResult) {
            step.element = step.element.map(DesktopElementPolicy.compact)
            step.focused_element = step.focused_element.map(DesktopElementPolicy.compact)
        }
        func dropWindowAndApp(_ step: inout DesktopBatchStepResult) {
            step.window = nil
            step.app = nil
        }
        func essentials(_ step: inout DesktopBatchStepResult) {
            step = DesktopBatchStepResult(
                index: step.index, action: step.action, ok: step.ok, summary: step.summary,
                error: step.error, note: step.note, skipped: step.skipped,
                permissions: step.permissions, system: step.system
            )
        }
        func shortenClipboard(_ step: inout DesktopBatchStepResult) {
            guard let text = step.clipboard_text else { return }
            // Every character removed shortens the JSON by at least one.
            let kept = String(text.prefix(max(text.count - (total() - budget), 0)))
            step.clipboard_text = kept.isEmpty ? nil : kept
        }
        let essentialFields = "only index, action, ok, summary, error, note, skipped, permissions, and system"
        func shortenTexts(_ indices: [Int], caps: [Int]) -> Bool {
            var fits = false
            for cap in caps where !fits {
                fits = reduce(indices, "summaries, errors, and notes were shortened") { step in
                    step.summary = step.summary.flatMap { shortened($0, to: cap) }
                    step.error = step.error.flatMap { shortened($0, to: cap) }
                    step.note = step.note.flatMap { shortened($0, to: cap) }
                }
            }
            return fits
        }

        // Each reduction runs only while the steps still do not fit.
        let fits = reduce(earlier, "the elements, texts, windows, and apps of the earlier steps were omitted", dropLists)
            || reduce(lastOnly, "the elements, texts, windows, and apps of the last step that ran were omitted", dropLists)
            || reduce(earlier, "element and focused_element of the earlier steps are compact", compactElements)
            || reduce(lastOnly, "element and focused_element of the last step that ran are compact", compactElements)
            || reduce(earlier, "window and app of the earlier steps were omitted", dropWindowAndApp)
            || reduce(earlier, "the earlier steps keep \(essentialFields)", essentials)
            || shortenTexts(earlier, caps: earlierTextCaps)
            || reduce(lastOnly, "the clipboard_text of the last step that ran was shortened", shortenClipboard)
            || reduce(lastOnly, "the last step that ran keeps \(essentialFields)", essentials)
            || shortenTexts(Array(steps.indices), caps: textCaps)
        if !fits {
            _ = reduce(Array(steps.indices), "permissions and system information were omitted") { step in
                step.permissions = nil
                step.system = nil
            }
        }
        guard !reductions.isEmpty else { return (steps, nil) }
        return (steps, "The steps were reduced to fit the response size budget: " + reductions.joined(separator: "; ")
            + ". Run a step on its own for its full output.")
    }

    /// `text` cut to `cap` characters with "...", nil for a cap of zero.
    static func shortened(_ text: String, to cap: Int) -> String? {
        guard cap > 0 else { return nil }
        guard text.count > cap else { return text }
        return String(text.prefix(max(cap - 3, 0))) + "..."
    }
}
