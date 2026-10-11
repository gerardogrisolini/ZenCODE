//
//  DS4CompatibilityAdvisor.swift
//  ZenCODE
//
//  Offline compatibility decisions for discovered DS4 hardware and artifacts.
//

import Foundation

public enum DS4CompatibilityStatus: String, Codable, CaseIterable, Hashable, Sendable {
    case ready
    case downloadRequired
    case streamingRecommended
    case partialInstallation
    case insufficientMemory
    case backendUnsupported
    case hardwareUnknown
    case memoryUnknown
    case diagnosticOnly

    public var isOperational: Bool {
        self == .ready || self == .streamingRecommended
    }

    public var requiresDownload: Bool {
        self == .downloadRequired
    }
}

public enum DS4CompatibilityMode: String, Codable, CaseIterable, Hashable, Sendable {
    case resident
    case ssdStreaming
    case download
    case diagnostic
    case unknown
}

public struct DS4CompatibilityProposal: Codable, Equatable, Hashable, Sendable {
    public let model: DS4ModelCatalogEntry
    public let installationState: DS4ModelInstallationState
    public let status: DS4CompatibilityStatus
    public let mode: DS4CompatibilityMode
    public let backend: AgentDS4RuntimeBackend?
    public let requiredDiskBytes: UInt64?
    public let requiredResidentMemoryBytes: UInt64?
    public let requiredStreamingMemoryBytes: UInt64?
    /// True only when the advisor has enough evidence for a safe local action.
    /// The advisor never performs that action; callers may render it as a
    /// download suggestion.
    public let shouldDownload: Bool
    public let rationale: [String]

    public init(
        model: DS4ModelCatalogEntry,
        installationState: DS4ModelInstallationState,
        status: DS4CompatibilityStatus,
        mode: DS4CompatibilityMode,
        backend: AgentDS4RuntimeBackend?,
        requiredDiskBytes: UInt64?,
        requiredResidentMemoryBytes: UInt64?,
        requiredStreamingMemoryBytes: UInt64?,
        shouldDownload: Bool,
        rationale: [String]
    ) {
        self.model = model
        self.installationState = installationState
        self.status = status
        self.mode = mode
        self.backend = backend
        self.requiredDiskBytes = requiredDiskBytes
        self.requiredResidentMemoryBytes = requiredResidentMemoryBytes
        self.requiredStreamingMemoryBytes = requiredStreamingMemoryBytes
        self.shouldDownload = shouldDownload
        self.rationale = rationale
    }

    public var modelID: String { model.id }
    public var isOperational: Bool { status.isOperational }
    public var downloadTarget: String { model.downloadTarget }
    public var diskBytes: UInt64? { requiredDiskBytes }
    public var residentMemoryBytes: UInt64? { requiredResidentMemoryBytes }
    public var streamingMemoryBytes: UInt64? { requiredStreamingMemoryBytes }
}

public struct DS4CompatibilityReport: Codable, Equatable, Sendable {
    public let proposals: [DS4CompatibilityProposal]
    public let diagnostics: [String]

    public init(proposals: [DS4CompatibilityProposal], diagnostics: [String] = []) {
        self.proposals = proposals
        self.diagnostics = diagnostics
    }

    public var operationalProposals: [DS4CompatibilityProposal] {
        proposals.filter(\.isOperational)
    }

    public var downloadProposals: [DS4CompatibilityProposal] {
        proposals.filter(\.shouldDownload)
    }

    public var recommended: DS4CompatibilityProposal? {
        operationalProposals.first
    }
}

/// Compatibility spelling used by UI callers that render a list of model
/// recommendations rather than a report.
public typealias DS4ModelRecommendation = DS4CompatibilityProposal

public struct DS4CompatibilityAdvisor: Sendable {
    public let catalog: DS4ModelCatalog

    public init(catalog: DS4ModelCatalog = .default) {
        self.catalog = catalog
    }

    public func advise(
        hardware: DS4HardwareSnapshot,
        installation: DS4InstallationSnapshot
    ) -> DS4CompatibilityReport {
        advise(hardware: hardware, installation: installation, requestedBackend: nil)
    }

    public func advise(
        hardware: DS4HardwareSnapshot,
        installation: DS4InstallationSnapshot,
        requestedBackend: AgentDS4RuntimeBackend?
    ) -> DS4CompatibilityReport {
        let hardwareBackends = hardware.availableBackends
        let selectedBackend = selectBackend(
            available: hardwareBackends,
            requested: requestedBackend
        )
        var reportDiagnostics = hardware.diagnostics
        if let requestedBackend, selectedBackend != requestedBackend {
            reportDiagnostics.append(
                "Requested DS4 backend \(requestedBackend.rawValue) is not proven by the hardware probe."
            )
        }

        let proposals = catalog.entries.map { entry in
            proposal(
                for: entry,
                hardware: hardware,
                installation: installation,
                selectedBackend: selectedBackend,
                requestedBackend: requestedBackend
            )
        }

        return DS4CompatibilityReport(
            proposals: proposals.sorted(by: proposalOrdering),
            diagnostics: reportDiagnostics
        )
    }

