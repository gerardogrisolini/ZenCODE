//
//  XcodeToolsFeatureMain.swift
//  ZenCODE
//
//  Created by Gerardo Grisolini on 30/05/26.
//

import Foundation
import ZenCODECore
import FeatureKit

@main
enum XcodeToolsFeature {
    static func main() async {
        await XcodeFeatureRunner.run()
    }
}

private enum XcodeFeatureRunner {
    static func run(
        arguments: [String] = CommandLine.arguments,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) async {
        let command = ParsedFeatureCommand(arguments: Array(arguments.dropFirst()))

        do {
            switch command {
            case .listTools:
                let tools = try await listTools(environment: environment)
                try emitJSON(ListToolsResponse(tools: tools))
            case let .invoke(toolName):
                let inputData = FileHandle.standardInput.readDataToEndOfFile()
                let output = try await invoke(
                    toolName: toolName,
                    inputData: inputData,
                    environment: environment
                )
                try emitJSON(InvocationResponse(ok: true, output: .string(output), error: nil))
            case .usage:
                try emitJSON(InvocationResponse(ok: false, output: nil, error: usageText))
                terminate(code: 64)
            }
        } catch {
            let mappedError = consentMappedError(error)
            try? emitJSON(
                InvocationResponse(
                    ok: false,
                    output: nil,
                    error: mappedError.localizedDescription
                )
            )
            terminate(code: 1)
        }
    }

    private static func listTools(
        environment: [String: String]
    ) async throws -> [FeatureToolDescriptor] {
        guard MCPServerConfiguration.isXcodeRunning(environment: environment),
              let configuration = MCPServerConfiguration.xcodeFromEnvironment(environment: environment) else {
            return []
        }

        // Connecting triggers the user-consent dialog inside Xcode. The feature
        // waits without any timeout until the user answers, then maps a denied
        // consent to an explicit error that the caller can catch.
        let executor = XcodeToolExecutor(configuration: configuration)
        let tools: [ToolDescriptor]
        do {
            tools = try await executor.loadTools()
        } catch {
            await executor.disconnect()
            throw consentMappedError(error)
        }
        await executor.disconnect()

        return ToolDescriptor.canonicalized(tools).map { tool in
            FeatureToolDescriptor(
                name: tool.name.hasPrefix("xcode.") ? tool.name : "xcode.\(tool.name)",
                description: tool.description.hasPrefix("Xcode:")
                    ? tool.description
                    : "Xcode: \(tool.description)",
                inputSchema: tool.inputSchema,
                outputSchema: tool.outputSchema
            )
        }
    }

    private static func invoke(
        toolName: String,
        inputData: Data,
        environment: [String: String]
    ) async throws -> String {
        guard MCPServerConfiguration.isXcodeRunning(environment: environment),
              let configuration = MCPServerConfiguration.xcodeFromEnvironment(environment: environment) else {
            throw XcodeFeatureError.unavailable
        }

        let executor = XcodeToolExecutor(configuration: configuration)

        let arguments = try decodeArguments(from: inputData)
        let request = ToolRequest(name: toolName, arguments: arguments)
        let normalizedRequest = XcodeToolRequestCompatibility.normalize(request) ?? request
        let rawToolName = normalizedRequest.name.hasPrefix("xcode.")
            ? String(normalizedRequest.name.dropFirst("xcode.".count))
            : normalizedRequest.name
        do {
            let output = try await executor.execute(
                ToolRequest(
                    name: rawToolName,
                    arguments: normalizedRequest.arguments
                )
            )
            await executor.disconnect()
            return output.text
        } catch {
            await executor.disconnect()
            throw consentMappedError(error)
        }
    }

    /// Intercepts the negative Xcode consent and maps the bridge authorization
    /// exception to an explicit consent-denied error.
    private static func consentMappedError(_ error: Error) -> Error {
        if isXcodeConsentDenied(error) {
            return XcodeFeatureError.consentDenied
        }
        return error
    }

    private static func isXcodeConsentDenied(_ error: Error) -> Bool {
        if let clientError = error as? MCPClientError {
            switch clientError {
            case .xcodePermissionRequired:
                return true
            case let .serverExited(_, message),
                 let .serverError(_, message):
                return messageLooksLikeConsentDenied(message)
            default:
                return false
            }
        }

        return messageLooksLikeConsentDenied(error.localizedDescription)
    }

    private static func messageLooksLikeConsentDenied(_ message: String) -> Bool {
        let lowered = message.lowercased()
        return lowered.contains("xcode.mcpbridge.authorization")
            || lowered.contains("authorization error")
            || lowered.contains("consent denied")
            || lowered.contains("permission denied")
            || lowered.contains("not authorized")
            || lowered.contains("not authorised")
            || lowered.contains("not allowed")
            || lowered.contains("not permitted")
            || lowered.contains("rejected")
            || lowered.contains("declined")
            || lowered.contains("cancelled")
            || lowered.contains("canceled")
    }

    private static func decodeArguments(from data: Data) throws -> [String: JSONValue] {
        guard !data.isEmpty else {
            return [:]
        }

        let value = try JSONDecoder().decode(JSONValue.self, from: data)
        guard case let .object(arguments) = value else {
            throw XcodeFeatureError.invalidArguments
        }
        return arguments
    }

    private static func emitJSON<T: Encodable>(_ value: T) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(value)
        FileHandle.standardOutput.write(data)
        FileHandle.standardOutput.write(Data("\n".utf8))
    }

    private static func terminate(code: Int32) -> Never {
        #if canImport(Darwin) || canImport(Glibc)
        exit(code)
        #else
        fatalError("xcode-tools-feature terminated with code \(code).")
        #endif
    }

    private static let usageText = """
    Usage:
      xcode-tools-feature --list-tools
      xcode-tools-feature --invoke <tool-name> [--working-directory <path>]
    """
}

private struct ListToolsResponse: Encodable {
    let tools: [FeatureToolDescriptor]
}

private struct InvocationResponse: Encodable {
    let ok: Bool
    let output: JSONValue?
    let error: String?
}

private enum ParsedFeatureCommand {
    case listTools
    case invoke(String)
    case usage

    init(arguments: [String]) {
        guard let first = arguments.first else {
            self = .usage
            return
        }

        switch first {
        case "--list-tools":
            self = .listTools
        case "--invoke":
            guard arguments.count >= 2 else {
                self = .usage
                return
            }
            self = .invoke(arguments[1])
        default:
            self = .usage
        }
    }
}

private enum XcodeFeatureError: LocalizedError {
    case unavailable
    case invalidArguments
    case consentDenied

    var errorDescription: String? {
        switch self {
        case .unavailable:
            return "Xcode MCP is not available. Open Xcode and approve the MCP connection, then retry."
        case .invalidArguments:
            return "Expected a JSON object as tool arguments."
        case .consentDenied:
            return "Xcode MCP consent was denied. The Xcode tools stay unavailable until you approve the MCP connection in Xcode."
        }
    }
}
