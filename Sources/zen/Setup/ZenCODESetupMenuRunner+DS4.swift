//
//  ZenCODESetupMenuRunner+DS4.swift
//  ZenCODE
//

import Foundation
import ZenCODECore
import ZenCODESetup

extension ZenCODESetupMenuRunner {
    static func ds4RuntimeSetupSection() -> ZenCODESetupAdditionalSection {
        ZenCODESetupAdditionalSection(
            title: "DS4 runtime",
            detail: ds4RuntimeSetupDetail(),
            aliases: ["ds4", "ds4 setup", "ds4 runtime"]
        ) {
            try configureDS4RuntimeSettings()
            return .unchanged
        }
    }

    static func ds4ModelsSetupSection() -> ZenCODESetupAdditionalSection {
        ZenCODESetupAdditionalSection(
            title: "DS4 models",
            detail: ds4ModelSetupDetail(),
            aliases: ["ds4", "ds4 setup", "ds4 runtime", "ds4 model", "ds4 models"]
        ) {
            try configureDS4ModelSelection()
            return .unchanged
        }
    }

    private static func ds4RuntimeSetupDetail() -> String {
        guard let settings = try? DS4SettingsStore.load() else {
            return "not installed"
        }
        let backend = settings.backend?.nilIfBlank ?? defaultDS4Backend()
        let ctx = settings.contextWindow ?? 65536
        var parts = ["\(backend)", "ctx \(formatTokenCount(ctx))"]
        if settings.ssdStreaming == true {
            let cache = formatStreamingCache(
                experts: settings.ssdStreamingCacheExperts ?? 0,
                bytes: settings.ssdStreamingCacheBytes ?? 0
            )
            parts.append(cache.map { "ssd \($0)" } ?? "ssd")
        }
        return parts.joined(separator: ", ")
    }

    private static func ds4ModelSetupDetail() -> String {
        guard let settings = try? DS4SettingsStore.load() else {
            return "install runtime first"
        }
        guard let modelPath = settings.modelPath?.nilIfBlank else {
            return "runtime ready, model not selected"
        }
        return URL(fileURLWithPath: modelPath).lastPathComponent
    }

