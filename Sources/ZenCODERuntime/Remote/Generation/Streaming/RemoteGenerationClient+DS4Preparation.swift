//
//  RemoteGenerationClient+DS4Preparation.swift
//  ZenCODE
//
//  Preparation of a DS4 engine round, outside the generation lease: images,
//  frozen current-turn user content, prompt rendering and tokenization,
//  compaction and the reserved output tokens.
//

import Foundation
import Synchronization
import ToolCore

/// A rendered prompt and its tokenization.
private struct DS4TokenizedRound {
    let rendered: DS4RenderedTranscript
    let prepared: DS4PreparedTranscript
    /// Messages of the session that were rendered.
    let messageCount: Int
}

extension RemoteGenerationClient {
    // MARK: - Preparation

    /// Renders the prompt of the round, compacting and recording the system
    /// prompt reminder when needed. Runs outside the generation lease. The
    /// returned prompt is tokenized once (`DS4Engine.prepare`); the caller
    /// releases it.
    func prepareDS4Round(
        _ ds4: DS4LocalGeneration,
        configuration: DS4EngineConfiguration,
        lease: SessionLease,
        staging: DS4ImageStaging,
        statusHandler: @escaping DS4EngineRegistry.StatusHandler,
        onEvent: @escaping @Sendable (DirectAgentEvent) async -> Void
    ) async throws -> DS4PreparedRound {
        let engine = try await ds4.registry.engine(for: configuration, onStatus: statusHandler)
        let info = engine.info
        let syntax = DS4ToolSyntax(rawValue: info.toolSyntaxID) ?? .dsml
        let contextSize = info.contextSize > 0 ? info.contextSize : configuration.contextSize
        let visionConfigured = info.hasVision && ds4.manifest.visionRelativePath != nil

        try await prepareDS4Images(lease: lease, visionConfigured: visionConfigured, onEvent: onEvent)
        try freezeDS4UserContent(lease: lease)
        // `/ds4 hints`: the note of this conversation boundary, if the setting changed.
        try applyDS4HintsBoundary(lease: lease)

        guard let session = currentSession(for: lease) else {
            throw RemoteGenerationClientError.missingSession
        }
        let descriptors = await toolExecutor.descriptors(
            allowedToolNames: session.allowedToolNames,
            preferredWorkspaceRootURL: session.cwd,
            sessionID: session.id
        )
        let toolsPrompt = DS4ToolsPrompt.toolsPrompt(
            descriptors: descriptors,
            syntax: syntax,
            hasVision: info.hasVision
        )
        let thinkMode = await DS4ThinkModeMapping.effectiveMode(
            for: session.thinkingSelection,
            syntax: syntax,
            engine: engine,
            contextSize: contextSize
        )
        let reserve = try await ds4ReserveTokens(
            engine: engine,
            identity: configuration.identity,
            contextSize: contextSize
        )
        func render(_ session: AgentSession) -> DS4RenderedTranscript {
            DS4TranscriptRenderer.render(
                messages: session.messages,
                context: DS4TranscriptRenderer.Context(
                    syntax: syntax,
                    thinkMode: thinkMode,
                    toolsPrompt: toolsPrompt,
                    preserveThinking: session.preserveThinking,
                    imageFiles: visionConfigured ? staging : nil,
                    tokenIdentity: info.tokenIdentity
                )
            )
        }

        /// Renders `session` and tokenizes it (`prepare`: images are encoded
        /// here, once). An image that cannot be read or encoded is removed
        /// from the session with a diagnostic, and the prompt is rendered
        /// again without images, instead of failing every later round.
        func tokenize(_ session: AgentSession) async throws -> DS4TokenizedRound {
            var current = session
            var removedImages = false
            while true {
                let rendered = render(current)
                if visionConfigured, !removedImages, staging.takeNewFailureCount() > 0 {
                    removedImages = true
                    current = try await removeDS4Images(
                        lease: lease, reason: "cannot read an attached image", onEvent: onEvent
                    )
                    continue
                }
                var encodeFailure: String?
                do {
                    let prepared = try await engine.prepare(transcript: rendered.operations)
                    return DS4TokenizedRound(rendered: rendered, prepared: prepared, messageCount: current.messages.count)
                } catch DS4EngineError.vision(let detail) where visionConfigured && !removedImages {
                    encodeFailure = detail
                }
                removedImages = true
                current = try await removeDS4Images(
                    lease: lease, reason: encodeFailure ?? "cannot encode an attached image", onEvent: onEvent
                )
            }
        }

        var tokenized = try await tokenize(session)
        do {
            // agent_worker_compact_if_needed before the assistant continuation.
            var compactions = 0
            while DS4CompactionPolicy.shouldCompact(
                usedTokens: tokenized.prepared.tokenCount, contextSize: contextSize, reserveTokens: reserve
            ),
                  compactions < AgentConversationCompactionPolicy.maximumPreflightCompactionAttempts {
                compactions += 1
                guard await compactSession(
                    id: lease.id, force: true, exactTokenCount: tokenized.prepared.tokenCount
                ) != nil else {
                    break
                }
                // The compacted context forgot the hints instructions (`compactSession`
                // marked the state); the note is decided again for the kept user message.
                try applyDS4HintsBoundary(lease: lease, replacingRecordedNote: true)
                guard let compacted = currentSession(for: lease) else {
                    throw RemoteGenerationClientError.missingSession
                }
                let previous = tokenized.prepared.tokenCount
                tokenized.prepared.release()
                tokenized = try await tokenize(compacted)
                await onEvent(.diagnostic(
                    "DS4 context compacted: \(previous) -> \(tokenized.prepared.tokenCount) tokens "
                        + "(context \(contextSize))."
                ))
            }

            // agent_worker_maybe_append_system_prompt_reminder: the position is
            // decided once and recorded in the message, so later renders agree.
            if tokenized.prepared.tokenCount >= DS4TranscriptRenderer.systemPromptReminderTokens,
               let lastIndex = tokenized.rendered.lastMessageIndex {
                // Recorded by `prepare`, so images before the anchor are not encoded again.
                let anchorOperationCount = tokenized.rendered.reminderAnchorOperationCount
                let anchorTokens: Int
                if let counted = tokenized.prepared.tokenCount(afterOperations: anchorOperationCount) {
                    anchorTokens = counted
                } else {
                    anchorTokens = try await engine.tokenCount(
                        of: Array(tokenized.rendered.operations.prefix(anchorOperationCount))
                    )
                }
                if tokenized.prepared.tokenCount - anchorTokens >= DS4TranscriptRenderer.systemPromptReminderTokens {
                    var recorded = false
                    let renderedMessageCount = tokenized.messageCount
                    guard mutateSession(for: lease, { session in
                        // Skip when the history changed while counting tokens.
                        guard session.messages.count == renderedMessageCount, lastIndex < session.messages.count else {
                            return
                        }
                        session.messages[lastIndex][DS4MessageKeys.systemReminder] = true
                        recorded = true
                    }), let updated = currentSession(for: lease) else {
                        throw RemoteGenerationClientError.missingSession
                    }
                    if recorded {
                        await onEvent(.status("Re-injecting system prompt reminder..."))
                        tokenized.prepared.release()
                        tokenized = try await tokenize(updated)
                    }
                }
            }

            let used = tokenized.prepared.tokenCount
            let maxTokens = DS4CompactionPolicy.generationTokenLimit(
                maxOutputTokens: self.configuration.maxOutputTokens,
                contextSize: contextSize,
                usedTokens: used,
                reserveTokens: reserve
            )
            guard maxTokens > 0 else {
                throw DS4EngineError.contextExhausted(used: used, limit: contextSize)
            }
            return DS4PreparedRound(
                sessionID: lease.id,
                transcript: tokenized.prepared,
                promptTokens: used,
                maxTokens: maxTokens,
                syntax: syntax,
                thinkMode: thinkMode,
                sampling: Self.ds4Sampling(
                    overrides: self.configuration.generationParameterOverrides,
                    syntax: syntax
                ),
                parameterTypes: DS4ToolParameterKind.map(from: descriptors),
                contextSize: contextSize,
                tokenIdentity: info.tokenIdentity,
                toolCatalog: RemoteToolWireCatalog(descriptors: descriptors)
            )
        } catch {
            tokenized.prepared.release()
            throw error
        }
    }

