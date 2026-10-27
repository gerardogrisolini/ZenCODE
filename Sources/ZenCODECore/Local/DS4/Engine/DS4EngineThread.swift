//
//  DS4EngineThread.swift
//  ZenCODE
//
//  One dedicated OS thread per DS4 engine, running submitted jobs in FIFO
//  order. The shim is not thread-safe and keeps per-thread error state, so
//  every C call touching an engine, its sessions or token buffers is made from
//  this thread only (each job reads the error message right after the failing
//  call, on the same thread).
//

import Foundation

final class DS4EngineThread: @unchecked Sendable {
    typealias Job = @Sendable () -> Void

    /// DS4 runs deep C call chains (Metal setup, GGUF parsing, sampling):
    /// give the thread a main-thread-sized stack instead of the 512 KiB default.
    static let defaultStackSize = 16 << 20

    // `condition` guards `jobs`, `isStopping` and `isFinished`.
    private let condition = NSCondition()
    private var jobs: [Job] = []
    private var isStopping = false
    private var isFinished = false

    init(name: String, stackSize: Int = DS4EngineThread.defaultStackSize) {
        let started = DispatchSemaphore(value: 0)
        let thread = Thread { [self] in
            // swift-corelibs-foundation applies the name only after start() has
            // registered the pthread on the calling thread, so wait for start()
            // to return before naming ourselves. On Linux pthread_setname_np
            // rejects (does not truncate) names longer than 15 bytes.
            started.wait()
            Thread.current.name = name
            run()
        }
        thread.name = name
        thread.stackSize = stackSize
        thread.qualityOfService = .userInitiated
        thread.start()
        started.signal()
    }

    /// Enqueues `job`. Returns false (the job is dropped) once `stop()` was called.
    @discardableResult
    func submit(_ job: @escaping Job) -> Bool {
        condition.lock()
        defer { condition.unlock() }
        guard !isStopping else {
            return false
        }
        jobs.append(job)
        condition.signal()
        return true
    }

    /// Rejects new jobs; the thread exits after running the queued ones.
    func stop() {
        condition.lock()
        isStopping = true
        condition.broadcast()
        condition.unlock()
    }

    /// True once `stop()` was called and every queued job has run.
    var hasFinished: Bool {
        condition.lock()
        defer { condition.unlock() }
        return isFinished
    }

    private func run() {
        while true {
            condition.lock()
            while jobs.isEmpty && !isStopping {
                condition.wait()
            }
            if jobs.isEmpty {
                isFinished = true
                condition.broadcast()
                condition.unlock()
                return
            }
            let job = jobs.removeFirst()
            condition.unlock()
            job()
        }
    }
}
