//
//  ChatGPTSubscriptionGenerationClient+Accumulator.swift
//  ZenCODE
//
//  Created by Gerardo Grisolini on 26/05/26.
//

#if os(macOS)
import Foundation
#if canImport(os)
import os
#endif

extension ChatGPTSubscriptionGenerationClient {
    struct StreamAccumulatorResult {
        let text: String
        let reasoningText: String
        let stopReason: String
        let toolCalls: [DirectAgentToolCall]
        let usage: RemoteGenerationUsage?
        let firstDeltaAt: Date?
        let latestResponseID: String?
        let didEmitContent: Bool
        let reasoningItemsJSON: String?
    }

    /// Streaming callbacks may cross concurrency domains; all accumulator mutations are serialized by `lock`.
    final class StreamAccumulator: @unchecked Sendable {
        private let lock = OSAllocatedUnfairLock()
        private var responseText = ""
        private var responseReasoningText = ""
        private var stopReason = "end_turn"
        private var toolCallAccumulator = RemoteToolCallAccumulator()
        private var requestUsage: RemoteGenerationUsage?
        private var firstDeltaAt: Date?
        private var latestResponseID: String?
        private var didEmitContent = false
        /// Replayable reasoning items in stream order, deduplicated by `id`, so
        /// the model's reasoning can be replayed on later requests while `store`
        /// is disabled (matching the Codex CLI behavior).
        private var reasoningItems: [[String: Any]] = []
        private var reasoningItemIndexByID: [String: Int] = [:]

        func ingest(_ object: [String: Any]) throws -> [DirectAgentEvent] {
            lock.lock()
            defer {
                lock.unlock()
            }

            if let errorMessage = ChatGPTSubscriptionGenerationClient.responseErrorMessage(from: object) {
                throw ChatGPTSubscriptionGenerationError.responseFailed(errorMessage)
            }

            if let responseID = ChatGPTSubscriptionGenerationClient.responseID(from: object) {
                latestResponseID = responseID
            }

            var events: [DirectAgentEvent] = []

            if let subscriptionUsage =
                ChatGPTSubscriptionGenerationClient.subscriptionUsage(from: object) {
                events.append(.subscriptionUsage(subscriptionUsage))
            }
            var didParseContentFromResponsesEvent = false
            var didParseReasoningDeltaFromResponsesEvent = false

            for event in RemoteGenerationClient.parseResponsesStreamEvent(object) {
                switch event {
                case let .content(delta):
                    guard !delta.isEmpty else {
                        continue
                    }
                    bufferContentDelta(delta)
                    markFirstDelta()
                    didParseContentFromResponsesEvent = true
                case let .contentSnapshot(snapshot):
                    bufferContentSnapshot(snapshot)
                    markFirstDelta()
                    didParseContentFromResponsesEvent = true
                case let .reasoning(delta):
                    guard !delta.isEmpty else {
                        continue
                    }
                    didParseReasoningDeltaFromResponsesEvent = true
                    markFirstDelta()
                    responseReasoningText.append(delta)
                    events.append(.thought(delta))
                case let .responseToolCallItem(item, outputIndex):
                    markFirstDelta()
                    toolCallAccumulator.ingestResponseToolCallItem(
                        item,
                        outputIndex: outputIndex
                    )
                case let .responseReasoningItem(item):
                    ingestReasoningItem(item)
                case let .responseToolCallArgumentsDelta(event):
                    markFirstDelta()
                    toolCallAccumulator.ingestResponseToolCallArgumentsDelta(event)
                case let .responseToolCallArgumentsDone(event):
                    markFirstDelta()
                    toolCallAccumulator.ingestResponseToolCallArgumentsDone(event)
                case let .stop(reason):
                    stopReason = reason
                case let .failure(message):
                    throw ChatGPTSubscriptionGenerationError.responseFailed(message)
                case let .usage(remoteUsage):
                    requestUsage = remoteUsage
                case .toolCallDelta, .ignored:
                    continue
                }
            }

            let normalizedType = (object["type"] as? String)
                .map(ChatGPTSubscriptionGenerationClient.normalizedEventType) ?? ""
            switch normalizedType {
            case "response_output_text_delta",
                 "response_content_part_delta":
                guard !didParseContentFromResponsesEvent,
                      let delta = ChatGPTSubscriptionGenerationClient.responseContentDelta(from: object),
                      !delta.isEmpty else {
                    return events
                }
                bufferContentDeltaOrSnapshot(delta)
                markFirstDelta()
            case "response_reasoning_summary_text_delta",
                 "response_reasoning_text_delta",
                 "response_reasoning_delta",
                 "response_reasoning_summary_delta",
                 "response_reasoning_raw_content_delta":
                if !didParseReasoningDeltaFromResponsesEvent,
                   let delta = ChatGPTSubscriptionGenerationClient.responseReasoningDelta(from: object),
                   !delta.isEmpty {
                    markFirstDelta()
                    responseReasoningText.append(delta)
                    events.append(.thought(delta))
                }
            case "response_completed",
                 "response_done",
                 "response_incomplete":
                if let completedText = ChatGPTSubscriptionGenerationClient.completedResponseText(from: object),
                   !completedText.isEmpty {
                    // ChatGPT Subscription may revise streamed text before the final
                    // response snapshot. Intermediate deltas are buffered, not emitted;
                    // emit only the completed assistant content so the terminal never
                    // shows both a draft and the corrected final answer.
                    markFirstDelta()
                    responseText = completedText
                    if !didEmitContent {
                        didEmitContent = true
                        events.append(.content(completedText))
                    }
                }
            default:
                break
            }

            return events
        }

