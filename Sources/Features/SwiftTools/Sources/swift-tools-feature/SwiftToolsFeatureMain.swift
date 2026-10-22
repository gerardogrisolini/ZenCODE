//
//  SwiftToolsFeatureMain.swift
//  ZenCODE
//
//  Created by Gerardo Grisolini on 31/05/26.
//

import ToolCore
import Foundation
import FeatureKit

struct SwiftBuildTool: FeatureTool {
    struct Input: Decodable, Sendable {
        let path: String?
        let workingDirectory: String?
        let target: String?
        let product: String?
        let configuration: String?
        let timeoutSeconds: Int?
        let timeout: Int?
    }

    static let name = "swift.build"
    static let description = "Builds a SwiftPM package with `swift build` and returns a structured summary of errors and warnings instead of raw output."
    static let inputSchema = buildInputSchema(
        CommonSchemaProperties.workingDirectory
            + CommonSchemaProperties.buildTarget
            + CommonSchemaProperties.configuration
            + CommonSchemaProperties.timeout
    )

    func run(_ input: Input, context: FeatureContext) async throws -> String {
        var args = ["build"]
        if let configuration = input.configuration?.nilIfBlank {
            args.append(contentsOf: ["-c", try SwiftToolsSupport.optionValue(configuration, named: "configuration")])
        }
        if let target = input.target?.nilIfBlank {
            args.append(contentsOf: ["--target", try SwiftToolsSupport.optionValue(target, named: "target")])
        }
        if let product = input.product?.nilIfBlank {
            args.append(contentsOf: ["--product", try SwiftToolsSupport.optionValue(product, named: "product")])
        }
        let result = try await SwiftToolsSupport.execute(
            args, path: input.path, workingDirectory: input.workingDirectory,
            timeout: input.timeoutSeconds ?? input.timeout, defaultTimeout: 900, context: context
        )
        return SwiftToolsSupport.renderBuildResult(result, command: SwiftToolsSupport.renderCommand(["swift"] + args))
    }
}

struct SwiftTestTool: FeatureTool {
    struct Input: Decodable, Sendable {
        let path: String?
        let workingDirectory: String?
        let filter: String?
        let target: String?
        let configuration: String?
        let arguments: [String]?
        let args: [String]?
        let timeoutSeconds: Int?
        let timeout: Int?
    }

    static let name = "swift.test"
    static let description = "Runs SwiftPM tests with `swift test` and returns a bounded structured summary of failures, diagnostics, exit code, timeout, and truncation state. Pass additional argv such as --no-parallel in arguments."
    static let inputSchema = buildInputSchema(
        CommonSchemaProperties.workingDirectory
            + CommonSchemaProperties.filter
            + CommonSchemaProperties.configuration
            + [
                .array("arguments", description: "Additional SwiftPM arguments passed as argv without shell interpretation, for example [\"--no-parallel\"]."),
                .array("args", description: "Alias for arguments."),
            ]
            + CommonSchemaProperties.timeout
    )

    func run(_ input: Input, context: FeatureContext) async throws -> String {
        var args = ["test"]
        if let configuration = input.configuration?.nilIfBlank {
            args.append(contentsOf: ["-c", try SwiftToolsSupport.optionValue(configuration, named: "configuration")])
        }
        if let filter = (input.filter?.nilIfBlank ?? input.target?.nilIfBlank) {
            args.append(contentsOf: ["--filter", try SwiftToolsSupport.optionValue(filter, named: "filter")])
        }
        args.append(contentsOf: SwiftToolsSupport.additionalArguments(input.arguments ?? input.args))
        let result = try await SwiftToolsSupport.execute(
            args, path: input.path, workingDirectory: input.workingDirectory,
            timeout: input.timeoutSeconds ?? input.timeout, defaultTimeout: 1200, context: context
        )
        return SwiftToolsSupport.renderTestResult(
            result,
            command: SwiftToolsSupport.renderCommand(["swift"] + args)
        )
    }
}

struct SwiftRunTool: FeatureTool {
    struct Input: Decodable, Sendable {
        let path: String?
        let workingDirectory: String?
        let executable: String?
        let product: String?
        let configuration: String?
        let arguments: [String]?
        let args: [String]?
        let timeoutSeconds: Int?
        let timeout: Int?
    }

    static let name = "swift.run"
    static let description = "Builds if needed and runs an executable product of a SwiftPM package with `swift run`. Pass executable and optional arguments. Returns build diagnostics plus the program output."
    static let inputSchema = buildInputSchema(
        CommonSchemaProperties.workingDirectory
            + [.string("executable"), .string("product")]
            + CommonSchemaProperties.configuration
            + [.array("arguments"), .array("args")]
            + CommonSchemaProperties.timeout
    )

    func run(_ input: Input, context: FeatureContext) async throws -> String {
        let args = try Self.arguments(for: input)
        let result = try await SwiftToolsSupport.execute(
            args, path: input.path, workingDirectory: input.workingDirectory,
            timeout: input.timeoutSeconds ?? input.timeout, defaultTimeout: 900, context: context
        )
        return SwiftToolsSupport.renderRunResult(result, command: SwiftToolsSupport.renderCommand(["swift"] + args))
    }

