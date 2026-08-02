import Foundation
import Testing
import FeatureKit
import LocalToolsSupport

@Suite
struct LocalFeatureToolsRegistryContractTests {
    @Test
    func publicToolGroupsExposeTheExpectedTools() {
        #expect(LocalFeatureTools.fileTools().map(\.descriptor.name) == [
            "local.pwd", "local.ls", "local.readFile", "local.readFiles",
            "local.inspectFile", "local.writeFile", "local.replace", "local.editFile",
            "local.multiEdit", "local.append", "local.mkdir", "local.delete",
            "local.move", "local.applyPatch"
        ])
        #expect(LocalFeatureTools.searchTools().map(\.descriptor.name) == [
            "search.glob", "search.grep", "search.locate"
        ])
        #expect(LocalFeatureTools.textTools().map(\.descriptor.name) == [
            "text.head", "text.tail", "text.sort", "text.wc"
        ])
    }

    @Test
    func fileToolAccessPartitionsAreExplicitAndLossless() {
        let expectedReadOnly = [
            "local.pwd", "local.ls", "local.readFile", "local.readFiles", "local.inspectFile"
        ]
        let expectedMutating = [
            "local.writeFile", "local.replace", "local.editFile", "local.multiEdit",
            "local.append", "local.mkdir", "local.delete", "local.move", "local.applyPatch"
        ]

        #expect(LocalFeatureTools.readOnlyFileTools().map(\.descriptor.name) == expectedReadOnly)
        #expect(LocalFeatureTools.mutatingFileTools().map(\.descriptor.name) == expectedMutating)
        #expect(
            LocalFeatureTools.fileTools().map(\.descriptor.name)
                == expectedReadOnly + expectedMutating
        )
    }

    @Test
    func fileListInspectAndWriteAdvertiseARequiredPathArgument() throws {
        let descriptors = LocalFeatureTools.fileTools().map(\.descriptor)

        for name in ["local.ls", "local.inspectFile", "local.writeFile"] {
            let descriptor = try #require(
                descriptors.first { $0.name == name }
            )
            let data = try #require(descriptor.inputSchema.data(using: .utf8))
            let schema = try #require(
                JSONSerialization.jsonObject(with: data) as? [String: Any]
            )
            let required = try #require(schema["required"] as? [String])

            #expect(required.contains("path"))
        }
    }

    @Test
    func fileListRejectsAnInvocationWithoutPath() async throws {
        let tool = try #require(
            LocalFeatureTools.fileTools().first {
                $0.descriptor.name == "local.ls"
            }
        )
        let context = FeatureContext(
            workingDirectory: FileManager.default.temporaryDirectory,
            environment: [:]
        )

        await #expect(throws: (any Error).self) {
            _ = try await tool.invoke(
                inputData: Data("{}".utf8),
                context: context
            )
        }
    }
}
