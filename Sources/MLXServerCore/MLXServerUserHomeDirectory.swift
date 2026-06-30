//
//  MLXServerUserHomeDirectory.swift
//  ZenCODE
//
//  Created by Gerardo Grisolini on 26/05/26.
//
import Foundation
import Darwin

enum MLXServerUserHomeDirectory {
    static func current(fileManager: FileManager = .default) -> URL {
        if let homeDirectoryPath = passwordDatabaseHomeDirectoryPath() {
            return URL(fileURLWithPath: homeDirectoryPath, isDirectory: true)
                .standardizedFileURL
        }

        return fileManager.homeDirectoryForCurrentUser.standardizedFileURL
    }

    private static func passwordDatabaseHomeDirectoryPath() -> String? {
        var passwdEntry = passwd()
        var result: UnsafeMutablePointer<passwd>?
        let suggestedBufferSize = sysconf(_SC_GETPW_R_SIZE_MAX)
        let bufferSize = max(suggestedBufferSize > 0 ? Int(suggestedBufferSize) : 0, 1024)
        var buffer = [CChar](repeating: 0, count: bufferSize)

        let status = getpwuid_r(
            getuid(),
            &passwdEntry,
            &buffer,
            buffer.count,
            &result
        )
        guard status == 0, let result, let homeDirectory = result.pointee.pw_dir else {
            return nil
        }

        let path = String(cString: homeDirectory)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return path.isEmpty ? nil : path
    }
}