    private static func configureDS4RuntimeSettings() throws {
        guard var settings = try DS4SettingsStore.load() ?? configureInitialDS4RuntimeInstall() else {
            return
        }

        let ds4Root = URL(fileURLWithPath: settings.ds4Root).standardizedFileURL
        guard directoryExists(ds4Root) else {
            AgentOutput.standardError.writeString(
                "DS4 root not found: \(ds4Root.path)\nRun Scripts/setup-ds4.sh /path/to/ds4 again.\n\n"
            )
            return
        }

        let libraryURL = URL(
            fileURLWithPath: settings.libraryPath?.nilIfBlank
                ?? ds4Root.appendingPathComponent(defaultDS4LibraryName()).path
        ).standardizedFileURL
        guard DS4ModelDiscovery.isFile(libraryURL) else {
            AgentOutput.standardError.writeString(
                "DS4 runtime library not found: \(libraryURL.path)\nRun Scripts/setup-ds4.sh \(ds4Root.path) again.\n\n"
            )
            return
        }

        AgentOutput.standardError.writeString(
            """
            DS4 runtime:
              root:    \(ds4Root.path)
              library: \(libraryURL.path)

            """
        )

        settings.libraryPath = libraryURL.path
        settings.backend = try promptBackend(defaultValue: settings.backend?.nilIfBlank ?? defaultDS4Backend())
        settings.contextWindow = try promptInt(
            "Context window tokens",
            defaultValue: settings.contextWindow ?? 65536,
            allowedRange: 1...1_048_576
        )
        settings.maxOutputTokens = try promptOptionalInt(
            "Max output tokens (0 for default)",
            defaultValue: settings.maxOutputTokens,
            allowedRange: 0...1_048_576
        )
        settings.maxToolRounds = try promptInt(
            "Max tool rounds",
            defaultValue: settings.maxToolRounds ?? AgentToolRoundPolicy.defaultMaxToolRounds,
            allowedRange: AgentToolRoundPolicy.minimumMaxToolRounds...Int.max
        )
        settings.nThreads = try promptInt(
            "Threads (0 for DS4 default)",
            defaultValue: settings.nThreads ?? 0,
            allowedRange: 0...1024
        )
        settings.prefillChunk = UInt32(
            try promptInt(
                "Prefill chunk (0 for DS4 default)",
                defaultValue: Int(settings.prefillChunk ?? 0),
                allowedRange: 0...Int(UInt32.max)
            )
        )
        settings.powerPercent = try promptInt(
            "Power percent",
            defaultValue: settings.powerPercent ?? 100,
            allowedRange: 1...100
        )
        settings.quality = promptBool(
            "Quality mode",
            defaultValue: settings.quality ?? false
        )

        let ssdStreaming = promptBool(
            "SSD streaming",
            defaultValue: settings.ssdStreaming ?? false
        )
        settings.ssdStreaming = ssdStreaming
        if ssdStreaming {
            let cache = try promptStreamingCache(
                defaultExperts: settings.ssdStreamingCacheExperts ?? 0,
                defaultBytes: settings.ssdStreamingCacheBytes ?? 0
            )
            settings.ssdStreamingCacheExperts = cache.experts
            settings.ssdStreamingCacheBytes = cache.bytes
            settings.ssdStreamingPreloadExperts = UInt32(
                try promptInt(
                    "SSD streaming preload experts (0 for none)",
                    defaultValue: Int(settings.ssdStreamingPreloadExperts ?? 0),
                    allowedRange: 0...Int(UInt32.max)
                )
            )
            settings.ssdStreamingCold = promptBool(
                "SSD streaming cold start",
                defaultValue: settings.ssdStreamingCold ?? false
            )
        }

        settings.mtpPath = try promptOptionalPath(
            "MTP model path (none for disabled)",
            defaultValue: settings.mtpPath?.nilIfBlank
        )
        settings.mtpDraftTokens = try promptInt(
            "MTP draft tokens",
            defaultValue: settings.mtpDraftTokens ?? 1,
            allowedRange: 1...1024
        )
        settings.mtpMargin = try promptFloat(
            "MTP margin",
            defaultValue: settings.mtpMargin ?? 3.0,
            allowedRange: 0...100
        )
        settings.temperature = try promptFloat(
            "Temperature",
            defaultValue: settings.temperature ?? 1.0,
            allowedRange: 0...2
        )
        settings.topK = try promptInt(
            "Top-k (0 to disable)",
            defaultValue: settings.topK ?? 0,
            allowedRange: 0...100000
        )
        settings.topP = try promptFloat(
            "Top-p",
            defaultValue: settings.topP ?? 1.0,
            allowedRange: 0.01...1
        )
        settings.minP = try promptFloat(
            "Min-p",
            defaultValue: settings.minP ?? 0.05,
            allowedRange: 0...1
        )
        settings.seed = UInt64(
            try promptInt(
                "Seed (0 for random/default)",
                defaultValue: Int(settings.seed ?? 0),
                allowedRange: 0...Int(Int32.max)
            )
        )

        try DS4SettingsStore.save(settings)
        AgentOutput.standardError.writeString(
            """
            DS4 runtime settings saved.

            Validate with:
              zen --ds4 --doctor

            """
        )
    }

    private static func configureInitialDS4RuntimeInstall() throws -> DS4SettingsManifest? {
        AgentOutput.standardError.writeString(
            """
            DS4 runtime is not installed yet.

            Enter the local DS4 checkout/build directory. The setup will register
            the runtime library and, on macOS, can build libds4.dylib for you.

            """
        )

        let ds4Root = try promptDS4RootURL()
        let defaultLibraryURL = ds4Root.appendingPathComponent(defaultDS4LibraryName())
            .standardizedFileURL

        let buildRuntime: Bool
        let libraryURL: URL?
        if DS4ModelDiscovery.isFile(defaultLibraryURL) {
            #if os(macOS)
            buildRuntime = promptBool(
                "Rebuild DS4 runtime library",
                defaultValue: false
            )
            #else
            buildRuntime = false
            #endif
            libraryURL = defaultLibraryURL
        } else {
            #if os(macOS)
            buildRuntime = promptBool(
                "Build DS4 runtime library now",
                defaultValue: true
            )
            libraryURL = buildRuntime
                ? defaultLibraryURL
                : try promptDS4LibraryURL(defaultValue: defaultLibraryURL.path)
            #else
            buildRuntime = false
            AgentOutput.standardError.writeString(
                """
                The bundled DS4 build helper is macOS/Metal only.
                Build libds4.so from the DS4 checkout, then enter its path.

                """
            )
            libraryURL = try promptDS4LibraryURL(defaultValue: defaultLibraryURL.path)
            #endif
        }

        let settings = try registerDS4Runtime(
            ds4Root: ds4Root,
            libraryURL: libraryURL,
            buildRuntime: buildRuntime
        )

        AgentOutput.standardError.writeString(
            """
            DS4 runtime registered:
              root:    \(settings.ds4Root)
              library: \(settings.libraryPath ?? defaultLibraryURL.path)

            """
        )
        return settings
    }

