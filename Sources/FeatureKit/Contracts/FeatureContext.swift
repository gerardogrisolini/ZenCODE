//
//  FeatureContext.swift
//  ZenCODE
//

import Foundation

public struct FeatureContext: Sendable {
    public let workingDirectory: URL
    public let environment: [String: String]

    public init(
        workingDirectory: URL = URL(fileURLWithPath: FileManager.default.currentDirectoryPath),
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) {
        self.workingDirectory = workingDirectory.standardizedFileURL
        self.environment = environment
    }

    public func resolvePath(_ path: String) -> URL {
        let expandedPath = NSString(string: path).expandingTildeInPath
        if expandedPath.hasPrefix("/") {
            return URL(fileURLWithPath: expandedPath).standardizedFileURL
        }
        return workingDirectory
            .appendingPathComponent(expandedPath)
            .standardizedFileURL
    }
}
