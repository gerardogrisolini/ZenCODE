import FeatureKit
import Foundation
import Testing
import ToolCore

@testable import MacOS

enum FeatureContextStub {
    static func make() -> FeatureContext {
        FeatureContext(
            workingDirectory: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString),
            environment: [:]
        )
    }
}

@Suite
struct JXARunnerTests {
    private struct Echo: Decodable, Equatable {
        let text: String
        let count: Int
        let flag: Bool
        let items: [String]
        let missing: String?
    }

    private static let echoScript = #"""
    function main(p) {
      return {text: str(p.text), count: p.items.length, flag: !!p.flag, items: p.items, missing: str(p.missing)};
    }
    """#

    @Test
    func embedsParametersAsAJSONLiteralWithoutInterpolatingThem() throws {
        let hostile = "x\u{2028}y\u{2029}</script>\"; fail('pwned'); //\\ é 😀 \n\t"
        let program = try JXARunner.program(Self.echoScript, parameters: ["text": .string(hostile), "n": .number(2)])
        #expect(program.hasPrefix("const PARAMS = {"))
        #expect(!program.contains("\u{2028}"))
        #expect(!program.contains("\u{2029}"))
        #expect(program.contains("\\u2028"))
        #expect(program.contains("\\u2029"))
        // The raw payload never appears unescaped in the program text.
        #expect(!program.contains("</script>\"; fail"))
        #expect(program.contains("function main(p)"))
        #expect(program.contains("function run()"))

        // The literal round-trips as plain JavaScript.
        let literal = program
            .components(separatedBy: "\n")[0]
            .dropFirst("const PARAMS = ".count)
            .dropLast()
        let decoded = try JSONDecoder().decode([String: JSONValue].self, from: Data(literal.utf8))
        #expect(decoded["text"] == .string(hostile))
        #expect(decoded["n"] == .number(2))
    }

    /// Runs a parameter-only script through the real `osascript`, which
    /// involves no application and needs no consent.
    @Test
    func roundTripsHostileParametersThroughOSAScript() async throws {
        let hostile = "a\u{2028}b</script>\"; fail('pwned'); //\\ é 😀 \"quoted\" \n\tend"
        let result = try await JXARunner.run(
            Self.echoScript,
            parameters: [
                "text": .string(hostile),
                "items": .array([.string("one"), .string("two")]),
                "flag": .bool(true),
                "missing": .null,
            ],
            as: Echo.self,
            timeout: 60
        )
        #expect(result == Echo(text: hostile, count: 2, flag: true, items: ["one", "two"], missing: nil))
    }

    @Test
    func surfacesScriptFailuresWithoutTheOSAScriptNoise() async throws {
        let script = #"function main(p) { fail("Nothing matches '" + p.needle + "'."); }"#
        await #expect(throws: MacOSControlError.self) {
            _ = try await JXARunner.run(script, parameters: ["needle": .string("x")], as: Echo.self, timeout: 60)
        }
        do {
            _ = try await JXARunner.run(script, parameters: ["needle": .string("x")], as: Echo.self, timeout: 60)
        } catch let error as MacOSControlError {
            guard case .scriptFailed(let message) = error else {
                Issue.record("unexpected error \(error)")
                return
            }
            #expect(message == "Nothing matches 'x'.")
        }
    }

    @Test
    func reportsUndecodableResults() async throws {
        let script = #"function main(p) { return {text: 1}; }"#
        do {
            _ = try await JXARunner.run(script, parameters: [:], as: Echo.self, timeout: 60)
            Issue.record("expected an error")
        } catch let error as MacOSControlError {
            guard case .scriptFailed(let message) = error else {
                Issue.record("unexpected error \(error)")
                return
            }
            #expect(message.contains("Unexpected automation result"))
        }
    }

    @Test
    func enforcesTheTimeout() async throws {
        let script = #"function main(p) { const end = Date.now() + 60000; while (Date.now() < end) {} return {}; }"#
        let started = Date()
        do {
            _ = try await JXARunner.run(script, parameters: [:], as: Echo.self, timeout: 1)
            Issue.record("expected a timeout")
        } catch let error as MacOSControlError {
            guard case .scriptFailed(let message) = error else {
                Issue.record("unexpected error \(error)")
                return
            }
            #expect(message.contains("did not finish within 1 seconds"))
        }
        #expect(Date().timeIntervalSince(started) < 30)
    }
}
