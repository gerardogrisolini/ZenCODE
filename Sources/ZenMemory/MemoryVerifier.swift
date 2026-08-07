import Foundation

/// Compatibility protocol for clients that previously used a post-retrieval verifier.
/// New code should prefer `MemorySelector`, which expresses the same role directly.
@available(*, deprecated, message: "Use MemorySelector instead")
public protocol MemoryVerifier: Sendable {
    func verify(context: String, candidates: [MemoryCandidate]) async throws -> [MemoryCandidate]
}

@available(*, deprecated, message: "Use TopScoreMemorySelector or a custom MemorySelector")
public struct PassthroughMemoryVerifier: MemoryVerifier {
    public init() {}
    public func verify(context: String, candidates: [MemoryCandidate]) async throws -> [MemoryCandidate] {
        candidates
    }
}

@available(*, deprecated, message: "Use MemorySelector directly")
public struct MemoryVerifierSelector: MemorySelector {
    public let verifier: any MemoryVerifier

    public init(_ verifier: any MemoryVerifier) {
        self.verifier = verifier
    }

    public func select(
        context: String,
        candidates: [MemoryCandidate],
        limit: Int
    ) async throws -> [MemoryCandidate] {
        Array(try await verifier.verify(context: context, candidates: candidates).prefix(limit))
    }
}
