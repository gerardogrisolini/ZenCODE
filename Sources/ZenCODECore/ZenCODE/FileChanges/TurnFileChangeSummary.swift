//
//  TurnFileChangeSummary.swift
//  ZenCODE
//
//  Created by Gerardo Grisolini on 26/05/26.
//
import Foundation

public struct TurnFileChangeSummary: Codable, Hashable, Sendable {
    public struct Entry: Codable, Hashable, Sendable, Identifiable {
        public enum Status: String, Codable, Hashable, Sendable {
            case added
            case modified
            case deleted
        }

        public let path: String
        public let additions: Int
        public let deletions: Int
        public let status: Status
        public let isBinary: Bool
        public let existedBefore: Bool?
        public let beforeDataBase64: String?
        public let patch: String?

        public init(
            path: String,
            additions: Int,
            deletions: Int,
            status: Status,
            isBinary: Bool,
            existedBefore: Bool?,
            beforeDataBase64: String?,
            patch: String?
        ) {
            self.path = path
            self.additions = additions
            self.deletions = deletions
            self.status = status
            self.isBinary = isBinary
            self.existedBefore = existedBefore
            self.beforeDataBase64 = beforeDataBase64
            self.patch = patch
        }

        public var id: String {
            path
        }

        public var canUndo: Bool {
            switch existedBefore {
            case false:
                return true
            case true:
                return beforeData != nil
            case nil:
                return patch != nil
            }
        }

        public var beforeData: Data? {
            guard let beforeDataBase64 else {
                return nil
            }

            return Data(base64Encoded: beforeDataBase64)
        }
    }

    public let entries: [Entry]

    public init(entries: [Entry]) {
        self.entries = entries
    }

    public var fileCount: Int {
        entries.count
    }

    public var totalAdditions: Int {
        entries.reduce(0) { $0 + $1.additions }
    }

    public var totalDeletions: Int {
        entries.reduce(0) { $0 + $1.deletions }
    }

    public var canUndo: Bool {
        !entries.isEmpty && entries.allSatisfy(\.canUndo)
    }

    public func encodedString() -> String? {
        let encoder = JSONEncoder()
        guard let data = try? encoder.encode(self) else {
            return nil
        }

        return String(data: data, encoding: .utf8)
    }

    public static func decode(from rawValue: String) -> TurnFileChangeSummary? {
        let trimmedValue = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedValue.isEmpty,
              let data = trimmedValue.data(using: .utf8) else {
            return nil
        }

        return try? JSONDecoder().decode(TurnFileChangeSummary.self, from: data)
    }
}
