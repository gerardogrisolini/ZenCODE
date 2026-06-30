//
//  MLXServerCoreTests.swift
//  ZenCODE
//
//  Created by Gerardo Grisolini on 25/05/26.
//
import Testing
@testable import MLXServerCore
import Foundation
import MLXLMCommon
import os

@Test
func validatesDefaultConfiguration() throws {
    let configuration = try MLXServerConfiguration().validated()

    #expect(configuration.host == "127.0.0.1")
    #expect(configuration.port == 8080)
}

@Test
func rejectsInvalidPort() {
    #expect(throws: MLXServerConfigurationError.invalidPort(0)) {
        try MLXServerConfiguration(port: 0).validated()
    }
}

@Test
func startsRuntimeWithNoLoadedModels() async {
    let runtime = MLXServerRuntime()
    let loadedModelIDs = await runtime.loadedModelIDs

    #expect(loadedModelIDs.isEmpty)
}

@Test
func perModelGenerationGateSerializesSameModel() async throws {
    let gate = MLXServerPerModelGenerationGate()
    let firstLease = try await gate.acquire(modelID: "model-a")
    let secondAcquired = AsyncSignalCounter()

    let secondTask = Task {
        let secondLease = try await gate.acquire(modelID: "model-a")
        await secondAcquired.signal()
        await secondLease.release()
    }

    let acquiredBeforeRelease = await secondAcquired.waitForCount(1, attempts: 10)
    #expect(!acquiredBeforeRelease)
    await firstLease.release()
    let acquiredAfterRelease = await secondAcquired.waitForCount(1, attempts: 200)
    #expect(acquiredAfterRelease)
    try await secondTask.value
}

@Test
func perModelGenerationGateAllowsDifferentModelsConcurrently() async throws {
    let gate = MLXServerPerModelGenerationGate()
    let firstLease = try await gate.acquire(modelID: "model-a")
    let secondAcquired = AsyncSignalCounter()

    let secondTask = Task {
        let secondLease = try await gate.acquire(modelID: "model-b")
        await secondAcquired.signal()
        await secondLease.release()
    }

    let acquiredSecondModel = await secondAcquired.waitForCount(1, attempts: 200)
    #expect(acquiredSecondModel)
    await firstLease.release()
    try await secondTask.value
}

@Test
func perModelGenerationGateAcquireAllWaitsForActiveModelLeases() async throws {
    let gate = MLXServerPerModelGenerationGate()
    let firstLease = try await gate.acquire(modelID: "model-a")
    let secondLease = try await gate.acquire(modelID: "model-b")
    let acquiredAll = AsyncSignalCounter()

    let acquireAllTask = Task {
        let leases = try await gate.acquireAll()
        await acquiredAll.signal()
        await leases.releaseAll()
    }

    let acquiredAllBeforeRelease = await acquiredAll.waitForCount(1, attempts: 10)
    #expect(!acquiredAllBeforeRelease)
    await firstLease.release()
    let acquiredAllAfterOneRelease = await acquiredAll.waitForCount(1, attempts: 10)
    #expect(!acquiredAllAfterOneRelease)
    await secondLease.release()
    let acquiredAllAfterBothReleases = await acquiredAll.waitForCount(1, attempts: 200)
    #expect(acquiredAllAfterBothReleases)
    try await acquireAllTask.value
}

@Test
func perModelGenerationGateReportsIdleState() async throws {
    let gate = MLXServerPerModelGenerationGate()

    // Unknown models are idle.
    #expect(await gate.isIdle(modelID: "model-a"))

    let lease = try await gate.acquire(modelID: "model-a")
    #expect(!(await gate.isIdle(modelID: "model-a")))
    #expect(await gate.isIdle(modelID: "model-b"))

    await lease.release()
    #expect(await gate.isIdle(modelID: "model-a"))
}

@Test
func transcriptKeepsDirectAnswerVisibleWhenThinkingWasRequested() {
    let text = "Ciao, risposta diretta."

    #expect(
        MLXServerChatSessionTranscriptText.visibleAssistantContent(
            from: text,
            startsInThinking: true
        ) == text
    )
    #expect(
        MLXServerChatSessionTranscriptText.visibleAssistantContentForHistory(
            from: text,
            startsInThinking: true
        ).isEmpty
    )
    #expect(
        MLXServerChatSessionTranscriptText.reasoningContent(
            from: text,
            startsInThinking: true
        ).isEmpty
    )
}

@Test
func transcriptDoesNotPersistUnclosedInitialThinkingAsAssistantHistory() {
    let text = "Analisi lunga senza tag di chiusura."

    #expect(
        MLXServerChatSessionTranscriptText.visibleAssistantContentForHistory(
            from: text,
            startsInThinking: true
        ).isEmpty
    )
}

@Test
func transcriptStillSeparatesExplicitThinkingBlock() {
    let text = "<think>Analisi.</think>Risposta."

    #expect(
        MLXServerChatSessionTranscriptText.visibleAssistantContent(
            from: text,
            startsInThinking: false
        ) == "Risposta."
    )
    #expect(
        MLXServerChatSessionTranscriptText.visibleAssistantContentForHistory(
            from: text,
            startsInThinking: false
        ) == "Risposta."
    )
    #expect(
        MLXServerChatSessionTranscriptText.reasoningContent(
            from: text,
            startsInThinking: false
        ) == "Analisi."
    )
}

@Test
func transcriptSeparatesImplicitThinkingBlockClosedByEndTag() {
    let text = "Analisi implicita.</think>Risposta."

    #expect(
        MLXServerChatSessionTranscriptText.visibleAssistantContent(
            from: text,
            startsInThinking: true
        ) == "Risposta."
    )
    #expect(
        MLXServerChatSessionTranscriptText.visibleAssistantContentForHistory(
            from: text,
            startsInThinking: true
        ) == "Risposta."
    )
    #expect(
        MLXServerChatSessionTranscriptText.reasoningContent(
            from: text,
            startsInThinking: true
        ) == "Analisi implicita."
    )
}

@Test
func transcriptPreservesVisibleContentBetweenThinkingBlocks() {
    let text = "Prima analisi.</think>Prima risposta.<think>Seconda analisi.</think>Seconda risposta."

    #expect(
        MLXServerChatSessionTranscriptText.visibleAssistantContent(
            from: text,
            startsInThinking: true
        ) == "Prima risposta.Seconda risposta."
    )
    #expect(
        MLXServerChatSessionTranscriptText.visibleAssistantContentForHistory(
            from: text,
            startsInThinking: true
        ) == "Prima risposta.Seconda risposta."
    )
    #expect(
        MLXServerChatSessionTranscriptText.reasoningContent(
            from: text,
            startsInThinking: true
        ) == "Prima analisi.Seconda analisi."
    )
}

@Test
func assistantHistoryMessagesPreserveThinkingWhenEnabled() {
    let messages = MLXServerChatSessionTranscriptText.assistantHistoryMessages(
        from: "Ragionamento.</think>Risposta.",
        startsInThinking: true,
        preservesThinking: true
    )

    #expect(messages.count == 2)
    #expect(messages[0].content == MLXServerReasoningTranscript.reasoningSummary("Ragionamento."))
    #expect(messages[1].content == "Risposta.")
    #expect(messages[1].reasoningContent == "Ragionamento.")
}

@Test
func assistantHistoryMessagesDropThinkingWhenDisabled() {
    let messages = MLXServerChatSessionTranscriptText.assistantHistoryMessages(
        from: "Ragionamento.</think>Risposta.",
        startsInThinking: true,
        preservesThinking: false
    )

    #expect(messages == [.assistant("Risposta.")])
}

