//
//  SwiftFeatureInvocationRendering.swift
//  ZenCODE
//
//  Created by Gerardo Grisolini on 03/06/26.
//

import Foundation
import FeatureKit
import ToolCore

struct SwiftFeatureInvocationResult: Sendable {
    let output: String
    let attachments: [AgentRuntimeAttachment]
}

extension SwiftFeatureRuntime {
    static func renderInvocationResult(
        _ result: AsyncProcessResult,
        feature: SwiftFeatureBundle
    ) throws -> String {
        try invocationResult(result, feature: feature).output
    }

    static func invocationResult(
        _ result: AsyncProcessResult,
        feature: SwiftFeatureBundle
    ) throws -> SwiftFeatureInvocationResult {
        guard !result.timedOut else {
            throw DirectToolError.timedOut(
                "Swift feature '\(feature.id)' timed out."
            )
        }

        guard result.exitCode == 0 else {
            throw DirectToolError.processFailed(
                processFailureMessage(result, feature: feature)
            )
        }

        return try invocationResult(result.stdoutData, feature: feature)
    }

    /// Decodes the unchanged invocation envelope returned by an opt-in
    /// persistent feature process. The internal service transport carries these
    /// bytes verbatim, so rendering and attachment validation remain identical
    /// to the historical one-shot path.
    static func invocationResult(
        _ responseData: Data,
        feature: SwiftFeatureBundle
    ) throws -> SwiftFeatureInvocationResult {
        let response: SwiftFeatureInvocationResponse
        do {
            response = try JSONDecoder().decode(
                SwiftFeatureInvocationResponse.self,
                from: responseData
            )
        } catch {
            throw DirectToolError.invalidResponse(
                "Swift feature '\(feature.id)' returned an invalid response: \(error.localizedDescription)"
            )
        }
        guard response.ok else {
            throw DirectToolError.toolFailed(
                response.error?.nilIfBlank
                    ?? "Swift feature '\(feature.id)' returned an error."
            )
        }
        return SwiftFeatureInvocationResult(
            output: renderOutput(response.output),
            attachments: try runtimeAttachments(
                from: response.attachments,
                feature: feature
            )
        )
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

    private static func runtimeAttachments(
        from declarations: [FeatureInvocationAttachment],
        feature: SwiftFeatureBundle
    ) throws -> [AgentRuntimeAttachment] {
        guard declarations.count <= 16 else {
            throw DirectToolError.invalidResponse(
                "Swift feature '\(feature.id)' returned more than 16 attachments."
            )
        }
        return try declarations.map { declaration in
            let expandedPath = NSString(string: declaration.path).expandingTildeInPath
            guard expandedPath.hasPrefix("/") else {
                throw DirectToolError.invalidResponse(
                    "Swift feature '\(feature.id)' returned a non-absolute attachment path."
                )
            }

            let fileURL = URL(fileURLWithPath: expandedPath).standardizedFileURL
            let imported: AgentRuntimeImportedAttachment
            do {
                imported = try AgentRuntimeAttachmentStore.importFile(from: fileURL)
            } catch {
                throw DirectToolError.invalidResponse(
                    "Swift feature '\(feature.id)' returned an unreadable attachment "
                        + "'\(fileURL.lastPathComponent)': \(error.localizedDescription)"
                )
            }

            guard imported.kind.rawValue == declaration.kind.rawValue else {
                throw DirectToolError.invalidResponse(
                    "Swift feature '\(feature.id)' declared attachment "
                        + "'\(fileURL.lastPathComponent)' as \(declaration.kind.rawValue), "
                        + "but its file type is \(imported.kind.rawValue)."
                )
            }

            let declaredContentType = declaration.contentType?.nilIfBlank
            if let declaredContentType,
               !declaredContentType.lowercased().hasPrefix("image/") {
                throw DirectToolError.invalidResponse(
                    "Swift feature '\(feature.id)' declared a non-image content type "
                        + "for image attachment '\(fileURL.lastPathComponent)'."
                )
            }
            let declaredFilename = declaration.originalFilename?.nilIfBlank.map {
                URL(fileURLWithPath: $0).lastPathComponent
            }

            return AgentRuntimeAttachment(
                kind: imported.kind,
                fileURL: imported.fileURL,
                data: imported.payload,
                contentType: declaredContentType ?? imported.contentType,
                originalFilename: declaredFilename ?? imported.originalFilename
            )
        }
    }
}

private struct SwiftFeatureInvocationResponse: Decodable {
    let ok: Bool
    let output: JSONValue?
    let error: String?
    let attachments: [FeatureInvocationAttachment]

    private enum CodingKeys: String, CodingKey {
        case ok, output, error, attachments
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.ok = try container.decode(Bool.self, forKey: .ok)
        self.output = try container.decodeIfPresent(JSONValue.self, forKey: .output)
        self.error = try container.decodeIfPresent(String.self, forKey: .error)
        self.attachments = try container.decodeIfPresent(
            [FeatureInvocationAttachment].self,
            forKey: .attachments
        ) ?? []
    }
}
