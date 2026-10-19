//  Created by Gerardo Grisolini on 30/05/26.
//
// SwiftFeaturePromotion+Catalog.swift

import Foundation
import ToolCore
import ZenPackageMetadata
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

extension SwiftFeatureRuntime {
    struct PromotionCatalogMetadata: Sendable {
        let id: String
        let productName: String
        let sourceRelativePath: String
        let description: String
        let toolNamePrefixes: [String]
        let toolNameAliases: [String]
        let discoversToolsAtRuntime: Bool
        let supportsPersistentSession: Bool
        let invocationTimeoutSeconds: TimeInterval?
        let isInstalledOnLinux: Bool

        init(
            id: String,
            manifest: SwiftFeatureManifest,
            packageContents: String,
            sourceRelativePath: String,
            isInstalledOnLinux: Bool,
            productName: String
        ) throws {
            self.id = id
            self.productName = productName.nilIfBlank
                ?? Self.productName(manifest: manifest, packageContents: packageContents, fallback: id)
            self.sourceRelativePath = sourceRelativePath
            self.description = manifest.description?.nilIfBlank
                ?? manifest.displayName?.nilIfBlank
                ?? "Swift feature for ZenCODE."
            self.toolNamePrefixes = Self.prefixes(manifest: manifest, id: id)
            self.toolNameAliases = manifest.toolNameAliases
            self.discoversToolsAtRuntime = manifest.discoversToolsAtRuntime
            self.supportsPersistentSession = manifest.supportsPersistentSession
            self.invocationTimeoutSeconds = manifest.invocationTimeoutSeconds
            self.isInstalledOnLinux = isInstalledOnLinux
        }

        static func productName(
            manifest: SwiftFeatureManifest,
            packageContents: String,
            fallback: String
        ) -> String {
            if let product = manifest.build?.product?.nilIfBlank {
                return product
            }
            let pattern = #"(?:name|product):\s*"([A-Za-z0-9._-]+)""#
            if let expression = try? NSRegularExpression(pattern: pattern),
               let match = expression.firstMatch(
                   in: packageContents,
                   range: NSRange(packageContents.startIndex..<packageContents.endIndex, in: packageContents)
               ),
               let range = Range(match.range(at: 1), in: packageContents),
               let value = String(packageContents[range]).nilIfBlank {
                return value
            }
            return fallback
        }

        static func prefixes(manifest: SwiftFeatureManifest, id: String) -> [String] {
            if !manifest.toolNamePrefixes.isEmpty { return manifest.toolNamePrefixes }
            if let name = manifest.tools.first?.name, let dot = name.firstIndex(of: ".") {
                return [String(name[...dot])]
            }
            return [SwiftFeatureRuntime.defaultToolPrefix(for: id) + "."]
        }
    }

    struct PromotionCatalogUpdate: Sendable {
        let url: URL
        let data: Data
    }

    func preparePromotionCatalogUpdates(
        metadata: PromotionCatalogMetadata,
        rootURL: URL,
        overwrite: Bool
    ) throws -> [PromotionCatalogUpdate] {
        let packageMetadataRoot = rootURL
            .appendingPathComponent("Sources", isDirectory: true)
            .appendingPathComponent("ZenPackageMetadata", isDirectory: true)
        let declarativeURL = packageMetadataRoot
            .appendingPathComponent(ZenBundledFeatureCatalog.declarativeCatalogFilename)
            .standardizedFileURL
        let distributionURL = packageMetadataRoot
            .appendingPathComponent("ZenBundledFeatureCatalog.swift")
            .standardizedFileURL
        let runtimeURL = rootURL
            .appendingPathComponent("Sources/ZenCODECore/Features/Catalog/SwiftBundledFeatureCatalog.swift")
            .standardizedFileURL

        let declarativeData = try promotionDeclarativeCatalogData(
            metadata: metadata, url: declarativeURL, overwrite: overwrite
        )
        var updates = [PromotionCatalogUpdate(url: declarativeURL, data: declarativeData)]
        if fileManager.fileExists(atPath: distributionURL.path) {
            updates.append(PromotionCatalogUpdate(
                url: distributionURL,
                data: try promotionDistributionCatalogData(from: declarativeData)
            ))
        }
        if fileManager.fileExists(atPath: runtimeURL.path) {
            let contents = try String(contentsOf: runtimeURL, encoding: .utf8)
            updates.append(PromotionCatalogUpdate(
                url: runtimeURL,
                data: Data(try promotionRuntimeCatalogContents(contents, metadata: metadata, overwrite: overwrite).utf8)
            ))
        }
        return updates
    }

