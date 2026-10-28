//
//  MemoryReembeddingSetupTests.swift
//  ZenCODECoreTests
//
//  The pure parts of the memory re-embedding offered by setup and by Data
//  management › Rebuild memory embeddings: the trigger, the list, the
//  progress line and the summary. No terminal, no network, no real graph.
//

import Foundation
import Synchronization
import Testing
@testable import ZenCODECore

private struct NamedEmbeddingProvider: EmbeddingProvider {
    let modelID: String
    func embed(_ text: String) async throws -> [Float] { [1] }
}

@Suite
struct MemoryReembeddingSetupTests {
    private typealias Runner = ZenCODESetupRunner

    private static let endpoint = "https://embeddings.example.test/v1/embeddings"

    private static func manifest(_ settings: AgentMemoryEmbeddingSettingsManifest?) -> AgentSettingsManifest {
        AgentSettingsManifest(models: [], memoryEmbedding: settings)
    }

    private static func settings(model: String?) -> AgentMemoryEmbeddingSettingsManifest {
        AgentMemoryEmbeddingSettingsManifest(endpoint: endpoint, model: model)
    }

    // MARK: - Trigger

    @Test
    func reembeddingIsOfferedOnlyAfterACompletedSetupThatChangedTheModel() throws {
        let previous = Self.settings(model: "qwen/qwen3-embedding-8b")
        let next = Self.settings(model: "qwen/qwen3-embedding-4b")

        let offered = try #require(Runner.memoryReembeddingProvider(
            setupOutcome: .configured,
            originalSettings: previous,
            finalManifest: Self.manifest(next),
            environment: [:]
        ))
        #expect(offered.modelID == "qwen/qwen3-embedding-4b")

        // Cancelled, reset or replaced: no graph is touched.
        for outcome in [SetupOutcome.cancelled, .reset, .dataReplaced] {
            #expect(Runner.memoryReembeddingProvider(
                setupOutcome: outcome,
                originalSettings: previous,
                finalManifest: Self.manifest(next),
                environment: [:]
            ) == nil)
        }
        // Unchanged configuration.
        #expect(Runner.memoryReembeddingProvider(
            setupOutcome: .configured,
            originalSettings: next,
            finalManifest: Self.manifest(next),
            environment: [:]
        ) == nil)
        // Switching to BM25 resolves no provider, even with the legacy variable set.
        #expect(Runner.memoryReembeddingProvider(
            setupOutcome: .configured,
            originalSettings: next,
            finalManifest: Self.manifest(.disabled),
            environment: [MemoryEmbedding.environmentEndpointKey: Self.endpoint]
        ) == nil)
        // Enabling embeddings for the first time is a change too.
        #expect(Runner.memoryReembeddingProvider(
            setupOutcome: .configured,
            originalSettings: .disabled,
            finalManifest: Self.manifest(next),
            environment: [:]
        )?.modelID == "qwen/qwen3-embedding-4b")
    }

    @Test
    func modelDescriptionNeverShowsTheEndpointURL() {
        let withModel = OpenAICompatibleEmbeddingProvider(
            endpoint: URL(string: "https://openrouter.ai/api/v1/embeddings")!,
            model: "qwen/qwen3-embedding-4b"
        )
        #expect(Runner.memoryReembeddingModelDescription(withModel) == "qwen/qwen3-embedding-4b")

        let endpointOnly = OpenAICompatibleEmbeddingProvider(
            endpoint: URL(string: "https://embeddings.example.test/v1/embeddings?token=secret-token")!
        )
        let description = Runner.memoryReembeddingModelDescription(endpointOnly)
        #expect(description == "the default model of embeddings.example.test")
        #expect(!description.contains("secret-token"))

        #expect(Runner.memoryReembeddingModelDescription(NamedEmbeddingProvider(modelID: "local-model")) == "local-model")
    }

    // MARK: - List

    @Test
    func shortNamesHideTheProjectHash() {
        let key = ProjectStorageKey.key(forProjectName: "ZenCODE")
        #expect(key.count == "ZenCODE-".count + ProjectStorageKey.hashLength)
        #expect(Runner.memoryReembeddingShortName(key) == "ZenCODE-…")
        #expect(Runner.memoryReembeddingShortName("global") == "global")
        let long = ProjectStorageKey.key(forProjectName: String(repeating: "a", count: 60))
        let short = Runner.memoryReembeddingShortName(long)
        #expect(short.count == 32)
        #expect(short.hasSuffix("…"))
    }

    @Test
    func planListsEveryGraphTheTotalAndWhatIsSent() {
        let lines = [
            Runner.MemoryReembeddingPlanLine(
                name: "ZenCODE-0123456789abcdef01234567",
                plan: MemoryReembeddingPlan(activeEntries: 238, entriesToEmbed: 238, archivedVectors: 48)
            ),
            Runner.MemoryReembeddingPlanLine(
                name: "global",
                plan: MemoryReembeddingPlan(activeEntries: 12, entriesToEmbed: 1, archivedVectors: 0)
            ),
            Runner.MemoryReembeddingPlanLine(
                name: "other-0123456789abcdef01234567",
                plan: MemoryReembeddingPlan(activeEntries: 3, entriesToEmbed: 0, archivedVectors: 0)
            ),
        ]
        let text = Runner.renderMemoryReembeddingPlan(
            lines,
            unavailable: [Runner.MemoryReembeddingResultLine(name: "broken-0123", error: "unsupported graph version")],
            modelDescription: "qwen/qwen3-embedding-4b",
            origin: .setupCompletion
        )

        #expect(text.split(separator: "\n").map(String.init) == [
            "Memory embeddings changed. Recall does not use vectors from another model, so those entries fall back to keyword matching until they are embedded again.",
            "Re-embed every memory graph with qwen/qwen3-embedding-4b:",
            "  ZenCODE-0123456789abcdef01234567: 238 entries to embed, 48 archived vectors to delete",
            "  global: 1 entry to embed",
            "  other-0123456789abcdef01234567: up to date",
            "  broken-0123: skipped (unsupported graph version)",
            "Total: 239 entries to embed, 48 archived vectors to delete.",
            "The content of each entry is sent to the embedding endpoint. Archived entries are not embedded and their vectors are deleted. Vectors are saved every 16 entries; Esc stops after the requests in flight.",
        ])
        #expect(Runner.memoryReembeddingConfirmationLabel(
            MemoryReembeddingPlan(activeEntries: 250, entriesToEmbed: 239, archivedVectors: 48)
        ) == "Embed 239 memory entries now?")
    }

    @Test
    func planWithOnlyArchivedVectorsSendsNothing() {
        let plan = MemoryReembeddingPlan(activeEntries: 5, entriesToEmbed: 0, archivedVectors: 2)
        let text = Runner.renderMemoryReembeddingPlan(
            [Runner.MemoryReembeddingPlanLine(name: "global", plan: plan)],
            modelDescription: "local-model",
            origin: .dataManagement
        )

        #expect(text.hasPrefix("Rebuild memory embeddings with local-model (saved settings):\n"))
        #expect(text.contains("  global: 0 entries to embed, 2 archived vectors to delete"))
        #expect(text.hasSuffix("No request is sent: only the vectors of archived entries are deleted."))
        #expect(!text.contains("is sent to the embedding endpoint"))
        #expect(Runner.memoryReembeddingConfirmationLabel(plan) == "Delete 2 archived vectors now?")
    }

    @Test
    func decliningAfterSetupPointsToDataManagement() {
        #expect(Runner.memoryReembeddingDeclinedMessage(origin: .setupCompletion)
            == "Memory not re-embedded. Run it later from /setup › Data management › Rebuild memory embeddings.")
        #expect(Runner.memoryReembeddingDeclinedMessage(origin: .dataManagement) == "Rebuild cancelled.")
    }

    // MARK: - Progress

    @Test
    func progressLineShowsCountsFailuresAndTheHint() {
        #expect(Runner.memoryReembeddingProgressLine(
            name: "ZenCODE-…",
            progress: MemoryReembeddingProgress(processed: 120, failed: 2, total: 238),
            hint: "Esc to stop"
        ) == "  ZenCODE-…: 120/238 (2 failed) · Esc to stop")
        #expect(Runner.memoryReembeddingProgressLine(
            name: "global",
            progress: MemoryReembeddingProgress(processed: 12, failed: 0, total: 12),
            hint: nil
        ) == "  global: 12/12")
    }

    @Test
    func printerRewritesOneLinePerGraphInPlace() {
        let written = Mutex<[String]>([])
        let printer = MemoryReembeddingProgressPrinter(showsStopHint: true) { text in
            written.withLock { $0.append(text) }
        }

        // A graph with nothing to embed prints nothing.
        printer.begin(name: "global")
        printer.report(MemoryReembeddingProgress(processed: 0, failed: 0, total: 0))
        printer.finish()
        #expect(written.withLock { $0 }.isEmpty)

        printer.begin(name: "ZenCODE-…")
        printer.report(MemoryReembeddingProgress(processed: 0, failed: 0, total: 3))
        printer.report(MemoryReembeddingProgress(processed: 1, failed: 1, total: 3))
        printer.markStopping()
        printer.report(MemoryReembeddingProgress(processed: 2, failed: 1, total: 3))
        printer.finish()

        let running = "  ZenCODE-…: 1/3 (1 failed) · Esc to stop"
        let stopping = "  ZenCODE-…: 1/3 (1 failed) · stopping…"
        let final = "  ZenCODE-…: 2/3 (1 failed)"
        #expect(written.withLock { $0 } == [
            "\r  ZenCODE-…: 0/3 · Esc to stop",
            "\r" + running,
            // Every shorter rewrite is padded over the previous line.
            "\r" + stopping + String(repeating: " ", count: running.count - stopping.count),
            "\r  ZenCODE-…: 2/3 (1 failed) · stopping…",
            "\r" + final + String(repeating: " ", count: stopping.count - final.count) + "\n",
        ])
    }

    // MARK: - Summary

    @Test
    func summaryOfAFinishedRunCountsEveryGraph() {
        let text = Runner.renderMemoryReembeddingSummary(
            [
                Runner.MemoryReembeddingResultLine(
                    name: "ZenCODE-0123456789abcdef01234567",
                    summary: MemoryReembeddingGraphSummary(
                        needed: 238,
                        embedded: 235,
                        resized: 3,
                        failed: 2,
                        skipped: 1,
                        clearedArchivedVectors: 48
                    )
                ),
                Runner.MemoryReembeddingResultLine(
                    name: "global",
                    summary: MemoryReembeddingGraphSummary(needed: 1, embedded: 1)
                ),
                Runner.MemoryReembeddingResultLine(name: "other-0123", summary: MemoryReembeddingGraphSummary()),
            ],
            modelDescription: "qwen/qwen3-embedding-4b",
            dimensions: 2_560,
            ending: .finished
        )

        #expect(text.split(separator: "\n").map(String.init) == [
            "Memory re-embedding finished (qwen/qwen3-embedding-4b, 2560 dimensions).",
            "  ZenCODE-0123456789abcdef01234567: 235 embedded, 2 failed, 1 skipped, 48 archived vectors deleted",
            "  global: 1 embedded",
            "  other-0123: up to date",
            "Total: 236 embedded, 2 failed, 1 skipped, 48 archived vectors deleted.",
            "3 embedded entries replaced a vector of a different length.",
            "1 entry skipped: changed, archived or embedded by another session meanwhile.",
            "Entries that failed keep their previous state: retry them with /setup › Data management › Rebuild memory embeddings.",
        ])
    }

    @Test
    func summaryOfAStoppedRunSaysHowToResume() {
        let text = Runner.renderMemoryReembeddingSummary(
            [
                Runner.MemoryReembeddingResultLine(
                    name: "ZenCODE-0123",
                    summary: MemoryReembeddingGraphSummary(needed: 238, embedded: 32)
                ),
                Runner.MemoryReembeddingResultLine(
                    name: "global",
                    summary: MemoryReembeddingGraphSummary(needed: 12)
                ),
            ],
            modelDescription: "qwen/qwen3-embedding-4b",
            dimensions: 2_560,
            ending: .stopped
        )

        #expect(text.hasPrefix("Memory re-embedding stopped with Esc (qwen/qwen3-embedding-4b, 2560 dimensions).\n"))
        #expect(text.contains("  ZenCODE-0123: 32 embedded, 206 not reached"))
        #expect(text.contains("  global: 0 embedded, 12 not reached"))
        #expect(text.contains("Total: 32 embedded, 218 not reached."))
        #expect(text.hasSuffix(
            "Vectors saved so far are kept and the other entries keep their previous state. Resume with /setup › Data management › Rebuild memory embeddings."
        ))
    }

    @Test
    func summaryOfAnAbortedRunNamesTheReasonWithoutSecrets() {
        let rejected = Runner.renderMemoryReembeddingSummary(
            [Runner.MemoryReembeddingResultLine(name: "global", summary: MemoryReembeddingGraphSummary(needed: 5))],
            modelDescription: "qwen/qwen3-embedding-4b",
            dimensions: nil,
            ending: .aborted(.endpointRejected(status: 401))
        )
        #expect(rejected.hasPrefix(
            "Memory re-embedding stopped: the embedding endpoint answered HTTP 401 (unauthorized: check the API key).\n"
        ))
        #expect(rejected.hasSuffix(
            "No further requests were sent and vectors saved so far are kept. Check /setup › Memory embeddings, then resume with /setup › Data management › Rebuild memory embeddings."
        ))

        #expect(Runner.memoryReembeddingAbortDescription(.endpointRejected(status: 404))
            == "the embedding endpoint answered HTTP 404 (not found: check the endpoint URL and the model)")
        #expect(Runner.memoryReembeddingAbortDescription(
            .initialRequestsFailed(count: 8, lastFailure: "httpStatus 400")
        ) == "the first 8 entries all failed (last error: httpStatus 400)")
    }

    // MARK: - Default model

    @Test
    func openRouterProposalDefaultsToTheFourBillionModel() throws {
        #expect(AgentMemoryEmbeddingSettingsManifest.openRouterEmbeddingsModel == "qwen/qwen3-embedding-4b")
        let ids = Runner.openRouterEmbeddingModelsFallback.map(\.id)
        #expect(ids.contains("qwen/qwen3-embedding-4b"))
        #expect(ids.contains("qwen/qwen3-embedding-8b"))

        let models: [Runner.MemoryEmbeddingModelOption] = [
            .init(id: "qwen/qwen3-embedding-4b", name: "Qwen 4B", contextLength: 32_768, promptPricePerToken: 0.00000002),
            .init(id: "qwen/qwen3-embedding-8b", name: "Qwen 8B", contextLength: 40_960, promptPricePerToken: 0.00000001),
        ]
        let fresh = Runner.openRouterEmbeddingModelMenu(
            models: models,
            existingSettings: nil,
            defaultModel: AgentMemoryEmbeddingSettingsManifest.openRouterEmbeddingsModel
        )
        #expect(fresh.defaultChoice == "qwen/qwen3-embedding-4b")

        // An 8B already saved stays the preselected model.
        let configured = Runner.openRouterEmbeddingModelMenu(
            models: models,
            existingSettings: AgentMemoryEmbeddingSettingsManifest(
                endpoint: AgentMemoryEmbeddingSettingsManifest.openRouterEmbeddingsEndpoint,
                model: "qwen/qwen3-embedding-8b",
                providerID: UUID()
            ),
            defaultModel: AgentMemoryEmbeddingSettingsManifest.openRouterEmbeddingsModel
        )
        #expect(configured.defaultChoice == "qwen/qwen3-embedding-8b")
    }

    // MARK: - Cleanup report

    @Test
    func cleanupReportPointsToTheRebuildForClearedVectors() {
        var report = MemoryCleanupReport(totalEntries: 3, activeEntries: 3, archivedEntries: 0)
        report.clearedEmbeddings = 2
        let text = Runner.renderMemoryCleanupReport(
            report,
            graphURL: URL(fileURLWithPath: "/tmp/memory.graph.json"),
            policy: MemoryCleanupPolicy(graphHygiene: true)
        )

        #expect(text.hasSuffix(
            "A cleared vector is regenerated when its entry is next written, updated or restored, or by Data management › Rebuild memory embeddings."
        ))
    }
}
