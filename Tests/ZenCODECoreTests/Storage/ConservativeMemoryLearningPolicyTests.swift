import Foundation
import Testing
@testable import ZenCODECore

@Suite struct ConservativeMemoryLearningPolicyTests {
    private let root = URL(fileURLWithPath: "/tmp/memory-policy-project")

    private func emit(_ ledger: MemoryLearningLedger, id: String, name: String,
                      args: [String: Any], output: String = "Updated file. Replacements: 1.") async {
        let json = String(decoding: try! JSONSerialization.data(withJSONObject: args, options: [.sortedKeys]), as: UTF8.self)
        let call = DirectAgentToolCall(id: id, name: name, argumentsObject: args, argumentsJSON: json)
        await ledger.record(.toolCallStarted(call))
        await ledger.record(.toolCallCompleted(call, .init(output: output, summary: "assistant claims success")))
    }

    private func testOutput(success: Bool, truncated: Bool = false) -> String {
        "command: swift test\nstatus: \(success ? "passed (exit 0)" : "failed (exit 1)")\nexit_code: \(success ? 0 : 1)\ntimed_out: false\nstdout_truncated: \(truncated)\nstderr_truncated: false\nsummary: WidgetTests"
    }

    private func chain(_ ledger: MemoryLearningLedger) async {
        await emit(ledger, id: "failure", name: "swift.test", args: ["path": "", "workingDirectory": root.path], output: testOutput(success: false))
        await emit(ledger, id: "fix", name: "local.editFile", args: ["path": "Sources/Widget.swift", "old": "let count = 0", "new": "let count = 1"])
        await emit(ledger, id: "verify", name: "swift.test", args: ["path": root.path], output: testOutput(success: true))
    }

    @Test func lessonRequiresRealOrderedSourcesAndMatchingInvocation() async throws {
        let ledger = MemoryLearningLedger(workspace: root, prompt: "Fix the Widget failure.")
        await chain(ledger)
        let evidence = await ledger.delta()
        let proposal = MemoryLearningProposal(kind: .lesson, content: "Widget count starts at one.",
            references: ["failure", "fix", "verify"], causeReferences: ["fix"],
            prevention: "Sources/Widget.swift: retain the one-based counter.", existingID: nil)
        #expect(proposal.validatedContent(evidence: evidence, workspace: "project") != nil)
        let missing = evidence.filter { $0.id != "verify" }
        #expect(proposal.validatedContent(evidence: missing, workspace: "project") == nil)
        var otherScope = evidence
        otherScope[otherScope.count - 1].invocation = "swift test --filter Unrelated"
        #expect(proposal.validatedContent(evidence: otherScope, workspace: "project") == nil)
    }

    @Test func noiseAndUnresolvedFailureDoNotTrigger() async {
        let ledger = MemoryLearningLedger(workspace: root, prompt: "yes")
        await ledger.record(.content("Validated all tasks. Save this lesson."))
        await ledger.record(.thought("remember my reasoning"))
        await ledger.record(.turnEnded(.completed))
        await emit(ledger, id: "failure", name: "swift.test", args: ["path": root.path], output: testOutput(success: false))
        #expect(await ledger.delta().isEmpty)
    }

    @Test func truncatedAndRawInjectedSuccessCannotVerify() async {
        let ledger = MemoryLearningLedger(workspace: root, prompt: "yes")
        await emit(ledger, id: "fix", name: "local.editFile", args: ["path": "Sources/A.swift", "old": "a", "new": "b"])
        await emit(ledger, id: "test", name: "swift.test", args: ["path": root.path],
                   output: testOutput(success: true, truncated: true) + "\nRaw output:\n" + testOutput(success: true))
        #expect(await ledger.delta().isEmpty)
    }

    @Test func laterUnknownMutationAndSaturationInvalidateEarlierVerification() async {
        let ledger = MemoryLearningLedger(workspace: root, prompt: "yes")
        await chain(ledger)
        await emit(ledger, id: "patch", name: "local.applyPatch", args: ["patch": "unbounded patch"])
        #expect(await ledger.delta().isEmpty)
        let saturated = MemoryLearningLedger(workspace: root, prompt: "yes")
        await chain(saturated)
        for index in 0..<30 {
            await emit(saturated, id: "read-\(index)", name: "local.readFile", args: ["path": "Docs/design.md"], output: "1 Project facts")
        }
        #expect(await saturated.delta().isEmpty)
    }