    private static func configureDS4ModelSelection() throws {
        guard var settings = try DS4SettingsStore.load() else {
            printDS4RuntimeInstallHelp()
            return
        }

        let ds4Root = URL(fileURLWithPath: settings.ds4Root).standardizedFileURL
        guard directoryExists(ds4Root) else {
            AgentOutput.standardError.writeString(
                "DS4 root not found: \(ds4Root.path)\nRun Scripts/setup-ds4.sh /path/to/ds4 again.\n\n"
            )
            return
        }

        if let libraryPath = settings.libraryPath?.nilIfBlank {
            let libraryURL = URL(fileURLWithPath: libraryPath).standardizedFileURL
            guard DS4ModelDiscovery.isFile(libraryURL) else {
                AgentOutput.standardError.writeString(
                    "DS4 runtime library not found: \(libraryURL.path)\nRun Scripts/setup-ds4.sh \(ds4Root.path) again.\n\n"
                )
                return
            }
        }

        let modelURL = try promptDS4ModelURL(
            ds4Root: ds4Root,
            currentModelPath: settings.modelPath?.nilIfBlank
        )
        settings.modelPath = modelURL.path
        try DS4SettingsStore.save(settings)

        AgentOutput.standardError.writeString(
            """
            DS4 model selected:
              \(modelURL.path)

            Validate with:
              zen --ds4 --doctor

            """
        )
    }

    private enum DS4ModelChoice: Hashable {
        case candidate(String)
        case manual
    }

    private static func promptBackend(defaultValue: String) throws -> String {
        let backends = ["metal", "cuda", "cpu"]
        let selected = backends.contains(defaultValue) ? defaultValue : defaultDS4Backend()
        let items = backends.map {
            TerminalCheckboxMenuItem(value: $0, title: $0, detail: nil)
        }
        guard let value = TerminalCheckboxMenu.selectOne(
            title: "DS4 backend",
            items: items,
            selected: selected
        ) else {
            throw DS4SetupError.cancelled
        }
        return value
    }

    private static func promptInt(
        _ prompt: String,
        defaultValue: Int,
        allowedRange: ClosedRange<Int>
    ) throws -> Int {
        while true {
            let rawValue = try promptLine(
                title: "DS4 runtime",
                prompt: prompt,
                defaultValue: String(defaultValue),
                allowEmpty: false
            )
            guard let parsed = Int(rawValue), allowedRange.contains(parsed) else {
                AgentOutput.standardError.writeString("Invalid value.\n")
                continue
            }
            return parsed
        }
    }

    private static func promptOptionalInt(
        _ prompt: String,
        defaultValue: Int?,
        allowedRange: ClosedRange<Int>
    ) throws -> Int? {
        let rawDefault = defaultValue.map(String.init)
        while true {
            let rawValue = try promptLine(
                title: "DS4 runtime",
                prompt: prompt,
                defaultValue: rawDefault,
                allowEmpty: true
            )
            guard let value = rawValue.nilIfBlank else {
                return nil
            }
            guard let parsed = Int(value), allowedRange.contains(parsed) else {
                AgentOutput.standardError.writeString("Invalid value.\n")
                continue
            }
            return parsed == 0 ? nil : parsed
        }
    }

    private static func promptFloat(
        _ prompt: String,
        defaultValue: Float,
        allowedRange: ClosedRange<Float>
    ) throws -> Float {
        while true {
            let rawValue = try promptLine(
                title: "DS4 runtime",
                prompt: prompt,
                defaultValue: String(format: "%.4g", Double(defaultValue)),
                allowEmpty: false
            )
            guard let parsed = Float(rawValue.replacingOccurrences(of: ",", with: ".")),
                  allowedRange.contains(parsed) else {
                AgentOutput.standardError.writeString("Invalid value.\n")
                continue
            }
            return parsed
        }
    }

