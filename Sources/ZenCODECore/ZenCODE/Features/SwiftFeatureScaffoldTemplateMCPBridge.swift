//
//  SwiftFeatureScaffoldTemplateMCPBridge.swift
//  ZenCODE
//

import Foundation

extension SwiftFeatureRuntime {
    static func mcpBridgeMainContents(
        serviceName: String,
        toolPrefix: String,
        endpointURLString: String?,
        executablePath: String?,
        arguments: [String],
        environment: [String: String]
    ) -> String {
        let escapedServiceName = swiftStringLiteral(serviceName)
        let escapedToolPrefix = swiftStringLiteral(toolPrefix)
        let endpointLiteral = endpointURLString.map(swiftStringLiteral) ?? "nil"
        let executablePathLiteral = executablePath.map(swiftStringLiteral) ?? "nil"
        let argumentsLiteral = swiftStringArrayLiteral(arguments)
        let environmentLiteral = swiftStringDictionaryLiteral(environment)
        return #"""
        import Foundation
        import FeatureKit
        import FeatureMCPBridgeKit
        import ToolCore
        #if canImport(Darwin)
        import Darwin
        #elseif canImport(Glibc)
        import Glibc
        #endif

        private let bridgeServiceName = \#(escapedServiceName)
        private let bridgeToolNamePrefix = \#(escapedToolPrefix)
        private let bridgeEndpointURLString: String? = \#(endpointLiteral)
        private let bridgeExecutablePath: String? = \#(executablePathLiteral)
        private let bridgeExecutableArguments: [String] = \#(argumentsLiteral)
        private let bridgeEnvironment: [String: String] = \#(environmentLiteral)

        @main
        enum MCPBridgeFeatureMain {
            static func main() async {
                let command = ParsedFeatureCommand(arguments: Array(CommandLine.arguments.dropFirst()))

                do {
                    switch command {
                    case .listTools:
                        let tools = try await listTools()
                        try emitJSON(ListToolsResponse(tools: tools))
                    case let .invoke(toolName):
                        let inputData = FileHandle.standardInput.readDataToEndOfFile()
                        let output = try await invoke(
                            toolName: toolName,
                            inputData: inputData
                        )
                        try emitJSON(
                            InvocationResponse(
                                ok: true,
                                output: .string(output),
                                error: nil
                            )
                        )
                    case .usage:
                        throw MCPBridgeFeatureError.usage
                    }
                } catch {
                    try? emitJSON(
                        InvocationResponse(
                            ok: false,
                            output: nil,
                            error: error.localizedDescription
                        )
                    )
                    terminate(code: 1)
                }
            }

            static func listTools() async throws -> [FeatureToolDescriptor] {
                let executor = RemoteMCPToolExecutor(
                    configuration: try configuration(),
                    toolNamePrefix: bridgeToolNamePrefix
                )
                do {
                    let tools = try await executor.loadTools()
                    await executor.disconnect()
                    return ToolDescriptor.canonicalized(tools).map { tool in
                        FeatureToolDescriptor(
                            name: tool.name,
                            description: tool.description.hasPrefix("\(bridgeServiceName):")
                                ? tool.description
                                : "\(bridgeServiceName): \(tool.description)",
                            inputSchema: tool.inputSchema,
                            outputSchema: tool.outputSchema
                        )
                    }
                } catch {
                    await executor.disconnect()
                    throw error
                }
            }

            static func invoke(
                toolName: String,
                inputData: Data
            ) async throws -> String {
                let executor = RemoteMCPToolExecutor(
                    configuration: try configuration(),
                    toolNamePrefix: bridgeToolNamePrefix
                )
                do {
                    let output = try await executor.execute(
                        ToolRequest(
                            name: toolName,
                            arguments: try decodeArguments(from: inputData)
                        )
                    )
                    await executor.disconnect()
                    return output.text
                } catch {
                    await executor.disconnect()
                    throw error
                }
            }

            static func configuration() throws -> MCPServerConfiguration {
                if let rawEndpointURL = bridgeEndpointURLString,
                   let endpointURL = URL(string: rawEndpointURL) {
                    return MCPServerConfiguration(
                        executablePath: "",
                        arguments: [],
                        environment: [:],
                        endpointURL: endpointURL
                    )
                }

                if let executablePath = bridgeExecutablePath,
                   !executablePath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    var environment = ProcessInfo.processInfo.environment
                    environment.merge(bridgeEnvironment) { _, new in new }
                    return MCPServerConfiguration(
                        executablePath: executablePath,
                        arguments: bridgeExecutableArguments,
                        environment: environment
                    )
                }

                throw MCPBridgeFeatureError.unconfigured
            }

            static func decodeArguments(from data: Data) throws -> [String: JSONValue] {
                guard !data.isEmpty else {
                    return [:]
                }

                let value = try JSONDecoder().decode(JSONValue.self, from: data)
                guard case let .object(arguments) = value else {
                    throw MCPBridgeFeatureError.invalidArguments
                }
                return arguments
            }

            static func emitJSON<T: Encodable>(_ value: T) throws {
                let encoder = JSONEncoder()
                encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
                let data = try encoder.encode(value)
                FileHandle.standardOutput.write(data)
                FileHandle.standardOutput.write(Data("\n".utf8))
            }

            static func terminate(code: Int32) -> Never {
                #if canImport(Darwin) || canImport(Glibc)
                exit(code)
                #else
                fatalError("MCP bridge feature terminated with code \(code).")
                #endif
            }
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

        private enum MCPBridgeFeatureError: LocalizedError {
            case invalidArguments
            case unconfigured
            case usage

            var errorDescription: String? {
                switch self {
                case .invalidArguments:
                    return "Expected a JSON object as tool arguments."
                case .unconfigured:
                    return "\(bridgeServiceName) MCP bridge is not configured. Set endpointURL for HTTP MCP or executablePath for stdio MCP in the scaffold arguments."
                case .usage:
                    return "Usage: feature-binary --list-tools | --invoke <tool-name> [--working-directory <path>]"
                }
            }
        }
        """#
    }

}
