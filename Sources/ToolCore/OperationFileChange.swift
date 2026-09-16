import Foundation
import Synchronization

/// Transient operation evidence, never encoded into provider or saved-session DTOs.
public struct OperationFileChange: Sendable, Equatable {
    public let path: String
    public let oldText: String?
    public let newText: String?
    public let explanation: String?

    public init(path: String, oldText: String?, newText: String?, explanation: String? = nil) {
        self.path = path
        self.oldText = oldText
        self.newText = newText
        self.explanation = explanation
    }
}

public final class OperationFileChangeRecorder: Sendable {
    @TaskLocal public static var current: OperationFileChangeRecorder?
    /// Limits apply only to transient evidence, never to the file mutation.
    public static let maximumTextBytes = 64 * 1024
    public static let maximumOperationBytes = 256 * 1024
    private struct State {
        var changes: [OperationFileChange] = []
        var capturedBytes = 0
        var emittedBytes = 0
    }
    private let storage = Mutex(State())

    public init() {}

    /// Reserve before reading. Failed snapshots conservatively consume their reservation.
    public func reserveSnapshotBytes(_ count: Int) -> Bool {
        storage.withLock {
            guard count >= 0, count <= Self.maximumTextBytes,
                  count <= Self.maximumOperationBytes - $0.capturedBytes else { return false }
            $0.capturedBytes += count
            return true
        }
    }

    public func record(_ change: OperationFileChange) {
        storage.withLock {
            let oldCount = change.oldText?.utf8.count ?? 0
            let newCount = change.newText?.utf8.count ?? 0
            guard oldCount <= Self.maximumTextBytes, newCount <= Self.maximumTextBytes,
                  oldCount + newCount <= Self.maximumOperationBytes - $0.emittedBytes else {
                $0.changes.append(.init(path: change.path, oldText: nil, newText: nil,
                    explanation: "Diff unavailable: file or operation evidence exceeds the byte limit."))
                return
            }
            $0.emittedBytes += oldCount + newCount
            $0.changes.append(change)
        }
    }
    public var changes: [OperationFileChange] { storage.withLock { $0.changes } }
}

/// Conservative overlap detector for in-process shell, Git and opaque tools.
/// It carries no ownership or file contents; it only invalidates unsafe evidence.
public enum OperationMutationUncertainty {
    private struct State { var revision: UInt64 = 0; var active = 0 }
    private static let state = Mutex(State())
    public static func begin() { state.withLock { $0.revision &+= 1; $0.active += 1 } }
    public static func end() { state.withLock { $0.revision &+= 1; $0.active -= 1 } }
    public static var snapshot: UInt64? { state.withLock { $0.active == 0 ? $0.revision : nil } }
}
