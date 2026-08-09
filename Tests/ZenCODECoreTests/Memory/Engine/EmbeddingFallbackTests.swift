//
//  EmbeddingFallbackTests.swift
//  ZenCODECoreTests (memory engine)
//
//  Verifies that an embedding-endpoint failure during recall/search never
//  fails the whole retrieval: the engine emits a redacted, always-visible
//  error line on the preserved stderr descriptor (plus the opt-in ZenLogger
//  file channel unless it already targets stderr) and continues with BM25-only
//  results. Cancellation is never degraded into a fallback.
//

import Foundation
import Synchronization
import Testing
@testable import ZenCODECore

// MARK: - Doubles

/// An embedder whose endpoint is unreachable: every call throws a generic error.
private struct AlwaysFailingEmbeddingProvider: EmbeddingProvider {
    struct EndpointUnavailable: Error {}
    let modelID = "failing-embedding-test-model"
    func embed(_ text: String) async throws -> [Float] {
        throw EndpointUnavailable()
    }
}

/// An embedder that fails with an OpenAI-compatible HTTP error carrying a body
/// that echoes input-like or credential-like content. Proves the diagnostic
/// summary never includes the response body.
private struct HTTPFailingEmbeddingProvider: EmbeddingProvider {
    let modelID = "failing-embedding-test-model"
    func embed(_ text: String) async throws -> [Float] {
        throw OpenAICompatibleEmbeddingError.httpStatus(503, "upstream echoed input or a secret")
    }
}

/// An embedder that surfaces a caller-initiated cancellation as a
/// transport-style `URLError.cancelled` instead of `CancellationError`, so the
/// engine's generic catch must convert it back via `Task.checkCancellation()`.
private struct CancellationSurfacingEmbeddingProvider: EmbeddingProvider {
    let modelID = "failing-embedding-test-model"
    func embed(_ text: String) async throws -> [Float] {
        while !Task.isCancelled {
            try? await Task.sleep(for: .milliseconds(10))
        }
        throw URLError(.cancelled)
    }
}

// MARK: - Tests

@Suite(.serialized)
struct EmbeddingFallbackTests {
    @Test
    func recallFallsBackToBM25WhenEmbeddingFails() async throws {
        let engine = MemoryEngine(embedder: AlwaysFailingEmbeddingProvider())
        try await engine.insert(
            EngineMemoryEntry(id: "a", category: .fact, content: "Swift actors protect mutable state"),
            persist: false
        )
        try await engine.insert(
            EngineMemoryEntry(id: "b", category: .fact, content: "Postgres migrations run at startup"),
            persist: false
        )

        // Must not throw: the embedding failure is contained and the retrieval
        // continues with the BM25 results that were already computed.
        let results = try await engine.recall("Swift actors")
        #expect(!results.isEmpty)
        #expect(results.contains { $0.memory.content.contains("actors") })
    }

    @Test
    func searchReadOnlyFallsBackToBM25WhenEmbeddingFails() async throws {
        let engine = MemoryEngine(embedder: AlwaysFailingEmbeddingProvider())
        try await engine.insert(
            EngineMemoryEntry(id: "a", category: .fact, content: "Swift actors protect mutable state"),
            persist: false
        )
        try await engine.insert(
            EngineMemoryEntry(id: "b", category: .fact, content: "Postgres migrations run at startup"),
            persist: false
        )

        // Same guarantee on the read-only `memory.search` path.
        let results = try await engine.searchReadOnly("actors mutable state")
        #expect(!results.isEmpty)
        #expect(results.allSatisfy { $0.memory.content.contains("actors") })
    }

