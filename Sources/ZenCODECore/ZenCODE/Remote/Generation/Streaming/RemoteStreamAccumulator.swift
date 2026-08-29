//
//  RemoteStreamAccumulator.swift
//  ZenCODE
//
//  Accumulates streamed deltas into a final RemoteStreamResult. Extracted from
//  RemoteGenerationClient+Streaming to keep streaming logic focused.
//

import Foundation
import ToolCore

/// Accumulates text, reasoning, tool calls, usage, and stop-reason from
/// parsed stream events and produces a `RemoteStreamResult`.
public struct RemoteStreamAccumulator {
    private var accumulatedText = ""
    private var accumulatedReasoningText = ""
    private var stopReason = "end_turn"
    private var toolCallAccumulator = RemoteToolCallAccumulator()
    private var firstDeltaAt: Date?
    private var usage: RemoteGenerationUsage?
    private var contentNormalizer = ThinkingBoundarySpacingNormalizer()
    private var reasoningContentClosed = false
    private var reasoningItems: [[String: Any]] = []
    private var reasoningItemIndexByID: [String: Int] = [:]
    /// Only a proper prefix of a closing marker can matter across two deltas.
    /// Retaining the complete accumulated reasoning here would make every token
    /// rescan and copy all prior output, producing quadratic allocator growth.
    private var reasoningClosingMarkerPrefix = ""

    private static let reasoningClosingMarkers = [
        "</think>", "</thinking>", "<channel|>"
    ]
    private static let reasoningClosingMarkerBytes = reasoningClosingMarkers.map {
        Array($0.utf8)
    }
    static let maximumReasoningClosingMarkerLookbehindByteCount = max(
        0,
        (reasoningClosingMarkerBytes.map(\.count).max() ?? 1) - 1
    )

    /// Internal diagnostic used by the regression test to keep the cross-delta
    /// boundary state independent of the total reasoning response size.
    var reasoningClosingMarkerLookbehindByteCount: Int {
        reasoningClosingMarkerPrefix.utf8.count
    }

    public init() {}

    // MARK: - Ingest

    public mutating func ingest(
        _ event: ParsedRemoteStreamEvent,
        onEvent: @escaping @Sendable (DirectAgentEvent) async -> Void
    ) async throws {
        switch event {
        case let .content(delta):
            await appendContent(delta, onEvent: onEvent)
        case let .contentSnapshot(snapshot):
            let delta = RemoteStreamAccumulator.streamContentDelta(
                fromSnapshot: snapshot,
                accumulatedText: accumulatedText
            )
            await appendContent(delta, onEvent: onEvent)
        case let .reasoning(delta):
            await appendReasoning(delta, onEvent: onEvent)
        case let .toolCallDelta(rawToolCalls):
            markFirstDelta()
            toolCallAccumulator.ingestChatCompletionToolCalls(rawToolCalls)
        case let .responseToolCallItem(item, outputIndex):
            markFirstDelta()
            toolCallAccumulator.ingestResponseToolCallItem(item, outputIndex: outputIndex)
        case let .responseReasoningItem(item):
            markFirstDelta()
            appendReasoningItemIfReplayable(item)
        case let .responseToolCallArgumentsDelta(event):
            markFirstDelta()
            toolCallAccumulator.ingestResponseToolCallArgumentsDelta(event)
        case let .responseToolCallArgumentsDone(event):
            markFirstDelta()
            toolCallAccumulator.ingestResponseToolCallArgumentsDone(event)
        case .discardToolCalls:
            toolCallAccumulator = RemoteToolCallAccumulator()
        case let .stop(reason):
            if stopReason == "refusal", reason == "end_turn" {
                break
            }
            stopReason = reason
        case let .failure(message):
            throw RemoteGenerationClientError.remoteFailure(message)
        case let .usage(remoteUsage):
            usage = remoteUsage
        case .ignored:
            break
        }
    }

    // MARK: - Finish

