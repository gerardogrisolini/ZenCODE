//
//  ZenCODESleepAssertion.swift
//  ZenCODE
//
//  Keeps macOS from entering idle system sleep while an ZenCODE session is active.
//
import Foundation
public final class ZenCODESleepAssertion {
    #if os(macOS)
    private let lock = NSLock()
    private var activity: NSObjectProtocol?
    #else
    #endif

    public init(reason: String) {
        #if os(macOS)
        self.activity = ProcessInfo.processInfo.beginActivity(
            options: [
                .idleSystemSleepDisabled,
                .suddenTerminationDisabled
            ],
            reason: reason
        )
        #endif
    }

    deinit {
        invalidate()
    }

    public func invalidate() {
        #if os(macOS)
        let activityToEnd: NSObjectProtocol?
        lock.lock()
        activityToEnd = activity
        activity = nil
        lock.unlock()

        if let activityToEnd {
            ProcessInfo.processInfo.endActivity(activityToEnd)
        }
        #endif
    }
}
