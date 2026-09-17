import Foundation

/// Transient, transport-neutral access to text owned by the embedding editor.
/// Inherited by child tasks, never encoded in a session or supplied by the model.
/// A missing operation preserves local I/O; an operation that throws never falls
/// back to disk (which may differ from the editor's unsaved buffer).
public struct ClientTextFileSystem: Sendable {
    public typealias Read = @Sendable (URL) async throws -> String
    public typealias Write = @Sendable (URL, String) async throws -> Void
    public typealias Transform = @Sendable (String) throws -> String
    public typealias Edit = @Sendable (URL, @escaping Transform) async throws -> (before: String, after: String)

    @TaskLocal public static var current: ClientTextFileSystem?

    public let read: Read?
    public let write: Write?
    public let edit: Edit?

    public init(read: Read?, write: Write?, edit: Edit?) {
        self.read = read
        self.write = write
        self.edit = edit
    }
}