    public mutating func finish(
        onEvent: @escaping @Sendable (DirectAgentEvent) async -> Void
    ) async {
        let normalizedRemainder = contentNormalizer.finish()
        guard !normalizedRemainder.isEmpty else {
            return
        }
        markFirstDelta()
        accumulatedText.append(normalizedRemainder)
        await onEvent(.content(normalizedRemainder))
    }

    // MARK: - Result

    public func result(requestStartedAt: Date) throws -> RemoteStreamResult {
        let toolCalls = try toolCallAccumulator.finalize()
        return RemoteStreamResult(
            text: accumulatedText,
            reasoningText: accumulatedReasoningText,
            stopReason: toolCalls.isEmpty ? stopReason : "tool_calls",
            toolCalls: toolCalls,
            stats: RemoteGenerationStats(
                usage: usage,
                requestStartedAt: requestStartedAt,
                firstDeltaAt: firstDeltaAt,
                finishedAt: Date(),
                generatedCharacterCount: accumulatedText.count
            ),
            reasoningItemsJSON: reasoningItemsJSON()
        )
    }

    // MARK: - Content helpers

    private mutating func appendContent(
        _ delta: String,
        onEvent: @escaping @Sendable (DirectAgentEvent) async -> Void
    ) async {
        guard !delta.isEmpty else {
            return
        }
        markFirstDelta()
        let normalizedDelta = contentNormalizer.append(delta)
        guard !normalizedDelta.isEmpty else {
            return
        }
        accumulatedText.append(normalizedDelta)
        await onEvent(.content(normalizedDelta))
    }

    private mutating func appendReasoning(
        _ delta: String,
        onEvent: @escaping @Sendable (DirectAgentEvent) async -> Void
    ) async {
        guard !delta.isEmpty else {
            return
        }
        if reasoningContentClosed {
            await appendContent(delta, onEvent: onEvent)
            return
        }

        let lookbehind = reasoningClosingMarkerPrefix
        let boundaryText = lookbehind + delta
        if let closingMarker = Self.firstReasoningClosingMarker(in: boundaryText) {
            reasoningClosingMarkerPrefix = ""
            let boundaryUTF8 = boundaryText.utf8
            guard let markerEnd = closingMarker.range.upperBound.samePosition(
                in: boundaryUTF8
            ) else {
                // Closing markers are ASCII, so their end is always a UTF-8
                // boundary. Keep a defensive linear fallback if that invariant
                // is ever changed by a future marker.
                await appendThoughtDelta(delta, onEvent: onEvent)
                return
            }
            let markerEndByteOffset = boundaryUTF8.distance(
                from: boundaryUTF8.startIndex,
                to: markerEnd
            )
            let deltaUTF8 = delta.utf8
            let thoughtByteCount = min(
                max(markerEndByteOffset - lookbehind.utf8.count, 0),
                deltaUTF8.count
            )
            let splitIndex = deltaUTF8.index(
                deltaUTF8.startIndex,
                offsetBy: thoughtByteCount
            )
            let thoughtDelta = String(
                decoding: deltaUTF8[..<splitIndex],
                as: UTF8.self
            )
            let contentDelta = String(
                decoding: deltaUTF8[splitIndex...],
                as: UTF8.self
            )

            await appendThoughtDelta(thoughtDelta, onEvent: onEvent)
            reasoningContentClosed = true
            await appendContent(contentDelta, onEvent: onEvent)
            return
        }

        reasoningClosingMarkerPrefix = Self.trailingReasoningClosingMarkerPrefix(
            in: boundaryText
        )
        await appendThoughtDelta(delta, onEvent: onEvent)
    }

    private mutating func appendThoughtDelta(
        _ delta: String,
        onEvent: @escaping @Sendable (DirectAgentEvent) async -> Void
    ) async {
        guard !delta.isEmpty else {
            return
        }
        markFirstDelta()
        accumulatedReasoningText.append(delta)
        await onEvent(.thought(delta))
    }