        func recordCompletionResponseID(_ responseID: String?) {
            guard let responseID = responseID?.nilIfBlank else {
                return
            }
            lock.lock()
            latestResponseID = responseID
            lock.unlock()
        }

        func result(toolCatalog: RemoteToolWireCatalog) throws -> StreamAccumulatorResult {
            lock.lock()
            defer {
                lock.unlock()
            }

            let remoteToolCalls = try toolCallAccumulator.finalize()
            let reasoningItemsJSON: String?
            if reasoningItems.isEmpty {
                reasoningItemsJSON = nil
            } else if let data = try? JSONValue(jsonObject: reasoningItems).jsonData(
                outputFormatting: [.withoutEscapingSlashes]
            ) {
                reasoningItemsJSON = String(decoding: data, as: UTF8.self)
            } else {
                reasoningItemsJSON = nil
            }
            return StreamAccumulatorResult(
                text: responseText,
                reasoningText: responseReasoningText,
                stopReason: stopReason,
                toolCalls: remoteToolCalls.map(toolCatalog.localToolCall),
                usage: requestUsage,
                firstDeltaAt: firstDeltaAt,
                latestResponseID: latestResponseID,
                didEmitContent: didEmitContent,
                reasoningItemsJSON: reasoningItemsJSON
            )
        }

        /// Stores a replayable reasoning item, replacing any earlier version that
        /// shares the same `id` so a later, more complete snapshot wins.
        private func ingestReasoningItem(_ item: [String: Any]) {
            guard ChatGPTSubscriptionGenerationClient.reasoningItemHasReplayableContent(item) else {
                return
            }
            markFirstDelta()
            let sanitizedItem = ChatGPTSubscriptionGenerationClient.sanitizedReasoningItem(item)
            if let id = ChatGPTSubscriptionGenerationClient.stringValue(item["id"])?.nilIfBlank {
                if let existingIndex = reasoningItemIndexByID[id] {
                    reasoningItems[existingIndex] = sanitizedItem
                } else {
                    reasoningItemIndexByID[id] = reasoningItems.count
                    reasoningItems.append(sanitizedItem)
                }
            } else {
                reasoningItems.append(sanitizedItem)
            }
        }

        private func bufferContentDelta(_ delta: String) {
            guard !delta.isEmpty else {
                return
            }
            responseText.append(delta)
        }

        private func bufferContentDeltaOrSnapshot(_ delta: String) {
            guard !delta.isEmpty else {
                return
            }
            if !responseText.isEmpty,
               Self.looksLikeRevisedSnapshot(delta, replacing: responseText) {
                responseText = delta
            } else {
                responseText.append(delta)
            }
        }

        private func bufferContentSnapshot(_ snapshot: String) {
            guard !snapshot.isEmpty else {
                return
            }
            responseText = snapshot
        }

        private static func looksLikeRevisedSnapshot(
            _ candidate: String,
            replacing accumulated: String
        ) -> Bool {
            let candidateCharacters = Array(candidate)
            let accumulatedCharacters = Array(accumulated)
            let shorterCount = min(candidateCharacters.count, accumulatedCharacters.count)
            let longerCount = max(candidateCharacters.count, accumulatedCharacters.count)
            guard shorterCount >= 24,
                  Double(shorterCount) / Double(longerCount) >= 0.75 else {
                return false
            }

            let prefixCount = zip(candidateCharacters, accumulatedCharacters)
                .prefix { $0 == $1 }
                .count
            let suffixCount = zip(candidateCharacters.reversed(), accumulatedCharacters.reversed())
                .prefix { $0 == $1 }
                .count
            return prefixCount + suffixCount >= Int(Double(shorterCount) * 0.6)
        }

        private func markFirstDelta() {
            if firstDeltaAt == nil {
                firstDeltaAt = Date()
            }
        }
    }
}
#endif
