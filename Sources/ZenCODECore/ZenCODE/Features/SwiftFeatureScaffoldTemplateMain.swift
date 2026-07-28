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
        import FeatureKit
        import Foundation
        import ToolCore

        private struct EchoInput: Decodable, Sendable {
            let text: String?
        }

        private struct GeneratedEchoTool: FeatureTool {
            static let name = \#(escapedToolName)
            static let description = \#(escapedDescription)
            static let inputSchema = #"{"type":"object","properties":{"text":{"type":"string"}},"required":["text"]}"#
            static let presentation = ToolPresentationDefinition(
                title: "Echo",
                action: "Echo",
                kind: .execute,
                target: .argument(["text"], format: .text),
                sections: [.parameters()]
            )

            func run(_ input: EchoInput, context _: FeatureContext) async throws -> String {
                input.text ?? ""
            }
        }

        @main
        private enum GeneratedFeatureMain {
            static func main() async {
                await FeatureRunner.run([
                    AnyFeatureTool(GeneratedEchoTool())
                ])
            }
        }
        """#
    }
}
