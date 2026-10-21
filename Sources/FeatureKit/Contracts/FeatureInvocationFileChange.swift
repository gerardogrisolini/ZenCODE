import Foundation

/// Transient evidence of one on-disk file mutation performed by a feature
/// invocation, for features whose tools write files outside the host process
/// (for example through an application's MCP server). It crosses only the local
/// feature-process boundary: the host validates and bounds every entry before
/// turning it into tool-call file-change evidence, and never persists it.
///
/// `oldText == nil` with no explanation means the file did not exist before the
/// invocation; `newText == nil` with no explanation means it no longer exists.
/// A non-nil `explanation` marks evidence the feature could not capture
/// reliably; the host then reports the path without a diff.
public struct FeatureInvocationFileChange: Codable, Hashable, Sendable {
    /// Absolute local path of the changed file.
    public let path: String
    public let oldText: String?
    public let newText: String?
    public let explanation: String?

    public init(
        path: String,
        oldText: String?,
        newText: String?,
        explanation: String? = nil
    ) {
        self.path = path
        self.oldText = oldText
        self.newText = newText
        self.explanation = explanation
    }
}
