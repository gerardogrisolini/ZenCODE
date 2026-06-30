//
//  SwiftFeatureInvocationRendering.swift
//  ZenCODE
//
//  Created by Gerardo Grisolini on 03/06/26.
//
import Foundation

extension SwiftFeatureRuntime {
    static func renderInvocationResult(
        _ result: AsyncProcessResult,
        feature: SwiftFeatureBundle
    ) throws -> String {
        guard !result.timedOut else {
            throw DirectToolError.permissionDenied(
                "Swift feature '\(feature.id)' timed out."
            )
        }

        guard result.exitCode == 0 else {
            throw DirectToolError.permissionDenied(
                processFailureMessage(result, feature: feature)
            )
        }

        let response = try JSONDecoder().decode(
            SwiftFeatureInvocationResponse.self,
            from: result.stdoutData
        )
        guard response.ok else {
            throw DirectToolError.permissionDenied(
                response.error?.nilIfBlank
                    ?? "Swift feature '\(feature.id)' returned an error."
            )
        }
        return renderOutput(response.output)
    }

    private static func processFailureMessage(
        _ result: AsyncProcessResult,
        feature: SwiftFeatureBundle
    ) -> String {
        var lines = [
            "Swift feature '\(feature.id)' failed with exit code \(result.exitCode)."
        ]
        if let stdout = result.stdout.nilIfBlank {
            lines.append("stdout:\n\(stdout)")
        }
        if let stderr = result.stderr.nilIfBlank {
            lines.append("stderr:\n\(stderr)")
        }
        return lines.joined(separator: "\n")
    }

    private static func renderOutput(_ output: JSONValue?) -> String {
        guard let output else {
            return "<no output>"
        }
        switch output {
        case let .string(value):
            return value
        case let .number(value):
            return "\(value)"
        case let .bool(value):
            return "\(value)"
        case .null:
            return "null"
        case .array, .object:
            return output.prettyPrinted()
        }
    }
}

private struct SwiftFeatureInvocationResponse: Decodable {
    let ok: Bool
    let output: JSONValue?
    let error: String?
}
