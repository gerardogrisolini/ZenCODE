//
//  MemoryPersistenceExecutor.swift
//  ZenCODE
//
//  The dedicated serial executor `JSONMemoryPersistence` runs on, so its
//  blocking `flock` waits and file I/O never park the cooperative pool.
//

import Dispatch

/// The serial executor of one `JSONMemoryPersistence`, backed by a private
/// serial dispatch queue.
///
/// The persistence holds the graph's `flock` and performs synchronous file I/O
/// inside its isolated methods, and `flock(LOCK_EX)` blocks until the current
/// holder — possibly another ZenCODE process in the middle of a long
/// transaction — releases the lock. On the default actor executor that wait
/// parks a worker of Swift's cooperative pool, which has one worker per core
/// and never grows: a handful of concurrent waiters stall every unrelated task
/// of the process for as long as the lock is held (on Darwin, observed to
/// starve the constrained global dispatch queues as well). Running the actor
/// on its own queue moves the wait and the I/O to a dispatch thread and leaves
/// the cooperative pool free.
///
/// Actor semantics are unchanged: the queue is serial, so the actor's jobs
/// still run one at a time and in order, the persistence adds no suspension
/// point, and a job runs as its task (cancellation, task-locals and
/// `Task.checkCancellation()` behave exactly as on the default executor).
///
/// One queue per persistence instance is deliberate and cheap. A serial queue
/// owns no thread: GCD lends one from its process-wide pool only while a job
/// runs and takes it back afterwards. Serial queues target GCD's overcommitting
/// root queues, so a queue blocked in `flock` never keeps another one from
/// getting a thread. In production `MemoryGraphStoreRegistry` keeps a single
/// store, and therefore a single persistence, per graph URL — the workspace
/// graphs in use plus the global graph — so at most that many threads ever
/// wait on a lock at once. A queue shared by every instance would instead make
/// each graph wait behind another graph's lock.
///
/// The queue has no QoS of its own and `enqueue` ignores `job.priority`, so a
/// job runs at the QoS GCD propagates from the thread that enqueued it, not at
/// the priority of the task that owns the job. Unlike the default actor
/// executor, the actor also gets no priority escalation: the runtime does not
/// raise the priority of work already queued ahead of a higher-priority task.
/// The impact is low, because the work is bounded by I/O (and by `flock` waits
/// on other processes) rather than by CPU.
final class MemoryPersistenceSerialExecutor: SerialExecutor {
    private let queue: DispatchQueue

    init(label: String) {
        queue = DispatchQueue(label: label)
    }

    func enqueue(_ job: consuming ExecutorJob) {
        let unownedJob = UnownedJob(job)
        queue.async { [self] in
            unownedJob.runSynchronously(on: asUnownedSerialExecutor())
        }
    }
}
