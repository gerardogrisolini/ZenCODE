//
//  TerminalRawInput+ForegroundTerminal.swift
//  ZenCODE
//
//  Job-control helpers of the raw input: claiming the foreground process
//  group of the terminal and reclaiming it from a stale owner.
//

#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif
import Dispatch
import Foundation
import Synchronization

extension TerminalRawInput {
    private static func setForegroundProcessGroup(
        _ processGroup: Int32,
        fileDescriptor: Int32
    ) -> Bool {
        guard withSIGTTOUBlocked({ tcsetpgrp(fileDescriptor, processGroup) == 0 }) == true else {
            return false
        }
        return tcgetpgrp(fileDescriptor) == processGroup
    }

    static func shouldReclaimForegroundTerminal(
        foregroundProcessGroup: Int32,
        currentProcessGroup: Int32,
        foregroundProcessGroupExists: Bool
    ) -> Bool {
        foregroundProcessGroup != currentProcessGroup
            && !foregroundProcessGroupExists
    }

    private static func processGroupExists(_ processGroup: Int32) -> Bool {
        guard processGroup > 0 else {
            return false
        }
        if kill(-processGroup, 0) == 0 {
            return true
        }
        // EPERM still proves that the process group exists. Only ESRCH makes a
        // foreground owner stale enough for ZenCODE to reclaim safely.
        return errno != ESRCH
    }

    static func ensureForegroundTerminal(fileDescriptor: Int32) -> Bool {
        guard isTerminalDevice(fileDescriptor: fileDescriptor) else {
            return false
        }

        let foregroundProcessGroup = tcgetpgrp(fileDescriptor)
        guard foregroundProcessGroup >= 0 else {
            return false
        }

        let currentProcessGroup = getpgrp()
        guard foregroundProcessGroup != currentProcessGroup else {
            return true
        }
        guard shouldReclaimForegroundTerminal(
            foregroundProcessGroup: foregroundProcessGroup,
            currentProcessGroup: currentProcessGroup,
            foregroundProcessGroupExists: processGroupExists(foregroundProcessGroup)
        ) else {
            // A live process group owns the terminal. Job control requires this
            // background reader to stand down rather than stealing foreground.
            return false
        }
        return setForegroundProcessGroup(
            currentProcessGroup,
            fileDescriptor: fileDescriptor
        )
    }

    /// Recovers only a foreground process group that no longer has any members.
    /// Callers gate this behind EIO so an ordinary hand-off to a live child is
    /// never pre-empted by the TUI's polling loop.
    static func reclaimStaleForegroundTerminalIfNeeded(fileDescriptor: Int32) -> Bool {
        guard isTerminalDevice(fileDescriptor: fileDescriptor) else {
            return false
        }
        let foregroundProcessGroup = tcgetpgrp(fileDescriptor)
        guard foregroundProcessGroup >= 0 else {
            return false
        }
        let currentProcessGroup = getpgrp()
        guard shouldReclaimForegroundTerminal(
            foregroundProcessGroup: foregroundProcessGroup,
            currentProcessGroup: currentProcessGroup,
            foregroundProcessGroupExists: processGroupExists(foregroundProcessGroup)
        ) else {
            return false
        }
        return setForegroundProcessGroup(
            currentProcessGroup,
            fileDescriptor: fileDescriptor
        )
    }
}
