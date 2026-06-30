//
//  DeveloperToolEnvironment.swift
//  ZenCODE
//
//  Created by Gerardo Grisolini on 26/05/26.
//
import Foundation

#if canImport(Darwin) || canImport(Glibc)
public enum DeveloperToolEnvironment {
    public static func processEnvironment(
        base: [String: String] = ProcessInfo.processInfo.environment
    ) -> [String: String] {
        var environment = base
        environment["PATH"] = searchPathString(basePath: base["PATH"])
        return environment
    }

    public static func executableURL(named name: String) -> URL? {
        let fileManager = FileManager.default
        for directoryPath in searchPaths() {
            let candidateURL = URL(fileURLWithPath: directoryPath)
                .appendingPathComponent(name)
            if fileManager.isExecutableFile(atPath: candidateURL.path) {
                return candidateURL
            }
        }
        return nil
    }

    public static func searchPathString(basePath: String? = ProcessInfo.processInfo.environment["PATH"]) -> String {
        searchPaths(basePath: basePath).joined(separator: ":")
    }

    private static func searchPaths(basePath: String? = ProcessInfo.processInfo.environment["PATH"]) -> [String] {
        let basePaths = basePath?
            .split(separator: ":")
            .map(String.init) ?? []
        return uniquePaths(basePaths + fallbackPaths)
    }

    private static func uniquePaths(_ paths: [String]) -> [String] {
        var seen = Set<String>()
        var result: [String] = []
        for path in paths {
            let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, !seen.contains(trimmed) else {
                continue
            }
            seen.insert(trimmed)
            result.append(trimmed)
        }
        return result
    }

    private static let fallbackPaths = [
        "/usr/local/bin",
        "/usr/bin",
        "/bin"
    ]
}
#endif
