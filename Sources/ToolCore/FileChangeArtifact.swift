//  Created by Gerardo Grisolini on 30/05/26.
//
import Foundation

/// Neutral, in-memory evidence for one file mutation.
///
/// This type is intentionally not part of saved sessions, checkpoints,
/// transcripts, or ACP wire DTOs. Renderers can project the same evidence into
/// terminal output or standard ACP content without re-discovering paths or
/// making different binary/uncertain-content decisions.
public struct FileChangeArtifact: Sendable, Equatable, Hashable {
    public enum Status: String, Sendable, Equatable, Hashable {
        case added
        case modified
        case deleted
        case unknown
    }

    public let absolutePath: String
    public let displayPath: String
    public let status: Status
    public let additions: Int
    public let deletions: Int
    public let isBinary: Bool
    public let oldText: String?
    public let newText: String?
    public let patch: String?
    public let explanation: String?

    public init(
        absolutePath: String,
        displayPath: String,
        status: Status,
        additions: Int = 0,
        deletions: Int = 0,
        isBinary: Bool = false,
        oldText: String? = nil,
        newText: String? = nil,
        patch: String? = nil,
        explanation: String? = nil
    ) {
        self.absolutePath = absolutePath
        self.displayPath = displayPath
        self.status = status
        self.additions = max(0, additions)
        self.deletions = max(0, deletions)
        self.isBinary = isBinary
        self.oldText = oldText
        self.newText = newText
        self.patch = patch
        self.explanation = explanation
    }
}
