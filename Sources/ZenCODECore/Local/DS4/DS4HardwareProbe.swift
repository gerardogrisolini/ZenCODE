//
//  DS4HardwareProbe.swift
//  ZenCODE
//
//  Created by Gerardo Grisolini on 30/05/26.
//
//  Bounded, diagnostic-only hardware discovery for the optional local DS4 runtime.
//

import Foundation
import ToolCore
#if canImport(Darwin)
import Darwin
#endif
#if canImport(Metal)
import Metal
#endif

/// The host family used when deciding which non-invasive probes to attempt.
public enum DS4HostPlatform: String, Codable, CaseIterable, Hashable, Sendable {
    case macOS
    case linux
    case wsl
    case unknown

    public static func current(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        fileManager: FileManager = .default
    ) -> DS4HostPlatform {
        if environment["WSL_DISTRO_NAME"]?.isEmpty == false
            || environment["WSL_INTEROP"]?.isEmpty == false
            || environment["WSLENV"]?.isEmpty == false {
            return .wsl
        }

        #if os(macOS)
        return .macOS
        #elseif os(Linux)
        if let release = try? String(
            contentsOf: URL(fileURLWithPath: "/proc/sys/kernel/osrelease"),
            encoding: .utf8
        ), release.localizedCaseInsensitiveContains("microsoft") {
            return .wsl
        }
        return .linux
        #else
        _ = environment
        _ = fileManager
        return .unknown
        #endif
    }
}

/// A command represented as executable name plus argv. No shell or command
/// interpolation is involved, which keeps probe inputs data-only.
public struct DS4HardwareCommand: Hashable, Sendable {
    public let executableName: String
    public let arguments: [String]

    public init(executableName: String, arguments: [String] = []) {
        self.executableName = executableName
        self.arguments = arguments
    }
}

public struct DS4GPUDevice: Codable, Equatable, Hashable, Sendable {
    public let name: String
    /// Nil means that the device was seen but its backend could not be proven.
    public let backend: AgentDS4RuntimeBackend?
    /// Nil means that the device utility did not expose VRAM. It must not be
    /// filled from disk size or a guessed machine memory value.
    public let memoryBytes: UInt64?
    public let evidence: [String]

    public init(
        name: String,
        backend: AgentDS4RuntimeBackend?,
        memoryBytes: UInt64? = nil,
        evidence: [String] = []
    ) {
        self.name = name
        self.backend = backend
        self.memoryBytes = memoryBytes
        self.evidence = evidence
    }
}

public struct DS4HardwareSnapshot: Codable, Equatable, Hashable, Sendable {
    public let platform: DS4HostPlatform
    public let architecture: String?
    /// Physical RAM only. Disk capacity is deliberately not represented here.
    public let physicalMemoryBytes: UInt64?
    public let gpus: [DS4GPUDevice]
    /// Backends proven by a GPU/platform probe. CPU is intentionally absent:
    /// DS4's CPU path is diagnostic/reference-only, not an operational choice.
    public let availableBackends: [AgentDS4RuntimeBackend]
    public let diagnostics: [String]
    public let evidence: [String]

    public init(
        platform: DS4HostPlatform,
        architecture: String? = nil,
        physicalMemoryBytes: UInt64? = nil,
        gpus: [DS4GPUDevice] = [],
        availableBackends: [AgentDS4RuntimeBackend] = [],
        diagnostics: [String] = [],
        evidence: [String] = []
    ) {
        self.platform = platform
        self.architecture = architecture
        self.physicalMemoryBytes = physicalMemoryBytes
        self.gpus = gpus
        self.availableBackends = availableBackends
        self.diagnostics = diagnostics
        self.evidence = evidence
    }

    public var primaryBackend: AgentDS4RuntimeBackend? {
        if availableBackends.contains(.metal) { return .metal }
        if availableBackends.contains(.cuda) { return .cuda }
        if availableBackends.contains(.rocm) { return .rocm }
        return nil
    }

    public var hasKnownGPUBackend: Bool {
        primaryBackend != nil
    }

    /// True for every snapshot. Keeping this as an explicit API prevents a
    /// caller from accidentally promoting CPU discovery to a provider.
    public var cpuIsDiagnosticOnly: Bool { true }

    public var isOperationallyComplete: Bool {
        hasKnownGPUBackend && physicalMemoryBytes != nil
    }
}

