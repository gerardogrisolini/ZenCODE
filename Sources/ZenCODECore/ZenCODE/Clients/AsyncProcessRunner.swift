//
//  AsyncProcessRunner.swift
//  ZenCODE
//
//  Created by Gerardo Grisolini on 26/05/26.
//

import FeatureKit
import Foundation

public struct AsyncProcessResult: Sendable {
    public let exitCode: Int32
    public let stdoutData: Data
    public let stderrData: Data
    public let timedOut: Bool
    public let stdoutWasTruncated: Bool

    public var stdout: String {
        String(decoding: stdoutData, as: UTF8.self)
    }

    public var stderr: String {
        String(decoding: stderrData, as: UTF8.self)
    }
}

/// Compatibility facade for the shared process support owned by `FeatureKit`.
/// Keeping one lifecycle implementation avoids Linux Foundation `Process`
/// termination-handler stalls and guarantees identical pipe, timeout, and
/// cancellation semantics for feature and core callers.
public enum AsyncProcessRunner {
    public static func run(
        executableURL: URL,
        arguments: [String],
        workingDirectory: URL? = nil,
        environment: [String: String]? = nil,
        stdinData: Data? = nil,
        timeout: TimeInterval? = nil,
        stdoutLineLimit: Int? = nil
    ) async throws -> AsyncProcessResult {
        #if os(macOS) || os(Linux)
        let result = try await FeatureProcessRunner.run(
            executableURL: executableURL,
            arguments: arguments,
            workingDirectory: workingDirectory,
            environment: environment,
            stdinData: stdinData,
            timeout: timeout,
            stdoutLineLimit: stdoutLineLimit
        )
        return AsyncProcessResult(
            exitCode: result.exitCode,
            stdoutData: result.stdoutData,
            stderrData: result.stderrData,
            timedOut: result.timedOut,
            stdoutWasTruncated: result.stdoutWasTruncated
        )
        #else
        _ = executableURL
        _ = arguments
        _ = workingDirectory
        _ = environment
        _ = stdinData
        _ = timeout
        _ = stdoutLineLimit
        throw AsyncProcessRunnerError.unsupportedPlatform
        #endif
    }
}

public enum AsyncProcessRunnerError: LocalizedError, Sendable {
    case unsupportedPlatform

    public var errorDescription: String? {
        switch self {
        case .unsupportedPlatform:
            return "Local process execution is unavailable on this platform."
        }
    }
}
