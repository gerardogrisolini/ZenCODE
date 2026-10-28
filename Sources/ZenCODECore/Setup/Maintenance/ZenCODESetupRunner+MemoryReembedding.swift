//
//  ZenCODESetupRunner+MemoryReembedding.swift
//  ZenCODE
//
//  Created by Gerardo Grisolini on 28/10/26.
//
//  Re-embedding of every memory graph: offered after setup saved a changed
//  embedding configuration, and run from Data management › Rebuild memory
//  embeddings. The trigger, the list, the progress line and the summary are
//  pure so tests can assert them without a terminal; the interactive flow only
//  wires them to the prompt, the Esc monitor and the stores.
//

import Foundation
import Synchronization

extension ZenCODESetupRunner {
    /// Where a re-embedding was started; only the wording differs.
    enum MemoryReembeddingOrigin: Sendable, Equatable {
        /// Right after "save and exit" stored a changed embedding configuration.
        case setupCompletion
        /// Data management › Rebuild memory embeddings.
        case dataManagement
    }

    /// One graph in the list shown before a run.
    struct MemoryReembeddingPlanLine: Sendable, Equatable {
        /// The graph's directory name under `<support>/memory/`.
        let name: String
        let plan: MemoryReembeddingPlan
    }

    /// One graph in the summary shown after a run.
    struct MemoryReembeddingResultLine: Sendable, Equatable {
        let name: String
        var summary = MemoryReembeddingGraphSummary()
        /// Why this graph was not (fully) processed: it could not be opened, or
        /// saving failed. Never an endpoint, a key or entry text.
        var error: String?
    }

    /// How a run ended.
    enum MemoryReembeddingEnding: Sendable, Equatable {
        case finished
        /// The operator pressed Esc.
        case stopped
        case aborted(MemoryReembeddingAbort)
    }

    /// Where the operator resumes or retries a run.
    static let memoryReembeddingMenuPath = "/setup › Data management › Rebuild memory embeddings"

    // MARK: - Trigger

    /// The provider a finished setup offers to re-embed every graph with, or
    /// `nil`. Only a completed setup (`.configured`) whose saved embedding
    /// configuration differs from the one it started with, and resolves to a
    /// provider rather than BM25, qualifies: a cancelled setup never touches a
    /// graph.
    static func memoryReembeddingProvider(
        setupOutcome: SetupOutcome,
        originalSettings: AgentMemoryEmbeddingSettingsManifest?,
        finalManifest: AgentSettingsManifest,
        environment: [String: String]
    ) -> (any EmbeddingProvider)? {
        guard setupOutcome == .configured,
              originalSettings != finalManifest.memoryEmbedding else {
            return nil
        }
        return MemoryEmbedding.provider(manifest: finalManifest, environment: environment)
    }

    // MARK: - Rendering

    /// The model a provider embeds with, as shown to the operator: the
    /// configured model, or the endpoint's host for an endpoint-only
    /// configuration. Never the full endpoint URL, which may carry a token.
    static func memoryReembeddingModelDescription(_ provider: any EmbeddingProvider) -> String {
        if let provider = provider as? OpenAICompatibleEmbeddingProvider {
            if let model = provider.requestModel {
                return model
            }
            if let host = provider.endpoint.host {
                return "the default model of \(host)"
            }
        }
        return provider.modelID
    }

    /// Short form of a graph directory name for the progress line, which is
    /// rewritten in place and must fit on one terminal row: the hash suffix of
    /// a project key becomes "…" (`ZenCODE-0123…` reads `ZenCODE-…`) and any
    /// name is capped at 32 characters.
    static func memoryReembeddingShortName(_ directoryName: String) -> String {
        let hashLength = ProjectStorageKey.hashLength
        var name = directoryName
        if name.count > hashLength + 1 {
            let separator = name.index(name.endIndex, offsetBy: -(hashLength + 1))
            let suffix = name[name.index(after: separator)...]
            if name[separator] == "-", suffix.allSatisfy(\.isHexDigit) {
                name = String(name[...separator]) + "…"
            }
        }
        let limit = 32
        if name.count > limit {
            name = String(name.prefix(limit - 1)) + "…"
        }
        return name
    }