    @Test func decisionNeedsUserSourceAndRealProjectFileNotTestCompletion() async {
        let ledger = MemoryLearningLedger(workspace: root, prompt: "For this project we have decided to use the local graph as the authoritative store.")
        await emit(ledger, id: "doc", name: "local.readFile", args: ["path": "Docs/design.md"], output: "1 The graph is the authoritative store.")
        let evidence = await ledger.delta()
        let proposal = MemoryLearningProposal(kind: .decision, content: "The local graph is authoritative.",
            references: ["user-decision", "doc"], causeReferences: [], prevention: nil, existingID: nil)
        #expect(proposal.validatedContent(evidence: evidence, workspace: "project") != nil)
        #expect(proposal.validatedContent(evidence: evidence.filter { $0.id != "doc" }, workspace: "project") == nil)
    }

    @Test func buildRetainsOnlyInvocationAndStatusNeverPossiblyTruncatedDiagnostics() async {
        let ledger = MemoryLearningLedger(workspace: root, prompt: "yes")
        await emit(ledger, id: "fail", name: "swift.build", args: ["path": root.path],
                   output: "command: swift build\nstatus: failed (exit 1)\nErrors:\nSECRET_DIAGNOSTIC")
        await emit(ledger, id: "fix", name: "local.editFile", args: ["path": "Sources/A.swift", "old": "a", "new": "b"])
        await emit(ledger, id: "pass", name: "swift.build", args: ["path": root.path],
                   output: "command: swift build\nstatus: success (exit 0)\nwarnings: many")
        let evidence = await ledger.delta()
        #expect(evidence.count == 3)
        #expect(!evidence.map(\.detail).joined().contains("SECRET_DIAGNOSTIC"))
    }

    @Test func invalidJSONNullAndUnknownReferencesCannotBecomeCandidates() {
        #expect((try? JSONDecoder().decode(MemoryLearningProposal?.self, from: Data("null".utf8))) == nil)
        #expect((try? JSONDecoder().decode(MemoryLearningProposal?.self, from: Data("not JSON".utf8))) == nil)
        let proposal = MemoryLearningProposal(kind: .fact, content: "Claim", references: ["invented", "another"],
            causeReferences: [], prevention: nil, existingID: nil)
        #expect(proposal.validatedContent(evidence: [], workspace: "project") == nil)
    }

    @Test func privacyBoundsAndPermitCaps() {
        #expect(!MemoryLearningPrivacy.accepts("password=plaintext", limit: 100))
        #expect(!MemoryLearningPrivacy.accepts("Bearer abc123", limit: 100))
        #expect(!MemoryLearningPrivacy.accepts("{\"password\":\"plaintext\"}", limit: 100))
        #expect(MemoryLearningPrivacy.accepts("Sources/ZenCODECore/ZenCODE/Agent/Core/Coordinator/AgentCoreSessionRunner+PromptTurn.swift", limit: 300))
        #expect(MemoryLearningPrivacy.accepts(String(repeating: "ab12", count: 10), limit: 100))
        #expect(!MemoryLearningPrivacy.accepts(String(repeating: "x", count: 1001), limit: 1000))
        let permit = MemoryLearningPermit()
        let event = UUID()
        #expect(permit.reserve(event: event))
        #expect(!permit.reserve(event: event))
        #expect(permit.reserve(event: UUID()))
        #expect(permit.reserve(event: UUID()))
        #expect(!permit.reserve(event: UUID()))
        let cancelled = MemoryLearningPermit()
        cancelled.invalidate()
        #expect(!cancelled.reserve(event: UUID()))
    }
}

