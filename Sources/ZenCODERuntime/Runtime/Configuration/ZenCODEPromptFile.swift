//
//  ZenCODEPromptFile.swift
//  ZenCODE
//
//  Created by Gerardo Grisolini on 25/10/26.
//

import Foundation

/// Reads the prompt file of `zen -f`; `/cron add -f` uses it to check a file before scheduling it.
public enum ZenCODEPromptFile {
    /// Only absolute paths are accepted; `~` is not expanded.
    public static func isAbsolutePath(_ path: String) -> Bool {
        path.hasPrefix("/")
    }

    /// The file as UTF-8 text, trimmed of whitespace and newlines.
    public static func read(
        path: String,
        fileManager: FileManager = .default
    ) throws -> String {
        guard isAbsolutePath(path) else {
            throw ZenCODEPromptFileError.notAbsolute(path: path)
        }
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: path, isDirectory: &isDirectory),
              !isDirectory.boolValue else {
            throw ZenCODEPromptFileError.unreadable(path: path)
        }
        let data: Data
        do {
            data = try Data(contentsOf: URL(fileURLWithPath: path))
        } catch {
            throw ZenCODEPromptFileError.unreadable(path: path)
        }
        guard let text = String(data: data, encoding: .utf8) else {
            throw ZenCODEPromptFileError.notUTF8(path: path)
        }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw ZenCODEPromptFileError.empty(path: path)
        }
        return trimmed
    }
}

public enum ZenCODEPromptFileError: LocalizedError, Equatable {
    case notAbsolute(path: String)
    case unreadable(path: String)
    case notUTF8(path: String)
    case empty(path: String)

    public var errorDescription: String? {
        switch self {
        case let .notAbsolute(path):
            return "The prompt file path must be absolute: \(path)."
        case let .unreadable(path):
            return "Cannot read the prompt file \(path)."
        case let .notUTF8(path):
            return "The prompt file \(path) is not UTF-8 text."
        case let .empty(path):
            return "The prompt file \(path) is empty."
        }
    }
}
