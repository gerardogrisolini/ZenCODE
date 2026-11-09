//
//  TerminalChat+SubAgents.swift
//  ZenCODE
//
//  Created by Gerardo Grisolini on 26/05/26.
//

import Foundation
import ToolCore

extension TerminalChat {
    /// Publishes the sub-agent overview through the shared controller (see
    /// ``ChatSessionController/publishSubAgentOverviewIfChanged(relatedToolName:presenter:)``):
    /// nothing for a tool that is not a sub-agent tool, and without a tool
    /// name always.
    public func publishSubAgentOverviewIfChanged(
        relatedToolName: String? = nil
    ) async {
        await chatSession.publishSubAgentOverviewIfChanged(
            relatedToolName: relatedToolName
        )
    }

    // MARK: - Live refresh during agent.* tool calls

    /// Starts the periodic overview refresh of the shared controller (see
    /// ``ChatSessionController/startSubAgentOverviewRefreshIfNeeded(presenter:)``),
    /// so sub-agent status stays visible while a blocking `agent.*` tool call
    /// such as `agent.wait` is executing. Each tick reaches the signature-deduped
    /// ``renderSubAgentOverview(_:origin:publication:force:)``, so an unchanged
    /// snapshot writes nothing. Idempotent.
    func startSubAgentOverviewRefreshIfNeeded() {
        chatSession.startSubAgentOverviewRefreshIfNeeded()
    }

    /// Stops the periodic refresh and **drains** the tick in flight before the
    /// final publication (see
    /// ``ChatSessionController/stopSubAgentOverviewRefresh(presenter:)``), so
    /// no in-flight tick can publish a stale overview afterwards. Idempotent.
    func stopSubAgentOverviewRefresh() async {
        await chatSession.stopSubAgentOverviewRefresh()
    }

    // MARK: - Sub-agent section

    /// Reserves the next publication of the sub-agent section: its revision
    /// fences every publication reserved before it and drops the section
    /// deferred so far.
    func reserveSubAgentOverviewPublication() async -> ChatOverviewPublication {
        ChatOverviewPublication(
            revision: await renderCoordinator.beginOverviewPublication(.subAgents)
        )
    }

    /// Renders an overview the controller presented, with the revision of its
    /// reservation, adding what only the terminal knows: the delegated tool
    /// rows the render coordinator tracks (part of the signature), the rows the
    /// scrolling region has for an in-place rewrite, and the status-bar git
    /// summary refresh for sub-agents that completed. No snapshot clears the
    /// section unless `force` writes the empty section anyway.
    ///
    /// Only a reservation of the terminal's own orders the section: its
    /// revisions start from 1. The slot's presenter forwards the reservation
    /// and the presentation to the channel that drives the slot at each
    /// moment, so a switch in between can hand the terminal one that Telegram
    /// took (Telegram's revisions are never positive); that one is presented
    /// as a publication without a reservation is, as it comes, and moves no
    /// revision.
    func renderSubAgentOverview(
        _ overview: ChatSubAgentOverview,
        origin: ChatOverviewOrigin,
        publication: ChatOverviewPublication?,
        force: Bool = false
    ) async {
        let publicationRevision = publication.flatMap { $0.revision > 0 ? $0.revision : nil }
        let snapshots = overview.snapshots
        let toolPresentations = await renderCoordinator.subAgentToolPresentationSnapshot()
        await refreshStatusBarGitStatusSummaryForCompletedSubAgents(snapshots)
        let maximumInPlaceRows = await statusBar.scrollableOutputRowCapacity()
        let renderOrigin: TerminalChatRenderCoordinator.OverviewPublicationOrigin =
            origin == .automatic ? .automatic : .explicit
        guard force || !snapshots.isEmpty else {
            await renderCoordinator.clearSubAgentOverview(
                revision: publicationRevision,
                maximumInPlaceRows: maximumInPlaceRows,
                origin: renderOrigin
            )
            return
        }
        let signature = overview.signature
            + "\u{1C}tools:\(toolPresentations.revision)"
        let resolver = subAgentModelTitleResolver()
        let text = TerminalSubAgentOverviewLayout.render(
            snapshots,
            modelTitleResolver: resolver,
            includesFinalResponses: false,
            toolPresentationsByAgentID: toolPresentations.presentationsByAgentID,
            rowBudget: TerminalSubAgentOverviewLayout.overviewRowBudget(
                forInPlaceRows: maximumInPlaceRows
            )
        ) + "\n"
        let partialResponses = TerminalSubAgentOverviewLayout.partialResponses(snapshots)
        let responses = TerminalSubAgentOverviewLayout.markdownResponses(snapshots)
        _ = await renderCoordinator.renderSubAgentOverview(
            signature: signature,
            text: text,
            partialResponses: partialResponses,
            responses: responses,
            revision: publicationRevision,
            force: force,
            rememberSignature: true,
            origin: renderOrigin,
            // The runtime marks the current wave while producing the
            // snapshots (see ``ChatSubAgentOverview/currentBatchID``).
            overviewBatchID: overview.currentBatchID,
            maximumInPlaceRows: maximumInPlaceRows
        )
    }

    public nonisolated static func renderSubAgentOverview(
        _ snapshots: [DirectSubAgentRuntime.AgentSnapshot],
        modelTitleResolver: (String) -> String = { $0 }
    ) -> String {
        TerminalSubAgentOverviewLayout.render(
            snapshots,
            modelTitleResolver: modelTitleResolver,
            includesFinalResponses: true,
            toolPresentationsByAgentID: [:]
        )
    }

    /// Builds the model title resolver used by the instance overview renderer
    /// and by the sub-agent detail header.
    func subAgentModelTitleResolver() -> (String) -> String {
        { modelID in
            Self.resolvedSubAgentModelTitle(
                for: modelID,
                hostedModel: self.hostedModelManifest(for: modelID)
            )
        }
    }

    /// Resolves a sub-agent model identifier into a human-readable title: the
    /// hosted manifest title if known, else the model name of an unresolved
    /// remote API `<providerKey>:<modelID>` identifier, else the identifier
    /// unchanged.
    public nonisolated static func resolvedSubAgentModelTitle(
        for modelID: String,
        hostedModel: AgentSettingsModelManifest? = nil
    ) -> String {
        if let hostedModel {
            return AgentModelCatalogPresentation.modelTitle(for: hostedModel)
        }
        return ModelNamePresentation.subAgentModelNameStrippingRemoteAPIPrefix(modelID) ?? modelID
    }

    /// Returns the significant model name when `modelID` is a remote API
    /// `<providerKey>:<modelName>` identifier (split on the first colon),
    /// otherwise `nil`.
    public nonisolated static func subAgentModelNameStrippingRemoteAPIPrefix(
        _ modelID: String
    ) -> String? {
        ModelNamePresentation.subAgentModelNameStrippingRemoteAPIPrefix(modelID)
    }

    /// Returns the bare model name from a binding identifier when the provider
    /// is already shown separately. Reuses the remote API provider-key
    /// stripping and, when a provider is shown, also strips the other
    /// provider-scoped identifiers such as `chatgpt:gpt-5.6-terra` on their
    /// first colon (unrecognised prefixes fall back to the last colon).
    public nonisolated static func strippedModelNameForBinding(
        _ modelID: String,
        modelProvider: String?
    ) -> String {
        ModelNamePresentation.strippedModelNameForBinding(modelID, modelProvider: modelProvider)
    }
}