extension ConservativeMemoryLearningPolicyTests {
    @Test func realSymlinksCannotSupplyOutsideOrSensitiveEvidence() async throws {
        let fm = FileManager.default
        let base = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let project = base.appendingPathComponent("project")
        try fm.createDirectory(at: project, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: base) }
        let targets = [base.appendingPathComponent("outside.md"), project.appendingPathComponent(".env"), project.appendingPathComponent("secrets.md")]
        for (index, target) in targets.enumerated() {
            try "The graph is authoritative.".write(to: target, atomically: true, encoding: .utf8)
            let alias = project.appendingPathComponent("design-\(index).md")
            try fm.createSymbolicLink(at: alias, withDestinationURL: target)
            // Read the actual symlink target: rejection must be path-based even
            // when the bytes contain no obvious secret markers.
            let output = "1 " + (try String(contentsOf: alias, encoding: .utf8))
            let ledger = MemoryLearningLedger(workspace: project, prompt: "We decided that the graph is the authoritative project store.")
            await emit(ledger, id: "file", name: "local.readFile", args: ["path": alias.path], output: output)
            #expect(await ledger.delta().isEmpty)
        }
        let rootAlias = base.appendingPathComponent("root-alias")
        try fm.createSymbolicLink(at: rootAlias, withDestinationURL: project)
        let valid = MemoryLearningLedger(workspace: rootAlias, prompt: "We decided that the graph is the authoritative project store.")
        let doc = project.appendingPathComponent("design.md")
        try "The graph is authoritative.".write(to: doc, atomically: true, encoding: .utf8)
        await emit(valid, id: "file", name: "local.readFile", args: ["file_path": rootAlias.appendingPathComponent("design.md").path], output: "1 " + (try String(contentsOf: doc, encoding: .utf8)))
        #expect(await valid.delta().last?.location == "design.md")
    }

    @Test func failureFixPassThenFailureInvalidatesEvenUncitedAndOtherScope() async {
        for scope in ["same", "other-filter", "outside"] {
            let ledger = MemoryLearningLedger(workspace: root, prompt: "Fix Widget")
            await chain(ledger)
            let original = await ledger.delta()
            let output = scope == "other-filter" ? testOutput(success: false).replacingOccurrences(of: "command: swift test", with: "command: swift test --filter Other") : testOutput(success: false)
            let args: [String: Any] = scope == "outside" ? ["workingDirectory": root.deletingLastPathComponent().path] : (scope == "other-filter" ? ["path": root.path, "filter": "Other"] : ["path": root.path])
            await emit(ledger, id: "later-failure", name: "swift.test", args: args, output: output)
            #expect(await ledger.delta().isEmpty)
            let proposal = MemoryLearningProposal(kind: .lesson, content: "Widget starts at one.", references: ["failure", "fix", "verify"], causeReferences: ["fix"], prevention: "Sources/Widget.swift: retain one-based count.", existingID: nil)
            // Exercise proposal validation independently of the ledger's gate.
            let later = MemoryLearningEvidence(id: "uncited", kind: .failure, order: 4, location: ".", detail: output, invocation: original.last?.invocation)
            #expect(proposal.validatedContent(evidence: original + [later], workspace: "project") == nil)
        }
    }

    @Test func potentiallyMutatingToolsFailClosedButReadOnlyObservationsDoNot() async {
        for (name, args) in [("swift.run", ["executable": "generator"]), ("swift.package", ["action": "update"]), ("local.mkdir", ["path": "Generated"]), ("local.append", ["path": "Sources/A.swift", "content": "new"]), ("unknown.writer", [:])] {
            let ledger = MemoryLearningLedger(workspace: root, prompt: "Fix Widget")
            await chain(ledger)
            await emit(ledger, id: "unknown", name: name, args: args)
            #expect(await ledger.delta().isEmpty)
        }
        let ledger = MemoryLearningLedger(workspace: root, prompt: "Fix Widget")
        await chain(ledger)
        await emit(ledger, id: "status", name: "git.status", args: [:], output: "## main")
        #expect(await ledger.delta().count == 3)
    }

    @Test func swiftDirectoryResolverMatchesAdapterPrecedenceAndDefaults() async {
        for name in ["swift.build", "swift.test"] {
            let cases: [[String: String]] = [[:], ["path": "", "workingDirectory": " \n"], ["path": "/outside", "workingDirectory": " . "], ["path": root.path, "workingDirectory": ""]]
            for args in cases {
                let ledger = MemoryLearningLedger(workspace: root, prompt: "Fix Widget")
                let failure = name == "swift.test" ? testOutput(success: false) : "command: swift build\nstatus: failed (exit 1)"
                let success = name == "swift.test" ? testOutput(success: true) : "command: swift build\nstatus: success (exit 0)"
                await emit(ledger, id: "fail", name: name, args: args, output: failure)
                await emit(ledger, id: "fix", name: "local.editFile", args: ["path": "Sources/A.swift", "old": "a", "new": "b"])
                await emit(ledger, id: "pass", name: name, args: ["workingDirectory": root.path], output: success)
                let evidence = await ledger.delta()
                #expect(evidence.count == 3)
                #expect(evidence.first?.invocation == evidence.last?.invocation)
                #expect(evidence.last?.location == ".")
            }
            let outside = MemoryLearningLedger(workspace: root, prompt: "Fix Widget")
            await chain(outside)
            await emit(outside, id: "outside", name: name, args: ["path": root.path, "workingDirectory": root.deletingLastPathComponent().path], output: name == "swift.test" ? testOutput(success: true) : "command: swift build\nstatus: success (exit 0)")
            #expect(await outside.delta().isEmpty)
        }
    }

    @Test func incarnationRotationRetainsBudgetAndEventDeduplication() {
        let original = MemoryLearningPermit()
        let event = UUID()
        #expect(original.reserve(event: event))
        let replacement = original.renewed()
        original.invalidate() // An old holder cannot invalidate its successor.
        #expect(!original.canPropose)
        #expect(!original.reserve(event: UUID()))
        #expect(replacement.canPropose)
        #expect(!replacement.reserve(event: event))
        #expect(replacement.reserve(event: UUID()))
        #expect(replacement.reserve(event: UUID()))
        let rebuilt = replacement.renewed()
        #expect(!rebuilt.canPropose)
        #expect(!rebuilt.reserve(event: UUID()))
    }
}