    static func arguments(for input: Input) throws -> [String] {
        var args = ["run"]
        if let configuration = input.configuration?.nilIfBlank {
            args.append(contentsOf: ["-c", try SwiftToolsSupport.optionValue(configuration, named: "configuration")])
        }
        if let executable = (input.executable ?? input.product)?.nilIfBlank {
            args.append(try SwiftToolsSupport.optionValue(executable, named: "executable"))
        }
        // SwiftPM stops parsing its own options at the executable name, so the
        // program arguments are forwarded verbatim (not trimmed) after it.
        args.append(contentsOf: SwiftToolsSupport.additionalArguments(input.arguments ?? input.args))
        return args
    }
}

struct SwiftPackageTool: FeatureTool {
    struct Input: Decodable, Sendable {
        let path: String?
        let workingDirectory: String?
        let action: String?
        let timeoutSeconds: Int?
        let timeout: Int?
    }

    static let actions = ["resolve", "update", "clean", "reset", "describe", "dump-package"]
    static let name = "swift.package"
    static let description = "Runs `swift package` subcommands. action is one of: resolve, update, clean, reset, describe, dump-package. describe and dump-package report targets, products, and dependencies without reading Package.swift by hand."
    static let inputSchema = buildInputSchema(
        CommonSchemaProperties.workingDirectory
            + [.string("action", enumValues: actions)]
            + CommonSchemaProperties.timeout
    )

    func run(_ input: Input, context: FeatureContext) async throws -> String {
        let action = (input.action?.nilIfBlank ?? "describe").lowercased()
        guard Self.actions.contains(action) else {
            throw SwiftToolsFeatureError.invalidArgument(
                "action must be one of: resolve, update, clean, reset, describe, dump-package."
            )
        }
        var args = ["package", action]
        if action == "describe" {
            args.append(contentsOf: ["--type", "json"])
        }
        let result = try await SwiftToolsSupport.execute(
            args, path: input.path, workingDirectory: input.workingDirectory,
            timeout: input.timeoutSeconds ?? input.timeout,
            defaultTimeout: (action == "update" || action == "resolve") ? 600 : 120,
            context: context
        )
        return SwiftToolsSupport.renderPackageResult(result, command: SwiftToolsSupport.renderCommand(["swift"] + args))
    }
}

struct SwiftOutlineTool: FeatureTool {
    struct Input: Decodable, Sendable {
        let path: String?
        let file_path: String?
        let maxSymbols: Int?
        let max_symbols: Int?
    }

    static let name = "swift.outline"
    static let description = "Returns a compact outline of Swift declarations in a source file without returning the full file contents."
    static let inputSchema = buildInputSchema(
        CommonSchemaProperties.pathAliases + CommonSchemaProperties.symbolLimit,
        required: ["path"]
    )

    func run(_ input: Input, context: FeatureContext) async throws -> String {
        let path = try SwiftToolsSupport.requiredPath(input.path, input.file_path, context: context)
        return try SwiftToolsSupport.renderSwiftOutline(
            fileURL: path,
            maxSymbols: input.maxSymbols ?? input.max_symbols
        )
    }
}

@main
struct SwiftToolsFeatureMain {
    static func main() async {
        await FeatureRunner.run([
            AnyFeatureTool(SwiftBuildTool()),
            AnyFeatureTool(SwiftTestTool()),
            AnyFeatureTool(SwiftRunTool()),
            AnyFeatureTool(SwiftPackageTool()),
            AnyFeatureTool(SwiftOutlineTool())
        ])
    }
}

// MARK: - Semantic presentation

extension SwiftBuildTool {
    static var presentation: ToolPresentationDefinition {
        .standard(title: "Swift package", action: "Build", kind: .execute, targetKeyPaths: ["target", "product", "path", "workingDirectory"])
    }
}

extension SwiftTestTool {
    static var presentation: ToolPresentationDefinition {
        .standard(title: "Swift tests", action: "Test", kind: .execute, targetKeyPaths: ["filter", "target", "path", "workingDirectory"])
    }
}

extension SwiftRunTool {
    static var presentation: ToolPresentationDefinition {
        .standard(title: "Swift executable", action: "Run", kind: .execute, targetKeyPaths: ["executable", "product", "path", "workingDirectory"])
    }
}

extension SwiftPackageTool {
    static var presentation: ToolPresentationDefinition {
        .standard(title: "Swift package", action: "Manage", kind: .manage, targetKeyPaths: ["action", "path", "workingDirectory"])
    }
}

extension SwiftOutlineTool {
    static var presentation: ToolPresentationDefinition {
        .standard(title: "Swift outline", action: "Inspect", kind: .inspect, targetKeyPaths: ["file_path", "path"], targetFormat: .path)
    }
}
