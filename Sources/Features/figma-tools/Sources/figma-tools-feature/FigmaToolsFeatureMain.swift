//
//  FigmaToolsFeatureMain.swift
//  ZenCODE
//
//  Created by Gerardo Grisolini on 30/05/26.
//
//  Figma tool feature backed by the Figma cloud REST API
//  (https://api.figma.com). It needs neither the Figma desktop app nor its
//  local MCP server. Access uses the Figma login managed by the feature
//  (see FigmaLogin): the tools open the sign-in page when needed, and
//  `figma-tools-feature --login` signs in from a terminal.
//

import FeatureKit
import Foundation

@main
enum FigmaToolsFeature {
    static func main() async {
        if CommandLine.arguments.dropFirst().contains("--login") {
            let store = FigmaCredentialStore(environment: ProcessInfo.processInfo.environment)
            do {
                _ = try await FigmaLogin.signIn(reason: .manual, store: store)
                FeatureProcessProtocol.terminate(code: 0)
            } catch {
                FileHandle.standardError.write(Data("ZenCODE: \(error.localizedDescription)\n".utf8))
                FeatureProcessProtocol.terminate(code: 1)
            }
        }

        await FeatureRunner.run([
            AnyFeatureTool(FigmaGetDesignContextTool()),
            AnyFeatureTool(FigmaGetMetadataTool()),
            AnyFeatureTool(FigmaGetScreenshotTool()),
            AnyFeatureTool(FigmaGetVariableDefsTool()),
            AnyFeatureTool(FigmaWhoAmITool()),
            AnyFeatureTool(FigmaLoginTool()),
            AnyFeatureTool(FigmaLogoutTool())
        ])
    }
}
