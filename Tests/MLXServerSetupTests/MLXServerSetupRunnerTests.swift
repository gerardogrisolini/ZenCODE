//
//  MLXServerSetupRunnerTests.swift
//  ZenCODE
//
//  Created by Gerardo Grisolini on 28/05/26.
//

import Foundation
import HuggingFace
import MLXServerCore
import Testing
@testable import MLXServerSetup

@Test
func setupDoubleParserAcceptsDotAndCommaDecimalSeparators() {
    #expect(MLXServerSetupInputParser.parseDouble("1.25") == 1.25)
    #expect(MLXServerSetupInputParser.parseDouble("1,25") == 1.25)
}

@Test
func setupDoubleParserRejectsAmbiguousDecimalSeparators() {
    #expect(MLXServerSetupInputParser.parseDouble("1,2,3") == nil)
    #expect(MLXServerSetupInputParser.parseDouble("1.2.3") == nil)
    #expect(MLXServerSetupInputParser.parseDouble("1,2.3") == nil)
}

@Test
func setupDoubleParserRejectsNonFiniteValues() {
    #expect(MLXServerSetupInputParser.parseDouble("nan") == nil)
    #expect(MLXServerSetupInputParser.parseDouble("inf") == nil)
    #expect(MLXServerSetupInputParser.parseDouble("-inf") == nil)
}

@Test
func setupPathInputLengthValidatorAllowsConfiguredMaximum() {
    let maximum = MLXServerSetupInputParser.maximumPathLength

    #expect(MLXServerSetupInputParser.isValidLength(String(repeating: "a", count: maximum), maximumLength: maximum))
    #expect(!MLXServerSetupInputParser.isValidLength(String(repeating: "a", count: maximum + 1), maximumLength: maximum))
}

@Test
func huggingFaceCacheRemovalDeletesRepositoryMetadataAndLocks() throws {
    let fileManager = FileManager.default
    let cacheRoot = fileManager.temporaryDirectory
        .appendingPathComponent("mlx-server-cache-removal-\(UUID().uuidString)", isDirectory: true)
    defer {
        try? fileManager.removeItem(at: cacheRoot)
    }

    let cache = HubCache(cacheDirectory: cacheRoot)
    let urls = try #require(
        MLXServerHuggingFaceCacheRemoval.removalURLs(
            repositoryID: "mlx-community/Test-Model",
            cache: cache
        )
    )
    #expect(urls.contains(cacheRoot.appendingPathComponent("models--mlx-community--Test-Model")))
    #expect(urls.contains(cacheRoot.appendingPathComponent(".metadata/models--mlx-community--Test-Model")))
    #expect(urls.contains(cacheRoot.appendingPathComponent(".locks/models--mlx-community--Test-Model")))
    #expect(urls.contains(cacheRoot.appendingPathComponent(".locks/.metadata/models--mlx-community--Test-Model")))

    for url in urls {
        if url.path.contains("/.locks/") {
            try fileManager.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try Data().write(to: url)
        } else {
            try fileManager.createDirectory(
                at: url,
                withIntermediateDirectories: true
            )
        }
    }

    let result = try MLXServerHuggingFaceCacheRemoval.remove(
        repositoryID: "mlx-community/Test-Model",
        cache: cache,
        fileManager: fileManager
    )

    #expect(result == .removed)
    for url in urls {
        #expect(!fileManager.fileExists(atPath: url.path))
    }
}

@Test
func huggingFaceCacheRemovalRejectsInvalidRepositoryID() throws {
    let cache = HubCache(
        cacheDirectory: FileManager.default.temporaryDirectory
            .appendingPathComponent("mlx-server-cache-removal-invalid-\(UUID().uuidString)", isDirectory: true)
    )

    #expect(
        try MLXServerHuggingFaceCacheRemoval.remove(
            repositoryID: "invalid-repository-id",
            cache: cache
        ) == .invalidRepositoryID
    )
    #expect(
        MLXServerHuggingFaceCacheRemoval.removalURLs(
            repositoryID: "invalid-repository-id",
            cache: cache
        ) == nil
    )
}

@Test
func importableCachedCandidatesExcludeAlreadyConfiguredSnapshots() {
    let candidates = [
        MLXServerCachedModelCandidate(
            repositoryID: "mlx-community/Already-Configured",
            revision: "abc123",
            snapshotURL: URL(fileURLWithPath: "/tmp/already")
        ),
        MLXServerCachedModelCandidate(
            repositoryID: "mlx-community/New-Model",
            revision: "def456",
            snapshotURL: URL(fileURLWithPath: "/tmp/new")
        )
    ]
    let configuredModels = [
        MLXServerModelRecord(
            id: "already",
            displayName: "Already",
            repositoryID: "mlx-community/Already-Configured",
            revision: "abc123"
        )
    ]

    let importable = MLXServerModelSetupRunner.importableCachedCandidates(
        from: candidates,
        excludingConfiguredModels: configuredModels
    )

    #expect(importable.map(\.repositoryID) == ["mlx-community/New-Model"])
}