    /// Noun-oriented alias for callers that prefer recommendation terminology.
    public func recommendations(
        hardware: DS4HardwareSnapshot,
        installation: DS4InstallationSnapshot,
        requestedBackend: AgentDS4RuntimeBackend? = nil
    ) -> [DS4CompatibilityProposal] {
        advise(
            hardware: hardware,
            installation: installation,
            requestedBackend: requestedBackend
        ).proposals
    }

    private func proposal(
        for entry: DS4ModelCatalogEntry,
        hardware: DS4HardwareSnapshot,
        installation: DS4InstallationSnapshot,
        selectedBackend: AgentDS4RuntimeBackend?,
        requestedBackend: AgentDS4RuntimeBackend?
    ) -> DS4CompatibilityProposal {
        let installationState = entry.installationState(in: installation)
        let requiredDisk = entry.resources.diskBytes
        let requiredResident = entry.resources.residentMemoryBytes
        let requiredStreaming = entry.resources.streamingMemoryBytes
        let backend = requestedBackend.map { requested in
            hardware.availableBackends.contains(requested) && entry.supports(backend: requested)
                ? requested
                : nil
        } ?? selectedBackend.flatMap { entry.supports(backend: $0) ? $0 : nil }

        var rationale: [String] = []
        rationale.append("Installation: \(installationState.rawValue).")
        if let requiredDisk {
            rationale.append("Documented disk estimate: \(formatBytes(requiredDisk)); this is not a RAM estimate.")
        } else {
            rationale.append("The checkout does not publish a disk estimate for this target.")
        }

        guard hardware.hasKnownGPUBackend else {
            if hardware.platform == .unknown {
                rationale.append("Host platform is unknown; no provider-operational claim is made.")
                return makeProposal(
                    entry: entry,
                    installationState: installationState,
                    status: .hardwareUnknown,
                    mode: .unknown,
                    backend: nil,
                    requiredDisk: requiredDisk,
                    requiredResident: requiredResident,
                    requiredStreaming: requiredStreaming,
                    shouldDownload: false,
                    rationale: rationale
                )
            }
            if hardware.gpus.contains(where: { $0.backend == nil }) {
                rationale.append("A GPU was observed, but its backend could not be identified.")
                return makeProposal(
                    entry: entry,
                    installationState: installationState,
                    status: .hardwareUnknown,
                    mode: .unknown,
                    backend: nil,
                    requiredDisk: requiredDisk,
                    requiredResident: requiredResident,
                    requiredStreaming: requiredStreaming,
                    shouldDownload: false,
                    rationale: rationale
                )
            }
            rationale.append("No GPU backend was proven; CPU is diagnostic-only and is not an operational proposal.")
            return makeProposal(
                entry: entry,
                installationState: installationState,
                status: .diagnosticOnly,
                mode: .diagnostic,
                backend: nil,
                requiredDisk: requiredDisk,
                requiredResident: requiredResident,
                requiredStreaming: requiredStreaming,
                shouldDownload: false,
                rationale: rationale
            )
        }

        guard let backend else {
            if hardware.hasKnownGPUBackend {
                rationale.append("A proven GPU backend is unavailable for this model.")
                return makeProposal(
                    entry: entry,
                    installationState: installationState,
                    status: .backendUnsupported,
                    mode: .unknown,
                    backend: nil,
                    requiredDisk: requiredDisk,
                    requiredResident: requiredResident,
                    requiredStreaming: requiredStreaming,
                    shouldDownload: false,
                    rationale: rationale
                )
            }
            rationale.append("Hardware backend is unknown; no provider-operational claim is made.")
            return makeProposal(
                entry: entry,
                installationState: installationState,
                status: .hardwareUnknown,
                mode: .unknown,
                backend: nil,
                requiredDisk: requiredDisk,
                requiredResident: requiredResident,
                requiredStreaming: requiredStreaming,
                shouldDownload: false,
                rationale: rationale
            )
        }
        rationale.append("Proven backend: \(backend.rawValue).")

        guard let physicalMemory = hardware.physicalMemoryBytes else {
            rationale.append("Physical RAM is unknown; disk size is not used as a substitute.")
            return makeProposal(
                entry: entry,
                installationState: installationState,
                status: .memoryUnknown,
                mode: .unknown,
                backend: backend,
                requiredDisk: requiredDisk,
                requiredResident: requiredResident,
                requiredStreaming: requiredStreaming,
                shouldDownload: false,
                rationale: rationale
            )
        }

        guard let requiredResident else {
            rationale.append("No resident-RAM estimate is documented for this target; compatibility remains unknown.")
            return makeProposal(
                entry: entry,
                installationState: installationState,
                status: .memoryUnknown,
                mode: .unknown,
                backend: backend,
                requiredDisk: requiredDisk,
                requiredResident: nil,
                requiredStreaming: requiredStreaming,
                shouldDownload: installationState == .missing || installationState == .partial,
                rationale: rationale
            )
        }

        let residentFits = physicalMemory >= requiredResident
        let streamingFits = entry.supportsSSDStreaming
            && requiredStreaming.map { physicalMemory >= $0 } == true
        let mode: DS4CompatibilityMode
        let memoryStatus: DS4CompatibilityStatus
        if residentFits {
            mode = .resident
            memoryStatus = .ready
            rationale.append("Physical RAM meets the documented resident estimate.")
        } else if streamingFits {
            mode = .ssdStreaming
            memoryStatus = .streamingRecommended
            rationale.append("Resident RAM is below the estimate; documented SSD streaming is recommended.")
        } else {
            mode = .unknown
            memoryStatus = .insufficientMemory
            rationale.append("Physical RAM is below the resident estimate and no fitting documented streaming budget was found.")
        }

        let status: DS4CompatibilityStatus
        let finalMode: DS4CompatibilityMode
        let shouldDownload: Bool
        switch installationState {
        case .installed:
            status = memoryStatus
            finalMode = mode
            shouldDownload = false
        case .partial:
            status = .partialInstallation
            finalMode = mode
            shouldDownload = false
            rationale.append("Some required GGUF artifacts are absent; no automatic download is performed.")
        case .missing:
            if memoryStatus == .insufficientMemory {
                status = .insufficientMemory
                finalMode = .unknown
                shouldDownload = false
            } else {
                status = .downloadRequired
                finalMode = .download
                shouldDownload = true
                rationale.append("Model is absent; download target is proposed without executing a download.")
            }
        }

        return makeProposal(
            entry: entry,
            installationState: installationState,
            status: status,
            mode: finalMode,
            backend: backend,
            requiredDisk: requiredDisk,
            requiredResident: requiredResident,
            requiredStreaming: requiredStreaming,
            shouldDownload: shouldDownload,
            rationale: rationale
        )
    }

