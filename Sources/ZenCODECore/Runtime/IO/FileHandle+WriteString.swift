//
//  FileHandle+WriteString.swift
//  ZenCODE
//
//  Created by Gerardo Grisolini on 30/05/26.
//

import Foundation
import Synchronization

/// Neutral process-wide output serialization. A frontend may install a writer
/// for its terminal; unhandled destinations always pass through unchanged.
/// This boundary neither selects a screen nor discards output during prompts.
enum TerminalOutputSynchronization {
    private static let outputLock = NSRecursiveLock()
    typealias Writer = @Sendable (String, FileHandle) -> Bool
    private static let writer = Mutex<Writer?>(nil)

    static func installWriter(_ value: Writer?) { writer.withLock { $0 = value } }

    static func withTransaction<T>(_ body: () -> T) -> T {
        outputLock.lock()
        defer { outputLock.unlock() }
        return body()
    }

    static func write(_ string: String, to fileHandle: FileHandle) {
        withTransaction {
            let handler = writer.withLock { $0 }
            if handler?(string, fileHandle) == true { return }
            fileHandle.write(Data(string.utf8))
        }
    }

    /// Already-composed output bypasses the frontend writer, not the lock.
    static func writeOverlay(_ string: String, to fileHandle: FileHandle) {
        withTransaction { fileHandle.write(Data(string.utf8)) }
    }

    static func writeOverlay(_ data: Data, to fileHandle: FileHandle) {
        withTransaction { fileHandle.write(data) }
    }

    static func write(_ string: String, output: FileHandle?, sink: (@Sendable (String) -> Void)?) {
        guard !string.isEmpty else { return }
        withTransaction {
            if let sink { sink(string) }
            else { output?.write(Data(string.utf8)) }
        }
    }

    static func writeOverlay(_ string: String, output: FileHandle?, sink: (@Sendable (String) -> Void)?) {
        write(string, output: output, sink: sink)
    }
}

extension FileHandle {
    public func writeString(_ string: String) {
        TerminalOutputSynchronization.write(string, to: self)
    }
}
