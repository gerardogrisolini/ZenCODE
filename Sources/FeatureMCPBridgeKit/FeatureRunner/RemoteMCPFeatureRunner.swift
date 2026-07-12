//
//  RemoteMCPFeatureRunner.swift
//  ZenCODE
//
//  Shared CLI runner for MCP tool features. Each
//  feature supplies a lightweight configuration; this runner handles
//  argument parsing, JSON envelope, and error rendering so that
//  individual feature mains stay thin.
//

import Foundation
import FeatureKit
import ToolCore

// MARK: - Configuration protocol

/// Describes an MCP-backed tool feature so the shared runner can
/// perform availability checks, wire up the executor, and map errors
/// without duplicating CLI boilerplate.
public protocol MCPFeatureConfiguration {
    /// Human-readable name used in diagnostics / usage text.
    var featureName: String { get }

    /// CLI usage text for `--usage`.
    var usageText: String { get }

    /// Returns `true` when the target application / server is reachable.
    func isAvailable(environment: [String: String]) async -> Bool

    /// Lists tools available through this feature's MCP server.
    /// Default implementation uses `RemoteMCPToolExecutor`.
    func listTools(environment: [String: String]) async throws -> [FeatureToolDescriptor]

    /// Invokes a tool by name. Default implementation uses `RemoteMCPToolExecutor`.
    func invoke(
        toolName: String,
        inputData: Data,
        environment: [String: String]
    ) async throws -> String

    /// Maps feature-specific errors (e.g. consent denied) into
    /// user-visible errors.
    func mapError(_ error: Error) -> Error
}

// MARK: - Default executor-based implementation

/// Defaults that work for standard MCP features backed by `RemoteMCPToolExecutor`.
extension MCPFeatureConfiguration {
    /// Must override — provides the prefix and description prefix.
    var toolNamePrefix: String { "" }
    var descriptionPrefix: String { "" }

    /// Must override — builds the appropriate `RemoteMCPToolExecutor`.
    func makeExecutor(environment: [String: String]) async throws -> RemoteMCPToolExecutor {
        fatalError("MCPFeatureConfiguration.makeExecutor(environment:) must be overridden")
    }

    public func listTools(
        environment: [String: String]
    ) async throws -> [FeatureToolDescriptor] {
        guard await isAvailable(environment: environment) else {
            return []
        }

        let executor = try await makeExecutor(environment: environment)
        let tools: [ToolDescriptor]
        do {
            tools = try await executor.loadTools()
        } catch {
            await executor.disconnect()
            throw error
        }
        await executor.disconnect()

        let prefix = descriptionPrefix
        return ToolDescriptor.canonicalized(tools).map { tool in
            FeatureToolDescriptor(
                toolDescriptor: tool,
                description: tool.description.hasPrefix(prefix)
                    ? tool.description
                    : "\(prefix)\(tool.description)"
            )
        }
    }

    public func invoke(
        toolName: String,
        inputData: Data,
        environment: [String: String]
    ) async throws -> String {
        guard await isAvailable(environment: environment) else {
            throw MCPFeatureError.unavailable(featureName)
        }

        let arguments = try RemoteMCPFeatureRunner.decodeArguments(from: inputData)
        let request = ToolRequest(name: toolName, arguments: arguments)

        let executor = try await makeExecutor(environment: environment)
        do {
            let output = try await executor.execute(request)
            await executor.disconnect()
            return output.text
        } catch {
            await executor.disconnect()
            throw error
        }
    }

    public func mapError(_ error: Error) -> Error {
        error
    }
}

// MARK: - Shared runner

/// Stateless runner that parses `--list-tools` / `--invoke` CLI arguments,
/// manages the MCP executor lifecycle, and writes JSON responses to stdout.
public enum RemoteMCPFeatureRunner {

    /// Entry point. Call this from `@main static func main() async`.
    public static func run(
        configuration: some MCPFeatureConfiguration,
        arguments: [String] = Array(CommandLine.arguments.dropFirst()),
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) async {
        let command = FeatureProcessProtocol.parse(arguments: arguments)

        do {
            switch command {
            case .listTools:
                let tools = try await configuration.listTools(environment: environment)
                try FeatureProcessProtocol.emitJSON(
                    FeatureListToolsResponse(
                        tools: FeatureToolDescriptor.canonicalized(tools)
                    )
                )

            case let .invoke(toolName, _):
                let inputData = FileHandle.standardInput.readDataToEndOfFile()
                let output = try await configuration.invoke(
                    toolName: toolName,
                    inputData: inputData,
                    environment: environment
                )
                try FeatureProcessProtocol.emitJSON(
                    InvocationResponse(ok: true, output: .string(output), error: nil)
                )

            case .usage:
                try FeatureProcessProtocol.emitJSON(
                    InvocationResponse(
                        ok: false,
                        output: nil,
                        error: configuration.usageText
                    )
                )
                terminate(code: 64)
            }
        } catch {
            let mapped = configuration.mapError(error)
            try? FeatureProcessProtocol.emitJSON(
                InvocationResponse(
                    ok: false,
                    output: nil,
                    error: mapped.localizedDescription
                )
            )
            terminate(code: 1)
        }
    }

    // MARK: - Shared utilities

    public static func decodeArguments(from data: Data) throws -> [String: JSONValue] {
        guard !data.isEmpty else {
            return [:]
        }
        let value = try JSONDecoder().decode(JSONValue.self, from: data)
        guard case let .object(arguments) = value else {
            throw MCPFeatureError.invalidArguments
        }
        return arguments
    }

    public static func emitJSON<T: Encodable>(_ value: T) throws {
        try FeatureProcessProtocol.emitJSON(value)
    }

    public static func terminate(code: Int32) -> Never {
        FeatureProcessProtocol.terminate(code: code)
    }
}

// MARK: - Shared types

public struct ListToolsResponse: Encodable {
    public let tools: [FeatureToolDescriptor]

    public init(tools: [FeatureToolDescriptor]) {
        self.tools = tools
    }
}

public struct InvocationResponse: Encodable {
    public let ok: Bool
    public let output: JSONValue?
    public let error: String?

    public init(ok: Bool, output: JSONValue?, error: String?) {
        self.ok = ok
        self.output = output
        self.error = error
    }
}

public enum ParsedFeatureCommand {
    case listTools
    case invoke(String)
    case usage

    public init(arguments: [String]) {
        switch FeatureProcessProtocol.parse(arguments: arguments) {
        case .listTools:
            self = .listTools
        case let .invoke(toolName, _):
            self = .invoke(toolName)
        case .usage:
            self = .usage
        }
    }
}

public enum MCPFeatureError: LocalizedError {
    case unavailable(String)
    case invalidArguments

    public var errorDescription: String? {
        switch self {
        case let .unavailable(name):
            return "\(name) MCP is not available. Open \(name) and enable its MCP server, then retry."
        case .invalidArguments:
            return "Expected a JSON object as tool arguments."
        }
    }
}
