//
//  FileTransactionCoordinator.swift
//  ZenCODE
//

import Foundation
import Synchronization

/// Serializes complete file transactions within this process by standardized
/// file URL. This deliberately provides no inter-process coordination.
final class FileTransactionCoordinator: Sendable {
    static let shared = FileTransactionCoordinator()

    private final class DocumentLock: Sendable {
        private let mutex = Mutex(())

        func withLock<T>(_ body: () throws -> T) rethrows -> T {
            try mutex.withLock { _ in
                try body()
            }
        }
    }

    private let locks = Mutex<[URL: DocumentLock]>([:])

    func withLock<T>(for fileURL: URL, _ body: () throws -> T) rethrows -> T {
        let standardizedURL = fileURL.standardizedFileURL
        let documentLock = locks.withLock { locks in
            if let existingLock = locks[standardizedURL] {
                return existingLock
            }

            let newLock = DocumentLock()
            locks[standardizedURL] = newLock
            return newLock
        }
        return try documentLock.withLock(body)
    }
}