    /// The list shown before a run, without a trailing newline: one line per
    /// graph, the total, and what the run sends and changes.
    static func renderMemoryReembeddingPlan(
        _ lines: [MemoryReembeddingPlanLine],
        unavailable: [MemoryReembeddingResultLine] = [],
        modelDescription: String,
        origin: MemoryReembeddingOrigin,
        batchSize: Int = MemoryReembedding.Options.default.batchSize
    ) -> String {
        let total = lines.map(\.plan).reduce(MemoryReembeddingPlan(), +)
        var output: [String] = []
        switch origin {
        case .setupCompletion:
            output.append(
                "Memory embeddings changed. Recall does not use vectors from another model, so those entries fall back to keyword matching until they are embedded again."
            )
            output.append("Re-embed every memory graph with \(modelDescription):")
        case .dataManagement:
            output.append("Rebuild memory embeddings with \(modelDescription) (saved settings):")
        }
        for line in lines {
            output.append("  \(line.name): \(memoryReembeddingPlanDetail(line.plan))")
        }
        for line in unavailable {
            output.append("  \(line.name): skipped (\(line.error ?? "cannot be opened"))")
        }
        output.append("Total: \(memoryReembeddingPlanDetail(total)).")
        if total.entriesToEmbed > 0 {
            output.append(
                "The content of each entry is sent to the embedding endpoint. Archived entries are not embedded and their vectors are deleted. Vectors are saved every \(batchSize) entries; Esc stops after the requests in flight."
            )
        } else {
            output.append("No request is sent: only the vectors of archived entries are deleted.")
        }
        return output.joined(separator: "\n")
    }

    /// The confirmation asked after the list.
    static func memoryReembeddingConfirmationLabel(_ total: MemoryReembeddingPlan) -> String {
        if total.entriesToEmbed > 0 {
            return "Embed \(reembeddingPlural(total.entriesToEmbed, "memory entry", plural: "memory entries")) now?"
        }
        return "Delete \(reembeddingPlural(total.archivedVectors, "archived vector")) now?"
    }

    /// What is printed when the operator declines.
    static func memoryReembeddingDeclinedMessage(origin: MemoryReembeddingOrigin) -> String {
        switch origin {
        case .setupCompletion:
            "Memory not re-embedded. Run it later from \(memoryReembeddingMenuPath)."
        case .dataManagement:
            "Rebuild cancelled."
        }
    }

    /// The line rewritten in place while a graph is processed, e.g.
    /// `  ZenCODE-…: 120/238 (2 failed) · Esc to stop`.
    static func memoryReembeddingProgressLine(
        name: String,
        progress: MemoryReembeddingProgress,
        hint: String?
    ) -> String {
        var line = "  \(name): \(progress.processed)/\(progress.total)"
        if progress.failed > 0 {
            line += " (\(progress.failed) failed)"
        }
        if let hint {
            line += " · \(hint)"
        }
        return line
    }

    /// The summary shown after a run, without a trailing newline.
    static func renderMemoryReembeddingSummary(
        _ lines: [MemoryReembeddingResultLine],
        modelDescription: String,
        dimensions: Int?,
        ending: MemoryReembeddingEnding
    ) -> String {
        let total = lines.map(\.summary).reduce(MemoryReembeddingGraphSummary(), +)
        let model = dimensions.map { "\(modelDescription), \($0) dimensions" } ?? modelDescription
        var output: [String] = []
        switch ending {
        case .finished:
            output.append("Memory re-embedding finished (\(model)).")
        case .stopped:
            output.append("Memory re-embedding stopped with Esc (\(model)).")
        case let .aborted(abort):
            output.append("Memory re-embedding stopped: \(memoryReembeddingAbortDescription(abort)).")
        }
        for line in lines {
            output.append("  \(line.name): \(memoryReembeddingResultDetail(line.summary, error: line.error))")
        }
        output.append("Total: \(memoryReembeddingResultDetail(total, error: nil)).")
        if total.resized > 0 {
            output.append(
                "\(reembeddingPlural(total.resized, "embedded entry", plural: "embedded entries")) replaced a vector of a different length."
            )
        }
        if total.skipped > 0 {
            output.append(
                "\(reembeddingPlural(total.skipped, "entry", plural: "entries")) skipped: changed, archived or embedded by another session meanwhile."
            )
        }
        switch ending {
        case .finished:
            if total.failed > 0 || lines.contains(where: { $0.error != nil }) {
                output.append("Entries that failed keep their previous state: retry them with \(memoryReembeddingMenuPath).")
            }
        case .stopped:
            output.append(
                "Vectors saved so far are kept and the other entries keep their previous state. Resume with \(memoryReembeddingMenuPath)."
            )
        case .aborted:
            output.append(
                "No further requests were sent and vectors saved so far are kept. Check /setup › Memory embeddings, then resume with \(memoryReembeddingMenuPath)."
            )
        }
        return output.joined(separator: "\n")
    }

