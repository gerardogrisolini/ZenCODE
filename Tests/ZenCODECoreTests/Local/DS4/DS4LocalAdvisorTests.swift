import Foundation
import Testing
@testable import ZenCODECore

@Suite
struct DS4HardwareProbeTests {
    @Test
    func linuxProbeUsesBoundedCommandResultsAndKeepsCPUOutOfOperationalBackends() async {
        let runner: DS4HardwareProbe.CommandRunner = { command in
            switch command.executableName {
            case "uname":
                return Self.result(stdout: "aarch64\n")
            case "nvidia-smi":
                return Self.result(stdout: "NVIDIA A100, 40960\n")
            default:
                throw DS4HardwareProbeError.executableUnavailable(command.executableName)
            }
        }

        let snapshot = await DS4HardwareProbe(
            platform: .linux,
            environment: [:],
            commandRunner: runner
        ).probe()

        #expect(snapshot.architecture == "aarch64")
        #expect(snapshot.gpus.count == 1)
        #expect(snapshot.gpus[0].backend == .cuda)
        #expect(snapshot.gpus[0].memoryBytes.map { $0 == UInt64(40) * 1024 * 1024 * 1024 } == true)
        #expect(snapshot.availableBackends == [.cuda])
        #expect(!snapshot.availableBackends.contains(.cpu))
        #expect(snapshot.cpuIsDiagnosticOnly)
    }

    @Test
    func macProbeParsesPhysicalMemoryAndMetalEvidenceWithoutGuessingVRAM() async {
        let runner: DS4HardwareProbe.CommandRunner = { command in
            switch command.executableName {
            case "uname":
                return Self.result(stdout: "arm64\n")
            case "sysctl":
                return Self.result(stdout: "137438953472\n")
            case "system_profiler":
                return Self.result(stdout: """
                    Chipset Model: Apple M4 Max
                    Metal Support: Metal 4
                    
                    """)
            default:
                throw DS4HardwareProbeError.executableUnavailable(command.executableName)
            }
        }

        let snapshot = await DS4HardwareProbe(
            platform: .macOS,
            environment: [:],
            commandRunner: runner
        ).probe()

        #expect(snapshot.physicalMemoryBytes.map { $0 == UInt64(128) * 1024 * 1024 * 1024 } == true)
        #expect(snapshot.gpus.map(\.backend) == [.metal])
        #expect(snapshot.gpus[0].memoryBytes == nil)
        #expect(snapshot.availableBackends == [.metal])
        #expect(snapshot.evidence.contains("sysctl:hw.memsize"))
    }

    @Test
    func wslPlatformIsDetectedFromEnvironment() {
        #expect(
            DS4HostPlatform.current(
                environment: ["WSL_DISTRO_NAME": "Ubuntu"],
                fileManager: .default
            ) == .wsl
        )
    }

    private static func result(
        stdout: String = "",
        stderr: String = "",
        exitCode: Int32 = 0,
        timedOut: Bool = false
    ) -> AsyncProcessResult {
        AsyncProcessResult(
            exitCode: exitCode,
            stdoutData: Data(stdout.utf8),
            stderrData: Data(stderr.utf8),
            timedOut: timedOut,
            stdoutWasTruncated: false,
            stderrWasTruncated: false
        )
    }
}

