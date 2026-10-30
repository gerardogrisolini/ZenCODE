//
//  DirectToolPresentationKindTests.swift
//  ZenCODE
//
//  ACP clients (Xcode) render every `execute` tool call as a "Terminal
//  Command", so only `local.exec` may present itself as `.execute`; every
//  other core direct tool, and the feature scaffold templates, use `.other`.
//

import Foundation
import Testing
import ToolCore
@testable import ZenCODECore

@Suite
struct DirectToolPresentationKindTests {
    private func executeToolNames(in descriptors: [DirectToolDescriptor]) -> [String] {
        descriptors
            .filter { $0.presentation?.kind == .execute }
            .map(\.name)
            .sorted()
    }

    @Test
    func onlyLocalExecPresentsAsExecuteInTheBuiltInCatalog() {
#if canImport(Darwin) || canImport(Glibc)
        let expected = ["local.exec"]
#else
        let expected: [String] = []
#endif
        #expect(executeToolNames(in: DirectToolCatalog.baseDescriptors) == expected)
        #expect(executeToolNames(in: DirectToolCatalog.coreDescriptors) == expected)
        #expect(executeToolNames(in: DirectToolCatalog.featureDescriptors).isEmpty)
        #expect(executeToolNames(in: DirectToolCatalog.todoTaskDescriptors).isEmpty)
    }

    @Test
    func formerExecuteToolsKeepTheirActionButPresentAsOther() throws {
        let expectedActions = [
            "tasks.retry": "Retry",
            "feature.reload": "Reload",
            "feature.build": "Build",
        ]
        let descriptors = DirectToolCatalog.baseDescriptors
        for (name, action) in expectedActions {
            let descriptor = try #require(descriptors.first { $0.name == name }, "\(name)")
            #expect(descriptor.presentation?.kind == .other, "\(name)")
            #expect(descriptor.presentation?.action == action, "\(name)")
        }
    }

    @Test
    func featureScaffoldTemplatesPresentTheGeneratedToolAsOther() throws {
        let manifest = try SwiftFeatureRuntime.featureManifestContents(
            id: "kind-check",
            displayName: "Kind Check",
            description: "Scaffold presentation kind check.",
            toolName: "kind.echo",
            enabled: true
        )
        let object = try #require(
            JSONSerialization.jsonObject(with: Data(manifest.utf8)) as? [String: Any]
        )
        let tools = try #require(object["tools"] as? [[String: Any]])
        let presentation = try #require(tools.first?["presentation"] as? [String: Any])
        #expect(presentation["kind"] as? String == "other")
        #expect(presentation["action"] as? String == "Echo")

        let main = SwiftFeatureRuntime.featureMainContents(
            toolName: "kind.echo",
            toolDescription: "Echoes text."
        )
        #expect(main.contains("kind: .other,"))
        #expect(!main.contains("kind: .execute"))
    }
}
