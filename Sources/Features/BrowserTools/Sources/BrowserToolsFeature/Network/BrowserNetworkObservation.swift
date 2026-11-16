//
//  BrowserNetworkObservation.swift
//  BrowserToolsFeature
//
//  Result of a network observation snapshot, plus the response-body candidate
//  and fetching types used to capture bodies afterwards.
//

import Foundation
import Synchronization

struct BrowserNetworkObservation: Sendable {
    let entries: [BrowserNetworkEntry]
    let truncated: Bool
    let captureTruncated: Bool
    let totalCapturedEntries: Int
    let totalMatchingEntries: Int
    let summary: BrowserNetworkSummary

    /// Request identifiers are intentionally only an invocation-local bridge
    /// to Network.getResponseBody. They are not Codable and are discarded
    /// before BrowserNetworkOutput is constructed.
    private let bodyCandidates: [BrowserNetworkBodyCandidate]

    init(
        entries: [BrowserNetworkEntry],
        truncated: Bool,
        captureTruncated: Bool,
        totalCapturedEntries: Int,
        totalMatchingEntries: Int,
        summary: BrowserNetworkSummary,
        bodyCandidates: [BrowserNetworkBodyCandidate] = []
    ) {
        self.entries = entries
        self.truncated = truncated
        self.captureTruncated = captureTruncated
        self.totalCapturedEntries = totalCapturedEntries
        self.totalMatchingEntries = totalMatchingEntries
        self.summary = summary
        self.bodyCandidates = bodyCandidates
    }

    func capturingBodies(from responseBodyFetcher: any BrowserNetworkResponseBodyFetching) async -> Self {
        guard !bodyCandidates.isEmpty else { return withoutBodyCandidates() }
        let bodies = await BrowserNetworkBodyCapture.capture(from: responseBodyFetcher, candidates: bodyCandidates)
        guard !bodies.isEmpty else { return withoutBodyCandidates() }

        var amendedEntries = entries
        for (index, body) in bodies where amendedEntries.indices.contains(index) {
            amendedEntries[index].responseBody = body
        }
        return Self(
            entries: amendedEntries,
            truncated: truncated,
            captureTruncated: captureTruncated,
            totalCapturedEntries: totalCapturedEntries,
            totalMatchingEntries: totalMatchingEntries,
            summary: summary
        )
    }

    private func withoutBodyCandidates() -> Self {
        Self(
            entries: entries,
            truncated: truncated,
            captureTruncated: captureTruncated,
            totalCapturedEntries: totalCapturedEntries,
            totalMatchingEntries: totalMatchingEntries,
            summary: summary
        )
    }
}

struct BrowserNetworkBodyCandidate: Sendable {
    let outputIndex: Int
    let requestID: String
    let mimeType: String
    let encodedDataLength: Int64
}

struct BrowserNetworkResponseBodyPayload: Sendable {
    let body: String
    let isBase64Encoded: Bool
}

/// Keeps CDP transport details out of the observation so redirect/body
/// association can be tested with the same request-ID semantics as production.
protocol BrowserNetworkResponseBodyFetching: Sendable {
    func responseBody(for requestID: String) async throws -> BrowserNetworkResponseBodyPayload?
}

extension CDPSession: BrowserNetworkResponseBodyFetching {
    func responseBody(for requestID: String) async throws -> BrowserNetworkResponseBodyPayload? {
        let response = try await send(method: "Network.getResponseBody", params: ["requestId": requestID])
        guard let result = response["result"] as? [String: Any],
              let body = result["body"] as? String
        else {
            return nil
        }
        return BrowserNetworkResponseBodyPayload(
            body: body,
            isBase64Encoded: BrowserNetworkValue.bool(result["base64Encoded"]) ?? false
        )
    }
}
