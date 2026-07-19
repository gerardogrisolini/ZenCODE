//
//  ACPVerboseLogFile.swift
//  ZenCODE
//
//  Created by Gerardo Grisolini on 10/06/26.
//

import Foundation

public actor ACPVerboseLogFile {
    public nonisolated let url: URL

    private let handle: FileHandle

    private init(url: URL, handle: FileHandle) {
        self.url = url
        self.handle = handle
    }

    public static func open(
        fileManager: FileManager = .default,
        supportDirectoryURL: URL = AppStorageDirectory.appSupportDirectoryURL()
    ) -> ACPVerboseLogFile? {
        let directoryURL = supportDirectoryURL
            .appendingPathComponent("logs", isDirectory: true)
            .standardizedFileURL
        do {
            try fileManager.createDirectory(
                at: directoryURL,
                withIntermediateDirectories: true
            )
            let filename = "acp-\(filenameTimestamp())-\(ProcessInfo.processInfo.processIdentifier).log"
            let url = directoryURL.appendingPathComponent(filename)
            if !fileManager.fileExists(atPath: url.path) {
                _ = fileManager.createFile(atPath: url.path, contents: nil)
            }
            let handle = try FileHandle(forWritingTo: url)
            handle.seekToEndOfFile()
            return ACPVerboseLogFile(url: url, handle: handle)
        } catch {
            return nil
        }
    }

    public func write(_ message: String) {
        let line = "\(Self.lineTimestamp()) \(message.trimmingCharacters(in: .newlines))\n"
        guard let data = line.data(using: .utf8) else {
            return
        }
        handle.write(data)
        handle.synchronizeFile()
    }

    deinit {
        handle.closeFile()
    }

    private static func filenameTimestamp() -> String {
        timestamp(format: "yyyyMMdd-HHmmss")
    }

    private static func lineTimestamp() -> String {
        timestamp(format: "yyyy-MM-dd'T'HH:mm:ss.SSSZZZZZ")
    }

    private static func timestamp(format: String) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = format
        return formatter.string(from: Date())
    }
}