    static func memoryReembeddingAbortDescription(_ abort: MemoryReembeddingAbort) -> String {
        switch abort {
        case let .endpointRejected(status):
            let hint = switch status {
            case 401: "unauthorized: check the API key"
            case 403: "forbidden: check the API key and its permissions"
            case 404: "not found: check the endpoint URL and the model"
            default: "rejected"
            }
            return "the embedding endpoint answered HTTP \(status) (\(hint))"
        case let .initialRequestsFailed(count, lastFailure):
            return "the first \(count) entries all failed (last error: \(lastFailure))"
        }
    }

    private static func memoryReembeddingPlanDetail(_ plan: MemoryReembeddingPlan) -> String {
        guard !plan.isEmpty else { return "up to date" }
        var parts = ["\(reembeddingPlural(plan.entriesToEmbed, "entry", plural: "entries")) to embed"]
        if plan.archivedVectors > 0 {
            parts.append("\(reembeddingPlural(plan.archivedVectors, "archived vector")) to delete")
        }
        return parts.joined(separator: ", ")
    }

    private static func memoryReembeddingResultDetail(
        _ summary: MemoryReembeddingGraphSummary,
        error: String?
    ) -> String {
        var parts: [String] = []
        if summary.needed > 0 || summary.embedded > 0 {
            parts.append("\(summary.embedded) embedded")
        }
        if summary.failed > 0 {
            parts.append("\(summary.failed) failed")
        }
        if summary.skipped > 0 {
            parts.append("\(summary.skipped) skipped")
        }
        if summary.remaining > 0 {
            parts.append("\(summary.remaining) not reached")
        }
        if summary.clearedArchivedVectors > 0 {
            parts.append("\(reembeddingPlural(summary.clearedArchivedVectors, "archived vector")) deleted")
        }
        if let error {
            parts.append("error: \(error)")
        }
        return parts.isEmpty ? "up to date" : parts.joined(separator: ", ")
    }

    private static func reembeddingPlural(_ count: Int, _ singular: String, plural: String? = nil) -> String {
        "\(count) \(count == 1 ? singular : (plural ?? singular + "s"))"
    }

    // MARK: - Interactive flow

    /// After "save and exit": offers the run when the embedding configuration
    /// changed and resolves to a provider. The registry has been reset, so the
    /// stores open with the settings just saved. Never throws: the settings
    /// are already saved and the setup must still complete.
    static func offerMemoryReembeddingAfterSetup(
        originalSettings: AgentMemoryEmbeddingSettingsManifest?,
        finalManifest: AgentSettingsManifest
    ) async {
        guard let provider = memoryReembeddingProvider(
            setupOutcome: .configured,
            originalSettings: originalSettings,
            finalManifest: finalManifest,
            environment: ProcessInfo.processInfo.environment
        ) else {
            return
        }
        await runMemoryReembeddingFlow(provider: provider, origin: .setupCompletion)
    }

    /// Data management › Rebuild memory embeddings, with the provider of the
    /// settings saved on disk.
    static func runMemoryReembeddingFromDataManagement() async {
        guard let provider = MemoryEmbedding.provider() else {
            AgentOutput.standardError.writeString(
                "No embedding endpoint is configured: memory retrieval uses BM25 only, so there are no vectors to rebuild. Configure one in /setup › Memory embeddings and save it first.\n\n"
            )
            return
        }
        await runMemoryReembeddingFlow(provider: provider, origin: .dataManagement)
    }

