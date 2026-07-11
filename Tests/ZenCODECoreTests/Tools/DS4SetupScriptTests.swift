//
//  DS4SetupScriptTests.swift
//  ZenCODE
//

import Foundation
import Testing

@Suite
struct DS4SetupScriptTests {
    @Test
    func installerBuildsDS4RuntimeWithoutWritingConfiguration() throws {
        let packageRoot = try RepositoryTestSupport.packageRoot(containing: #filePath)
        let installScript = try String(
            contentsOf: packageRoot.appendingPathComponent("Scripts/install.sh"),
            encoding: .utf8
        )

        #expect(installScript.contains("CONFIG_RELATIVE_PATHS=("))
        #expect(installScript.contains("\"agents.json\""))
        #expect(installScript.contains("backup_existing_config_files"))
        #expect(installScript.contains("trap restore_config_files EXIT"))
        #expect(installScript.contains("Preserved existing configuration"))
        #expect(!installScript.contains("${SCRIPT_DIR}/setup-ds4.sh"))
        #expect(installScript.contains("${SCRIPT_DIR}/build-ds4-runtime.sh"))
        #expect(installScript.contains("configuration files were left unchanged"))

        let setupScript = try String(
            contentsOf: packageRoot.appendingPathComponent("Scripts/setup-ds4.sh"),
            encoding: .utf8
        )
        #expect(setupScript.contains("cleanup_tmp_file()"))
        #expect(setupScript.contains("rm -f -- \"$tmp_file\""))
        #expect(setupScript.contains("trap cleanup_tmp_file EXIT"))
    }

    @Test
    func setupScriptPreservesExistingRuntimeAndModelSettings() throws {
        let fileManager = FileManager.default
        let packageRoot = try RepositoryTestSupport.packageRoot(containing: #filePath)
        let runID = UUID().uuidString
        let rootURL = fileManager.temporaryDirectory
            .appendingPathComponent("zencode-ds4-setup-\(runID)", isDirectory: true)
        defer {
            try? fileManager.removeItem(at: rootURL)
        }

        let ds4Root = rootURL.appendingPathComponent("ds4", isDirectory: true)
        let supportDir = rootURL.appendingPathComponent("support", isDirectory: true)
        let settingsDir = supportDir.appendingPathComponent("ds4", isDirectory: true)
        let modelURL = ds4Root
            .appendingPathComponent("models", isDirectory: true)
            .appendingPathComponent("configured.gguf")
        let libraryURL = ds4Root.appendingPathComponent("custom-libds4.dylib")
        let settingsURL = settingsDir.appendingPathComponent("settings.json")

        try fileManager.createDirectory(
            at: modelURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try fileManager.createDirectory(
            at: settingsDir,
            withIntermediateDirectories: true
        )
        fileManager.createFile(atPath: modelURL.path, contents: Data())
        fileManager.createFile(atPath: libraryURL.path, contents: Data())

        let existingSettings = """
        {
          "backend" : "metal",
          "contextWindow" : 131072,
          "ds4Root" : "/old/ds4",
          "libraryPath" : "/old/ds4/libds4.dylib",
          "modelPath" : "\(modelURL.path)",
          "ssdStreaming" : true,
          "ssdStreamingCacheBytes" : 34359738368,
          "topK" : 0,
          "version" : 1
        }
        """
        try existingSettings.write(to: settingsURL, atomically: true, encoding: .utf8)

        let result = try ProcessCapture.run(
            executableURL: URL(fileURLWithPath: "/usr/bin/env"),
            arguments: [
                "bash",
                packageRoot.appendingPathComponent("Scripts/setup-ds4.sh").path,
                ds4Root.path,
                "--skip-build",
                "--library",
                libraryURL.path,
                "--support-dir",
                supportDir.path
            ],
            workingDirectory: packageRoot
        )

        #expect(
            result.exitCode == 0,
            """
            setup-ds4.sh failed with exit code \(result.exitCode)

            stdout:
            \(result.stdout)

            stderr:
            \(result.stderr)
            """
        )

        let data = try Data(contentsOf: settingsURL)
        let settings = try #require(
            JSONSerialization.jsonObject(with: data) as? [String: Any]
        )
        let resolvedDS4Root = try ProcessCapture.run(
            executableURL: URL(fileURLWithPath: "/bin/sh"),
            arguments: ["-c", "cd \"$1\" && pwd -P", "sh", ds4Root.path],
            workingDirectory: packageRoot
        )
        .stdout
        .trimmingCharacters(in: .whitespacesAndNewlines)
        let resolvedLibraryPath = "\(resolvedDS4Root)/\(libraryURL.lastPathComponent)"

        #expect(settings["ds4Root"] as? String == resolvedDS4Root)
        #expect(settings["libraryPath"] as? String == resolvedLibraryPath)
        #expect(settings["modelPath"] as? String == modelURL.path)
        #expect(settings["backend"] as? String == "metal")
        #expect((settings["contextWindow"] as? NSNumber)?.intValue == 131072)
        #expect(settings["ssdStreaming"] as? Bool == true)
        #expect((settings["ssdStreamingCacheBytes"] as? NSNumber)?.uint64Value == 34_359_738_368)
        #expect((settings["topK"] as? NSNumber)?.intValue == 0)
    }
}

private enum ProcessCapture {
    static func run(
        executableURL: URL,
        arguments: [String],
        workingDirectory: URL
    ) throws -> (exitCode: Int32, stdout: String, stderr: String) {
        let process = Process()
        let stdout = Pipe()
        let stderr = Pipe()

        process.executableURL = executableURL
        process.arguments = arguments
        process.currentDirectoryURL = workingDirectory
        process.standardOutput = stdout
        process.standardError = stderr

        try process.run()
        process.waitUntilExit()

        let stdoutData = stdout.fileHandleForReading.readDataToEndOfFile()
        let stderrData = stderr.fileHandleForReading.readDataToEndOfFile()

        return (
            process.terminationStatus,
            String(data: stdoutData, encoding: .utf8) ?? "",
            String(data: stderrData, encoding: .utf8) ?? ""
        )
    }
}
