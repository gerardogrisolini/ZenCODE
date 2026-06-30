//
//  SwiftFeatureScaffoldTemplateMain.swift
//  ZenCODE
//

import Foundation

extension SwiftFeatureRuntime {
    static func featureMainContents(
        toolName: String,
        toolDescription: String
    ) -> String {
        let escapedToolName = swiftStringLiteral(toolName)
        let escapedDescription = swiftStringLiteral(toolDescription)
        return #"""
        import Foundation
        #if canImport(Darwin)
        import Darwin
        #elseif canImport(Glibc)
        import Glibc
        #endif

        private let generatedToolName = \#(escapedToolName)
        private let generatedToolDescription = \#(escapedDescription)
        private let generatedInputSchema = #"{"type":"object","properties":{"text":{"type":"string"}},"required":["text"]}"#

        private struct ToolDescriptor: Codable {
            let name: String
            let description: String
            let inputSchema: String
        }

        private struct ListToolsResponse: Codable {
            let tools: [ToolDescriptor]
        }

        private struct InvocationResponse: Codable {
            let ok: Bool
            let output: String?
            let error: String?
        }

        private struct EchoInput: Decodable {
            let text: String?
        }

        struct InvocationContext {
            let workingDirectory: URL

            func resolvePath(_ path: String) -> URL {
                let expandedPath = NSString(string: path).expandingTildeInPath
                if expandedPath.hasPrefix("/") {
                    return URL(fileURLWithPath: expandedPath).standardizedFileURL
                }
                return workingDirectory
                    .appendingPathComponent(expandedPath)
                    .standardizedFileURL
            }
        }

        @main
        struct GeneratedFeatureMain {
            static func main() async {
                do {
                    let parsed = ParsedArguments(arguments: Array(CommandLine.arguments.dropFirst()))
                    switch parsed.command {
                    case .listTools:
                        try writeJSON(
                            ListToolsResponse(
                                tools: [
                                    ToolDescriptor(
                                        name: generatedToolName,
                                        description: generatedToolDescription,
                                        inputSchema: generatedInputSchema
                                    )
                                ]
                            )
                        )
                    case let .invoke(toolName, workingDirectory):
                        let inputData = FileHandle.standardInput.readDataToEndOfFile()
                        let output = try invoke(
                            toolName: toolName,
                            inputData: inputData,
                            context: InvocationContext(
                                workingDirectory: workingDirectory
                                    ?? URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
                            )
                        )
                        try writeJSON(
                            InvocationResponse(
                                ok: true,
                                output: output,
                                error: nil
                            )
                        )
                    case .usage:
                        throw GeneratedFeatureError.usage
                    }
                } catch {
                    try? writeJSON(
                        InvocationResponse(
                            ok: false,
                            output: nil,
                            error: error.localizedDescription
                        )
                    )
                    exit(1)
                }
            }

            static func invoke(
                toolName: String,
                inputData: Data,
                context: InvocationContext
            ) throws -> String {
                guard toolName == generatedToolName else {
                    throw GeneratedFeatureError.unknownTool(toolName)
                }

                let normalizedInput = inputData.isEmpty ? Data("{}".utf8) : inputData
                let input = try JSONDecoder().decode(EchoInput.self, from: normalizedInput)

                _ = context
                return input.text ?? ""
            }

            static func writeJSON<T: Encodable>(_ value: T) throws {
                let encoder = JSONEncoder()
                encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
                let data = try encoder.encode(value)
                FileHandle.standardOutput.write(data)
                FileHandle.standardOutput.write(Data("\n".utf8))
            }
        }

        private enum Command {
            case listTools
            case invoke(String, URL?)
            case usage
        }

        private struct ParsedArguments {
            let command: Command

            init(arguments: [String]) {
                guard let first = arguments.first else {
                    command = .usage
                    return
                }

                switch first {
                case "--list-tools":
                    command = .listTools
                case "--invoke":
                    guard arguments.count >= 2 else {
                        command = .usage
                        return
                    }
                    command = .invoke(
                        arguments[1],
                        Self.optionValue("--working-directory", in: arguments).map {
                            URL(fileURLWithPath: NSString(string: $0).expandingTildeInPath)
                        }
                    )
                default:
                    command = .usage
                }
            }

            static func optionValue(_ option: String, in arguments: [String]) -> String? {
                guard let index = arguments.firstIndex(of: option),
                      arguments.indices.contains(index + 1) else {
                    return nil
                }
                return arguments[index + 1]
            }
        }

        private enum GeneratedFeatureError: LocalizedError {
            case unknownTool(String)
            case usage

            var errorDescription: String? {
                switch self {
                case let .unknownTool(toolName):
                    return "Unknown feature tool: \(toolName)"
                case .usage:
                    return "Usage: feature-binary --list-tools | --invoke <tool-name> [--working-directory <path>]"
                }
            }
        }
        """#
    }

}