@Test
func cachedCandidateLookupPrefersExactRevisionThenRepositoryFallback() {
    let exact = MLXServerCachedModelCandidate(
        repositoryID: "mlx-community/Test-Model",
        revision: "exact-sha",
        snapshotURL: URL(fileURLWithPath: "/tmp/exact")
    )
    let fallback = MLXServerCachedModelCandidate(
        repositoryID: "mlx-community/Test-Model",
        revision: "older-sha",
        snapshotURL: URL(fileURLWithPath: "/tmp/fallback")
    )
    let other = MLXServerCachedModelCandidate(
        repositoryID: "mlx-community/Other",
        revision: "exact-sha",
        snapshotURL: URL(fileURLWithPath: "/tmp/other")
    )

    #expect(
        MLXServerModelSetupRunner.cachedCandidate(
            forRepositoryID: "mlx-community/Test-Model",
            revision: "exact-sha",
            in: [fallback, other, exact]
        )?.snapshotURL.path == "/tmp/exact"
    )
    #expect(
        MLXServerModelSetupRunner.cachedCandidate(
            forRepositoryID: "mlx-community/Test-Model",
            revision: "missing-sha",
            in: [fallback, other]
        )?.snapshotURL.path == "/tmp/fallback"
    )
    #expect(
        MLXServerModelSetupRunner.cachedCandidate(
            forRepositoryID: "mlx-community/Missing",
            revision: "exact-sha",
            in: [fallback, other, exact]
        ) == nil
    )
}

@Test
func importCachedModelsAddsAllCandidatesTogether() throws {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("mlx-server-cached-import-\(UUID().uuidString)", isDirectory: true)
    defer {
        try? FileManager.default.removeItem(at: directory)
    }

    let firstSnapshot = directory.appendingPathComponent("first", isDirectory: true)
    let secondSnapshot = directory.appendingPathComponent("second", isDirectory: true)
    try createUsableCachedSnapshot(at: firstSnapshot, contextWindow: 32_768)
    try createUsableCachedSnapshot(at: secondSnapshot, contextWindow: 65_536)

    let candidates = [
        MLXServerCachedModelCandidate(
            repositoryID: "mlx-community/First",
            revision: "first-sha",
            snapshotURL: firstSnapshot
        ),
        MLXServerCachedModelCandidate(
            repositoryID: "mlx-community/Second",
            revision: "second-sha",
            snapshotURL: secondSnapshot
        )
    ]
    var manifest = MLXServerModelsManifest()

    let importedCount = try MLXServerModelSetupRunner.importCachedModels(
        candidates,
        into: &manifest
    )

    #expect(importedCount == 2)
    #expect(manifest.models.map(\.repositoryID) == ["mlx-community/First", "mlx-community/Second"])
    #expect(manifest.models.map(\.revision) == ["first-sha", "second-sha"])
    #expect(manifest.models.map(\.id) == ["mlx-community/First", "mlx-community/Second"])
    #expect(manifest.defaultModelID == "mlx-community/First")
}

@Test
func huggingFaceSearchPromptSuggestsLeadingModels() {
    #expect(MLXServerModelSetupRunner.leadingModelSearchHelp.contains("qwen3.6"))
    #expect(MLXServerModelSetupRunner.leadingModelSearchHelp.contains("gemma-4"))
}

@Test
func modelSearchDetailIncludesEstimatedSize() throws {
    let model = try decodeHuggingFaceModel(
        """
        {
          "id": "mlx-community/Example",
          "downloads": 42,
          "likes": 1,
          "tags": ["mlx"],
          "siblings": [
            { "rfilename": "config.json", "size": 1000 },
            { "rfilename": "model-00001-of-00002.safetensors", "size": 1500000000 },
            { "rfilename": "model-00002-of-00002.safetensors", "size": 1499999000 }
          ]
        }
        """
    )

    #expect(MLXServerModelSetupRunner.modelSearchDetail(model) == "3.0 GB, 42 downloads, 1 like")
}

@Test
func modelSearchSizeFallsBackToUsedStorage() throws {
    let model = try decodeHuggingFaceModel(
        """
        {
          "id": "mlx-community/Example",
          "downloads": 1,
          "likes": 2,
          "tags": ["mlx"],
          "usedStorage": 2400000000
        }
        """
    )

    #expect(MLXServerModelSetupRunner.modelDownloadSizeDetail(model) == "2.4 GB")
    #expect(MLXServerModelSetupRunner.modelSearchDetail(model) == "2.4 GB, 1 download, 2 likes")
}

