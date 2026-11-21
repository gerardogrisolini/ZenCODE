//
//  DirectSubAgentRuntime+Commands.swift
//  ZenCODE
//
//  Created by Gerardo Grisolini on 26/05/26.
//

import Foundation
import ToolCore

extension DirectSubAgentRuntime {
    /// One `agent.create` item after validation and profile resolution.
    private struct PreparedAgent {
        let offset: Int
        let payload: RequestedAgentPayload
        let id: String
        let profile: AgentProfile
        let workingDirectory: URL
        let note: String?
    }

    /// `delegatingSessionID` is the ID of the session executing this
    /// `agent.create` (before root-room resolution); each child receives it
    /// in its ``BackendContext/delegatingSessionID``. A child created with the
    /// coordinator's own profile under a restricted grant also reads that
    /// session's feature exposures
    /// (``BackendContext/inheritsFeatureExposures``).
    public func createAgents(
        arguments: [String: JSONValue],
        workingDirectory: URL,
        parentAllowedToolNames: Set<String>?,
        rootSessionID: String = "default",
        delegatingSessionID: String? = nil
    ) async throws -> String {
        // MARK: Validate
        let payloads = try Self.requestedAgentPayloads(from: arguments)
        guard !payloads.isEmpty else {
            throw DirectSubAgentRuntimeError.missingArgument("agents")
        }
        if let taskOrchestrator,
           await taskOrchestrator.executionScope(for: rootSessionID) != nil {
            throw SessionTaskOrchestratorError.permissionDenied(
                "A task-bound delegated sub-agent cannot create nested sub-agents."
            )
        }
        pruneTerminalAgentRecords()
        // Role-based items bound to a task are resolved against the task's own
        // complexity, read before the synchronous preparation below.
        var complexityByTaskID: [String: Int] = [:]
        for payload in payloads where payload.profileRole != nil {
            guard let taskID = payload.taskID else { continue }
            guard let taskOrchestrator else {
                throw SessionTaskOrchestratorError.permissionDenied(
                    "Task assignment is unavailable because no session task orchestrator is installed."
                )
            }
            complexityByTaskID[taskID] = try await taskOrchestrator.task(
                sessionID: rootSessionID,
                taskID: taskID
            ).task.complexity
        }
        // Sub-agents created while an earlier batch is still working join that
        // batch, so sequential `agent.create` calls stay visible together in the
        // transient overview instead of replacing each other.
        let overviewBatchID = currentOverviewWaveID()
        let previousOverviewBatchID = latestOverviewBatchID

        // MARK: Prepare
        let prepared = if coordinatesLiveManifestReads {
            try SensitiveManifestCoordination.withExclusiveLock {
                try self.prepareAgents(
                    payloads,
                    complexityByTaskID: complexityByTaskID,
                    workingDirectory: workingDirectory
                )
            }
        } else {
            try prepareAgents(
                payloads,
                complexityByTaskID: complexityByTaskID,
                workingDirectory: workingDirectory
            )
        }

        // MARK: Materialize
        let reservationIDs = try await reserveTasklessDelegationReservations(
            count: prepared.filter { $0.payload.taskID == nil }.count,
            parentAllowedToolNames: parentAllowedToolNames,
            rootSessionID: rootSessionID
        )
        // One read per batch: every agent of the batch answers in the
        // coordinator's language; without a source the generic rule applies.
        let responseLanguageSection = await responseLanguageSectionProvider?(rootSessionID)
        let tasklessAgentIDs = prepared
            .filter { $0.payload.taskID == nil }
            .map(\.id)
        let reservationIDsByAgentID = Dictionary(
            uniqueKeysWithValues: zip(tasklessAgentIDs, reservationIDs)
        )

        var createdIDs: [String] = []
        var createdBackends: [(String, any AgentRuntimeBackend)] = []
        var claimReceipts: [TaskClaimReceipt] = []
        // Role-resolution notes report the chosen profile and binding.
        var advisories: [String] = prepared.compactMap(\.note)
        do {
            let claims = prepared.compactMap { item -> TaskClaim? in
                guard let taskID = item.payload.taskID else { return nil }
                return TaskClaim(taskID: taskID, agentID: item.id, executor: .subAgent)
            }
            if claims.isEmpty {
                claimReceipts = []
            } else {
                guard let taskOrchestrator else {
                    throw SessionTaskOrchestratorError.permissionDenied(
                        "Task assignment is unavailable because no session task orchestrator is installed."
                    )
                }
                claimReceipts = try await taskOrchestrator.claimTasks(
                    sessionID: rootSessionID,
                    claims: claims
                )
            }
            // Supersede the standby residents whose task was just claimed by a
            // new attempt: a new attempt always wins over an old standby. Only
            // an agent that is actually waiting (`.standby`) is closed right
            // here; a resident whose follow-up is queued or in flight is flagged
            // and released at turn end by `recordStandbyTurnCompletion` /
            // `concludeTaskBoundTurn`, and an `.idle` resident (its follow-up
            // was already denied) stops accepting messages and is reaped. This
            // keeps the post-retry fence observable as a permission error
            // instead of racing the agent to `.closed`.
            for receipt in claimReceipts {
                let supersededResidents = agents.values.filter {
                    isStandbyResident($0)
                        && $0.taskID == receipt.taskID
                        && $0.rootSessionID == rootSessionID
                }
                for record in supersededResidents {
                    mutateAgent(record.id) { agent in
                        agent.supersededByAttemptID = receipt.attemptID
                        agent.pendingRelease = true
                        agent.pendingReleaseReason = Self.standbySupersededReason
                        agent.updatedAt = .now
                    }
                    guard record.status == .standby else { continue }
                    await closeStandbyAgent(
                        id: record.id,
                        reason: Self.standbySupersededReason
                    )
                }
            }
            let receiptsByAgentID = Dictionary(
                uniqueKeysWithValues: claimReceipts.compactMap { receipt in
                    receipt.agentID.map { ($0, receipt) }
                }
            )
            _ = try await sharedChat.registerCoordinator(roomID: rootSessionID)
            for item in prepared {
                let payload = item.payload
                let id = item.id
                let sessionID = "\(id)_session"
                // The child that inherits the coordinator's restricted grant
                // (see `SubAgentToolGrant.resolve`) inherits, by feature ID,
                // the features exposed to the delegating session too.
                let inheritsFeatureExposures = parentAllowedToolNames != nil
                    && SubAgentToolGrant.inheritsParentToolGrant(
                        profile: item.profile,
                        parentProfileID: parentProfileID,
                        parentProfileName: parentProfileName
                    )
                let backendContext = Self.backendContext(
                    for: payload,
                    profile: item.profile
                )
                .injecting(
                    sharedChat: sharedChat,
                    sharedChatSenderID: id,
                    sharedChatRoomID: rootSessionID,
                    delegatingSessionID: delegatingSessionID,
                    inheritsFeatureExposures: inheritsFeatureExposures
                )
                let backend = try backendFactory(backendContext)
                let runtime = self
                await backend.updateBorrowedSubAgentToolExecutor { toolCall in
                    try await runtime.executeBorrowedSubAgentTool(
                        senderID: id,
                        rootSessionID: rootSessionID,
                        toolCall: toolCall
                    )
                }
                await synchronizeSubAgentToolEventHandler(with: backend)
                if payload.taskID == nil {
                    // A taskless child may delegate in turn: its runtime
                    // resolves the same root room and reads the same source.
                    // A task-bound child cannot create nested sub-agents.
                    await backend.updateSubAgentResponseLanguageSectionProvider(
                        responseLanguageSectionProvider
                    )
                }
                createdBackends.append((id, backend))
                if let taskOrchestrator {
                    await backend.installTaskOrchestrator(taskOrchestrator)
                }

                let receipt = receiptsByAgentID[id]
                if let receipt, let taskOrchestrator {
                    if let capability = payload.capability,
                       let taskView = try? await taskOrchestrator.task(
                           sessionID: rootSessionID,
                           taskID: receipt.taskID,
                           graphID: receipt.graphID
                       ),
                       taskView.task.complexity > capability {
                        advisories.append(Self.capabilityGapAdvisory(
                            taskID: receipt.taskID,
                            taskComplexity: taskView.task.complexity,
                            capability: capability,
                            payload: payload,
                            profile: item.profile
                        ))
                    }
                    try await taskOrchestrator.registerExecutionScope(
                        executionSessionID: sessionID,
                        scope: TaskExecutionScope(
                            rootSessionID: rootSessionID,
                            graphID: receipt.graphID,
                            taskID: receipt.taskID,
                            attemptID: receipt.attemptID
                        )
                    )
                }

                let childAllowedToolNames = SubAgentToolGrant.resolve(
                    parentAllowedToolNames: parentAllowedToolNames,
                    parentProfileID: parentProfileID,
                    parentProfileName: parentProfileName,
                    profile: item.profile,
                    isTaskBound: payload.taskID != nil
                )
                await backend.createSession(
                    id: sessionID,
                    cwd: item.workingDirectory.path,
                    systemPrompt: Self.systemPrompt(
                        name: payload.name,
                        taskID: payload.taskID,
                        taskAttemptID: receipt?.attemptID,
                        allowedToolNames: childAllowedToolNames,
                        selectedProfile: item.profile,
                        workingDirectory: payload.workingDirectory == nil
                            ? nil
                            : item.workingDirectory,
                        responseLanguageSection: responseLanguageSection
                    ),
                    history: [],
                    cacheKey: nil,
                    allowedToolNames: childAllowedToolNames,
                    thinkingSelection: backendContext.thinkingSelection,
                    preserveThinking: false
                )
                // Propagate the parent session's prompt-skill provider so the
                // sub-agent can actually execute `skills.list` and `skills.read`
                // through its own backend executor.
                if let promptSkillToolProvider {
                    await backend.updateToolProviders(
                        [promptSkillToolProvider],
                        sessionID: sessionID
                    )
                }

                let record = Self.makeAgentRecord(
                    for: item,
                    sessionID: sessionID,
                    rootSessionID: rootSessionID,
                    receipt: receipt,
                    tasklessDelegationReservationID: reservationIDsByAgentID[id],
                    overviewBatchID: overviewBatchID,
                    backend: backend,
                    modelID: backendContext.modelID
                )
                mutateAgents { $0[id] = record }
                // From this point every following operation can throw. Record
                // the id first so the batch rollback also removes this record,
                // its backend/session scope and its reservation if shared-chat
                // registration rejects it at the participant limit.
                createdIDs.append(id)
                try await registerSharedChatAgent(record)

                if let prompt = payload.prompt {
                    try queuePrompt(prompt, for: id)
                }
            }
        } catch {
            for id in createdIDs {
                if let agent = agents[id] {
                    await sharedChat.unregisterParticipant(
                        id: id,
                        roomID: agent.rootSessionID
                    )
                }
                mutateAgents { $0.removeValue(forKey: id) }
            }
            for (id, backend) in createdBackends {
                if let sessionID = prepared.first(where: { $0.id == id }).map({ "\($0.id)_session" }),
                   let taskOrchestrator {
                    await taskOrchestrator.unregisterExecutionScope(
                        executionSessionID: sessionID
                    )
                }
                await backend.updateBorrowedSubAgentToolExecutor(nil)
                await backend.shutdown()
            }
            if let taskOrchestrator {
                for reservationID in reservationIDs {
                    try? await taskOrchestrator.releaseTasklessDelegationReservation(
                        sessionID: rootSessionID,
                        reservationID: reservationID
                    )
                }
                for receipt in claimReceipts {
                    _ = try await taskOrchestrator.interruptAttempt(
                        sessionID: rootSessionID,
                        taskID: receipt.taskID,
                        attemptID: receipt.attemptID,
                        reason: "sub-agent batch creation failed: \(error.localizedDescription)"
                    )
                }
            }
            latestOverviewBatchID = previousOverviewBatchID
            throw error
        }

        latestOverviewBatchID = overviewBatchID
        let snapshots = snapshots(for: createdIDs)
        var response = "Created \(snapshots.count) delegated sub-agent\(snapshots.count == 1 ? "" : "s").\n"
            + Self.renderSnapshots(snapshots)
        if !advisories.isEmpty {
            response += "\n" + advisories.joined(separator: "\n")
        }
        return response
    }

