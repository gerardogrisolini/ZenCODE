//
//  MLXServerModelSetupRunner+RemoteModels.swift
//  ZenCODE
//
//  Created by Gerardo Grisolini on 14/06/26.
//

import Foundation
import HuggingFace
import ZenCODECore
import MLXServerCore

extension MLXServerModelSetupRunner {
    static let leadingModelSearchHelp = "Top searches: qwen3.6, gemma-4"

    static func configureRemoteModel() async throws -> ConfiguredModelRecord? {
        let client = MLXServerHuggingFaceCacheAccessStore.hubClient()
        guard let selectedModel = try await selectHuggingFaceModel(client: client) else {
            return nil
        }
        return try await downloadAndConfigureRemoteModel(selectedModel, client: client)
    }

    static func downloadAndConfigureRemoteModel(
        _ selectedModel: Model,
        client: HubClient
    ) async throws -> ConfiguredModelRecord {
        let repositoryID = selectedModel.id.rawValue
        let revision = selectedModel.sha ?? "main"

        if let cachedCandidate = cachedCandidate(
            forRepositoryID: repositoryID,
            revision: revision,
            in: MLXServerCachedModelScanner.candidates(
                cache: MLXServerHuggingFaceCacheAccessStore.cache
            )
        ) {
            AgentOutput.standardError.writeString(
                "\nUsing downloaded \(cachedCandidate.repositoryID) [\(cachedCandidate.revision)] from \(cachedCandidate.snapshotURL.path)\n"
            )
            return try configureCachedModel(cachedCandidate)
        }

        AgentOutput.standardError.writeString("\nDownloading \(repositoryID) [\(revision)]...\n")
        let snapshotURL = try await client.downloadSnapshot(
            of: selectedModel.id,
            revision: revision,
            progressHandler: { progress in
                Self.printDownloadProgress(progress)
            }
        )
        AgentOutput.standardError.writeString("\nDownload completed: \(snapshotURL.path)\n")

        return try configureModelRecord(
            repositoryID: repositoryID,
            revision: revision,
            snapshotURL: snapshotURL,
            defaultRuntimeKind: inferredRuntimeKind(
                fromSnapshot: snapshotURL,
                fallback: inferredRuntimeKind(from: selectedModel)
            )
        )
    }


    static func selectHuggingFaceModel(client: HubClient) async throws -> Model? {
        searchLoop: while true {
            let query = try promptString(
                "Hugging Face MLX search",
                defaultValue: nil,
                allowEmpty: true,
                help: leadingModelSearchHelp
            ).trimmedNonEmpty

            let models: [Model]
            do {
                models = try await searchHuggingFaceModels(
                    client: client,
                    query: query
                )
            } catch {
                AgentOutput.standardError.writeString(
                    "Hugging Face search failed: \(describeHuggingFaceError(error))\n"
                )
                AgentOutput.standardError.writeString("Try a different search.\n")
                continue
            }

            guard !models.isEmpty else {
                AgentOutput.standardError.writeString("No MLX model found.\n")
                continue
            }

            var items = models.enumerated().map { index, model in
                return TerminalCheckboxMenuItem(
                    value: index,
                    title: model.id.rawValue,
                    detail: modelSearchDetail(model)
                )
            }
            items.append(
                TerminalCheckboxMenuItem(
                    value: -1,
                    title: "Search again",
                    detail: "try a different Hugging Face search",
                    groupTitle: " "
                )
            )
            items.append(
                TerminalCheckboxMenuItem(
                    value: -2,
                    title: "Continue without download",
                    detail: "skip remote model download"
                )
            )

            let selection = TerminalCheckboxMenu.selectOne(
                title: "Select Hugging Face model",
                items: items,
                selected: 0
            ) ?? -2
            if selection == -1 {
                continue searchLoop
            }
            if selection == -2 {
                return nil
            }
            if models.indices.contains(selection) {
                return models[selection]
            }

        }
    }

    static func searchHuggingFaceModels(
        client: HubClient,
        query: String?
    ) async throws -> [Model] {
        let response = try await client.listModels(
            search: query,
            filter: "mlx",
            sort: "downloads",
            direction: .descending,
            limit: 10,
            full: true
        )
        return try await modelsWithDownloadMetadata(
            response.items.filter(isUsableMLXModel),
            client: client
        )
    }

    static func modelsWithDownloadMetadata(
        _ models: [Model],
        client: HubClient
    ) async throws -> [Model] {
        var detailedModels: [Model] = []
        detailedModels.reserveCapacity(models.count)
        for model in models {
            let detailedModel = try? await client.getModel(
                model.id,
                revision: model.sha,
                full: true,
                filesMetadata: true
            )
            detailedModels.append(detailedModel ?? model)
        }
        return detailedModels
    }

    static func describeHuggingFaceError(_ error: Error) -> String {
        if let error = error as? HTTPClientError {
            return error.description
        }
        return error.localizedDescription
    }

    static func printDownloadProgress(_ progress: Progress) {
        AgentOutput.standardError.writeString("\r\u{001B}[2K\(downloadProgressLine(for: progress))")
    }

    static func downloadProgressLine(for progress: Progress) -> String {
        let fraction = progress.fractionCompleted.isFinite
            ? min(max(progress.fractionCompleted, 0), 1)
            : 0
        let percent = fraction * 100
        let completed = max(progress.completedUnitCount, 0)
        let total = max(progress.totalUnitCount, 0)
        let sizeDetail = total > 1
            ? " \(formatBytes(completed)) / \(formatBytes(total))"
            : ""
        return "Download: \(formatPercent(percent))%\(sizeDetail)"
    }

