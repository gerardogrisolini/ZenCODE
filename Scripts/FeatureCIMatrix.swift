import Foundation

@main
enum FeatureCIMatrix {
    struct Entry: Codable {
        let feature: String
        let product: String
        let packagePath: String
        let os: String
        let platform: String
        let container: String
    }

    struct Matrix: Codable {
        let include: [Entry]
    }

    static func main() throws {
        var entries: [Entry] = []
        for feature in ZenBundledFeatureCatalog.all {
            entries.append(
                Entry(
                    feature: feature.id,
                    product: feature.productName,
                    packagePath: feature.sourceRelativePath,
                    os: "macos-26",
                    platform: "macos",
                    container: ""
                )
            )
            if feature.isInstalledOnLinux {
                entries.append(
                    Entry(
                        feature: feature.id,
                        product: feature.productName,
                        packagePath: feature.sourceRelativePath,
                        os: "ubuntu-24.04",
                        platform: "linux",
                        container: "swift:6.3-noble"
                    )
                )
            }
        }
        let data = try JSONEncoder().encode(Matrix(include: entries))
        print(String(decoding: data, as: UTF8.self))
    }
}
