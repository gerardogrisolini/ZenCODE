//
//  MLXMetalLibraryBootstrap.swift
//  ZenCODE
//
//  Created by Gerardo Grisolini on 25/05/26.
//

import Foundation
#if os(macOS)
import Darwin
#endif

enum MLXMetalLibraryBootstrap {
    static func prepareIfNeeded() throws {
        #if os(macOS)
        setenv("MLX_METAL_FAST_SYNCH", "1", 0)

        let executableDirectory = try executableDirectory()
        let outputURL = executableDirectory.appendingPathComponent("mlx.metallib")
        let manifestURL = executableDirectory.appendingPathComponent("mlx.metallib.manifest.json")
        guard let source = try? findMetalKernelSource() else {
            if FileManager.default.fileExists(atPath: outputURL.path) {
                return
            }
            throw MLXMetalLibraryBootstrapError.missingMetalKernelDirectory
        }
        let manifest = try MLXMetalLibraryManifest(sourceFiles: source.metalFiles)

        if FileManager.default.fileExists(atPath: outputURL.path) {
            if (try? MLXMetalLibraryManifest.load(from: manifestURL)) == manifest {
                return
            }
            if !FileManager.default.fileExists(atPath: manifestURL.path),
               try isExistingLibraryFresh(outputURL: outputURL, sourceFiles: source.metalFiles) {
                try manifest.save(to: manifestURL)
                return
            }
        }

        writeStatus("ZenCODE preparing Metal kernels...\n")
        try compileMetalKernels(from: source, to: outputURL)
        try manifest.save(to: manifestURL)
        writeStatus("ZenCODE prepared Metal kernels.\n")
        #endif
    }

    #if os(macOS)
    private struct MLXMetalKernelSource {
        var sourceRootURL: URL
        var kernelsURL: URL
        var metalFiles: [URL]
    }

    private struct MLXMetalLibraryManifest: Codable, Equatable {
        struct SourceFile: Codable, Equatable {
            var path: String
            var byteCount: UInt64
            var modificationTime: TimeInterval
        }

        var version: Int
        var sourceFiles: [SourceFile]

        init(sourceFiles: [URL]) throws {
            self.version = 1
            self.sourceFiles = try sourceFiles.map { url in
                let values = try url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
                return SourceFile(
                    path: url.path,
                    byteCount: UInt64(values.fileSize ?? 0),
                    modificationTime: values.contentModificationDate?.timeIntervalSince1970 ?? 0
                )
            }
        }

        static func load(from url: URL) throws -> Self {
            let data = try Data(contentsOf: url)
            return try JSONDecoder().decode(Self.self, from: data)
        }

        func save(to url: URL) throws {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
            try encoder.encode(self).write(to: url, options: .atomic)
        }
    }

    private static func executableDirectory() throws -> URL {
        var size: UInt32 = 0
        _NSGetExecutablePath(nil, &size)
        let buffer = UnsafeMutablePointer<CChar>.allocate(capacity: Int(size))
        defer {
            buffer.deallocate()
        }

        guard _NSGetExecutablePath(buffer, &size) == 0 else {
            throw MLXMetalLibraryBootstrapError.missingExecutableURL
        }

        return URL(fileURLWithPath: String(cString: buffer))
            .resolvingSymlinksInPath()
            .deletingLastPathComponent()
    }

    private static func findMetalKernelSource() throws -> MLXMetalKernelSource {
        let fileManager = FileManager.default
        let currentDirectory = URL(fileURLWithPath: fileManager.currentDirectoryPath)
        let executableDirectory = try executableDirectory()

        let executableRoots = ancestorURLs(startingAt: executableDirectory)
        let roots = executableDirectory.pathComponents.contains(".build")
            ? ancestorURLs(startingAt: currentDirectory) + executableRoots
            : executableRoots

        for root in roots {
            let sourceRootURL = root
                .appendingPathComponent(".build/checkouts/mlx-swift/Source/Cmlx/mlx", isDirectory: true)
            let kernelsURL = sourceRootURL
                .appendingPathComponent("mlx/backend/metal/kernels", isDirectory: true)
            if fileManager.fileExists(atPath: kernelsURL.path) {
                return MLXMetalKernelSource(
                    sourceRootURL: sourceRootURL,
                    kernelsURL: kernelsURL,
                    metalFiles: try metalFiles(in: kernelsURL)
                )
            }
        }

        throw MLXMetalLibraryBootstrapError.missingMetalKernelDirectory
    }

