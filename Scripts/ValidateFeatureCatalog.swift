import Foundation

@main
enum ValidateFeatureCatalog {
    struct Root: Decodable { let schemaVersion: Int; let features: [Feature] }
    struct Feature: Decodable {
        let id: String
        let productName: String
        let sourceRelativePath: String
        let isInstalledOnLinux: Bool
    }

    static func main() throws {
        let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
        let catalogURL = root
            .appendingPathComponent("Sources/ZenPackageMetadata", isDirectory: true)
            .appendingPathComponent("feature-catalog.json")
        let data = try Data(contentsOf: catalogURL)
        let declarative = try JSONDecoder().decode(Root.self, from: data)
        let declarativeDuplicates = Dictionary(grouping: declarative.features, by: \.id)
            .filter { $0.value.count > 1 }.keys.sorted()
        guard declarativeDuplicates.isEmpty else {
            throw ValidationError("duplicate declarative feature ids: \(declarativeDuplicates.joined(separator: ", "))")
        }
        let swiftDuplicates = Dictionary(grouping: ZenBundledFeatureCatalog.all, by: \.id)
            .filter { $0.value.count > 1 }.keys.sorted()
        guard swiftDuplicates.isEmpty else {
            throw ValidationError("duplicate Swift feature ids: \(swiftDuplicates.joined(separator: ", "))")
        }
        let records = Dictionary(uniqueKeysWithValues: ZenBundledFeatureCatalog.all.map { ($0.id, $0) })
        guard Set(declarative.features.map(\.id)) == Set(records.keys) else {
            throw ValidationError("declarative and Swift catalog ids differ")
        }
        for feature in declarative.features {
            guard let record = records[feature.id],
                  record.productName == feature.productName,
                  record.sourceRelativePath == feature.sourceRelativePath,
                  record.isInstalledOnLinux == feature.isInstalledOnLinux else {
                throw ValidationError("catalog metadata differs for \(feature.id)")
            }
            let packageURL = root.appendingPathComponent(feature.sourceRelativePath, isDirectory: true)
            let packageManifest = packageURL.appendingPathComponent("Package.swift")
            guard FileManager.default.fileExists(atPath: packageManifest.path) else {
                throw ValidationError("missing package for \(feature.id): \(packageManifest.path)")
            }
        }

        let featuresRoot = root.appendingPathComponent("Sources/Features", isDirectory: true)
        let entries = try FileManager.default.contentsOfDirectory(at: featuresRoot, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles])
        for packageURL in entries where (try? packageURL.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true {
            let distributionURL = packageURL.appendingPathComponent("feature-distribution.json")
            guard FileManager.default.fileExists(atPath: distributionURL.path) else {
                throw ValidationError("missing per-package feature-distribution.json: \(packageURL.path)")
            }
            let object = try JSONSerialization.jsonObject(with: Data(contentsOf: distributionURL)) as? [String: Any]
            guard let id = object?["id"] as? String,
                  let productName = object?["productName"] as? String,
                  let relativePath = object?["sourceRelativePath"] as? String,
                  let linux = object?["isInstalledOnLinux"] as? Bool,
                  relativePath == packageURL.path.replacingOccurrences(of: root.path + "/", with: ""),
                  let catalogRecord = records[id],
                  catalogRecord.productName == productName,
                  catalogRecord.sourceRelativePath == relativePath,
                  catalogRecord.isInstalledOnLinux == linux else {
                throw ValidationError("invalid feature-distribution.json or catalog parity in \(packageURL.path)")
            }
            let manifest = try String(contentsOf: packageURL.appendingPathComponent("Package.swift"), encoding: .utf8)
            guard manifest.contains("// zencode:package-path"),
                  manifest.contains("../../.."),
                  manifest.contains("enableUpcomingFeature(\"MemberImportVisibility\")") else {
                throw ValidationError("promoted package \(id) is not promotion-ready")
            }
            try rejectSymlinks(below: packageURL)
        }
        print("Feature catalog valid (\(declarative.features.count) entries).")
    }

    static func rejectSymlinks(below root: URL) throws {
        guard let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isSymbolicLinkKey], options: [.skipsHiddenFiles]) else { return }
        while let url = enumerator.nextObject() as? URL {
            if try url.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink == true {
                throw ValidationError("symbolic link is not allowed in promoted package: \(url.path)")
            }
        }
    }

    struct ValidationError: LocalizedError {
        let message: String
        init(_ message: String) { self.message = message }
        var errorDescription: String? { message }
    }
}