    private static func promptBool(_ prompt: String, defaultValue: Bool) -> Bool {
        let items = [
            TerminalCheckboxMenuItem(value: true, title: "Yes", detail: nil),
            TerminalCheckboxMenuItem(value: false, title: "No", detail: nil)
        ]
        return TerminalCheckboxMenu.selectOne(
            title: prompt,
            items: items,
            selected: defaultValue
        ) ?? defaultValue
    }

    private static func promptStreamingCache(
        defaultExperts: UInt32,
        defaultBytes: UInt64
    ) throws -> (experts: UInt32, bytes: UInt64) {
        while true {
            let rawValue = try promptLine(
                title: "DS4 runtime",
                prompt: "SSD streaming cache (N experts, NGB memory, or 0 for DS4 default)",
                defaultValue: formatStreamingCache(experts: defaultExperts, bytes: defaultBytes),
                allowEmpty: true,
                help: "Use 32GB to match --ssd-streaming-cache-experts 32GB, or 32 to cache 32 experts."
            )
            guard let value = rawValue.nilIfBlank else {
                return (0, 0)
            }
            if let parsed = parseStreamingCache(value) {
                return parsed
            }
            AgentOutput.standardError.writeString("Invalid value. Use a number of experts like 32 or a memory size like 32GB.\n")
        }
    }

    private static func promptOptionalPath(
        _ prompt: String,
        defaultValue: String?
    ) throws -> String? {
        let rawValue = try promptLine(
            title: "DS4 runtime",
            prompt: prompt,
            defaultValue: defaultValue,
            allowEmpty: true,
            help: "Enter an absolute path, or type none to clear this setting."
        )
        guard let value = rawValue.nilIfBlank else {
            return nil
        }
        let normalized = value.lowercased()
        if ["none", "off", "-"].contains(normalized) {
            return nil
        }
        return URL(fileURLWithPath: value).standardizedFileURL.path
    }

    private static func promptDS4RootURL() throws -> URL {
        let defaultValue = defaultDS4RootPath()
        while true {
            let rawValue = try promptLine(
                title: "DS4 runtime",
                prompt: "DS4 checkout directory",
                defaultValue: defaultValue,
                allowEmpty: false,
                help: "Enter the absolute path to the DS4 source/build checkout."
            )
            let url = fileURL(expandingPath: rawValue)
            guard directoryExists(url) else {
                AgentOutput.standardError.writeString("Directory not found: \(url.path)\n")
                continue
            }
            return url
        }
    }

    private static func promptDS4LibraryURL(defaultValue: String) throws -> URL {
        while true {
            let rawValue = try promptLine(
                title: "DS4 runtime",
                prompt: "DS4 runtime library path",
                defaultValue: defaultValue,
                allowEmpty: false,
                help: "Enter the path to libds4.dylib on macOS or libds4.so on Linux."
            )
            let url = fileURL(expandingPath: rawValue)
            guard DS4ModelDiscovery.isFile(url) else {
                AgentOutput.standardError.writeString("File not found: \(url.path)\n")
                continue
            }
            return url
        }
    }

    private static func promptLine(
        title: String,
        prompt: String,
        defaultValue: String?,
        allowEmpty: Bool,
        help: String? = nil
    ) throws -> String {
        guard let value = TerminalCheckboxMenu.promptLine(
            title: title,
            prompt: prompt,
            defaultValue: defaultValue,
            allowEmpty: allowEmpty,
            help: help
        ) else {
            throw DS4SetupError.cancelled
        }
        return value
    }

    private static func parseStreamingCache(_ rawValue: String) -> (experts: UInt32, bytes: UInt64)? {
        let uppercased = rawValue.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        if uppercased == "0" {
            return (0, 0)
        }
        if uppercased.hasSuffix("GB") || uppercased.hasSuffix("GIB") {
            let suffix = uppercased.hasSuffix("GIB") ? "GIB" : "GB"
            let number = String(uppercased.dropLast(suffix.count))
            guard let value = Double(number), value > 0 else {
                return nil
            }
            return (0, UInt64(value * 1_073_741_824.0))
        }
        guard let experts = UInt32(uppercased), experts > 0 else {
            return nil
        }
        return (experts, 0)
    }

