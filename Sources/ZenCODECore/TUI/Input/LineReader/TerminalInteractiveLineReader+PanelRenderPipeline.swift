//
//  TerminalInteractiveLineReader+PanelRenderPipeline.swift
//  ZenCODE
//

extension TerminalInteractiveLineReader {
    /// A complete, immutable prompt projection waiting to reach the status bar.
    ///
    /// The input reducer publishes these under ``state``'s mutex, while one
    /// asynchronous render task consumes them outside the mutex. Keeping the whole
    /// projection together prevents a slow terminal repaint from observing a
    /// hybrid of two edits.
    struct PanelRenderSnapshot: Sendable {
        let statusBar: TerminalStatusBar?
        let text: String
        let cursorIndex: Int
        let modeText: String
        let helpText: String
        let compactHelpText: String?
        let prioritizesModeText: Bool
        let suggestionLines: [String]
        let suggestionSelectedIndex: Int?
        let revision: UInt64
    }

    /// The input panel's single-renderer pipeline, as a pure value.
    ///
    /// ``State`` owns one instance under the reader's mutex, next to the draft
    /// it projects. Every transition is synchronous: it never locks, awaits or
    /// resumes anything. It returns what the caller must do once the lock is
    /// released (start the renderer task, or resume the waiters it hands back),
    /// so the reader keeps resuming continuations outside the mutex and the
    /// pipeline can be exercised on its own with any waiter type.
    struct PanelRenderPipeline<Waiter> {
        /// Completion boundary for one explicit refresh. A newer coalesced frame
        /// also satisfies an older waiter because it contains a later projection
        /// of the same reader state.
        struct RevisionWaiter {
            let revision: UInt64
            let waiter: Waiter
        }

        /// Last revision handed out, to a frame or to a stop.
        private(set) var revision: UInt64 = 0
        /// At most one task sends prompt snapshots to the status-bar actor.
        /// Producers replace ``pending`` while that task awaits a slow redraw,
        /// keeping input acquisition independent of repaint latency.
        private(set) var isRenderInFlight = false
        private(set) var pending: PanelRenderSnapshot?
        /// Highest revision applied by the renderer, or invalidated by a stop.
        private(set) var completedRevision: UInt64 = 0
        /// Explicit refresh callers wait only for their own revision (or a newer
        /// coalesced one), never for the continuously changing queue to go idle.
        private(set) var revisionWaiters: [RevisionWaiter] = []
        /// Lifecycle teardown still needs the renderer itself to stop before the
        /// terminal is handed to another interactive reader.
        private(set) var drainWaiters: [Waiter] = []

        /// Hands out the revision of the next frame.
        mutating func nextRevision() -> UInt64 {
            revision &+= 1
            return revision
        }

        /// Publishes `snapshot` as the one pending frame, replacing an older
        /// one. Returns `true` when no renderer is running: the caller must start
        /// one, which the pipeline counts as in flight from now on.
        mutating func enqueue(_ snapshot: PanelRenderSnapshot) -> Bool {
            pending = snapshot
            guard !isRenderInFlight else {
                return false
            }
            isRenderInFlight = true
            return true
        }

        /// Removes one immutable frame for the renderer. Clearing the in-flight
        /// flag in the same transition that observes an empty queue prevents a
        /// producer from leaving a frame stranded between the check and task
        /// completion; the drain waiters released by it are returned with `nil`.
        mutating func takeNext() -> (snapshot: PanelRenderSnapshot?, drainWaiters: [Waiter]) {
            if let snapshot = pending {
                pending = nil
                return (snapshot, [])
            }
            isRenderInFlight = false
            let waiters = drainWaiters
            drainWaiters.removeAll()
            return (nil, waiters)
        }

        /// Marks a snapshot applied and returns only the explicit refreshes that
        /// it satisfies. A coalesced newer snapshot deliberately completes
        /// waiters for every older revision it replaced.
        mutating func complete(revision: UInt64) -> [Waiter] {
            completedRevision = max(completedRevision, revision)
            var remaining: [RevisionWaiter] = []
            var completed: [Waiter] = []
            for waiter in revisionWaiters {
                if waiter.revision <= completedRevision {
                    completed.append(waiter.waiter)
                } else {
                    remaining.append(waiter)
                }
            }
            revisionWaiters = remaining
            return completed
        }

        /// Parks `waiter` until `revision` has been applied or superseded.
        /// Returns `true`, keeping nothing, when that already happened: the
        /// caller resumes `waiter` at once.
        mutating func registerRevisionWaiter(_ waiter: Waiter, revision: UInt64) -> Bool {
            guard completedRevision < revision else {
                return true
            }
            revisionWaiters.append(RevisionWaiter(revision: revision, waiter: waiter))
            return false
        }

        /// Parks `waiter` until the renderer has nothing left to apply. Returns
        /// `true`, keeping nothing, when it is already idle: the caller resumes
        /// `waiter` at once.
        mutating func registerDrainWaiter(_ waiter: Waiter) -> Bool {
            guard isRenderInFlight || pending != nil else {
                return true
            }
            drainWaiters.append(waiter)
            return false
        }

        /// Invalidates the session a stop tears down: hands out a fencing
        /// revision, discards the queued frame and returns every explicit
        /// refresh, whose revision can no longer be applied. The frame already
        /// owned by the renderer is left to it, and so are the drain waiters.
        mutating func invalidateForStop() -> (revision: UInt64, waiters: [Waiter]) {
            let stopRevision = nextRevision()
            pending = nil
            completedRevision = stopRevision
            let waiters = revisionWaiters.map(\.waiter)
            revisionWaiters.removeAll()
            return (stopRevision, waiters)
        }
    }
}