public enum DS4HardwareProbeError: LocalizedError, Equatable, Sendable {
    case executableUnavailable(String)
    case unsupportedPlatform

    public var errorDescription: String? {
        switch self {
        case let .executableUnavailable(name):
            return "The DS4 hardware probe executable is unavailable: \(name)."
        case .unsupportedPlatform:
            return "The DS4 hardware probe is unavailable on this platform."
        }
    }
}

/// Performs only bounded, read-only diagnostics. Missing utilities and
/// malformed output remain visible in `diagnostics` and never become a guessed
/// backend or memory value.
public struct DS4HardwareProbe: @unchecked Sendable {
    public typealias CommandRunner = @Sendable (
        DS4HardwareCommand
    ) async throws -> AsyncProcessResult

    private static let maximumOutputBytesPerStream = 64 * 1024
    private static let commandTimeout: TimeInterval = 2
    private static let maximumDiagnostics = 32

    private let platform: DS4HostPlatform
    private let environment: [String: String]
    private let fileManager: FileManager
    private let commandRunner: CommandRunner

    public init(
        platform: DS4HostPlatform? = nil,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        fileManager: FileManager = .default,
        commandRunner: CommandRunner? = nil
    ) {
        self.platform = platform ?? DS4HostPlatform.current(
            environment: environment,
            fileManager: fileManager
        )
        self.environment = environment
        self.fileManager = fileManager
        self.commandRunner = commandRunner ?? { command in
            try await Self.runLive(command: command, environment: environment)
        }
    }

    public func probe() async -> DS4HardwareSnapshot {
        var diagnostics: [String] = []
        var evidence: [String] = ["platform:\(platform.rawValue)"]
        let architecture = await runAndReadFirstLine(
            DS4HardwareCommand(executableName: "uname", arguments: ["-m"]),
            diagnostics: &diagnostics,
            evidence: &evidence
        )

        var physicalMemoryBytes: UInt64?
        var gpus: [DS4GPUDevice] = []

        switch platform {
        case .macOS:
            physicalMemoryBytes = await probeMacMemory(
                diagnostics: &diagnostics,
                evidence: &evidence
            )
            gpus = await probeMacGPUs(
                diagnostics: &diagnostics,
                evidence: &evidence
            )
        case .linux, .wsl:
            physicalMemoryBytes = probeLinuxMemory(
                diagnostics: &diagnostics,
                evidence: &evidence
            )
            gpus = await probeLinuxGPUs(
                diagnostics: &diagnostics,
                evidence: &evidence
            )
        case .unknown:
            appendDiagnostic(
                "Unsupported host platform; no hardware backend inferred.",
                to: &diagnostics
            )
        }

        var backends: [AgentDS4RuntimeBackend] = []
        for gpu in gpus {
            guard let backend = gpu.backend, !backends.contains(backend) else {
                continue
            }
            backends.append(backend)
        }
        if gpus.isEmpty {
            appendDiagnostic(
                "No GPU backend was proven; CPU remains diagnostic-only.",
                to: &diagnostics
            )
        } else if gpus.contains(where: { $0.backend == nil }) {
            appendDiagnostic(
                "At least one GPU was observed without a proven DS4 backend.",
                to: &diagnostics
            )
        }
        if physicalMemoryBytes == nil {
            appendDiagnostic(
                "Physical RAM is unknown; disk capacity is not used as a substitute.",
                to: &diagnostics
            )
        }

        return DS4HardwareSnapshot(
            platform: platform,
            architecture: architecture,
            physicalMemoryBytes: physicalMemoryBytes,
            gpus: gpus,
            availableBackends: backends,
            diagnostics: diagnostics,
            evidence: evidence
        )
    }

    /// Compatibility spelling for callers that use a noun-oriented API.
    public func collect() async -> DS4HardwareSnapshot {
        await probe()
    }

    private func probeMacMemory(
        diagnostics: inout [String],
        evidence: inout [String]
    ) async -> UInt64? {
        guard let output = await run(
            DS4HardwareCommand(executableName: "sysctl", arguments: ["-n", "hw.memsize"]),
            diagnostics: &diagnostics,
            evidence: &evidence
        ) else {
#if canImport(Darwin)
            if let bytes = Self.readDarwinPhysicalMemory() {
                evidence.append("Darwin:sysctlbyname:hw.memsize")
                return bytes
            }
#endif
            return nil
        }
        guard let bytes = Self.parseUnsignedInteger(output.stdout) else {
            appendDiagnostic("sysctl hw.memsize returned no usable byte count.", to: &diagnostics)
#if canImport(Darwin)
            if let bytes = Self.readDarwinPhysicalMemory() {
                evidence.append("Darwin:sysctlbyname:hw.memsize")
                return bytes
            }
#endif
            return nil
        }
        evidence.append("sysctl:hw.memsize")
        return bytes
    }

