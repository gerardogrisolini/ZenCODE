import FeatureKit
import Foundation
import ToolCore

/// Runs fixed JavaScript-for-Automation scripts through `osascript`. Scripts
/// are static program text owned by this feature; caller data only travels as
/// a JSON object literal (`PARAMS`), so no caller-supplied code is ever
/// evaluated. The whole program is written to stdin: command-line arguments
/// are visible to every local user through `ps` and are capped by `ARG_MAX`,
/// which message bodies and note contents could exceed.
enum JXARunner {
    static let defaultTimeout: TimeInterval = 150
    private static let osascriptURL = URL(fileURLWithPath: "/usr/bin/osascript")

    /// Helpers shared by every script. `main(p)` is provided by each script.
    static let prelude = #"""
    function iso(d) { return (d instanceof Date && !isNaN(d.getTime())) ? d.toISOString() : null; }
    function str(v) { return (v === null || v === undefined) ? null : String(v); }
    function num(v) { const n = Number(v); return Number.isFinite(n) ? n : null; }
    function lower(s) { return (s === null || s === undefined) ? "" : String(s).toLowerCase(); }
    function contains(haystack, needle) { return lower(haystack).indexOf(lower(needle)) !== -1; }
    function safe(fn, fallback) { try { const v = fn(); return (v === undefined) ? fallback : v; } catch (e) { return fallback; } }
    function safeArray(fn) { const v = safe(fn, []); return Array.isArray(v) ? v : []; }
    function clampLimit(value, fallback, max) { let n = parseInt(value, 10); if (!Number.isFinite(n) || n <= 0) { n = fallback; } return Math.min(n, max); }
    function date(value) { if (!value) { return null; } const d = new Date(value); return isNaN(d.getTime()) ? null : d; }
    function fail(message) { throw new Error(message); }
    function run() {
      const result = main(PARAMS || {});
      return JSON.stringify(result === undefined ? {} : result);
    }
    """#

    /// Assembles the program text: the parameters as a JSON literal, the
    /// shared prelude, and the script. JSON is a syntactic subset of a
    /// JavaScript expression; U+2028/U+2029, which JSON leaves raw, are
    /// escaped as well so the literal stays valid for every parser.
    static func program(_ script: String, parameters: [String: JSONValue]) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let parameterJSON = String(decoding: try encoder.encode(parameters), as: UTF8.self)
            .replacingOccurrences(of: "\u{2028}", with: "\\u2028")
            .replacingOccurrences(of: "\u{2029}", with: "\\u2029")
        return "const PARAMS = " + parameterJSON + ";\n" + prelude + "\n" + script + "\n"
    }

    static func run<Result: Decodable>(
        _ script: String,
        parameters: [String: JSONValue],
        as type: Result.Type,
        timeout: TimeInterval = defaultTimeout
    ) async throws -> Result {
        let data = try await execute(script, parameters: parameters, timeout: timeout)
        do {
            return try JSONDecoder().decode(type, from: data)
        } catch {
            let preview = String(decoding: data.prefix(400), as: UTF8.self)
            throw MacOSControlError.scriptFailed(
                "Unexpected automation result (\(error.localizedDescription)): \(preview)"
            )
        }
    }

    private static func execute(
        _ script: String,
        parameters: [String: JSONValue],
        timeout: TimeInterval
    ) async throws -> Data {
        let program = try program(script, parameters: parameters)

        let result: FeatureProcessResult
        do {
            result = try await FeatureProcessRunner.run(
                executableURL: osascriptURL,
                arguments: ["-l", "JavaScript", "-"],
                stdinData: Data(program.utf8),
                timeout: timeout,
                maximumOutputBytesPerStream: 32 * 1_024 * 1_024
            )
        } catch {
            throw MacOSControlError.scriptFailed("Could not launch osascript: \(error.localizedDescription)")
        }
        guard !result.timedOut else {
            throw MacOSControlError.scriptFailed(
                "The automation request did not finish within \(Int(timeout)) seconds. The app may be showing a consent dialog or processing a very large library; narrow the request and retry."
            )
        }
        guard !result.stdoutWasTruncated else {
            throw MacOSControlError.scriptFailed("The automation result exceeded the output limit; lower limit or max_chars.")
        }
        let stderr = String(decoding: result.stderrData, as: UTF8.self)
        guard result.exitCode == 0 else {
            throw MacOSControlError.scriptFailed(describeFailure(stderr, exitCode: result.exitCode))
        }
        return result.stdoutData
    }

    private static func describeFailure(_ stderr: String, exitCode: Int32) -> String {
        var message = stderr.trimmingCharacters(in: .whitespacesAndNewlines)
        if let range = message.range(of: "execution error: ") {
            message = String(message[range.upperBound...])
        }
        while message.hasPrefix("Error: ") {
            message = String(message.dropFirst("Error: ".count))
        }
        // -2700 is the generic "script error" code carried by our own fail() calls.
        if message.hasSuffix(" (-2700)") {
            message = String(message.dropLast(" (-2700)".count))
        }
        if message.isEmpty {
            message = "osascript exited with code \(exitCode)."
        }
        let lowered = message.lowercased()
        if message.contains("-1743") || lowered.contains("not authorized") || lowered.contains("non è autorizzat") {
            message += " macOS denied Automation access: allow the application hosting ZenCODE to control this app in System Settings > Privacy & Security > Automation."
        } else if message.contains("-600") || message.contains("-10810") {
            message += " The target app could not be launched."
        } else if message.contains("-1712") {
            message += " The app did not answer before the Apple event timed out; narrow the request and retry."
        }
        return message
    }
}
