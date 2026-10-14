// Per-turn structured output collection shared by terminal and ACP.

actor PlanningPointCollector {
    private var points: [TerminalSessionPlanPoint] = []
    private var completedPlan: TerminalSessionPlan?
    private var observedTodoWriteCount = 0
    private var hasInvalidTodoWrite = false
    private var derivedFinalPoints: [TerminalSessionPlanPoint]?

    func recordTodoWrite(
        _ update: (
            points: [TerminalSessionPlanPoint],
            mode: DirectTodoTaskRuntime.TodoWriteMode
        )?
    ) {
        observedTodoWriteCount += 1
        guard let update, case .upsert = update.mode else {
            hasInvalidTodoWrite = true
            return
        }
        apply(update.points, mode: update.mode)
    }

    func hasObservedTodoWrites() -> Bool {
        observedTodoWriteCount > 0
    }

    func validFinalPlanPoints() -> [TerminalSessionPlanPoint]? {
        guard observedTodoWriteCount == 1,
              !hasInvalidTodoWrite,
              !points.isEmpty else {
            return nil
        }
        return points
    }

    /// Resolves the final structured plan points for a Planner turn, shared by
    /// the terminal TUI and the ACP bridge so both surfaces behave identically.
    ///
    /// Registered points (a single valid `todo.write`) keep priority and are
    /// still required to be coherent with the final text. When the coordinator
    /// emitted **no** `todo.write` at all, the points are derived from the final
    /// text itself, but only if that text is rigorously valid. A `todo.write`
    /// that was malformed, in the wrong mode, or repeated remains a hard
    /// failure: no fallback is attempted in that case.
    func finalPlanPoints(forFinalText text: String) -> [TerminalSessionPlanPoint]? {
        if observedTodoWriteCount > 0 {
            guard let registered = validFinalPlanPoints(),
                  PlanningCommandKernel.structuredPlanOutputIsCoherent(
                      text: text,
                      points: registered
                  ) else {
                return nil
            }
            return registered
        }
        if let derivedFinalPoints,
           PlanningCommandKernel.structuredPlanOutputIsCoherent(
               text: text,
               points: derivedFinalPoints
           ) {
            return derivedFinalPoints
        }
        guard let derived = PlanningCommandKernel.planPoints(
            derivedFromFinalText: text
        ) else {
            return nil
        }
        derivedFinalPoints = derived
        points = derived
        return derived
    }

    func apply(
        _ updates: [TerminalSessionPlanPoint],
        mode: DirectTodoTaskRuntime.TodoWriteMode
    ) {
        switch mode {
        case .replace:
            points = updates
        case .append:
            points.append(contentsOf: updates)
        case .upsert:
            var pointsByID = Dictionary(
                points.map { ($0.id, $0) },
                uniquingKeysWith: { current, _ in current }
            )
            for point in updates {
                pointsByID[point.id] = point
            }
            points = DirectTodoTaskRuntime.orderedValues(
                from: pointsByID,
                preserving: points.map(\.id) + updates.map(\.id)
            )
        }
    }

    func snapshot() -> [TerminalSessionPlanPoint] {
        points
    }

    func recordAutomaticCompletion(_ plan: TerminalSessionPlan) {
        completedPlan = plan
    }

    func automaticallyCompletedPlan() -> TerminalSessionPlan? {
        completedPlan
    }
}