    /// Images: without a configured vision encoder they are removed from the
    /// session (once per round that has any), each replaced by a text notice so
    /// the model does not believe it saw them; with one they stay in history
    /// and `DS4TranscriptRenderer` sends them as multimodal messages.
    private func prepareDS4Images(
        lease: SessionLease,
        visionConfigured: Bool,
        onEvent: @escaping @Sendable (DirectAgentEvent) async -> Void
    ) async throws {
        guard let session = currentSession(for: lease) else {
            throw RemoteGenerationClientError.missingSession
        }
        guard !visionConfigured, Self.messagesContainImageContent(session.messages) else {
            return
        }
        guard mutateSession(for: lease, { session in
            session.messages = Self.messagesStrippingImageContent(from: session.messages)
        }) else {
            throw RemoteGenerationClientError.missingSession
        }
        await onEvent(.diagnostic("DS4 model has no vision encoder configured; images were ignored"))
    }

    /// An attached image could not be read or encoded: removes every image
    /// from the session (the same message would fail every round), leaving a
    /// text notice in its place, and says so.
    private func removeDS4Images(
        lease: SessionLease,
        reason: String,
        onEvent: @escaping @Sendable (DirectAgentEvent) async -> Void
    ) async throws -> AgentSession {
        guard mutateSession(for: lease, { session in
            session.messages = Self.messagesStrippingImageContent(
                from: session.messages,
                notice: Self.unreadableImageNotice
            )
        }), let session = currentSession(for: lease) else {
            throw RemoteGenerationClientError.missingSession
        }
        await onEvent(.diagnostic("DS4 could not use the attached images (\(reason)); images were ignored"))
        return session
    }