    func promotionDistributionCatalogData(from declarativeData: Data) throws -> Data {
        guard let root = try JSONSerialization.jsonObject(with: declarativeData) as? [String: Any],
              let rawFeatures = root["features"] as? [[String: Any]] else {
            throw DirectToolError.permissionDenied("Could not generate the Swift feature catalog.")
        }
        let features = try rawFeatures.map { object -> (String, String, String, Bool) in
            guard let id = object["id"] as? String,
                  let product = object["productName"] as? String,
                  let path = object["sourceRelativePath"] as? String,
                  let linux = object["isInstalledOnLinux"] as? Bool else {
                throw DirectToolError.permissionDenied("Declarative feature catalog contains an incomplete entry.")
            }
            return (id, product, path, linux)
        }.sorted { $0.0 < $1.0 }
        let entries = features.map { feature in
            """
                    ZenBundledFeatureMetadata(
                        id: \(Self.swiftLiteral(feature.0)),
                        productName: \(Self.swiftLiteral(feature.1)),
                        sourceRelativePath: \(Self.swiftLiteral(feature.2)),
                        isInstalledOnLinux: \(feature.3),
                    )
            """
        }.joined(separator: ",\n")
        let output = """
        //
        //  ZenBundledFeatureCatalog.swift
        //  Generated by Scripts/GenerateFeatureCatalog.swift. Do not edit by hand.
        //

        public struct ZenBundledFeatureMetadata: Sendable, Equatable, Hashable {
            public let id: String
            public let productName: String
            public let sourceRelativePath: String
            public let isInstalledOnLinux: Bool

            public init(id: String, productName: String, sourceRelativePath: String, isInstalledOnLinux: Bool) {
                self.id = id
                self.productName = productName
                self.sourceRelativePath = sourceRelativePath
                self.isInstalledOnLinux = isInstalledOnLinux
            }
        }

        public enum ZenBundledFeatureCatalog {
            public static let declarativeCatalogFilename = "feature-catalog.json"

            public static let all: [ZenBundledFeatureMetadata] = [
        \(entries)
            ]

            public static func feature(id: String) -> ZenBundledFeatureMetadata? {
                all.first { $0.id == id }
            }

            public static var linuxInstallerProductNames: [String] {
                all.filter(\\.isInstalledOnLinux).map(\\.productName)
            }
        }
        """ + "\n"
        return Data(output.utf8)
    }