@Test
func modelSearchSizeFallsBackToParameterEstimate() throws {
    let model = try decodeHuggingFaceModel(
        """
        {
          "id": "mlx-community/Example-26B-MLX-4bit",
          "downloads": 10,
          "likes": 2,
          "tags": ["mlx"]
        }
        """
    )

    #expect(MLXServerModelSetupRunner.modelDownloadSizeDetail(model) == "~15.6 GB")
    #expect(MLXServerModelSetupRunner.modelSearchDetail(model) == "~15.6 GB, 10 downloads, 2 likes")
}

@Test
func modelSearchSizeDoesNotUseQuantizationAsParameterCount() throws {
    let model = try decodeHuggingFaceModel(
        """
        {
          "id": "mlx-community/Example-MLX-4bit",
          "downloads": 10,
          "likes": 2,
          "tags": ["mlx"]
        }
        """
    )

    #expect(MLXServerModelSetupRunner.modelDownloadSizeDetail(model) == "size n/a")
}

@Test
func downloadProgressLineUsesSingleLineAndFractionalPercent() {
    let progress = Progress(totalUnitCount: 1_000)
    progress.completedUnitCount = 123

    let line = MLXServerModelSetupRunner.downloadProgressLine(for: progress)

    #expect(line.hasPrefix("Download: 12.3%"))
    #expect(line.contains(" / "))
    #expect(!line.contains("\n"))
    #expect(!line.contains("\r"))
}

@Test
func downloadProgressPercentIsClampedAndStable() {
    #expect(MLXServerModelSetupRunner.formatPercent(-1) == "0.0")
    #expect(MLXServerModelSetupRunner.formatPercent(42.2) == "42.2")
    #expect(MLXServerModelSetupRunner.formatPercent(101) == "100.0")
}

@Test
func modelSearchSelectionParserSelectsModelByNumberOrDefault() {
    #expect(
        MLXServerModelSetupInputParser.parseSearchSelection(
            "2",
            defaultSelection: 1,
            allowedRange: 1...3
        ) == .model(2)
    )
    #expect(
        MLXServerModelSetupInputParser.parseSearchSelection(
            "",
            defaultSelection: 1,
            allowedRange: 1...3
        ) == .model(1)
    )
}

@Test
func modelSearchSelectionParserCanSearchAgain() {
    #expect(
        MLXServerModelSetupInputParser.parseSearchSelection(
            "s",
            defaultSelection: 1,
            allowedRange: 1...3
        ) == .searchAgain
    )
    #expect(
        MLXServerModelSetupInputParser.parseSearchSelection(
            "search again",
            defaultSelection: 1,
            allowedRange: 1...3
        ) == .searchAgain
    )
    #expect(
        MLXServerModelSetupInputParser.parseSearchSelection(
            "cerca ancora",
            defaultSelection: 1,
            allowedRange: 1...3
        ) == .searchAgain
    )
}

@Test
func modelSearchSelectionParserCanContinueWithoutDownload() {
    #expect(
        MLXServerModelSetupInputParser.parseSearchSelection(
            "c",
            defaultSelection: 1,
            allowedRange: 1...3
        ) == .continueWithoutDownload
    )
    #expect(
        MLXServerModelSetupInputParser.parseSearchSelection(
            "continue without download",
            defaultSelection: 1,
            allowedRange: 1...3
        ) == .continueWithoutDownload
    )
    #expect(
        MLXServerModelSetupInputParser.parseSearchSelection(
            "continua senza scaricare",
            defaultSelection: 1,
            allowedRange: 1...3
        ) == .continueWithoutDownload
    )
}

@Test
func modelSearchSelectionParserRejectsInvalidValues() {
    #expect(
        MLXServerModelSetupInputParser.parseSearchSelection(
            "4",
            defaultSelection: 1,
            allowedRange: 1...3
        ) == nil
    )
    #expect(
        MLXServerModelSetupInputParser.parseSearchSelection(
            "not-a-choice",
            defaultSelection: 1,
            allowedRange: 1...3
        ) == nil
    )
}

private func createUsableCachedSnapshot(
    at snapshotURL: URL,
    contextWindow: Int
) throws {
    try FileManager.default.createDirectory(
        at: snapshotURL,
        withIntermediateDirectories: true
    )
    try Data(
        """
        { "max_position_embeddings": \(contextWindow) }
        """.utf8
    ).write(to: snapshotURL.appendingPathComponent("config.json"))
    try Data().write(to: snapshotURL.appendingPathComponent("model.safetensors"))
}

private func decodeHuggingFaceModel(_ json: String) throws -> Model {
    try JSONDecoder().decode(Model.self, from: Data(json.utf8))
}