    /// List, confirmation, run with progress and Esc, summary. With nothing to
    /// do it asks nothing (after setup it prints nothing either).
    private static func runMemoryReembeddingFlow(
        provider: any EmbeddingProvider,
        origin: MemoryReembeddingOrigin,
        fileManager: FileManager = .default
    ) async {
        let output = AgentOutput.standardError
        let modelDescription = memoryReembeddingModelDescription(provider)
        let supportDirectoryURL = ZenFileService.supportDirectoryURL(fileManager: fileManager)
        let workspaceURL = AgentConfiguration.launchWorkingDirectoryURL(
            arguments: ZenCODECommandLineArgumentSanitizer.sanitized(CommandLine.arguments),
            environment: ProcessInfo.processInfo.environment
        )
        let inventory = memoryGraphInventory(
            supportDirectoryURL: supportDirectoryURL,
            currentWorkspaceURL: workspaceURL,
            fileManager: fileManager
        )

        var graphs: [ReembeddingGraph] = []
        var unavailable: [MemoryReembeddingResultLine] = []
        for item in inventory {
            do {
                graphs.append(try await reembeddingGraph(for: item, modelID: provider.modelID))
            } catch {
                unavailable.append(
                    MemoryReembeddingResultLine(name: item.directoryName, error: error.localizedDescription)
                )
            }
        }

        let total = graphs.map(\.plan).reduce(MemoryReembeddingPlan(), +)
        guard !total.isEmpty else {
            if origin == .dataManagement {
                let message = inventory.isEmpty
                    ? "No memory graphs found under \(supportDirectoryURL.appendingPathComponent(MemoryGraphLocation.directoryName).path)."
                    : "Every active memory entry already has a vector from \(modelDescription): nothing to rebuild."
                output.writeString(message + "\n\n")
            }
            return
        }

        output.writeString(
            "\n"
                + renderMemoryReembeddingPlan(
                    graphs.map { MemoryReembeddingPlanLine(name: $0.name, plan: $0.plan) },
                    unavailable: unavailable,
                    modelDescription: modelDescription,
                    origin: origin
                )
                + "\n"
        )
        // Cancelling the prompt counts as No.
        let confirmed = (try? promptYesNo(
            memoryReembeddingConfirmationLabel(total),
            defaultValue: true
        )) ?? false
        guard confirmed else {
            output.writeString(memoryReembeddingDeclinedMessage(origin: origin) + "\n\n")
            return
        }

        let run = MemoryReembeddingRun()
        let watchesEscape = TerminalRawInput.supportsInteractiveInput()
        let printer = MemoryReembeddingProgressPrinter(showsStopHint: watchesEscape)
        // Esc only asks the run to stop; Ctrl-C keeps terminating the process
        // (the monitor's raw mode leaves signal generation on).
        let monitor = TerminalEscapeStopMonitor.startIfNeeded(isEnabled: watchesEscape) {
            run.requestStop()
            printer.markStopping()
        }
        // Non-throwing, so the monitor is always torn down and the terminal
        // leaves raw mode before anything else is printed or asked.
        let results = await reembedGraphs(graphs, run: run, printer: printer)
        monitor?.cancel()
        await monitor?.value
        printer.finish()

        let remaining = results.reduce(0) { $0 + $1.summary.remaining }
        let ending: MemoryReembeddingEnding
        if let abort = run.abort {
            ending = .aborted(abort)
        } else if run.isStopRequested, remaining > 0 {
            ending = .stopped
        } else {
            ending = .finished
        }
        output.writeString(
            "\n"
                + renderMemoryReembeddingSummary(
                    results + unavailable,
                    modelDescription: modelDescription,
                    dimensions: run.dimensions,
                    ending: ending
                )
                + "\n\n"
        )
    }

    private struct ReembeddingGraph: Sendable {
        let name: String
        let store: MemoryGraphStore
        let plan: MemoryReembeddingPlan
    }

    /// The registry's store for `item` with its plan. A store cached with
    /// another provider is reopened, so the run embeds with `modelID`.
    private static func reembeddingGraph(
        for item: MemoryGraphInventoryItem,
        modelID: String
    ) async throws -> ReembeddingGraph {
        var store = try await MemoryGraphStoreRegistry.shared.store(graphURL: item.graphURL)
        if store.embeddingModelID != modelID {
            await MemoryGraphStoreRegistry.shared.remove(graphURL: item.graphURL)
            store = try await MemoryGraphStoreRegistry.shared.store(graphURL: item.graphURL)
        }
        guard store.embeddingModelID == modelID,
              let plan = try await store.reembeddingPlan() else {
            throw ReembeddingProviderMismatch()
        }
        return ReembeddingGraph(name: item.directoryName, store: store, plan: plan)
    }

