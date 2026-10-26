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
        let thread = Thread { [self] in
            // swift-corelibs-foundation applies a name only to the running
            // thread (Linux keeps at most 15 bytes); set it from inside so the
            // name is visible on every platform.
            Thread.current.name = name
            run()
        }
        thread.name = name
        thread.stackSize = stackSize
        thread.qualityOfService = .userInitiated
        thread.start()
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