    private func probeMacGPUs(
        diagnostics: inout [String],
        evidence: inout [String]
    ) async -> [DS4GPUDevice] {
        let output = await run(
            DS4HardwareCommand(
                executableName: "system_profiler",
                arguments: ["SPDisplaysDataType"]
            ),
            diagnostics: &diagnostics,
            evidence: &evidence
        )
        let displayText = output?.stdout ?? ""
        let lines = displayText.split(whereSeparator: \.isNewline).map(String.init)
        var devices = Self.parseMacDisplayDevices(displayText)


#if canImport(Metal)
        if devices.isEmpty {
            devices = Self.probeMetalAPI()
        }
#endif

        if devices.isEmpty,
           lines.contains(where: { line in
               let lower = line.lowercased()
               return lower.contains("metal") || lower.contains("apple gpu")
           }) {
            devices.append(
                DS4GPUDevice(
                    name: "Metal GPU (name unavailable)",
                    backend: .metal,
                    evidence: ["system_profiler:SPDisplaysDataType"]
                )
            )
        }
        if devices.isEmpty {
            appendDiagnostic(
                "system_profiler did not expose a recognizable GPU; Metal remains unknown.",
                to: &diagnostics
            )
        }
        return devices
    }

    #if canImport(Darwin)
    private static func readDarwinPhysicalMemory() -> UInt64? {
        var value: UInt64 = 0
        var size = MemoryLayout<UInt64>.size
        let result = sysctlbyname("hw.memsize", &value, &size, nil, 0)
        return result == 0 && size == MemoryLayout<UInt64>.size ? value : nil
    }
    #endif

    private static func parseMacDisplayDevices(_ text: String) -> [DS4GPUDevice] {
        let lines = text.split(whereSeparator: \.isNewline).map(String.init)
        var devices: [DS4GPUDevice] = []
        var currentName: String?
        var currentMemory: UInt64?
        var currentEvidence: [String] = ["system_profiler:SPDisplaysDataType"]

        func finishDevice() {
            guard let currentName else { return }
            devices.append(
                DS4GPUDevice(
                    name: currentName,
                    backend: .metal,
                    memoryBytes: currentMemory,
                    evidence: currentEvidence
                )
            )
        }

        for rawLine in lines {
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            let lower = line.lowercased()
            if lower.contains("chipset model:") || lower.contains("chip model:") {
                finishDevice()
                currentName = valueAfterColon(line) ?? "Metal GPU"
                currentMemory = nil
                currentEvidence = ["system_profiler:SPDisplaysDataType"]
                continue
            }
            guard currentName != nil else { continue }
            if lower.contains("vram") || lower.contains("memory") {
                currentMemory = currentMemory ?? parseByteCount(line)
            }
        }
        finishDevice()
        return devices
    }

#if canImport(Metal)
    private static func probeMetalAPI() -> [DS4GPUDevice] {
        MTLCopyAllDevices().map { device in
            DS4GPUDevice(
                name: device.name,
                backend: .metal,
                // Metal's recommended working-set limit is not VRAM and is
                // intentionally not exposed as a memory estimate here.
                memoryBytes: nil,
                evidence: ["Metal API:MTLCopyAllDevices"]
            )
        }
    }
#endif
    private func probeLinuxMemory(
        diagnostics: inout [String],
        evidence: inout [String]
    ) -> UInt64? {
        let url = URL(fileURLWithPath: "/proc/meminfo")
        guard let text = try? String(contentsOf: url, encoding: .utf8) else {
            appendDiagnostic("Unable to read /proc/meminfo; physical RAM is unknown.", to: &diagnostics)
            return nil
        }
        guard let line = text.split(whereSeparator: \.isNewline).first(where: {
            $0.hasPrefix("MemTotal:")
        }) else {
            appendDiagnostic("/proc/meminfo has no MemTotal entry.", to: &diagnostics)
            return nil
        }
        let fields = line.split(whereSeparator: { $0 == " " || $0 == "\t" })
        guard fields.count >= 2, let kib = UInt64(fields[1]) else {
            appendDiagnostic("/proc/meminfo MemTotal is malformed.", to: &diagnostics)
            return nil
        }
        evidence.append("/proc/meminfo:MemTotal")
        return kib.multipliedReportingOverflow(by: 1024).overflow ? nil : kib * 1024
    }

