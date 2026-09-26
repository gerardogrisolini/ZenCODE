//
//  SwiftFeaturePackageMaterializer.swift
//  ZenCODE
//
//  Shared manifest policy for feature package materialization.
//

import Foundation
import ToolCore

enum SwiftFeaturePackageManifestPolicy: Sendable {
    case markerRequired
    case promotionCompatible
}

/// Internal manifest rewriter shared by optional installation and promotion.
/// The policies are intentionally explicit: installation is strict, while
/// promotion retains its deterministic legacy fallback for old Builder
/// scaffolds.
enum SwiftFeaturePackageMaterializer {
    static func rewriteZenPackagePath(
        _ contents: String,
        zenPackagePath: String,
        packageURL: URL,
        policy: SwiftFeaturePackageManifestPolicy
    ) throws -> String {
        switch policy {
        case .markerRequired:
            return try rewriteMarkedDependency(
                contents,
                zenPackagePath: zenPackagePath,
                packageURL: packageURL,
                acceptsNamedPackage: false
            )
        case .promotionCompatible:
            return try rewritePromotionDependency(
                contents,
                zenPackagePath: zenPackagePath,
                packageURL: packageURL
            )
        }
    }

    private static func rewriteMarkedDependency(
        _ contents: String,
        zenPackagePath: String,
        packageURL: URL,
        acceptsNamedPackage: Bool
    ) throws -> String {
        var lines = contents.components(separatedBy: "\n")
        guard let markerIndex = lines.firstIndex(where: {
            $0.trimmingCharacters(in: .whitespaces) == SwiftFeatureRuntime.zenPackagePathMarker
        }) else {
            throw DirectToolError.permissionDenied(
                """
                \(packageURL.path) does not declare the '\(SwiftFeatureRuntime.zenPackagePathMarker)' marker \
                before its ZenCODE '.package(path:)' dependency.
                """
            )
        }

        var dependencyIndex = markerIndex + 1
        while dependencyIndex < lines.count,
              lines[dependencyIndex].trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            dependencyIndex += 1
        }
        guard dependencyIndex < lines.count,
              let rewritten = rewrittenPackagePathLine(
                  lines[dependencyIndex],
                  zenPackagePath: zenPackagePath,
                  acceptsNamedPackage: acceptsNamedPackage
              ) else {
            throw DirectToolError.permissionDenied(
                """
                \(packageURL.path) must declare a '.package(path: \"…\")' dependency \
                on the line following '\(SwiftFeatureRuntime.zenPackagePathMarker)'.
                """
            )
        }
        lines[dependencyIndex] = rewritten
        return lines.joined(separator: "\n")
    }

    private static func rewritePromotionDependency(
        _ contents: String,
        zenPackagePath: String,
        packageURL: URL
    ) throws -> String {
        let marker = SwiftFeatureRuntime.zenPackagePathMarker
        if contents.components(separatedBy: "\n").contains(where: {
            $0.trimmingCharacters(in: .whitespaces) == marker
        }) {
            var lines = contents.components(separatedBy: "\n")
            guard let markerIndex = lines.firstIndex(where: {
                $0.trimmingCharacters(in: .whitespaces) == marker
            }) else { return contents }
            var dependencyIndex = markerIndex + 1
            while dependencyIndex < lines.count,
                  lines[dependencyIndex].trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                dependencyIndex += 1
            }
            guard dependencyIndex < lines.count,
                  let rewritten = rewrittenPackagePathLine(
                      lines[dependencyIndex],
                      zenPackagePath: zenPackagePath,
                      acceptsNamedPackage: true
                  ) else {
                throw DirectToolError.permissionDenied(
                    "\(packageURL.path) must declare .package(path:) after the package-path marker."
                )
            }
            lines[dependencyIndex] = rewritten
            return lines.joined(separator: "\n")
        }

        let pattern = #"(?m)^(\s*)(\.package\(\s*path:\s*\"(?:[^\"\\]|\\.)*\"\s*\).*?)$"#
        guard let expression = try? NSRegularExpression(pattern: pattern) else {
            throw DirectToolError.permissionDenied("Could not inspect \(packageURL.path).")
        }
        let range = NSRange(contents.startIndex..<contents.endIndex, in: contents)
        let matches = expression.matches(in: contents, range: range)
        guard matches.count == 1,
              let match = matches.first,
              let fullRange = Range(match.range(at: 0), in: contents),
              let indentRange = Range(match.range(at: 1), in: contents) else {
            throw DirectToolError.permissionDenied(
                "\(packageURL.path) must contain the package-path marker or exactly one local .package(path:) dependency."
            )
        }
        let indent = contents[indentRange]
        let replacement = "\(indent)\(marker)\n\(indent).package(name: \"ZenCODE\", path: \(swiftStringLiteral(zenPackagePath)))"
        return contents.replacingCharacters(in: fullRange, with: replacement)
    }

    private static func rewrittenPackagePathLine(
        _ line: String,
        zenPackagePath: String,
        acceptsNamedPackage: Bool
    ) -> String? {
        let regexPrefix = acceptsNamedPackage
            ? #"(?:name:\s*\"ZenCODE\"\s*,\s*)?"#
            : ""
        let pattern = "^(\\s*)\\.package\\(\\s*\(regexPrefix)path:\\s*\"(?:[^\"\\\\]|\\\\.)*\"\\s*\\)(.*)$"
        guard let expression = try? NSRegularExpression(pattern: pattern),
              let match = expression.firstMatch(
                  in: line,
                  range: NSRange(line.startIndex..<line.endIndex, in: line)
              ),
              let indentRange = Range(match.range(at: 1), in: line),
              let trailingRange = Range(match.range(at: 2), in: line) else {
            return nil
        }
        let outputPrefix = acceptsNamedPackage
            ? ".package(name: \"ZenCODE\", path: "
            : ".package(path: "
        return line[indentRange]
            + outputPrefix
            + swiftStringLiteral(zenPackagePath)
            + ")"
            + line[trailingRange]
    }

    private static func swiftStringLiteral(_ value: String) -> String {
        "\"" + value.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }
}
