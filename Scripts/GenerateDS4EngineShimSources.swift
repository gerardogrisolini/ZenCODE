import Foundation

/// Embeds the canonical DS4 engine shim sources and the engine build script in a
/// generated Swift file, so the installed `zen` binary can extract and run them
/// without any resource bundle (the installers copy only the `zen` executable).
///
/// Run from the repository root:
///
///     swiftc Scripts/GenerateDS4EngineShimSources.swift -o /tmp/gen-ds4
///     /tmp/gen-ds4            # regenerate
///     /tmp/gen-ds4 --check    # fail when the generated file is stale
enum GenerateDS4EngineShimSources {
    struct Source {
        /// Name of the file once extracted on the user's machine.
        let fileName: String
        /// Name of the `static let` holding the content in the generated enum.
        let propertyName: String
        /// Canonical file, relative to the repository root.
        let relativePath: String
        let summary: String
    }

    static let sources: [Source] = [
        Source(
            fileName: "zencode_ds4_abi.h",
            propertyName: "abiHeader",
            relativePath: "Sources/ZenCODECore/Resources/DS4Engine/zencode_ds4_abi.h",
            summary: "C ABI header of the DS4 engine shim."
        ),
        Source(
            fileName: "zencode_ds4_shim.c",
            propertyName: "shimSource",
            relativePath: "Sources/ZenCODECore/Resources/DS4Engine/zencode_ds4_shim.c",
            summary: "C source of the DS4 engine shim."
        ),
        Source(
            fileName: "build-ds4-engine.sh",
            propertyName: "buildScript",
            relativePath: "Scripts/build-ds4-engine.sh",
            summary: "Script that builds libzencode-ds4 from the shim and a DS4 checkout."
        )
    ]

    static let outputRelativePath = "Sources/ZenCODECore/Local/DS4/Engine/DS4EngineShimSources.generated.swift"

    static func run() throws {
        let check = CommandLine.arguments.dropFirst() == ["--check"]
        guard check || CommandLine.arguments.count == 1 else {
            throw GeneratorError("usage: GenerateDS4EngineShimSources [--check]")
        }
        let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)

        var contents: [(source: Source, text: String)] = []
        for source in sources {
            let url = root.appendingPathComponent(source.relativePath)
            guard let data = try? Data(contentsOf: url) else {
                throw GeneratorError("missing canonical file: \(url.path) (run from the repository root)")
            }
            contents.append((source, try validatedText(data, path: source.relativePath)))
        }

        let outputURL = root.appendingPathComponent(outputRelativePath)
        try writeOrCheck(Data(renderSwift(contents).utf8), at: outputURL, check: check)
        print(check
            ? "DS4 engine shim sources are embedded and current."
            : "Generated DS4 engine shim sources (\(contents.count) files).")
    }

    /// The embedded literal must reproduce the file byte for byte. Swift
    /// normalizes line endings in multi-line literals and cannot hold NUL, so
    /// such content is rejected instead of silently altered.
    static func validatedText(_ data: Data, path: String) throws -> String {
        guard let text = String(data: data, encoding: .utf8), Data(text.utf8) == data else {
            throw GeneratorError("\(path) is not valid UTF-8")
        }
        guard !data.contains(0x0D) else {
            throw GeneratorError("\(path) contains a carriage return; use LF line endings")
        }
        guard !data.contains(0x00) else {
            throw GeneratorError("\(path) contains a NUL byte")
        }
        return text
    }

    /// Smallest number of `#` that makes a raw multi-line literal unable to end
    /// early or to start an escape: one more than the longest run of `#` that
    /// directly follows a `"` (possible closing delimiter) or a `\` (possible
    /// escape or interpolation) anywhere in the content.
    static func rawDelimiterHashCount(for text: String) -> Int {
        var longestRun = 0
        var previous: Character?
        var run = 0
        for character in text {
            if character == "#" {
                if run > 0 || previous == "\"" || previous == "\\" {
                    run += 1
                    longestRun = max(longestRun, run)
                }
            } else {
                run = 0
            }
            previous = character
        }
        return longestRun + 1
    }

    /// Renders `text` as a raw multi-line string literal whose value is exactly
    /// `text`: the newline after the opening delimiter and the one before the
    /// closing delimiter are not part of the value, and the closing delimiter
    /// sits in column 0 so no indentation is stripped.
    static func rawLiteral(_ text: String) -> String {
        let hashes = String(repeating: "#", count: rawDelimiterHashCount(for: text))
        return "\(hashes)\"\"\"\n\(text)\n\"\"\"\(hashes)"
    }

    static func renderSwift(_ contents: [(source: Source, text: String)]) -> String {
        var output = """
        //
        //  DS4EngineShimSources.generated.swift
        //  Generated by Scripts/GenerateDS4EngineShimSources.swift. Do not edit by hand.
        //
        //  Exact contents of the canonical DS4 engine shim sources and of the engine
        //  build script, embedded so the installed `zen` binary does not depend on a
        //  resource bundle. `DS4EngineShimSourcesParityTests` compares them with the
        //  files in the repository.
        //

        enum DS4EngineShimSources {
            /// A file extracted into `<support>/ds4/shim/` before building the engine.
            struct File: Sendable, Equatable {
                let name: String
                let contents: String
            }

        """
        for (source, text) in contents {
            output += "\n"
            output += "    static let \(source.propertyName)FileName = \(literal(source.fileName))\n"
            output += "\n"
            output += "    /// \(source.summary)\n"
            output += "    static let \(source.propertyName) = \(rawLiteral(text))\n"
        }
        let fileEntries = contents.map { entry in
            "        File(name: \(entry.source.propertyName)FileName, contents: \(entry.source.propertyName))"
        }.joined(separator: ",\n")
        output += """

            /// Every embedded file, in extraction order.
            static let files: [File] = [
        \(fileEntries)
            ]
        }

        """
        return output
    }

    static func literal(_ value: String) -> String {
        "\"" + value.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }

    static func writeOrCheck(_ data: Data, at url: URL, check: Bool) throws {
        if check {
            guard (try? Data(contentsOf: url)) == data else {
                throw GeneratorError("generated file is stale: \(url.path); run swiftc Scripts/GenerateDS4EngineShimSources.swift -o /tmp/gen-ds4 && /tmp/gen-ds4")
            }
        } else {
            try data.write(to: url, options: .atomic)
        }
    }

    struct GeneratorError: LocalizedError {
        let message: String
        init(_ message: String) { self.message = message }
        var errorDescription: String? { message }
    }
}

do {
    try GenerateDS4EngineShimSources.run()
} catch {
    fatalError(error.localizedDescription)
}
