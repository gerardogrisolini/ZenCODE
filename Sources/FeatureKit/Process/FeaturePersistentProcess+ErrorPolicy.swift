//
//  FeaturePersistentProcess+ErrorPolicy.swift
//  ZenCODE
//
//  Decides which transport failures invalidate the child process of a
//  persistent feature session.
//

import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#endif

extension FeaturePersistentProcess {
    func shouldInvalidate(after error: Error) -> Bool {
        guard let transportError = error as? FeaturePersistentProcessError else {
            return true
        }
        switch transportError.kind {
        case .remote:
            return false
        case .unavailable, .closed, .timedOut, .malformedResponse:
            return true
        }
    }
}