    static func formatPercent(_ percent: Double) -> String {
        String(format: "%.1f", min(max(percent, 0), 100))
    }

    static func formatBytes(_ bytes: Int64) -> String {
        ByteCountFormatter.string(
            fromByteCount: bytes,
            countStyle: .file
        )
    }

    static func modelSearchDetail(_ model: Model) -> String {
        let size = modelDownloadSizeDetail(model)
        let downloads = countDetail(model.downloads, singular: "download", plural: "downloads")
        let likes = countDetail(model.likes, singular: "like", plural: "likes")
        return "\(size), \(downloads), \(likes)"
    }

    static func modelDownloadSizeDetail(_ model: Model) -> String {
        if let bytes = modelDownloadBytes(model) {
            return formatGigabytes(bytes)
        }
        if let bytes = estimatedParameterDownloadBytes(from: model) {
            return "~\(formatGigabytes(bytes))"
        }
        return "size n/a"
    }

    static func modelDownloadBytes(_ model: Model) -> Int64? {
        if let siblings = model.siblings {
            let siblingBytes = siblings.compactMap(\.size).reduce(Int64(0)) { partial, size in
                partial + Int64(size)
            }
            if siblingBytes > 0 {
                return siblingBytes
            }
        }
        if let usedStorage = model.usedStorage, usedStorage > 0 {
            return Int64(usedStorage)
        }
        return nil
    }

    static func estimatedParameterDownloadBytes(from model: Model) -> Int64? {
        let searchable = ([model.id.rawValue] + (model.tags ?? []))
            .joined(separator: " ")
            .lowercased()
        guard let parameterBillions = firstParameterCountInBillions(in: searchable) else {
            return nil
        }
        return Int64(parameterBillions * 1_000_000_000 * estimatedBytesPerParameter(in: searchable))
    }

    static func estimatedBytesPerParameter(in value: String) -> Double {
        if value.contains("4bit")
            || value.contains("4-bit")
            || value.contains("int4")
            || value.contains("q4") {
            return 0.6
        }
        if value.contains("5bit")
            || value.contains("5-bit")
            || value.contains("int5")
            || value.contains("q5") {
            return 0.72
        }
        if value.contains("6bit")
            || value.contains("6-bit")
            || value.contains("int6")
            || value.contains("q6") {
            return 0.85
        }
        if value.contains("8bit")
            || value.contains("8-bit")
            || value.contains("int8")
            || value.contains("q8") {
            return 1.05
        }
        return 2.0
    }

    static func firstParameterCountInBillions(in value: String) -> Double? {
        let pattern = #"(?i)(\d+(?:[\._]\d+)?)\s*b(?!it)"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else {
            return nil
        }
        let range = NSRange(value.startIndex..<value.endIndex, in: value)
        guard let match = regex.firstMatch(in: value, range: range),
              match.numberOfRanges > 1,
              let valueRange = Range(match.range(at: 1), in: value) else {
            return nil
        }
        return Double(String(value[valueRange]).replacingOccurrences(of: "_", with: "."))
    }

    static func formatGigabytes(_ bytes: Int64) -> String {
        let gigabytes = Double(max(bytes, 0)) / 1_000_000_000
        return String(format: "%.1f GB", gigabytes)
    }

    static func countDetail(_ count: Int?, singular: String, plural: String) -> String {
        guard let count else {
            return "\(plural) n/a"
        }
        let unit = count == 1 ? singular : plural
        return "\(count) \(unit)"
    }

    static func isUsableMLXModel(_ model: Model) -> Bool {
        let tags = model.tags ?? []
        let hasMLXTag = tags.contains { $0.localizedCaseInsensitiveContains("mlx") }
        let hasModelFiles = model.siblings?.contains { sibling in
            let filename = sibling.relativeFilename.lowercased()
            return filename == "config.json"
                || filename.hasSuffix(".safetensors")
                || filename.hasSuffix(".gguf")
        } ?? true
        return hasMLXTag && hasModelFiles && model.isDisabled != true
    }

    static func inferredRuntimeKind(from model: Model) -> MLXServerModelRuntimeKind {
        let searchable = ((model.tags ?? []) + [model.pipelineTag, model.library].compactMap { $0 })
            .joined(separator: " ")
            .lowercased()
        if searchable.contains("vision")
            || searchable.contains("image")
            || searchable.contains("vlm") {
            return .vlm
        }
        return .llm
    }

    static func inferredRuntimeKind(
        fromSnapshot snapshotURL: URL,
        fallback: MLXServerModelRuntimeKind
    ) -> MLXServerModelRuntimeKind {
        if let probe = decodeRuntimeKindProbe(from: snapshotURL),
           let preferredRuntimeKind = probe.preferredTextRuntimeKind {
            return preferredRuntimeKind
        }

        if hasVisionProcessorFiles(in: snapshotURL) {
            return .vlm
        }

        return fallback
    }

    static func inferredRuntimeKind(fromRepositoryID repositoryID: String) -> MLXServerModelRuntimeKind {
        let searchable = repositoryID.lowercased()
        if searchable.contains("vision")
            || searchable.contains("image")
            || searchable.contains("vlm") {
            return .vlm
        }
        return .llm
    }

    static func decodeRuntimeKindProbe(from snapshotURL: URL) -> ModelRuntimeKindProbe? {
        let configURL = snapshotURL.appendingPathComponent("config.json")
        guard let data = try? Data(contentsOf: configURL) else {
            return nil
        }
        return try? JSONDecoder().decode(ModelRuntimeKindProbe.self, from: data)
    }

}
