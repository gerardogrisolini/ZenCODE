//
//  ZenSleepAssertion.swift
//  ZenCODE
//
//  Created by Gerardo Grisolini on 03/06/26.
//

import Foundation

public final class ZenSleepAssertion {
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
        let activityToEnd = lock.withLock {
            let activityToEnd = activity
            activity = nil
            return activityToEnd
        }

        if let activityToEnd {
            ProcessInfo.processInfo.endActivity(activityToEnd)
        }
        #endif
    }
}
