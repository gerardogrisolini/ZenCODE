//
//  RemoteProviderSessionCompatibility.swift
//  ZenCODE
//
//  Created by Gerardo Grisolini on 20/07/26.
//

import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Source-compatible name for the historical provider session parameter and
/// property. It is retained for embedders that inspect or inject that value;
/// HTTP/SSE/WebSocket requests always use `RemoteTransportCore` instead.
public typealias RemoteProviderSession = URLSession

enum RemoteProviderSessionCompatibility {
    static func generationSession() -> RemoteProviderSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 900
        configuration.timeoutIntervalForResource = 900
        return RemoteProviderSession(configuration: configuration)
    }

    static func isRetryableLegacyNetworkError(_ error: Error) -> Bool {
        if let urlError = error as? URLError {
            return isRetryableLegacyNetworkCode(urlError.code)
        }

        let nsError = error as NSError
        guard nsError.domain == NSURLErrorDomain else {
            return false
        }
#if canImport(FoundationNetworking)
        guard let code = URLError.Code(rawValue: nsError.code) else {
            return false
        }
        return isRetryableLegacyNetworkCode(code)
#else
        return isRetryableLegacyNetworkCode(
            URLError.Code(rawValue: nsError.code)
        )
#endif
    }

    static func isLegacyCancellationError(_ error: Error) -> Bool {
        let nsError = error as NSError
        return nsError.domain == NSURLErrorDomain
            && nsError.code == URLError.cancelled.rawValue
    }

    private static func isRetryableLegacyNetworkCode(
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