    private struct ReembeddingProviderMismatch: LocalizedError {
        var errorDescription: String? {
            "opened with another embedding configuration"
        }
    }

    /// Runs the graphs in order until the run stops; a graph that fails to
    /// save is reported and the next one still runs.
    private static func reembedGraphs(
        _ graphs: [ReembeddingGraph],
        run: MemoryReembeddingRun,
        printer: MemoryReembeddingProgressPrinter
    ) async -> [MemoryReembeddingResultLine] {
        var results: [MemoryReembeddingResultLine] = []
        for graph in graphs {
            var line = MemoryReembeddingResultLine(
                name: graph.name,
                summary: MemoryReembeddingGraphSummary(needed: graph.plan.entriesToEmbed)
            )
            guard run.acceptsNewRequests else {
                results.append(line)
                continue
            }
            printer.begin(name: memoryReembeddingShortName(graph.name))
            do {
                line.summary = try await graph.store.reembed(run: run) { progress in
                    printer.report(progress)
                }
            } catch {
                // Blocks saved before the error stay saved; the counts of this
                // graph are unknown.
                line.summary = MemoryReembeddingGraphSummary()
                line.error = error is CancellationError ? "cancelled" : error.localizedDescription
            }
            printer.finish()
            results.append(line)
        }
        return results
    }
}

/// Prints the progress of one graph on one line, rewritten in place with `\r`
/// (like `VoiceModeDownloadPrinter`). The Esc monitor's raw mode changes only
/// input flags, so output processing stays on: `\n` still ends the line and a
/// shorter rewrite is padded with spaces instead of escape sequences.
final class MemoryReembeddingProgressPrinter: Sendable {
    private struct State {
        var name: String?
        var progress = MemoryReembeddingProgress()
        var lineOpen = false
        var lastLength = 0
        var stopping = false
    }

    private let state = Mutex(State())
    private let showsStopHint: Bool
    private let write: @Sendable (String) -> Void

    init(
        showsStopHint: Bool,
        write: @escaping @Sendable (String) -> Void = { AgentOutput.standardError.writeString($0) }
    ) {
        self.showsStopHint = showsStopHint
        self.write = write
    }

    /// Starts the line of the next graph; nothing is printed until it has
    /// something to embed.
    func begin(name: String) {
        state.withLock { state in
            state.name = name
            state.progress = MemoryReembeddingProgress()
            state.lineOpen = false
            state.lastLength = 0
        }
    }

    // Writes happen under the lock, so a rewrite from the Esc monitor and one
    // from the run can never land out of order.

    func report(_ progress: MemoryReembeddingProgress) {
        state.withLock { state in
            state.progress = progress
            guard progress.total > 0 else { return }
            write(render(&state, final: false))
        }
    }

    /// Esc was pressed: the open line says the run is stopping.
    func markStopping() {
        state.withLock { state in
            state.stopping = true
            guard state.lineOpen else { return }
            write(render(&state, final: false))
        }
    }

    /// Rewrites the open line without the hint and ends it.
    func finish() {
        state.withLock { state in
            guard state.lineOpen else { return }
            write(render(&state, final: true) + "\n")
            state.lineOpen = false
            state.name = nil
        }
    }

    private func render(_ state: inout State, final: Bool) -> String {
        guard let name = state.name else { return "" }
        let hint: String?
        if final {
            hint = nil
        } else if state.stopping {
            hint = "stopping…"
        } else {
            hint = showsStopHint ? "Esc to stop" : nil
        }
        let line = ZenCODESetupRunner.memoryReembeddingProgressLine(
            name: name,
            progress: state.progress,
            hint: hint
        )
        let padding = String(repeating: " ", count: max(state.lastLength - line.count, 0))
        state.lastLength = line.count
        state.lineOpen = true
        return "\r" + line + padding
    }
}