    private func probeLinuxGPUs(
        diagnostics: inout [String],
        evidence: inout [String]
    ) async -> [DS4GPUDevice] {
        var devices: [DS4GPUDevice] = []

        if let output = await run(
            DS4HardwareCommand(
                executableName: "nvidia-smi",
                arguments: ["--query-gpu=name,memory.total", "--format=csv,noheader,nounits"]
            ),
            diagnostics: &diagnostics,
            evidence: &evidence,
            reportFailure: false
        ) {
            for line in output.stdout.split(whereSeparator: \.isNewline).map(String.init) {
                let fields = line.split(separator: ",", maxSplits: 1).map {
                    $0.trimmingCharacters(in: .whitespacesAndNewlines)
                }
                guard let name = fields.first, !name.isEmpty else { continue }
                let memoryBytes = fields.count > 1
                    ? UInt64(fields[1]).flatMap { $0.multipliedReportingOverflow(by: 1024 * 1024).overflow ? nil : $0 * 1024 * 1024 }
                    : nil
                devices.append(
                    DS4GPUDevice(
                        name: name,
                        backend: .cuda,
                        memoryBytes: memoryBytes,
                        evidence: ["nvidia-smi"]
                    )
                )
            }
        }

        if devices.isEmpty, let output = await run(
            DS4HardwareCommand(executableName: "rocminfo"),
            diagnostics: &diagnostics,
            evidence: &evidence,
            reportFailure: false
        ) {
            let lines = output.stdout.split(whereSeparator: \.isNewline).map(String.init)
            let names = lines.compactMap { line -> String? in
                let lower = line.lowercased()
                guard lower.contains("name:"),
                      !lower.contains("cpu"),
                      lower.contains("gfx") || lower.contains("amd") else {
                    return nil
                }
                return Self.valueAfterColon(line)
            }
            if names.isEmpty && output.stdout.localizedCaseInsensitiveContains("gfx") {
                devices.append(
                    DS4GPUDevice(
                        name: "ROCm GPU (name unavailable)",
                        backend: .rocm,
                        evidence: ["rocminfo"]
                    )
                )
            } else {
                for name in names {
                    devices.append(
                        DS4GPUDevice(name: name, backend: .rocm, evidence: ["rocminfo"])
                    )
                }
            }
        }

        if devices.isEmpty, let output = await run(
            DS4HardwareCommand(executableName: "lspci", arguments: ["-nn"]),
            diagnostics: &diagnostics,
            evidence: &evidence,
            reportFailure: false
        ) {
            for line in output.stdout.split(whereSeparator: \.isNewline).map(String.init) {
                let lower = line.lowercased()
                guard lower.contains("vga") || lower.contains("3d controller") || lower.contains("display controller") else {
                    continue
                }
                devices.append(
                    DS4GPUDevice(
                        name: line.trimmingCharacters(in: .whitespacesAndNewlines),
                        // lspci identifies a PCI device, not an installed DS4
                        // backend. Keep this unknown until nvidia-smi/rocminfo
                        // proves the runtime path.
                        backend: nil,
                        evidence: ["lspci"]
                    )
                )
            }
        }

        if devices.isEmpty {
            appendDiagnostic(
                "No NVIDIA/ROCm GPU utility reported a device; backend remains unknown.",
                to: &diagnostics
            )
        }
        return devices
    }