    /// Stores in a user message the content it is sent with (memory block and
    /// instruction appended by `applyingCurrentTurnMemory`), so later rounds
    /// and turns render it unchanged: the last user message, which is the
    /// prompt of the running turn, and every earlier prompt that carries the
    /// text of its own turn (`turnAdditionKey`) without its frozen content.
    /// The latter is the state of a session created from its history, where
    /// no KV checkpoint trailer brought the frozen content back.
    private func freezeDS4UserContent(lease: SessionLease) throws {
        guard let session = currentSession(for: lease) else {
            throw RemoteGenerationClientError.missingSession
        }
        let lastUserIndex = session.messages.lastIndex(where: { message in
            Self.stringValue(message["role"])?
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .lowercased() == "user"
        })
        let pending = session.messages.indices.filter { index in
            let message = session.messages[index]
            return message[DS4MessageKeys.userContent] == nil
                && (index == lastUserIndex || message[Self.turnAdditionKey] != nil)
        }
        guard !pending.isEmpty else {
            return
        }
        let outgoing = Self.applyingCurrentTurnMemory(to: session.messages)
        guard outgoing.count == session.messages.count else {
            return
        }
        let frozen = pending.compactMap { index -> (index: Int, content: String)? in
            let rendered = Self.contentString(from: outgoing[index]["content"]) ?? ""
            guard rendered != DS4TranscriptRenderer.userContent(of: session.messages[index]) else {
                return nil
            }
            return (index, rendered)
        }
        guard !frozen.isEmpty else {
            return
        }
        mutateSession(for: lease) { session in
            for (index, content) in frozen where index < session.messages.count {
                session.messages[index][DS4MessageKeys.userContent] = content
            }
        }
    }

    /// `agent_compact_reserve_tokens`, counted once per engine identity.
    private func ds4ReserveTokens(engine: any DS4Engine, identity: String, contextSize: Int) async throws -> Int {
        if let cached = ds4State.reserveTokensByIdentity[identity] {
            return cached
        }
        let promptTokens = try await engine.tokenCount(of: DS4CompactionPolicy.reserveTranscript)
        let reserve = DS4CompactionPolicy.reserveTokens(
            compactionPromptTokens: promptTokens,
            contextSize: contextSize
        )
        ds4State.reserveTokensByIdentity[identity] = reserve
        return reserve
    }
}
