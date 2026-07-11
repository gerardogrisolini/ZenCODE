//
//  ZenCODESupport.swift
//  ZenCODE
//
//  Created by Gerardo Grisolini on 26/05/26.
//

#if canImport(Darwin)

import Darwin
#elseif canImport(Glibc)
import Glibc
#endif
import Dispatch
import Foundation
import ZenPackageMetadata

let agentVersion = ZenPackageMetadata.version

public enum SwiftPMResourceBundleDirectory {
    private static let environmentKey = "PACKAGE_RESOURCE_BUNDLE_PATH"

    public static func configure() {
        guard getenv(environmentKey) == nil,
              let executableDirectory = resolvedExecutableDirectory() else {
            return
        }
        setenv(environmentKey, executableDirectory, 0)
    }

    private static func resolvedExecutableDirectory() -> String? {
        let candidatePaths = [
            executablePathFromDyld(),
            CommandLine.arguments.first
        ].compactMap { path -> String? in
            let trimmedPath = path?.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmedPath?.isEmpty == false ? trimmedPath : nil
        }

        for candidatePath in candidatePaths {
            guard let resolvedPath = realPath(candidatePath) else {
                continue
            }
            return URL(fileURLWithPath: resolvedPath)
                .deletingLastPathComponent()
                .path
        }

        return nil
    }

    private static func executablePathFromDyld() -> String? {
        Bundle.main.executableURL?.path
    }

    private static func realPath(_ path: String) -> String? {
        var buffer = [CChar](repeating: 0, count: Int(PATH_MAX))
        guard realpath(path, &buffer) != nil else {
            return nil
        }
        let length = buffer.firstIndex(of: 0) ?? buffer.count
        let bytes = buffer[..<length].map { UInt8(bitPattern: $0) }
        return String(decoding: bytes, as: UTF8.self)
    }
}