    func promotionDeclarativeCatalogData(
        metadata: PromotionCatalogMetadata,
        url: URL,
        overwrite: Bool
    ) throws -> Data {
        var root: [String: Any]
        if fileManager.fileExists(atPath: url.path) {
            guard let value = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any] else {
                throw DirectToolError.permissionDenied("Feature catalog is not a JSON object: \(url.path)")
            }
            root = value
        } else {
            root = ["schemaVersion": 1, "features": [[String: Any]]()]
        }
        var features = root["features"] as? [[String: Any]] ?? []
        let ids = features.compactMap { $0["id"] as? String }
        let duplicateIDs = Dictionary(grouping: ids, by: { $0 }).filter { $0.value.count > 1 }.keys.sorted()
        guard duplicateIDs.isEmpty else {
            throw DirectToolError.permissionDenied(
                "Feature catalog contains duplicate ids: \(duplicateIDs.joined(separator: ", "))."
            )
        }
        let products = features.compactMap { $0["productName"] as? String }
        let duplicateProducts = Dictionary(grouping: products, by: { $0 })
            .filter { $0.value.count > 1 }.keys.sorted()
        guard duplicateProducts.isEmpty else {
            throw DirectToolError.permissionDenied(
                "Feature catalog contains duplicate products: \(duplicateProducts.joined(separator: ", "))."
            )
        }
        if let collision = features.first(where: {
            ($0["productName"] as? String) == metadata.productName
                && ($0["id"] as? String) != metadata.id
        }), let collisionID = collision["id"] as? String {
            throw DirectToolError.permissionDenied(
                "Product '\(metadata.productName)' is already declared by feature '\(collisionID)'."
            )
        }
        let record = promotionCatalogJSONRecord(metadata)
        if let index = features.firstIndex(where: { $0["id"] as? String == metadata.id }) {
            guard overwrite else {
                throw DirectToolError.permissionDenied(
                    "Feature catalog already contains '\(metadata.id)'. Pass overwrite=true to replace it."
                )
            }
            features[index] = record
        } else {
            features.append(record)
        }
        features.sort { ($0["id"] as? String ?? "") < ($1["id"] as? String ?? "") }
        root["schemaVersion"] = (root["schemaVersion"] as? Int) ?? 1
        root["features"] = features
        var data = try JSONSerialization.data(
            withJSONObject: root,
            options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        )
        data.append(0x0A)
        return data
    }

    func promotionCatalogJSONRecord(_ metadata: PromotionCatalogMetadata) -> [String: Any] {
        var record: [String: Any] = [
            "id": metadata.id,
            "productName": metadata.productName,
            "sourceRelativePath": metadata.sourceRelativePath,
            "isInstalledOnLinux": metadata.isInstalledOnLinux,
            "description": metadata.description,
            "toolNamePrefixes": metadata.toolNamePrefixes
        ]
        if metadata.discoversToolsAtRuntime { record["discoversToolsAtRuntime"] = true }
        if !metadata.toolNameAliases.isEmpty { record["toolNameAliases"] = metadata.toolNameAliases }
        if metadata.supportsPersistentSession { record["supportsPersistentSession"] = true }
        if let timeout = metadata.invocationTimeoutSeconds {
            record["invocationTimeoutSeconds"] = timeout
        }
        return record
    }

    func promotionRuntimeCatalogContents(
        _ contents: String,
        metadata: PromotionCatalogMetadata,
        overwrite: Bool
    ) throws -> String {
        if contents.contains("id: \"\(metadata.id)\"") {
            if overwrite {
                throw DirectToolError.permissionDenied(
                    "Replacing an existing Swift catalog entry is not supported safely; choose a new feature id."
                )
            }
            throw DirectToolError.permissionDenied("Runtime catalog already contains '\(metadata.id)'.")
        }
        let marker = "        ]\n    }\n\n    private static func metadata"
        guard let range = contents.range(of: marker) else {
            throw DirectToolError.permissionDenied("Could not find runtime catalog insertion point.")
        }
        let timeout = metadata.invocationTimeoutSeconds.map { "\n                        invocationTimeoutSeconds: \($0)" } ?? ""
        let entry = """
            ,
                    SwiftFeatureRuntime.BundledFeatureDefinition(
                        id: \(Self.swiftLiteral(metadata.id)),
                        executableName: \(Self.swiftLiteral(metadata.productName)),
                        description: \(Self.swiftLiteral(metadata.description)),
                        sourceRelativePath: \(Self.swiftLiteral(metadata.sourceRelativePath)),
                        tools: [],
                        toolNamePrefixes: \(Self.swiftLiteralArray(metadata.toolNamePrefixes)),
                        toolNameAliases: \(Self.swiftLiteralArray(metadata.toolNameAliases)),
                        discoversToolsAtRuntime: \(metadata.discoversToolsAtRuntime),
                        supportsPersistentSession: \(metadata.supportsPersistentSession),\(timeout)
                    )
            """
        return contents.replacingCharacters(in: range, with: entry + String(contents[range.lowerBound...]))
    }
}
