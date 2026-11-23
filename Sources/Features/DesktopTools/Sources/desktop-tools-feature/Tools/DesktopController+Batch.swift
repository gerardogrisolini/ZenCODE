import FeatureKit
import Foundation

/// batch: runs its steps in order through `execute`, so every step gets the
/// same validation and protections as a call of its own, including the
/// host-app policy. The rules live in the pure `DesktopBatchPolicy`.
extension DesktopController {
    static func runBatch(_ input: DesktopRunInput, context: FeatureContext, action: String) async throws -> DesktopRunOutput {
        // Every step's action and batch safety policy are checked before any
        // runs: a refused step throws here. Action-specific argument validation
        // still runs in DesktopController.execute when the step is reached.
        let steps = try DesktopBatchPolicy.plan(input)
        let stopOnError = input.stop_on_error ?? true
        let clock = ContinuousClock()
        let start = clock.now
        var results: [DesktopBatchStepResult] = []
        var stop: DesktopBatchPolicy.Stop?

        for (offset, step) in steps.enumerated() {
            let index = offset + 1
            let name = DesktopAction.normalizedName(step.action)
            if let stop {
                results.append(DesktopBatchPolicy.skipped(index: index, action: name, stop: stop))
                continue
            }
            try Task.checkCancellation()
            let elapsed = seconds(start.duration(to: clock.now))
            let estimate = DesktopBatchPolicy.estimatedDuration(step)
            guard DesktopBatchPolicy.fitsTimeBudget(estimate: estimate, elapsed: elapsed) else {
                let budgetStop = DesktopBatchPolicy.Stop.timeBudget(index: index, elapsed: elapsed, estimate: estimate)
                stop = budgetStop
                results.append(DesktopBatchPolicy.skipped(index: index, action: name, stop: budgetStop))
                continue
            }
            do {
                results.append(DesktopBatchPolicy.result(index: index, output: try await execute(step, context: context)))
            } catch let cancellation as CancellationError {
                throw cancellation
            } catch {
                // A failed step does not fail the batch: it is reported in its result.
                results.append(DesktopBatchPolicy.failure(index: index, action: name, error: error))
                if stopOnError { stop = .error(index: index) }
            }
        }

        let fitted = DesktopBatchPolicy.fitted(results)
        return DesktopRunOutput(
            action: action,
            summary: DesktopBatchPolicy.summary(results, stop: stop),
            note: DesktopListPaging.joined([DesktopBatchPolicy.timeBudgetNote(stop), fitted.note]),
            steps: fitted.steps
        )
    }
}
