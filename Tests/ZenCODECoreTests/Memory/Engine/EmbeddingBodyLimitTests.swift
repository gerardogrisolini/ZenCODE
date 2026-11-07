//
//  EmbeddingBodyLimitTests.swift
//  ZenCODECoreTests (memory engine)
//

import Foundation
import Testing
@testable import ZenCODECore

@Suite(.timeLimit(.minutes(1)))
struct EmbeddingBodyLimitTests {
    @Test
    func responseBeyondTheLimitFailsBeforeReadingFurtherChunks() async throws {
        let limit = OpenAICompatibleEmbeddingProvider.maximumResponseBodyBytes
        let fixture = try await RemoteNIOStreamingFixture.start(
            responseBody: Data(),
            responseStatus: 200,
            responseHeaders: [
                RemoteHTTPHeader(name: "content-type", value: "application/json")
            ],
            // The second chunk crosses the boundary. The collector must reject
            // it before appending it or waiting for any later chunk.
            bodyChunks: [
                Data(repeating: 0x20, count: limit),
                Data([0x20]),
                Data(repeating: 0x20, count: 256 * 1_024)
            ]
        )

        let provider = OpenAICompatibleEmbeddingProvider(
            endpoint: fixture.baseURL.appendingPathComponent("embeddings"),
            transport: fixture.transport
        )

        do {
            _ = try await provider.embed("oversized response")
            Issue.record("expected an oversized embedding response to fail")
        } catch let error as OpenAICompatibleEmbeddingError {
            switch error {
            case let .responseBodyTooLarge(maximumBytes):
                #expect(maximumBytes == limit)
            default:
                Issue.record("unexpected embedding error: \(error)")
            }
        } catch {
            await fixture.shutdown()
            throw error
        }

        await fixture.shutdown()
    }
}