    private static func formatStreamingCache(experts: UInt32, bytes: UInt64) -> String? {
        if bytes > 0 {
            let gb = Double(bytes) / 1_073_741_824.0
            return gb.rounded() == gb
                ? "\(Int(gb))GB"
                : String(format: "%.1fGB", gb)
        }
        if experts > 0 {
            return "\(experts)"
        }
        return nil
    }

    private static func formatTokenCount(_ value: Int) -> String {
        if abs(value) >= 1_000 {
            return String(format: "%.1fk", Double(value) / 1_000)
        }
        return "\(value)"
    }

    private static func defaultDS4Backend() -> String {
        #if os(macOS)
        return "metal"
        #else
        return "cpu"
        #endif
    }

    private static func defaultDS4LibraryName() -> String {
        #if os(macOS)
        return "libds4.dylib"
        #else
        return "libds4.so"
        #endif
    }

    private static func defaultDS4RootPath() -> String? {
        let fileManager = FileManager.default
        let home = fileManager.homeDirectoryForCurrentUser
        let current = URL(fileURLWithPath: fileManager.currentDirectoryPath)
        let candidates = [
            home.appendingPathComponent("Projects/ds4"),
            home.appendingPathComponent("projects/ds4"),
            current.appendingPathComponent("ds4"),
            current.deletingLastPathComponent().appendingPathComponent("ds4")
        ]
        return candidates.first(where: { directoryExists($0) })?.path
    }

    private static func registerDS4Runtime(
        ds4Root: URL,
        libraryURL: URL?,
        buildRuntime: Bool
    ) throws -> DS4SettingsManifest {
        if let setupHelperURL = ds4SetupHelperURL() {
            var arguments = [ds4Root.path]
            if !buildRuntime {
                arguments.append("--skip-build")
            }
            if let libraryURL {
                arguments += ["--library", libraryURL.path]
            }
            try runExecutable(setupHelperURL, arguments: arguments)
            return try DS4SettingsStore.loadRequired()
        }

        if buildRuntime {
            try runDS4BuildHelper(ds4Root: ds4Root)
        }

        let resolvedLibraryURL = (libraryURL
            ?? ds4Root.appendingPathComponent(defaultDS4LibraryName()))
            .standardizedFileURL
        guard DS4ModelDiscovery.isFile(resolvedLibraryURL) else {
            throw DS4SetupError.libraryMissing(resolvedLibraryURL)
        }

        let settings = DS4SettingsManifest(
            ds4Root: ds4Root.path,
            libraryPath: resolvedLibraryURL.path
        )
        try DS4SettingsStore.save(settings)
        return settings
    }

    private static func runDS4BuildHelper(ds4Root: URL) throws {
        guard let buildHelperURL = ds4BuildHelperURL() else {
            throw DS4SetupError.buildHelperMissing
        }
        try runExecutable(buildHelperURL, arguments: [ds4Root.path])
    }

