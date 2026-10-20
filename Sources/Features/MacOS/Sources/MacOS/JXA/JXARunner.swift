import FeatureKit
import Foundation
import ToolCore

/// Runs fixed JavaScript-for-Automation scripts through `osascript`. Scripts
/// are static program text owned by this feature; caller data only travels as
/// a JSON argument, so no caller-supplied code is ever evaluated.
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
    function run(argv) {
      const params = JSON.parse(argv.length > 0 ? argv[0] : "{}");
      const result = main(params || {});
      return JSON.stringify(result === undefined ? {} : result);
    }
    """#

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
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let parameterJSON = String(decoding: try encoder.encode(parameters), as: UTF8.self)
        let program = prelude + "\n" + script + "\n"

        let result: FeatureProcessResult
        do {
            result = try await FeatureProcessRunner.run(
                executableURL: osascriptURL,
                arguments: ["-l", "JavaScript", "-", parameterJSON],
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
        }
        return message
    }
}