    /// Resolves the directory, profile, and model binding of every item
    /// against one catalog snapshot. Synchronous: `createAgents` runs it under
    /// the manifest lock when the runtime coordinates live manifest reads.
    private func prepareAgents(
        _ payloads: [RequestedAgentPayload],
        complexityByTaskID: [String: Int],
        workingDirectory: URL
    ) throws -> [PreparedAgent] {
        // Capture one authoritative snapshot so every agent in this batch
        // uses the same provider identities through backend creation.
        let catalogSnapshot = self.coordinatesLiveManifestReads
            ? AgentDelegationCatalog.liveSnapshotUnlocked(
                fileManager: .default
            )
            : self.modelCatalogProvider()
        // Role-based items choose among the configured profiles; read them
        // once per batch and only when needed.
        let roleCatalog = payloads.contains { $0.profileRole != nil }
            ? self.profileCatalogProvider()
            : []
        // Only profiles visible to the item's project may be delegated to:
        // the saved selection, or the system profiles when there is none.
        // The selection is read once per distinct directory.
        var projectSelections: [String: Set<String>?] = [:]
        return try payloads.enumerated().map { offset, payload in
            let itemDirectory = try payload.workingDirectory.map {
                try Self.resolvedAgentWorkingDirectory(
                    $0,
                    coordinatorDirectory: workingDirectory
                )
            } ?? workingDirectory
            let projectSelection: Set<String>?
            if let cached = projectSelections[itemDirectory.path] {
                projectSelection = cached
            } else {
                projectSelection = ProjectAgentSelectionStore.load(
                    workspaceRootURL: itemDirectory
                )
                projectSelections[itemDirectory.path] = projectSelection
            }
            let projectPath = ProjectAgentSelectionStore.workspacePath(
                workspaceRootURL: itemDirectory
            )
            let id = "agent_\(UUID().uuidString.lowercased())"

            if let profileRole = payload.profileRole {
                guard payload.profileReference == nil else {
                    throw DirectSubAgentRuntimeError.invalidArgument(
                        "agent.create profile and profileRole are mutually exclusive"
                    )
                }
                guard payload.requestedModelID == nil else {
                    throw DirectSubAgentRuntimeError.invalidArgument(
                        "agent.create model cannot be combined with profileRole"
                    )
                }
                guard let complexity = payload.taskID.flatMap({ complexityByTaskID[$0] })
                    ?? payload.complexity else {
                    throw DirectSubAgentRuntimeError.missingArgument("complexity")
                }
                let resolution = try Self.resolvingProfileRole(
                    for: payload,
                    role: profileRole,
                    complexity: complexity,
                    profiles: roleCatalog,
                    projectSelection: projectSelection,
                    projectPath: projectPath,
                    snapshot: catalogSnapshot
                )
                return PreparedAgent(
                    offset: offset,
                    payload: resolution.payload,
                    id: id,
                    profile: resolution.profile,
                    workingDirectory: itemDirectory,
                    note: resolution.note
                )
            }

            guard let profileReference = payload.profileReference?.nilIfBlank else {
                throw DirectSubAgentRuntimeError.missingArgument("profile or profileRole")
            }
            guard let profile = self.profileResolver(payload) else {
                throw DirectSubAgentRuntimeError.agentProfileNotFound(profileReference)
            }
            guard ProjectAgentSelectionStore.isAssociated(
                profile,
                selection: projectSelection
            ) else {
                throw DirectSubAgentRuntimeError.agentProfileNotAssociatedWithProject(
                    profileReference,
                    projectPath
                )
            }
            return PreparedAgent(
                offset: offset,
                payload: try Self.resolvingModelBinding(
                    for: payload,
                    profile: profile,
                    snapshot: catalogSnapshot
                ),
                id: id,
                profile: profile,
                workingDirectory: itemDirectory,
                note: nil
            )
        }
    }