    @Test
    func embeddingFailureEmitsRedactedDiagnosticAndContinues() async throws {
        let messages = Mutex<[String]>([])
        let engine = MemoryEngine(
            embedder: HTTPFailingEmbeddingProvider(),
            semanticFailureReporter: { message in
                messages.withLock { $0.append(message) }
            }
        )
        try await engine.insert(
            EngineMemoryEntry(id: "a", category: .fact, content: "Swift actors protect mutable state"),
            persist: false
        )

        // Retrieval still succeeds and returns BM25 hits.
        let results = try await engine.recall("Swift actors protect")
        #expect(!results.isEmpty)

        // Exactly one aggregated diagnostic was emitted through the reporter,
        // with a stable, status-only summary — never the input, the response
        // body, vectors, URLs, credentials, or the embedding model id.
        let recorded = messages.withLock { $0 }
        #expect(recorded.count == 1)
        let message = try #require(recorded.first)
        #expect(message.contains("BM25-only results"))
        #expect(message.contains("httpStatus 503"))
        #expect(!message.contains("Swift actors protect"))
        #expect(!message.contains("upstream echoed"))
        #expect(!message.contains("sk-"))
        #expect(!message.contains("failing-embedding-test-model"))

        // The default reporter renders the same body as a memory-category
        // ERROR line (its visible stderr emission is proven by
        // visibleEmissionIsRedactedAndAlwaysOnStderr).
        let rendered = ZenLogger.formattedMessage(level: .error, category: .memory, message: message)
        #expect(rendered.contains("[MemoryService][ERROR]"))
        #expect(!rendered.contains("Swift actors protect"))
        #expect(!rendered.contains("upstream echoed"))
    }

    @Test
    func visibleEmissionIsRedactedAndAlwaysOnStderr() throws {
        // The default reporter's visible path is exercised through its writer
        // seam: nothing is written to the real process stderr.
        var captured: [Data] = []
        MemorySemanticFallbackDiagnostics.emitVisibleError(
            message: "semantic embedding retrieval failed (httpStatus 503); continuing with BM25-only results (failedQueries=1/1).",
            loggerDestination: nil,
            stderrWriter: { captured.append($0) }
        )

        #expect(captured.count == 1)
        let line = try #require(String(data: captured[0], encoding: .utf8))
        #expect(line.hasSuffix("\n"))
        #expect(line.contains("[MemoryService][ERROR]"))
        #expect(line.contains("BM25-only results"))
        #expect(!line.contains("Swift actors protect"))
    }

    @Test
    func visibleLineIsRedactedEvenIfMessageCarriesSecretShapes() throws {
        // Belt and suspenders: the visible line goes through the same redactor
        // as the diagnostic file, so even a future message regression cannot
        // leak a credential-shaped value to the visible stderr line.
        let secret = "sk-abcdefghijklmnopqrstuvwxyz123456"
        var captured: [Data] = []
        MemorySemanticFallbackDiagnostics.emitVisibleError(
            message: "semantic embedding retrieval failed (httpStatus 500); api_key=\(secret)",
            loggerDestination: nil,
            stderrWriter: { captured.append($0) }
        )

        let capturedData = try #require(captured.first)
        let line = try #require(String(data: capturedData, encoding: .utf8))
        #expect(!line.contains(secret))
        #expect(line.contains(ZenSecretRedactor.placeholder))
    }

    @Test
    func zenLoggerFileChannelIsKeptButStderrIsNotDuplicated() throws {
        // The diagnostic-file channel still receives the line when it targets
        // a file (or is disabled, where the call is a harmless no-op)...
        #expect(MemorySemanticFallbackDiagnostics.shouldDuplicateToZenLogger(destinationDescription: "/tmp/memory.log") == true)
        #expect(MemorySemanticFallbackDiagnostics.shouldDuplicateToZenLogger(destinationDescription: nil) == true)
        // ...but never twice when the logger already writes to stderr.
        #expect(MemorySemanticFallbackDiagnostics.shouldDuplicateToZenLogger(destinationDescription: "stderr") == false)
    }

    @Test
    func cancelledEmbeddingIsNotDegradedToBM25Fallback() async throws {
        let engine = MemoryEngine(embedder: CancellationSurfacingEmbeddingProvider())
        try await engine.insert(
            EngineMemoryEntry(id: "a", category: .fact, content: "Swift actors protect mutable state"),
            persist: false
        )

        let task = Task { try await engine.recall("Swift actors") }
        try await Task.sleep(for: .milliseconds(100))
        task.cancel()

        do {
            _ = try await task.value
            Issue.record("expected the cancellation to propagate, not a BM25 fallback")
        } catch is CancellationError {
            // Expected: the degraded URLError.cancelled was converted back.
        } catch {
            Issue.record("unexpected error type: \(error)")
        }
    }
}