@Suite
struct DS4InstallationScannerTests {
    @Test
    func scansOnlyRootAndTopLevelGGUFDirectoryAndReportsDiskBytes() throws {
        let fileManager = FileManager.default
        let root = try temporaryDirectory(fileManager: fileManager)
        let outside = try temporaryDirectory(fileManager: fileManager)
        defer {
            try? fileManager.removeItem(at: root)
            try? fileManager.removeItem(at: outside)
        }

        try Data(repeating: 1, count: 7).write(to: root.appendingPathComponent("root.gguf"))
        try fileManager.createDirectory(
            at: root.appendingPathComponent("gguf"),
            withIntermediateDirectories: true
        )
        try Data(repeating: 2, count: 11).write(to: root.appendingPathComponent("gguf/model.gguf"))
        try Data(repeating: 3, count: 13).write(to: root.appendingPathComponent("gguf/not-a-model.bin"))
        try fileManager.createDirectory(
            at: root.appendingPathComponent("nested"),
            withIntermediateDirectories: true
        )
        try Data(repeating: 4, count: 17).write(to: root.appendingPathComponent("nested/hidden.gguf"))
        let outsideModel = outside.appendingPathComponent("outside.gguf")
        try Data(repeating: 5, count: 19).write(to: outsideModel)
        try fileManager.createSymbolicLink(
            at: root.appendingPathComponent("gguf/link.gguf"),
            withDestinationURL: outsideModel
        )

        let snapshot = try DS4InstallationScanner(fileManager: fileManager).scan(rootDirectory: root)

        #expect(snapshot.artifacts.map(\.relativePath) == ["gguf/model.gguf", "root.gguf"])
        #expect(snapshot.artifacts.map(\.diskBytes) == [11, 7])
        #expect(snapshot.totalDiskBytes == 18)
        #expect(snapshot.contains(relativePath: "gguf/model.gguf"))
        #expect(!snapshot.contains(relativePath: "nested/hidden.gguf"))
        #expect(snapshot.diagnostics.contains { $0.contains("symbolic-link") })
    }

    @Test
    func catalogReportsMissingPartialAndInstalledWithoutReadingGGUF() {
        let catalog = DS4ModelCatalog.default
        let entry = catalog.entry(id: "pro-q4-split")!
        let partial = DS4InstallationSnapshot(
            rootDirectory: "/tmp/ds4",
            artifacts: [
                DS4InstalledArtifact(
                    relativePath: entry.artifacts[0].relativePath,
                    url: URL(fileURLWithPath: "/tmp/ds4/\(entry.artifacts[0].relativePath)"),
                    diskBytes: 42
                )
            ]
        )
        let installed = DS4InstallationSnapshot(
            rootDirectory: "/tmp/ds4",
            artifacts: entry.artifacts.map {
                DS4InstalledArtifact(
                    relativePath: $0.relativePath,
                    url: URL(fileURLWithPath: "/tmp/ds4/\($0.relativePath)"),
                    diskBytes: 42
                )
            }
        )

        #expect(entry.installationState(in: DS4InstallationSnapshot(rootDirectory: "/tmp/ds4")) == .missing)
        #expect(entry.installationState(in: partial) == .partial)
        #expect(entry.installationState(in: installed) == .installed)
        #expect(entry.resources.diskBytes != nil)
    }

    @Test
    func catalogDownloadIdentitiesMapToDs4ModelsAPIAliases() {
        let catalog = DS4ModelCatalog.default

        #expect(catalog.entry(id: "ds4f-q4")?.apiModelID == "deepseek-v4-flash")
        #expect(catalog.entry(id: "pro-q2-imatrix")?.apiModelID == "deepseek-v4-pro")
        #expect(catalog.entry(id: "qwen38-q2")?.apiModelID == "qwen3.8-flash-next")
        #expect(catalog.entry(id: "glm-antirez-q4")?.apiModelID == "glm-5.2")
        #expect(catalog.entry(id: "glm53-q4")?.apiModelID == "glm-5.3-flash")
        #expect(
            DS4ModelCatalogEntry(
                id: "fixture-model",
                displayName: "Fixture",
                downloadTarget: "fixture-model",
                artifacts: [],
                resources: DS4ModelResourceEstimate(),
                supportedBackends: [.metal]
            ).apiModelID == "fixture-model"
        )
    }

    private func temporaryDirectory(fileManager: FileManager) throws -> URL {
        let url = fileManager.temporaryDirectory
            .appendingPathComponent("zencode-ds4-scan-")
            .appendingPathComponent(UUID().uuidString)
        try fileManager.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}

