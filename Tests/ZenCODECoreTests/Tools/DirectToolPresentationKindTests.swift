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
}