    private static func runExecutable(_ executableURL: URL, arguments: [String]) throws {
        AgentOutput.standardError.writeString(
            "Running: \(executableURL.path) \(arguments.joined(separator: " "))\n"
        )
        let process = Process()
        process.executableURL = executableURL
        process.arguments = arguments
        process.environment = ProcessInfo.processInfo.environment
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw DS4SetupError.helperFailed(
                executableURL,
                process.terminationStatus
            )
        }
    }

    private static func ds4SetupHelperURL() -> URL? {
        executableCandidateURLs(
            environmentKey: "ZENCODE_DS4_SETUP_SCRIPT",
            scriptName: "setup-ds4.sh"
        ).first
    }

    private static func ds4BuildHelperURL() -> URL? {
        executableCandidateURLs(
            environmentKey: "ZENCODE_DS4_BUILD_SCRIPT",
            scriptName: "build-ds4-runtime.sh"
        ).first
    }

    private static func executableCandidateURLs(
        environmentKey: String,
        scriptName: String
    ) -> [URL] {
        var candidates: [URL] = []
        let environment = ProcessInfo.processInfo.environment
        if let override = environment[environmentKey]?.nilIfBlank {
            candidates.append(fileURL(expandingPath: override))
        }

        let currentDirectory = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        candidates.append(
            currentDirectory
                .appendingPathComponent("Scripts")
                .appendingPathComponent(scriptName)
        )

        if let executableDirectory = Bundle.main.executableURL?
            .resolvingSymlinksInPath()
            .deletingLastPathComponent() {
            candidates.append(
                executableDirectory
                    .appendingPathComponent("Scripts")
                    .appendingPathComponent(scriptName)
            )
        }

        var seen = Set<String>()
        return candidates
            .map { $0.standardizedFileURL }
            .filter { seen.insert($0.path).inserted }
            .filter { FileManager.default.isExecutableFile(atPath: $0.path) }
    }

    private static func fileURL(expandingPath path: String) -> URL {
        URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
            .standardizedFileURL
    }

    private static func printDS4RuntimeInstallHelp() {
        AgentOutput.standardError.writeString(
            """
            DS4 runtime is not installed yet.

            Open Local inference, then DS4 runtime, and enter the DS4 checkout
            directory to register the runtime.

            """
        )
    }

    private static func promptDS4ModelURL(
        ds4Root: URL,
        currentModelPath: String?
    ) throws -> URL {
        let candidates = DS4ModelDiscovery.ggufModelCandidates(in: ds4Root)
        var items = candidates.map { candidate in
            TerminalCheckboxMenuItem(
                value: DS4ModelChoice.candidate(candidate.path),
                title: modelDisplayName(candidate, ds4Root: ds4Root),
                detail: candidate.path
            )
        }
        items.append(
            TerminalCheckboxMenuItem(
                value: .manual,
                title: "Enter model path",
                detail: "choose a GGUF file outside the detected list"
            )
        )

        let selectedChoice: DS4ModelChoice
        if let currentModelPath,
           candidates.contains(where: { $0.path == currentModelPath }) {
            selectedChoice = .candidate(currentModelPath)
        } else if let first = candidates.first {
            selectedChoice = .candidate(first.path)
        } else {
            selectedChoice = .manual
        }

        guard let choice = TerminalCheckboxMenu.selectOne(
            title: "DS4 model",
            items: items,
            selected: selectedChoice
        ) else {
            throw DS4SetupError.cancelled
        }

        switch choice {
        case .candidate(let path):
            return URL(fileURLWithPath: path).standardizedFileURL
        case .manual:
            return try promptManualDS4ModelURL(defaultValue: currentModelPath)
        }
    }

    private static func promptManualDS4ModelURL(defaultValue: String?) throws -> URL {
        while true {
            guard let rawValue = TerminalCheckboxMenu.promptLine(
                title: "DS4 model",
                prompt: "GGUF model path",
                defaultValue: defaultValue,
                allowEmpty: false,
                help: "Enter the absolute path to a local DS4 GGUF model file."
            )?.nilIfBlank else {
                throw DS4SetupError.cancelled
            }

            let url = URL(fileURLWithPath: rawValue).standardizedFileURL
            guard url.pathExtension.lowercased() == "gguf",
                  DS4ModelDiscovery.isFile(url) else {
                AgentOutput.standardError.writeString("Enter an existing .gguf file path.\n")
                continue
            }
            return url
        }
    }

    private static func modelDisplayName(_ url: URL, ds4Root: URL) -> String {
        let rootPath = ds4Root.standardizedFileURL.path
        let path = url.standardizedFileURL.path
        if path.hasPrefix(rootPath + "/") {
            return String(path.dropFirst(rootPath.count + 1))
        }
        return url.lastPathComponent
    }

    private static func directoryExists(_ url: URL) -> Bool {
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory)
            && isDirectory.boolValue
    }
}

private enum DS4SetupError: LocalizedError {
    case cancelled
    case buildHelperMissing
    case helperFailed(URL, Int32)
    case libraryMissing(URL)

    var errorDescription: String? {
        switch self {
        case .cancelled:
            return "DS4 setup was cancelled."
        case .buildHelperMissing:
            return "DS4 build helper not found. Install from a full package or enter an existing DS4 runtime library path."
        case .helperFailed(let url, let status):
            return "DS4 helper failed with exit code \(status): \(url.path)"
        case .libraryMissing(let url):
            return "DS4 runtime library not found: \(url.path)"
        }
    }
}
