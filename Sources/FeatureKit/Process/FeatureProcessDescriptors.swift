//
//  FeatureProcessDescriptors.swift
//  ZenCODE
//

import Foundation
import Synchronization

#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#endif

/// Descriptor-level mechanics shared by the one-shot runner and the persistent
/// session. Both own parent-side pipe ends that must never block a cooperative
/// executor thread, and both must survive a child that closes a pipe early.
enum FeatureProcessDescriptors {
    /// Writing to a pipe whose reader already exited raises SIGPIPE, whose
    /// default disposition kills ZenCODE itself. Ignore it once — process-wide
    /// and idempotent — so every write path observes `EPIPE` as an ordinary
    /// error instead.
    static func ignoreSIGPIPEOnce() {
        #if canImport(Darwin) || canImport(Glibc) || canImport(Musl)
        let shouldInstall = sigpipeIgnored.withLock { installed -> Bool in
            guard !installed else { return false }
            installed = true
            return true
        }
        if shouldInstall {
            signal(SIGPIPE, SIG_IGN)
        }
        #endif
    }

    /// Best-effort switch to `O_NONBLOCK`. A failure only degrades to the
    /// previous blocking behaviour, so it must not fail the run.
    static func makeNonBlocking(_ descriptor: Int32) {
        #if canImport(Darwin) || canImport(Glibc) || canImport(Musl)
        guard descriptor >= 0 else { return }
        let currentFlags = fcntl(descriptor, F_GETFL)
        guard currentFlags >= 0 else { return }
        _ = fcntl(descriptor, F_SETFL, currentFlags | O_NONBLOCK)
        #else
        _ = descriptor
        #endif
    }

    static func makeNonBlocking(_ handle: FileHandle) {
        makeNonBlocking(handle.fileDescriptor)
    }

    /// Detaches one parent-owned pipe end. Closing is idempotent from the
    /// caller's perspective: a descriptor that is already closed, or a handle
    /// that was never opened, is not an error during teardown.
    static func closeQuietly(_ handle: FileHandle?) {
        guard let handle else { return }
        try? handle.close()
    }

    private static let sigpipeIgnored = Mutex(false)
}