    private func runAndReadFirstLine(
        _ command: DS4HardwareCommand,
        diagnostics: inout [String],
        evidence: inout [String]
    ) async -> String? {
        guard let output = await run(command, diagnostics: &diagnostics, evidence: &evidence) else {
            return nil
        }
        guard let first = output.stdout
            .split(whereSeparator: \.isNewline)
            .map(String.init)
            .first(where: { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) else {
            appendDiagnostic("\(command.executableName) returned no usable output.", to: &diagnostics)
            return nil
        }
        return first.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func run(
        _ command: DS4HardwareCommand,
        diagnostics: inout [String],
        evidence: inout [String],
        reportFailure: Bool = true
    ) async -> AsyncProcessResult? {
        do {
            let result = try await commandRunner(command)
            guard !result.timedOut else {
                appendDiagnostic("\(command.executableName) timed out; output was ignored.", to: &diagnostics)
                return nil
            }
            guard !result.stdoutWasTruncated, !result.stderrWasTruncated else {
                appendDiagnostic("\(command.executableName) output exceeded the bounded probe limit.", to: &diagnostics)
                return nil
            }
            guard result.exitCode == 0 else {
                if reportFailure {
                    appendDiagnostic(
                        "\(command.executableName) exited with code \(result.exitCode).",
                        to: &diagnostics
                    )
                }
                return nil
            }
            evidence.append("command:\(command.executableName)")
            return result
        } catch {
            if reportFailure {
                appendDiagnostic(
                    "\(command.executableName) unavailable: \(error.localizedDescription)",
                    to: &diagnostics
                )
            }
            return nil
        }
    }

    private static func runLive(
        command: DS4HardwareCommand,
        environment: [String: String]
    ) async throws -> AsyncProcessResult {
        #if canImport(Darwin) || canImport(Glibc)
        guard let executableURL = DeveloperToolEnvironment.executableURL(
            named: command.executableName
        ) else {
            throw DS4HardwareProbeError.executableUnavailable(command.executableName)
        }
        return try await AsyncProcessRunner.run(
            executableURL: executableURL,
            arguments: command.arguments,
            environment: DeveloperToolEnvironment.processEnvironment(base: environment),
            timeout: Self.commandTimeout,
            stdoutLineLimit: 512,
            maximumOutputBytesPerStream: Self.maximumOutputBytesPerStream
        )
        #else
        _ = command
        _ = environment
        throw DS4HardwareProbeError.unsupportedPlatform
        #endif
    }

    private static func appendDiagnostic(_ diagnostic: String, to diagnostics: inout [String]) {
        guard diagnostics.count < maximumDiagnostics else { return }
        diagnostics.append(diagnostic)
    }

    private func appendDiagnostic(_ diagnostic: String, to diagnostics: inout [String]) {
        Self.appendDiagnostic(diagnostic, to: &diagnostics)
    }

    private static func valueAfterColon(_ line: String) -> String? {
        guard let colon = line.firstIndex(of: ":") else { return nil }
        let value = line[line.index(after: colon)...]
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }

    private static func parseUnsignedInteger(_ text: String) -> UInt64? {
        let token = text
            .split(whereSeparator: { !$0.isNumber })
            .first
        guard let token else { return nil }
        return UInt64(token)
    }

    /// Parses human-readable quantities from system utilities without treating
    /// an absent unit as a guess. Values are rounded down to bytes.
    private static func parseByteCount(_ text: String) -> UInt64? {
        let tokens = text
            .replacingOccurrences(of: ":", with: " ")
            .split(whereSeparator: { $0 == " " || $0 == "\t" })
        for (index, token) in tokens.enumerated() {
            let raw = String(token).lowercased()
            let unit: Double
            if raw.hasSuffix("gib") {
                unit = 1024 * 1024 * 1024
            } else if raw.hasSuffix("gb") {
                unit = 1000 * 1000 * 1000
            } else if raw.hasSuffix("mib") {
                unit = 1024 * 1024
            } else if raw.hasSuffix("mb") {
                unit = 1000 * 1000
            } else if raw.hasSuffix("bytes") || raw.hasSuffix("byte") {
                unit = 1
            } else if index + 1 < tokens.count {
                let next = String(tokens[index + 1]).lowercased()
                switch next {
                case "gib": unit = 1024 * 1024 * 1024
                case "gb": unit = 1000 * 1000 * 1000
                case "mib": unit = 1024 * 1024
                case "mb": unit = 1000 * 1000
                case "bytes", "byte": unit = 1
                default: continue
                }
            } else {
                continue
            }

            let numeric = raw
                .replacingOccurrences(of: "gib", with: "")
                .replacingOccurrences(of: "gb", with: "")
                .replacingOccurrences(of: "mib", with: "")
                .replacingOccurrences(of: "mb", with: "")
                .replacingOccurrences(of: "bytes", with: "")
                .replacingOccurrences(of: "byte", with: "")
            if let value = Double(numeric), value >= 0,
               value <= Double(UInt64.max) / unit {
                return UInt64(value * unit)
            }
        }
        return nil
    }
}
