//
//  DS4ModelDiscoveryTests.swift
//  ZenCODE
//

#if ZENCODE_LOCAL_DS4
import Foundation
import Testing
@testable import zen

@Suite
struct DS4ModelDiscoveryTests {
    @Test
    func findsGGUFFilesCaseInsensitivelyAndIgnoresDirectories() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        let nested = root.appendingPathComponent("nested", isDirectory: true)
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        let lowercase = root.appendingPathComponent("alpha.gguf")
        let uppercase = nested.appendingPathComponent("beta.GGUF")
        let directoryWithGGUFExtension = root.appendingPathComponent("not-a-model.gguf", isDirectory: true)
        try Data().write(to: lowercase)
        try Data().write(to: uppercase)
        try FileManager.default.createDirectory(at: directoryWithGGUFExtension, withIntermediateDirectories: true)

        let candidates = DS4ModelDiscovery.ggufModelCandidates(in: root).map(\.lastPathComponent)

        #expect(candidates == ["alpha.gguf", "beta.GGUF"])
        #expect(DS4ModelDiscovery.isGGUFModelFile(lowercase))
        #expect(!DS4ModelDiscovery.isGGUFModelFile(directoryWithGGUFExtension))
    }

    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("zencode-ds4-model-discovery-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}
#endif