    private static func metalFiles(in kernelsURL: URL) throws -> [URL] {
        guard let enumerator = FileManager.default.enumerator(
            at: kernelsURL,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }

        var files: [URL] = []
        while let url = enumerator.nextObject() as? URL {
            guard url.pathExtension == "metal",
                  (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true else {
                continue
            }
            files.append(url)
        }
        return files.sorted { $0.path < $1.path }
    }

    private static func isExistingLibraryFresh(
        outputURL: URL,
        sourceFiles: [URL]
    ) throws -> Bool {
        let outputValues = try outputURL.resourceValues(
            forKeys: [.fileSizeKey, .contentModificationDateKey]
        )
        guard (outputValues.fileSize ?? 0) > 0,
              let outputModificationDate = outputValues.contentModificationDate else {
            return false
        }

        for sourceFile in sourceFiles {
            let sourceValues = try sourceFile.resourceValues(forKeys: [.contentModificationDateKey])
            guard let sourceModificationDate = sourceValues.contentModificationDate,
                  sourceModificationDate <= outputModificationDate else {
                return false
            }
        }
        return true
    }

    private static func ancestorURLs(startingAt url: URL) -> [URL] {
        var result: [URL] = []
        var current = url.standardizedFileURL

        while true {
            result.append(current)
            let parent = current.deletingLastPathComponent()
            if parent.path == current.path {
                return result
            }
            current = parent
        }
    }

    private static func compileMetalKernels(from source: MLXMetalKernelSource, to outputURL: URL) throws {
        let fileManager = FileManager.default
        let temporaryDirectory = fileManager.temporaryDirectory
            .appendingPathComponent("ZenCODE-metal-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true)
        defer {
            try? fileManager.removeItem(at: temporaryDirectory)
        }

        guard !source.metalFiles.isEmpty else {
            throw MLXMetalLibraryBootstrapError.noMetalSources(source.kernelsURL.path)
        }

        var airFiles: [URL] = []
        for (index, metalFile) in source.metalFiles.enumerated() {
            let airFile = temporaryDirectory
                .appendingPathComponent("\(index)-\(metalFile.deletingPathExtension().lastPathComponent)")
                .appendingPathExtension("air")
            try runXcrun([
                "-sdk", "macosx",
                "metal",
                "-x", "metal",
                "-Wall",
                "-Wextra",
                "-fno-fast-math",
                "-Wno-c++17-extensions",
                "-Wno-c++20-extensions",
                "-c", metalFile.path,
                "-I", source.kernelsURL.path,
                "-I", source.sourceRootURL.path,
                "-o", airFile.path
            ])
            airFiles.append(airFile)
        }

        try runXcrun([
            "-sdk", "macosx",
            "metallib"
        ] + airFiles.map(\.path) + [
            "-o", outputURL.path
        ])
    }

    private static func runXcrun(_ arguments: [String]) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
        process.arguments = arguments

        let outputURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("ZenCODE-xcrun-\(UUID().uuidString).log")
        FileManager.default.createFile(atPath: outputURL.path, contents: nil)
        let outputHandle = try FileHandle(forWritingTo: outputURL)
        defer {
            try? outputHandle.close()
            try? FileManager.default.removeItem(at: outputURL)
        }

        process.standardError = outputHandle
        process.standardOutput = outputHandle

        try process.run()
        process.waitUntilExit()

        guard process.terminationStatus == 0 else {
            try? outputHandle.synchronize()
            let output = try? String(contentsOf: outputURL, encoding: .utf8)
            throw MLXMetalLibraryBootstrapError.xcrunFailed(arguments.joined(separator: " "), output ?? "")
        }
    }

    private static func writeStatus(_ message: String) {
        try? FileHandle.standardError.write(contentsOf: Data(message.utf8))
    }
    #endif
}

enum MLXMetalLibraryBootstrapError: LocalizedError {
    case missingExecutableURL
    case missingMetalKernelDirectory
    case noMetalSources(String)
    case xcrunFailed(String, String)

    var errorDescription: String? {
        switch self {
        case .missingExecutableURL:
            "Unable to resolve ZenCODE executable path."
        case .missingMetalKernelDirectory:
            "Unable to find mlx-swift Metal kernels under .build/checkouts."
        case .noMetalSources(let path):
            "No Metal source files found in \(path)."
        case .xcrunFailed(let command, let output):
            "xcrun failed while running \(command): \(output)"
        }
    }
}