    private func makeProposal(
        entry: DS4ModelCatalogEntry,
        installationState: DS4ModelInstallationState,
        status: DS4CompatibilityStatus,
        mode: DS4CompatibilityMode,
        backend: AgentDS4RuntimeBackend?,
        requiredDisk: UInt64?,
        requiredResident: UInt64?,
        requiredStreaming: UInt64?,
        shouldDownload: Bool,
        rationale: [String]
    ) -> DS4CompatibilityProposal {
        DS4CompatibilityProposal(
            model: entry,
            installationState: installationState,
            status: status,
            mode: mode,
            backend: backend,
            requiredDiskBytes: requiredDisk,
            requiredResidentMemoryBytes: requiredResident,
            requiredStreamingMemoryBytes: requiredStreaming,
            shouldDownload: shouldDownload,
            rationale: rationale
        )
    }

    private func selectBackend(
        available: [AgentDS4RuntimeBackend],
        requested: AgentDS4RuntimeBackend?
    ) -> AgentDS4RuntimeBackend? {
        if let requested, available.contains(requested) { return requested }
        for backend in [AgentDS4RuntimeBackend.metal, .cuda, .rocm] {
            if available.contains(backend) { return backend }
        }
        return nil
    }

    private func proposalOrdering(
        _ lhs: DS4CompatibilityProposal,
        _ rhs: DS4CompatibilityProposal
    ) -> Bool {
        let leftRank = rank(lhs)
        let rightRank = rank(rhs)
        if leftRank != rightRank { return leftRank < rightRank }
        return lhs.model.id.localizedStandardCompare(rhs.model.id) == .orderedAscending
    }

    private func rank(_ proposal: DS4CompatibilityProposal) -> Int {
        switch proposal.status {
        case .ready: return 0
        case .streamingRecommended: return 1
        case .downloadRequired: return 2
        case .partialInstallation: return 3
        case .memoryUnknown: return 4
        case .insufficientMemory: return 5
        case .backendUnsupported: return 6
        case .hardwareUnknown: return 7
        case .diagnosticOnly: return 8
        }
    }

    private func formatBytes(_ bytes: UInt64) -> String {
        let gib = Double(bytes) / Double(1024 * 1024 * 1024)
        if gib >= 1 {
            return String(format: "%.2f GiB", gib)
        }
        return "\(bytes) bytes"
    }
}
