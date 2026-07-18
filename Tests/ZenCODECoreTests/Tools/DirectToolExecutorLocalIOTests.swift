//
//  DirectToolExecutorLocalIOTests.swift
//  ZenCODE
//
//  Created by Gerardo Grisolini on 29/05/26.
//

import Foundation
@testable import ZenCODECore
import FeatureKit
import LocalToolsSupport
import Testing

@Suite
struct DirectToolExecutorLocalIOTests {
    @Test
    func baseCatalogKeepsCoreLocalAndTextToolsOnly() {
        let baseToolNames = Set(DirectToolCatalog.baseDescriptors.map(\.name))
        let selectableToolNames = Set(AgentToolSelection.selectableDescriptors().map(\.name))

        #expect(baseToolNames.contains("local.exec"))
        #expect(baseToolNames.contains("local.readFile"))
        #expect(baseToolNames.contains("local.inspectFile"))
        #expect(baseToolNames.contains("local.writeFile"))
        #expect(baseToolNames.contains("text.wc"))
        #expect(baseToolNames.contains("feature.list"))
        #expect(baseToolNames.contains("feature.enable"))
        #expect(baseToolNames.contains("feature.delete"))
        #expect(!baseToolNames.contains("search.glob"))
        #expect(!baseToolNames.contains("search.locate"))
        #expect(!baseToolNames.contains("web.search"))
        #expect(!baseToolNames.contains("git.status"))

        #expect(selectableToolNames.contains("local.readFile"))
        #expect(selectableToolNames.contains("local.inspectFile"))
        #expect(selectableToolNames.contains("local.writeFile"))
        #expect(selectableToolNames.contains("search.glob"))
        #expect(selectableToolNames.contains("search.locate"))
        #expect(selectableToolNames.contains("text.wc"))
        #expect(selectableToolNames.contains("web.search"))
        #expect(selectableToolNames.contains("git.status"))
        #expect(selectableToolNames.contains("git.push"))
    }