    private mutating func appendReasoningItemIfReplayable(_ item: [String: Any]) {
        guard RemoteGenerationClient.responseReasoningItemHasReplayableContent(item) else {
            return
        }
        let sanitizedItem = RemoteGenerationClient.sanitizedResponseReasoningItem(item)
        guard let id = RemoteGenerationClient.stringValue(item["id"])?.nilIfBlank else {
            reasoningItems.append(sanitizedItem)
            return
        }
        if let existingIndex = reasoningItemIndexByID[id] {
            reasoningItems[existingIndex] = sanitizedItem
        } else {
            reasoningItemIndexByID[id] = reasoningItems.count
            reasoningItems.append(sanitizedItem)
        }
    }

    private mutating func markFirstDelta() {
        if firstDeltaAt == nil {
            firstDeltaAt = Date()
        }
    }

    private func reasoningItemsJSON() -> String? {
        guard !reasoningItems.isEmpty,
              let data = try? JSONValue(jsonObject: reasoningItems).jsonData(
                outputFormatting: [.withoutEscapingSlashes]
              ) else {
            return nil
        }
        return String(decoding: data, as: UTF8.self)
    }

    // MARK: - Static helpers

    /// Computes the delta between a snapshot and the already-accumulated text,
    /// so the caller can emit only the new content.
    public static func streamContentDelta(
        fromSnapshot snapshot: String,
        accumulatedText: String
    ) -> String {
        guard !snapshot.isEmpty, !accumulatedText.isEmpty else {
            return snapshot
        }
        if snapshot == accumulatedText {
            return ""
        }
        if snapshot.hasPrefix(accumulatedText) {
            return String(snapshot.dropFirst(accumulatedText.count))
        }
        if accumulatedText.hasSuffix(snapshot) {
            return ""
        }

        let maximumOverlap = min(snapshot.count, accumulatedText.count)
        guard maximumOverlap > 0 else {
            return snapshot
        }

        let snapshotCharacters = Array(snapshot)
        let accumulatedCharacters = Array(accumulatedText)
        for overlapLength in stride(from: maximumOverlap, through: 1, by: -1) {
            let accumulatedSuffixStart = accumulatedCharacters.count - overlapLength
            let accumulatedSuffix = accumulatedCharacters[accumulatedSuffixStart...]
            let snapshotPrefix = snapshotCharacters[..<overlapLength]
            if accumulatedSuffix.elementsEqual(snapshotPrefix) {
                return String(snapshotCharacters.dropFirst(overlapLength))
            }
        }
        return snapshot
    }

    public static func firstReasoningClosingMarker(
        in text: String
    ) -> (range: Range<String.Index>, text: String)? {
        reasoningClosingMarkers
            .compactMap { marker in
                text.range(of: marker).map { range in
                    (range: range, text: marker)
                }
            }
            .min { lhs, rhs in
                lhs.range.lowerBound < rhs.range.lowerBound
            }
    }

    /// Returns the longest suffix that could become a closing marker when the
    /// next delta arrives. Marker bytes are ASCII, so a matching suffix can be
    /// decoded independently even when adjacent model text contains composed
    /// Unicode graphemes.
    private static func trailingReasoningClosingMarkerPrefix(
        in text: String
    ) -> String {
        let maximumLength = min(
            text.utf8.count,
            maximumReasoningClosingMarkerLookbehindByteCount
        )
        guard maximumLength > 0 else {
            return ""
        }

        let suffix = Array(text.utf8.suffix(maximumLength))
        for length in stride(from: maximumLength, through: 1, by: -1) {
            let candidate = suffix.suffix(length)
            let canCompleteMarker = reasoningClosingMarkerBytes.contains { marker in
                marker.count > length
                    && marker.prefix(length).elementsEqual(candidate)
            }
            if canCompleteMarker {
                return String(decoding: candidate, as: UTF8.self)
            }
        }
        return ""
    }
}
