import Foundation
import Testing
@testable import ZenCODECore

@Suite
struct DS4InstallationScannerTests {
    @Test
    func scansOnlyRootAndTopLevelGGUFDirectoryAndReportsDiskBytes() throws {
        let fileManager = FileManager.default
        let root = try temporaryDirectory(fileManager: fileManager)
        let outside = try temporaryDirectory(fileManager: fileManager)
        defer {
            try? fileManager.removeItem(at: root)
            try? fileManager.removeItem(at: outside)
        }

        try Data(repeating: 1, count: 7).write(to: root.appendingPathComponent("root.gguf"))
        try fileManager.createDirectory(
            at: root.appendingPathComponent("gguf"),
            withIntermediateDirectories: true
        )
        try Data(repeating: 2, count: 11).write(to: root.appendingPathComponent("gguf/model.gguf"))
        try Data(repeating: 3, count: 13).write(to: root.appendingPathComponent("gguf/not-a-model.bin"))
        try fileManager.createDirectory(
            at: root.appendingPathComponent("nested"),
            withIntermediateDirectories: true
        )
        try Data(repeating: 4, count: 17).write(to: root.appendingPathComponent("nested/hidden.gguf"))
        let outsideModel = outside.appendingPathComponent("outside.gguf")
        try Data(repeating: 5, count: 19).write(to: outsideModel)
        try fileManager.createSymbolicLink(
            at: root.appendingPathComponent("gguf/link.gguf"),
            withDestinationURL: outsideModel
        )

        let snapshot = try DS4InstallationScanner(fileManager: fileManager).scan(rootDirectory: root)

        #expect(snapshot.artifacts.map(\.relativePath) == ["gguf/model.gguf", "root.gguf"])
        #expect(snapshot.artifacts.map(\.diskBytes) == [11, 7])
        #expect(snapshot.totalDiskBytes == 18)
        #expect(snapshot.contains(relativePath: "gguf/model.gguf"))
        #expect(!snapshot.contains(relativePath: "nested/hidden.gguf"))
        #expect(snapshot.diagnostics.contains { $0.contains("symbolic-link") })
    }

    @Test
    func catalogDownloadIdentitiesMapToDs4ModelsAPIAliases() {
        let catalog = DS4ModelCatalog.default

        #expect(catalog.entry(id: "ds4f-q4")?.apiModelID == "deepseek-v4-flash")
        #expect(catalog.entry(id: "pro-q2-imatrix")?.apiModelID == "deepseek-v4-pro")
        #expect(catalog.entry(id: "qwen38-q2")?.apiModelID == "qwen3.8-flash-next")
        #expect(catalog.entry(id: "glm-antirez-q4")?.apiModelID == "glm-5.2")
        #expect(catalog.entry(id: "glm53-q4")?.apiModelID == "glm-5.3-flash")
        #expect(
            DS4ModelCatalogEntry(
                id: "fixture-model",
                displayName: "Fixture",
                artifacts: []
            ).apiModelID == "fixture-model"
        )
    }

    @Test
    func catalogLooksUpEntriesByArtifactPath() {
        let catalog = DS4ModelCatalog.default
        #expect(catalog.entry(forArtifactPath: "gguf/Qwen3.8-Flash-Next-Q2.gguf")?.id == "qwen38-q2")
        #expect(catalog.entry(forArtifactPath: "gguf/DeepSeek-V4-Pro-Q4K-Layers00-30.gguf")?.id == "pro-q4-split")
        #expect(catalog.entry(forArtifactPath: "gguf/unknown.gguf") == nil)
    }

    @Test
    func apiModelIDIsInferredFromFileNameInPriorityOrder() {
        func infer(_ name: String) -> String? {
            DS4ModelCatalog.inferredAPIModelID(fromFileName: name)
        }
        #expect(infer("DeepSeek-V4.1-Flash-1017-IQ2_XXS-Q2_K-imatrix.gguf") == "deepseek-v4.1-flash")
        #expect(infer("DeepSeek-V4-Pro-Custom.gguf") == "deepseek-v4-pro")
        #expect(infer("my-v4-pro-q2.gguf") == "deepseek-v4-pro")
        #expect(infer("DEEPSEEK-V4-FLASH-custom.gguf") == "deepseek-v4-flash")
        #expect(infer("Qwen3.8-Flash-Next-Q2.gguf") == "qwen3.8-flash-next")
        #expect(infer("GLM-5.3-Flash-Custom.gguf") == "glm-5.3-flash")
        #expect(infer("GLM-5.2-Custom.gguf") == "glm-5.2")
        // v4.1 wins over a name that also mentions the pro/flash variants.
        #expect(infer("deepseek-v4.1-flash-v4-pro.gguf") == "deepseek-v4.1-flash")
        #expect(infer("mystery-model.gguf") == nil)
        #expect(DS4ModelCatalog.servedAPIModelIDs.count == 6)
    }

    private func temporaryDirectory(fileManager: FileManager) throws -> URL {
        let url = fileManager.temporaryDirectory
            .appendingPathComponent("zencode-ds4-scan-")
            .appendingPathComponent(UUID().uuidString)
        try fileManager.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}