    /// Resolves an `agent.create` `workingDirectory`: `~` is expanded and a
    /// relative path is taken from the coordinator's directory. Both paths are
    /// standardized with symlinks resolved only to verify that the result is an
    /// existing directory equal to or inside the coordinator's directory. The
    /// returned URL is expressed under the coordinator's own (unresolved) path,
    /// whose folder name `ProjectStorageKey` keys the project selection and
    /// memory on, so a child sees the same project selection and memory as a
    /// `zen` launched in that directory; a directory equal to the root returns
    /// it unchanged.
    static func resolvedAgentWorkingDirectory(
        _ value: String,
        coordinatorDirectory: URL,
        fileManager: FileManager = .default
    ) throws -> URL {
        let expandedPath = NSString(string: value).expandingTildeInPath
        let candidate = expandedPath.hasPrefix("/")
            ? URL(fileURLWithPath: expandedPath, isDirectory: true)
            : coordinatorDirectory.appendingPathComponent(expandedPath, isDirectory: true)
        let resolved = candidate.standardizedFileURL.resolvingSymlinksInPath()
        let root = coordinatorDirectory.standardizedFileURL.resolvingSymlinksInPath()
        let rootPrefix = root.path.hasSuffix("/") ? root.path : root.path + "/"
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: resolved.path, isDirectory: &isDirectory),
              isDirectory.boolValue,
              resolved.path == root.path || resolved.path.hasPrefix(rootPrefix) else {
            throw DirectSubAgentRuntimeError.invalidArgument(
                "agent.create workingDirectory must be an existing directory inside "
                    + "\(coordinatorDirectory.standardizedFileURL.path): \(value)"
            )
        }
        guard resolved.path != root.path else { return coordinatorDirectory }
        let relativePath = String(resolved.path.dropFirst(rootPrefix.count))
        return coordinatorDirectory.standardizedFileURL
            .appendingPathComponent(relativePath, isDirectory: true)
            .standardizedFileURL
    }

    /// The warning reported when an item's task is more complex than the
    /// capability of the model binding its agent uses.
    private static func capabilityGapAdvisory(
        taskID: String,
        taskComplexity: Int,
        capability: Int,
        payload: RequestedAgentPayload,
        profile: AgentProfile
    ) -> String {
        let capabilityGap = taskComplexity - capability
        if let profileRole = payload.profileRole {
            // The runtime chose the profile and binding, so the
            // coordinator has no other choice to make here.
            return "Warning: task \"\(taskID)\" has complexity "
                + "\(taskComplexity) but profileRole "
                + "\"\(profileRole.rawValue)\" for agent "
                + "\"\(payload.name)\" resolved to profile "
                + "\"\(profile.name)\" with model "
                + "\"\(payload.modelID ?? "unknown")\" at capability "
                + "\(capability)/10, a capability gap of \(capabilityGap); "
                + "no authorized binding with this role meets the "
                + "complexity in this project."
        }
        return "Warning: task \"\(taskID)\" has complexity "
            + "\(taskComplexity) but agent \"\(payload.name)\" "
            + "uses profile \"\(profile.name)\" with "
            + "model \"\(payload.modelID ?? "unknown")\" at capability "
            + "\(capability)/10, a capability gap of "
            + "\(capabilityGap). Use this profile only when no "
            + "role-compatible profile with the required tool access has "
            + "sufficient capability; otherwise select the lowest-capability "
            + "compatible profile that meets the task complexity."
    }

    /// The registry record of an agent that has just been created: idle, or
    /// queued when its item carries a prompt.
    private static func makeAgentRecord(
        for item: PreparedAgent,
        sessionID: String,
        rootSessionID: String,
        receipt: TaskClaimReceipt?,
        tasklessDelegationReservationID: UUID?,
        overviewBatchID: UUID,
        backend: any AgentRuntimeBackend,
        modelID: String?
    ) -> AgentRecord {
        let payload = item.payload
        let now = Date()
        return AgentRecord(
            id: item.id,
            sessionID: sessionID,
            rootSessionID: rootSessionID,
            taskID: payload.taskID,
            taskAttemptID: receipt?.attemptID,
            taskAttemptOrdinal: receipt?.ordinal,
            tasklessDelegationReservationID: tasklessDelegationReservationID,
            name: payload.name.nilIfBlank ?? "sub-agent-\(item.offset + 1)",
            profileID: item.profile.id,
            profileName: item.profile.name,
            profileRole: item.profile.role,
            overviewBatchID: overviewBatchID,
            backend: backend,
            createdAt: now,
            updatedAt: now,
            status: payload.prompt == nil ? .idle : .queued,
            pendingPrompts: [],
            latestOutput: nil,
            latestError: nil,
            configuredModelID: modelID,
            modelID: modelID,
            runTask: nil
        )
    }

    func reserveTasklessDelegationReservations(
        count tasklessCount: Int,
        parentAllowedToolNames: Set<String>?,
        rootSessionID: String
    ) async throws -> [UUID] {
        guard tasklessCount > 0,
              let taskOrchestrator else {
            return []
        }

        do {
            return try await taskOrchestrator.reserveTasklessDelegations(
                sessionID: rootSessionID,
                count: tasklessCount,
                requiresExclusiveAccess: SystemPromptBuilder.taskWorkflowToolsAreAvailable(
                    parentAllowedToolNames
                )
            )
        } catch let error as SessionTaskOrchestratorError {
            switch error {
            case let .tasklessDelegationRequiresTaskID(graphID):
                throw DirectSubAgentRuntimeError.taskIDRequiredForActiveTaskGraph(graphID)
            case .tasklessDelegationConflict:
                throw DirectSubAgentRuntimeError.taskGraphRequiredForCoordinatedDelegation
            default:
                throw error
            }
        }
    }
}
