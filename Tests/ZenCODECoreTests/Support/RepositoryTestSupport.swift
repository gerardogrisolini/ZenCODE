import Foundation

enum RepositoryTestSupport {
    static func packageRoot(containing sourceFilePath: String) throws -> URL {
        let fileManager = FileManager.default
        var directoryURL = URL(fileURLWithPath: sourceFilePath)
            .standardizedFileURL
            .deletingLastPathComponent()

        while true {
            let manifestURL = directoryURL.appendingPathComponent("Package.swift")
            if fileManager.fileExists(atPath: manifestURL.path) {
                return directoryURL
            }

            let parentURL = directoryURL.deletingLastPathComponent()
            guard parentURL.path != directoryURL.path else {
                throw RepositoryRootError.packageManifestNotFound(sourceFilePath)
            }
            directoryURL = parentURL
        }
    }

    private enum RepositoryRootError: Error, LocalizedError {
        case packageManifestNotFound(String)

        var errorDescription: String? {
            switch self {
            case let .packageManifestNotFound(sourceFilePath):
                "Could not find Package.swift while walking ancestors of \(sourceFilePath)."
            }
        }
    }
}
