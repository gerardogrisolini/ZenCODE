//
//  RemoteNetworkErrorClassifier.swift
//  ZenCODE
//

import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Classifies URLSession-era network errors for retry and cancellation
/// decisions in provider request paths that still inspect `URLError`.
enum RemoteNetworkErrorClassifier {
    static func isRetryableNetworkError(_ error: Error) -> Bool {
        if let urlError = error as? URLError {
            return isRetryableNetworkCode(urlError.code)
        }

        let nsError = error as NSError
        guard nsError.domain == NSURLErrorDomain else {
            return false
        }
#if canImport(FoundationNetworking)
        guard let code = URLError.Code(rawValue: nsError.code) else {
            return false
        }
        return isRetryableNetworkCode(code)
#else
        return isRetryableNetworkCode(
            URLError.Code(rawValue: nsError.code)
        )
#endif
    }

    static func isCancellationError(_ error: Error) -> Bool {
        let nsError = error as NSError
        return nsError.domain == NSURLErrorDomain
            && nsError.code == URLError.cancelled.rawValue
    }

    private static func isRetryableNetworkCode(
        _ code: URLError.Code
    ) -> Bool {
        switch code {
        case .timedOut,
             .cannotFindHost,
             .cannotConnectToHost,
             .networkConnectionLost,
             .dnsLookupFailed,
             .notConnectedToInternet,
             .resourceUnavailable:
            return true
        default:
            return false
        }
    }
}