    @Test
    func localExecAuthorizationCommandsSplitShellPipelines() {
        // `printf`/`echo` are decorative and filtered; use real executables.
        #expect(
            DirectToolExecutor.localExecAuthorizationCommands(
                in: "cat one | grep one|sort"
            ) == ["cat one", "grep one", "sort"]
        )
        #expect(
            DirectToolExecutor.localExecAuthorizationCommands(
                in: "producer |& consumer"
            ) == ["producer", "consumer"]
        )
        #expect(
            DirectToolExecutor.localExecAuthorizationCommands(
                in: "primary || fallback"
            ) == ["primary", "fallback"]
        )
    }

    @Test
    func localExecAuthorizationCommandsPreserveQuotedAndEscapedPipes() {
        // Use `cat` instead of `printf` (printf is now decorative).
        // Quotes are stripped from the cleaned invocation but the pipe inside
        // quotes does not split the segment.
        #expect(
            DirectToolExecutor.localExecAuthorizationCommands(
                in: "cat 'a|b' | grep a"
            ) == ["cat a|b", "grep a"]
        )
        #expect(
            DirectToolExecutor.localExecAuthorizationCommands(
                in: "cat \"a|b\" | grep a"
            ) == ["cat a|b", "grep a"]
        )
        #expect(
            DirectToolExecutor.localExecAuthorizationCommands(
                in: "cat a\\|b | grep a"
            ) == ["cat a\\|b", "grep a"]
        )
    }

    @Test
    func localExecAuthorizationCommandsSplitOnAndAnd() {
        #expect(
            DirectToolExecutor.localExecAuthorizationCommands(in: "cmd1 && cmd2")
            == ["cmd1", "cmd2"]
        )
    }

    @Test
    func localExecAuthorizationCommandsSplitOnSemicolon() {
        #expect(
            DirectToolExecutor.localExecAuthorizationCommands(in: "cmd1; cmd2")
            == ["cmd1", "cmd2"]
        )
    }

    @Test
    func localExecAuthorizationCommandsSplitOnBackgroundAmpersand() {
        #expect(
            DirectToolExecutor.localExecAuthorizationCommands(in: "cmd &")
            == ["cmd"]
        )
    }

    @Test
    func localExecAuthorizationCommandsSplitOnNewlines() {
        #expect(
            DirectToolExecutor.localExecAuthorizationCommands(in: "cmd1\ncmd2")
            == ["cmd1", "cmd2"]
        )
    }

    @Test
    func localExecAuthorizationCommandsSkipHarmlessBuiltins() {
        // `true` and `false` are skipped, so they produce no authorization
        // request.
        #expect(
            DirectToolExecutor.localExecAuthorizationCommands(
                in: "swift build 2>&1 | tail -n 20 || true"
            ) == ["swift build 2>&1", "tail -n 20"]
        )
        #expect(
            DirectToolExecutor.localExecAuthorizationCommands(in: "false || make")
            == ["make"]
        )
        #expect(
            DirectToolExecutor.localExecAuthorizationCommands(in: "true")
            == []
        )
    }

    @Test
    func localExecAuthorizationCommandsDeduplicateRepeatedExecutables() {
        // Two `grep` invocations share an identity, so only the first is
        // surfaced for authorization.
        #expect(
            DirectToolExecutor.localExecAuthorizationCommands(
                in: "grep foo | sort | grep bar"
            ) == ["grep foo", "sort"]
        )
    }

    @Test
    func localExecAuthorizationCommandsExtractNestedFromCommandSubstitution() {
        // `echo` is decorative but its `$(...)` substitution is extracted.
        #expect(
            DirectToolExecutor.localExecAuthorizationCommands(
                in: "echo $(ls | wc -l)"
            ) == ["ls", "wc -l"]
        )
    }

    @Test
    func localExecAuthorizationCommandsExtractNestedFromBackticks() {
        // `echo` is decorative but its backtick content is extracted.
        #expect(
            DirectToolExecutor.localExecAuthorizationCommands(
                in: "echo `ls | wc -l`"
            ) == ["ls", "wc -l"]
        )
    }

    @Test
    func localExecAuthorizationDisplayIdentityExtractsExecutable() {
        #expect(
            DirectToolExecutor.localExecAuthorizationDisplayIdentity(
                in: "swift build 2>&1"
            ) == "swift"
        )
        #expect(
            DirectToolExecutor.localExecAuthorizationDisplayIdentity(
                in: "FOO=bar make all"
            ) == "make"
        )
    }

    @Test
    func localExecAuthorizationCommandsSurfaceExecutablesInsideControlFlow() {
        // C1: control-flow keywords are consumed; the real executable surfaces
        // with a cleaned invocation.
        #expect(
            DirectToolExecutor.localExecAuthorizationCommands(
                in: "if /bin/touch /tmp/x; then true; fi"
            ) == ["/bin/touch /tmp/x"]
        )
        #expect(
            DirectToolExecutor.localExecAuthorizationDisplayIdentity(
                in: "if /bin/touch /tmp/x"
            ) == "/bin/touch"
        )
    }

    @Test
    func localExecAuthorizationCommandsSkipBuiltinsWithRedirections() {
        // C2: a built-in with redirection is prompted, not skipped.
        #expect(
            DirectToolExecutor.localExecAuthorizationCommands(
                in: "true > out.txt"
            ) == ["true > out.txt"]
        )
    }

    @Test
    func localExecAuthorizesPipelineCommandsInOrderAndStopsAtDenial() async {
        let recorder = LocalExecAuthorizationRecorder(decisions: [true, false, true])
        let executor = DirectToolExecutor(
            authorizationHandler: { request in
                await recorder.authorize(request)
            },
            swiftFeatureRuntime: SwiftFeatureRuntime(features: []),
            subAgentBackendFactory: { TestAgentRuntimeBackend() }
        )
        // Use real executables (not echo/printf which are now decorative).
        let command = "cat one | grep one | sort"

        let output = await executor.deniedLocalExecOutputIfNeeded(
            sessionID: "session",
            toolCall: DirectAgentToolCall(
                id: "tool-call",
                name: "local.exec",
                argumentsObject: [:],
                argumentsJSON: "{}"
            ),
            command: command,
            cwd: URL(fileURLWithPath: "/tmp")
        )
        let authorizedCommands = await recorder.recordedCommands()

        #expect(authorizedCommands == ["cat one", "grep one"])
        #expect(output?.contains("no shell command was run") == true)
        #expect(output?.contains(command) == true)
    }

    @Test
    func localExecSkipsHarmlessBuiltinsEndToEnd() async {
        let recorder = LocalExecAuthorizationRecorder(decisions: [true, true])
        let executor = DirectToolExecutor(
            authorizationHandler: { request in
                await recorder.authorize(request)
            },
            swiftFeatureRuntime: SwiftFeatureRuntime(features: []),
            subAgentBackendFactory: { TestAgentRuntimeBackend() }
        )
        // `true` is a harmless builtin and must not produce a request.
        let command = "swift build 2>&1 | tail -n 20 || true"

        let output = await executor.deniedLocalExecOutputIfNeeded(
            sessionID: "session",
            toolCall: DirectAgentToolCall(
                id: "tool-call",
                name: "local.exec",
                argumentsObject: [:],
                argumentsJSON: "{}"
            ),
            command: command,
            cwd: URL(fileURLWithPath: "/tmp")
        )
        let authorizedCommands = await recorder.recordedCommands()

        #expect(authorizedCommands == ["swift build 2>&1", "tail -n 20"])
        #expect(output == nil)
    }

    @Test
    func localExecFiltersCommentsEchoAndBuiltinsEndToEnd() async {
        let recorder = LocalExecAuthorizationRecorder(decisions: [true])
        let executor = DirectToolExecutor(
            authorizationHandler: { request in
                await recorder.authorize(request)
            },
            swiftFeatureRuntime: SwiftFeatureRuntime(features: []),
            subAgentBackendFactory: { TestAgentRuntimeBackend() }
        )
        // Comments, decorative echo, and builtins should produce only one
        // authorization request for the real command.
        let command = """
        # build step
        echo "== Build =="
        true && env CI=1 command swift test
        """

        let output = await executor.deniedLocalExecOutputIfNeeded(
            sessionID: "session",
            toolCall: DirectAgentToolCall(
                id: "tool-call",
                name: "local.exec",
                argumentsObject: [:],
                argumentsJSON: "{}"
            ),
            command: command,
            cwd: URL(fileURLWithPath: "/tmp")
        )
        let authorizedCommands = await recorder.recordedCommands()

        #expect(authorizedCommands == ["swift test"])
        #expect(output == nil)
    }

    @Test
    func localExecAuthorizationRequestUsesCleanedInvocation() async {
        let recorder = LocalExecAuthorizationRecorder(decisions: [true])
        let executor = DirectToolExecutor(
            authorizationHandler: { request in
                await recorder.authorize(request)
            },
            swiftFeatureRuntime: SwiftFeatureRuntime(features: []),
            subAgentBackendFactory: { TestAgentRuntimeBackend() }
        )
        // The `command` field should be the cleaned invocation, not the raw
        // segment with env assignments and wrappers.
        _ = await executor.deniedLocalExecOutputIfNeeded(
            sessionID: "session",
            toolCall: DirectAgentToolCall(
                id: "tool-call",
                name: "local.exec",
                argumentsObject: [:],
                argumentsJSON: "{}"
            ),
            command: "FOO=bar env CI=1 swift build",
            cwd: URL(fileURLWithPath: "/tmp")
        )
        let authorizedCommands = await recorder.recordedCommands()

        #expect(authorizedCommands == ["swift build"])
    }

    @Test
    func localExecAuthorizationRequestPopulatesAllFields() async {
        let recorder = LocalExecAuthorizationRecorder(decisions: [true])
        let executor = DirectToolExecutor(
            authorizationHandler: { request in
                await recorder.authorize(request)
            },
            swiftFeatureRuntime: SwiftFeatureRuntime(features: []),
            subAgentBackendFactory: { TestAgentRuntimeBackend() }
        )
        _ = await executor.deniedLocalExecOutputIfNeeded(
            sessionID: "session-id",
            toolCall: DirectAgentToolCall(
                id: "call-id",
                name: "local.exec",
                argumentsObject: [:],
                argumentsJSON: "{}"
            ),
            command: "env CI=1 swift build",
            cwd: URL(fileURLWithPath: "/work/dir")
        )
        let requests = await recorder.recordedRequests()

        #expect(requests.count == 1)
        let request = requests[0]
        #expect(request.title == "Run swift")
        #expect(request.command == "swift build")
        #expect(request.workingDirectory == "/work/dir")
        #expect(request.toolName == "local.exec")
        #expect(request.kind == "execute")
        #expect(request.sessionID == "session-id")
        #expect(request.toolCallID == "call-id")
    }

    @Test
    func localExecAuthorizationExtractsNestedCommandFromSubstitution() async {
        let recorder = LocalExecAuthorizationRecorder(decisions: [true, true])
        let executor = DirectToolExecutor(
            authorizationHandler: { request in
                await recorder.authorize(request)
            },
            swiftFeatureRuntime: SwiftFeatureRuntime(features: []),
            subAgentBackendFactory: { TestAgentRuntimeBackend() }
        )
        // A normal executable with a nested command substitution must surface
        // BOTH the outer command and the nested one (security: rm must prompt).
        _ = await executor.deniedLocalExecOutputIfNeeded(
            sessionID: "session",
            toolCall: DirectAgentToolCall(
                id: "tool-call",
                name: "local.exec",
                argumentsObject: [:],
                argumentsJSON: "{}"
            ),
            command: "cat \"$(rm -rf /tmp/x)\"",
            cwd: URL(fileURLWithPath: "/tmp")
        )
        let authorizedCommands = await recorder.recordedCommands()

        #expect(authorizedCommands == ["cat $(rm -rf /tmp/x)", "rm -rf /tmp/x"])
    }

    private func runFileTool(
        _ name: String,
        arguments: [String: Any],
        workingDirectory: URL
    ) async throws -> String {
        let tool = LocalFeatureTools.fileTools().first { $0.descriptor.name == name }
        let unwrapped = try #require(tool)
        let data = try JSONSerialization.data(withJSONObject: arguments)
        let output = try await unwrapped.invoke(
            inputData: data,
            context: FeatureContext(workingDirectory: workingDirectory, environment: [:])
        )
        if let decoded = try? JSONDecoder().decode(String.self, from: output) {
            return decoded
        }
        return String(decoding: output, as: UTF8.self)
    }

    private func runSearchTool(
        _ name: String,
        arguments: [String: Any],
        workingDirectory: URL
    ) async throws -> String {
        let tool = LocalFeatureTools.searchTools().first { $0.descriptor.name == name }
        let unwrapped = try #require(tool)
        let data = try JSONSerialization.data(withJSONObject: arguments)
        let output = try await unwrapped.invoke(
            inputData: data,
            context: FeatureContext(workingDirectory: workingDirectory, environment: [:])
        )
        if let decoded = try? JSONDecoder().decode(String.self, from: output) {
            return decoded
        }
        return String(decoding: output, as: UTF8.self)
    }

    @Test
    func applyPatchUpdatesMultipleFilesAtomically() async throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("applypatch-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let fileA = root.appendingPathComponent("a.txt")
        let fileB = root.appendingPathComponent("b.txt")
        try "line1\nline2\nline3\n".write(to: fileA, atomically: true, encoding: .utf8)
        try "hello\nworld\n".write(to: fileB, atomically: true, encoding: .utf8)

        let patch = """
        --- a/a.txt
        +++ b/a.txt
        @@ -1,3 +1,3 @@
         line1
        -line2
        +line2-changed
         line3
        --- a/b.txt
        +++ b/b.txt
        @@ -1,2 +1,3 @@
         hello
        +inserted
         world
        """

        let output = try await runFileTool(
            "local.applyPatch",
            arguments: ["patch": patch],
            workingDirectory: root
        )
        #expect(output.contains("2 file(s)"))
        #expect(try String(contentsOf: fileA, encoding: .utf8) == "line1\nline2-changed\nline3\n")
        #expect(try String(contentsOf: fileB, encoding: .utf8) == "hello\ninserted\nworld\n")
    }

    @Test
    func applyPatchRejectsMismatchWithoutWriting() async throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("applypatch-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let fileA = root.appendingPathComponent("a.txt")
        try "line1\nline2\n".write(to: fileA, atomically: true, encoding: .utf8)

        let patch = """
        --- a/a.txt
        +++ b/a.txt
        @@ -1,2 +1,2 @@
         WRONG
        -line2
        +line2-changed
        """

        await #expect(throws: (any Error).self) {
            _ = try await self.runFileTool(
                "local.applyPatch",
                arguments: ["patch": patch],
                workingDirectory: root
            )
        }
        #expect(try String(contentsOf: fileA, encoding: .utf8) == "line1\nline2\n")
    }

    @Test
    func applyPatchSupportsBeginPatchFormatForUpdateAddAndDelete() async throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("applypatch-begin-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let existing = root.appendingPathComponent("existing.txt")
        let deleted = root.appendingPathComponent("deleted.txt")
        let added = root.appendingPathComponent("nested/added.txt")
        try "one\ntwo\nthree\n".write(to: existing, atomically: true, encoding: .utf8)
        try "remove me\n".write(to: deleted, atomically: true, encoding: .utf8)

        let patch = """
        *** Begin Patch
        *** Update File: existing.txt
        @@
         one
        -two
        +two changed
         three
        *** Add File: nested/added.txt
        +hello
        +world
        *** Delete File: deleted.txt
        *** End Patch
        """

        let output = try await runFileTool(
            "local.applyPatch",
            arguments: ["patch": patch],
            workingDirectory: root
        )

        #expect(output.contains("3 file(s)"))
        #expect(try String(contentsOf: existing, encoding: .utf8) == "one\ntwo changed\nthree\n")
        #expect(try String(contentsOf: added, encoding: .utf8) == "hello\nworld\n")
        #expect(!FileManager.default.fileExists(atPath: deleted.path))
    }

    @Test
    func beginPatchRejectsMismatchWithoutWriting() async throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("applypatch-begin-mismatch-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let existing = root.appendingPathComponent("existing.txt")
        let added = root.appendingPathComponent("added.txt")
        try "one\ntwo\n".write(to: existing, atomically: true, encoding: .utf8)

        let patch = """
        *** Begin Patch
        *** Update File: existing.txt
        @@
         missing
        -two
        +two changed
        *** Add File: added.txt
        +must not be written
        *** End Patch
        """

        await #expect(throws: (any Error).self) {
            _ = try await self.runFileTool(
                "local.applyPatch",
                arguments: ["patch": patch],
                workingDirectory: root
            )
        }
        #expect(try String(contentsOf: existing, encoding: .utf8) == "one\ntwo\n")
        #expect(!FileManager.default.fileExists(atPath: added.path))
    }

    @Test
    func readFilesReturnsEachFileWithHeader() async throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("readfiles-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let fileA = root.appendingPathComponent("a.txt")
        let fileB = root.appendingPathComponent("b.txt")
        try "alpha\n".write(to: fileA, atomically: true, encoding: .utf8)
        try "beta\n".write(to: fileB, atomically: true, encoding: .utf8)

        let output = try await runFileTool(
            "local.readFiles",
            arguments: ["paths": ["a.txt", "b.txt"]],
            workingDirectory: root
        )
        #expect(output.contains(fileA.path))
        #expect(output.contains(fileB.path))
        #expect(output.contains("alpha"))
        #expect(output.contains("beta"))
    }

    @Test
    func inspectFileReturnsMetadataOutlineAndReadSuggestions() async throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("inspectfile-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let source = root.appendingPathComponent("App.swift")
        try """
        import Foundation

        // MARK: View
        struct AppView {
            func render() {}
        }

        extension AppView {
            class func update() {}
        }
        """.write(to: source, atomically: true, encoding: .utf8)

        let output = try await runFileTool(
            "local.inspectFile",
            arguments: ["path": "App.swift"],
            workingDirectory: root
        )

        #expect(output.contains("File: \(source.path)"))
        #expect(output.contains("lines:"))
        #expect(output.contains("suggested_reads:"))
        #expect(output.contains("local.readFile path=\"\(source.path)\" offset=1"))
        #expect(output.contains("outline:"))
        #expect(output.contains("mark\tView"))
        #expect(output.contains("struct\tAppView"))
        #expect(output.contains("func\trender"))
        #expect(output.contains("extension\tAppView"))
        #expect(output.contains("func\tupdate"))
    }

    @Test
    func searchLocateReturnsCompactMatchesAndReadSuggestions() async throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("searchlocate-\(UUID().uuidString)")
        let sources = root.appendingPathComponent("Sources")
        try FileManager.default.createDirectory(at: sources, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let source = sources.appendingPathComponent("App.swift")
        try """
        struct App {
            func targetFeature() {}
        }
        """.write(to: source, atomically: true, encoding: .utf8)

        let output = try await runSearchTool(
            "search.locate",
            arguments: ["pattern": "targetFeature", "path": ".", "maxResults": 5],
            workingDirectory: root
        )

        #expect(output.contains("matches: 1"))
        #expect(output.contains(source.path))
        #expect(output.contains("targetFeature"))
        #expect(output.contains("suggested_reads:"))
        #expect(output.contains("local.readFile path=\"\(source.path)\""))
    }
}