@Suite
struct DS4CompatibilityAdvisorTests {
    @Test
    func missingModelIsProposedForDownloadWhenBackendAndRAMAreKnown() {
        let hardware = DS4HardwareSnapshot(
            platform: .macOS,
            architecture: "arm64",
            physicalMemoryBytes: 128 * 1024 * 1024 * 1024,
            gpus: [DS4GPUDevice(name: "Apple M4 Max", backend: .metal)],
            availableBackends: [.metal]
        )
        let report = DS4CompatibilityAdvisor().advise(
            hardware: hardware,
            installation: DS4InstallationSnapshot(rootDirectory: "/tmp/ds4")
        )
        let q2 = report.proposals.first { $0.model.id == "ds4f-q2" }!
        let q4 = report.proposals.first { $0.model.id == "ds4f-q4" }!

        #expect(q2.status == .downloadRequired)
        #expect(q2.shouldDownload)
        #expect(q2.installationState == .missing)
        #expect(q2.requiredDiskBytes != q2.requiredResidentMemoryBytes)
        #expect(q4.status == .insufficientMemory)
        #expect(!q4.shouldDownload)
        #expect(report.recommended == nil)
    }

    @Test
    func installedStreamingModelIsOperationalOnlyInDocumentedStreamingMode() {
        let catalog = DS4ModelCatalog.default
        let entry = catalog.entry(id: "ds41f-q2")!
        let installation = DS4InstallationSnapshot(
            rootDirectory: "/tmp/ds4",
            artifacts: [
                DS4InstalledArtifact(
                    relativePath: entry.artifacts[0].relativePath,
                    url: URL(fileURLWithPath: "/tmp/ds4/\(entry.artifacts[0].relativePath)"),
                    diskBytes: entry.resources.diskBytes!
                )
            ]
        )
        let hardware = DS4HardwareSnapshot(
            platform: .macOS,
            physicalMemoryBytes: 128 * 1024 * 1024 * 1024,
            gpus: [DS4GPUDevice(name: "Apple GPU", backend: .metal)],
            availableBackends: [.metal]
        )

        let proposal = DS4CompatibilityAdvisor(catalog: catalog).advise(
            hardware: hardware,
            installation: installation
        ).proposals.first { $0.model.id == entry.id }!

        #expect(proposal.status == .streamingRecommended)
        #expect(proposal.mode == .ssdStreaming)
        #expect(proposal.isOperational)
    }

    @Test
    func unknownAndCPUOnlyHardwareNeverBecomesReady() {
        let installation = DS4InstallationSnapshot(rootDirectory: "/tmp/ds4")
        let unknown = DS4HardwareSnapshot(platform: .unknown)
        let cpuOnly = DS4HardwareSnapshot(
            platform: .linux,
            architecture: "x86_64",
            physicalMemoryBytes: 256 * 1024 * 1024 * 1024
        )

        let unknownReport = DS4CompatibilityAdvisor().advise(
            hardware: unknown,
            installation: installation
        )
        let cpuReport = DS4CompatibilityAdvisor().advise(
            hardware: cpuOnly,
            installation: installation
        )

        #expect(unknownReport.proposals.allSatisfy { $0.status == .hardwareUnknown })
        #expect(unknownReport.recommended == nil)
        #expect(cpuReport.proposals.allSatisfy { $0.status == .diagnosticOnly })
        #expect(cpuReport.recommended == nil)
    }

    @Test
    func missingPhysicalMemoryStaysUnknownEvenWhenDiskEstimateExists() {
        let hardware = DS4HardwareSnapshot(
            platform: .macOS,
            gpus: [DS4GPUDevice(name: "Apple GPU", backend: .metal)],
            availableBackends: [.metal]
        )
        let report = DS4CompatibilityAdvisor().advise(
            hardware: hardware,
            installation: DS4InstallationSnapshot(rootDirectory: "/tmp/ds4")
        )
        let q2 = report.proposals.first { $0.model.id == "ds4f-q2" }!

        #expect(q2.status == .memoryUnknown)
        #expect(!q2.isOperational)
        #expect(!q2.shouldDownload)
        #expect(q2.rationale.contains { $0.localizedCaseInsensitiveContains("not used as a substitute") })
    }
}