private actor LocalExecAuthorizationRecorder {
    private let decisions: [Bool]
    private var requests: [AgentToolAuthorizationRequest] = []

    init(decisions: [Bool]) {
        self.decisions = decisions
    }

    func authorize(_ request: AgentToolAuthorizationRequest) -> Bool {
        let decisionIndex = requests.count
        requests.append(request)
        guard decisions.indices.contains(decisionIndex) else {
            return false
        }
        return decisions[decisionIndex]
    }

    func recordedCommands() -> [String] {
        requests.map(\.command)
    }

    func recordedRequests() -> [AgentToolAuthorizationRequest] {
        requests
    }
}

private actor TestAgentRuntimeBackend: AgentRuntimeBackend {
    func createSession(
        id _: String,
        cwd _: String,
        systemPrompt _: String?,
        history _: [AgentRuntimeMessage],
        cacheKey _: String?,
        allowedToolNames _: Set<String>?,
        thinkingSelection _: AgentThinkingSelection?,
        preserveThinking _: Bool
    ) {}

    func createSessionIfNeeded(
        id _: String,
        cwd _: String,
        systemPrompt _: String?,
        history _: [AgentRuntimeMessage],
        cacheKey _: String?,
        allowedToolNames _: Set<String>?,
        thinkingSelection _: AgentThinkingSelection?,
        preserveThinking _: Bool
    ) {}

    func updateSessionOptions(
        id _: String,
        systemPrompt _: String?,
        allowedToolNames _: Set<String>?,
        thinkingSelection _: AgentThinkingSelection?,
        preserveThinking _: Bool
    ) {}

    func closeSession(id _: String) {}

    func shutdown() async {}

    func preloadModel(
        onEvent _: @escaping @Sendable (DirectAgentEvent) async -> Void
    ) async throws -> String {
        "test"
    }

    func activeToolDescriptors() async -> [DirectToolDescriptor] {
        []
    }

    func sendPrompt(
        sessionID _: String,
        prompt _: String,
        attachments _: [AgentRuntimeAttachment],
        onEvent _: @escaping @Sendable (DirectAgentEvent) async -> Void
    ) async throws -> DirectAgentResponse {
        DirectAgentResponse(text: "", stopReason: "end_turn", modelID: "test")
    }
}
