import Foundation
import Synchronization

/// Internal, task-scoped isolation; never persisted or added to a public protocol.
enum MemoryConsolidationContext {
    @TaskLocal static var isIsolated = false
}

/// Logical-session budget shared by successive incarnation fences.
private final class MemoryLearningBudget: Sendable {
    struct State: Sendable {
        var incarnation: UUID?
        var mutations = 0
        var events: Set<UUID> = []
    }
    let state = Mutex(State())
}

/// Reservations and fence rotation use the same lock, including graph commits.
/// Failed saves may consume budget; rebuilding never replenishes it.
final class MemoryLearningPermit: Sendable {
    private let budget: MemoryLearningBudget
    private let incarnation: UUID
    init() {
        budget = MemoryLearningBudget()
        incarnation = UUID()
        budget.state.withLock { $0.incarnation = incarnation }
    }
    private init(budget: MemoryLearningBudget, incarnation: UUID) {
        self.budget = budget
        self.incarnation = incarnation
    }
    func renewed() -> MemoryLearningPermit {
        let next = UUID()
        budget.state.withLock { $0.incarnation = next }
        return MemoryLearningPermit(budget: budget, incarnation: next)
    }
    func invalidate() {
        budget.state.withLock { if $0.incarnation == incarnation { $0.incarnation = nil } }
    }
    var canPropose: Bool { budget.state.withLock { $0.incarnation == incarnation && $0.mutations < 3 } }
    func reserve(event: UUID) -> Bool {
        budget.state.withLock {
            guard $0.incarnation == incarnation, $0.mutations < 3,
                  $0.events.insert(event).inserted else { return false }
            $0.mutations += 1
            return true
        }
    }
}

/// Reject rather than redact evidence: redaction could remove a causal qualifier.
/// This heuristic is deliberately fail-closed but cannot identify every secret.
enum MemoryLearningPrivacy {
    static func accepts(_ text: String, limit: Int) -> Bool {
        guard !text.isEmpty, text.count <= limit else { return false }
        let patterns = [
            "(?i)(api[_-]?key|access[_-]?token|refresh[_-]?token|password|passwd|authorization|client[_-]?secret|private[_-]?key|secret|token)[\\\"']?\\s*[:=]",
            "(?i)bearer\\s+\\S+", "-----BEGIN .*PRIVATE KEY-----",
            "\\b(sk-|gh[pousr]_|github_pat_|AKIA|xox[baprs]-)[A-Za-z0-9_-]{8,}",
            "\\beyJ[A-Za-z0-9_-]{12,}\\.[A-Za-z0-9_-]{12,}\\.[A-Za-z0-9_-]{8,}", "https?://[^\\s/]+:[^\\s/]+@"
        ]
        return !patterns.contains { text.range(of: $0, options: .regularExpression) != nil }
    }
}

struct MemoryLearningEvidence: Codable, Sendable, Equatable {
    enum Kind: String, Codable, Sendable { case failure, correction, verification, projectDecision, projectFile }
    let id: String
    let kind: Kind
    let order: Int
    let location: String
    let detail: String
    var invocation: String? = nil
}

/// Only correlated, recognized tool outcomes enter this ledger. No transcript,
/// recalled memory, assistant text, task status, or sub-agent summary is evidence.
actor MemoryLearningLedger {
    private var started: Set<String> = []
    private var evidence: [MemoryLearningEvidence] = []
    private var sequence = 0
    private var overflow = false
    private let workspace: URL
    init(workspace: URL, prompt: String) {
        self.workspace = workspace.resolvingSymlinksInPath().standardizedFileURL
        // User text is a source, not self-certification. A substantive prompt
        // only becomes a trigger together with observed project-file evidence.
        let decisionCues = ["decid", "decision", "adott", "authoritative", "autorevole", "we will use", "useremo", "scegli"]
        if prompt.count >= 40, decisionCues.contains(where: { prompt.lowercased().contains($0) }),
           MemoryLearningPrivacy.accepts(prompt, limit: 1000) {
            evidence.append(.init(id: "user-decision", kind: .projectDecision, order: 0,
                                  location: "current user prompt", detail: prompt))
        }
    }
    func record(_ event: DirectAgentEvent) {
        switch event {
        case .toolCallStarted(let call):
            guard started.count < 128 else { overflow = true; return }
            started.insert(call.id)
        case .toolCallCompleted(let call, let result):
            sequence += 1
            // Only these internally supported observations are known read-only.
            // Everything else (including swift.run/package and arbitrary aliases)
            // may mutate the workspace: do not infer safety from a blacklist.
            let observations: Set<String> = [
                "local.readFile", "local.readFiles", "local.inspectFile", "local.ls", "local.pwd",
                "search.glob", "search.grep", "search.locate", "text.head", "text.tail", "text.wc", "text.sort",
                "git.status", "git.diff", "git.log", "git.show", "git.grep", "git.lsFiles", "git.blame", "git.branch", "git.remote",
                "swift.outline"
            ]
            let isCorrection = ["local.editFile", "local.multiEdit", "local.writeFile"].contains(call.name)
            let isVerification = call.name == "swift.test" || call.name == "swift.build"
            guard observations.contains(call.name) || isCorrection || isVerification else { overflow = true; return }
            // A verification/correction that cannot be interpreted cannot leave
            // an earlier pass authoritative (including failures outside root).
            var recorded = false
            defer { if (isCorrection || isVerification) && !recorded { overflow = true } }
            if isCorrection,
               (result.isFailure || !MemoryLearningPrivacy.accepts(call.argumentsJSON, limit: 2400)) { overflow = true }
            guard evidence.count < 24 else { overflow = true; return }
            guard started.remove(call.id) != nil, !overflow,
                  result.status != .permissionDenied, result.attachments.isEmpty else { return }
            let args = call.argumentsObject
            // Swift's adapter prefers workingDirectory, then path, then the
            // session cwd. File-tool resolution deliberately stays unchanged.
            let keys = isVerification ? ["workingDirectory", "path"] : ["path", "file_path", "workingDirectory"]
            let selectedPath = keys.compactMap { args[$0] as? String }
                .map { isVerification ? $0.trimmingCharacters(in: .whitespacesAndNewlines) : $0 }
                .first { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            guard let path = selectedPath ?? (isVerification ? "." : nil) else { return }
            let alias = path.hasPrefix("/") ? URL(fileURLWithPath: path) : workspace.appendingPathComponent(path)
            let url = alias.resolvingSymlinksInPath().standardizedFileURL
            let rootPrefix = workspace.path.hasSuffix("/") ? workspace.path : workspace.path + "/"
            guard url.path == workspace.path || url.path.hasPrefix(rootPrefix) else { overflow = true; return }
            let relative = url.path == workspace.path ? "." : String(url.path.dropFirst(rootPrefix.count))
            let sensitiveNames = [".env", "credentials", "secrets", "memory.md", "memory.graph.json", ".pem", ".key"]
            guard !sensitiveNames.contains(where: {
                alias.path.lowercased().contains($0) || url.path.lowercased().contains($0)
            }) else { overflow = true; return }
            var kind: MemoryLearningEvidence.Kind
            var detail: String
            var invocation: String?
            if call.name == "swift.test" || call.name == "swift.build" {
                // Parse only the leading machine-authored header, never logs.
                let structured = result.output.components(separatedBy: "\nRaw output:").first ?? ""
                let header = Array(structured.components(separatedBy: .newlines).prefix(6))
                guard let command = header.first, command.hasPrefix("command: swift "),
                      header.count >= 2 else { return }
                invocation = call.name + "@" + relative + " " + command
                if call.name == "swift.test" {
                    guard header.contains("timed_out: false"), header.contains("stdout_truncated: false"),
                          header.contains("stderr_truncated: false") else { return }
                    detail = structured
                } else {
                    // Build's public summary has no truncation metadata: retain
                    // ONLY command/status, never its possibly partial diagnostics.
                    detail = header.prefix(2).joined(separator: "\n")
                }
                if header[1] == (call.name == "swift.test" ? "status: passed (exit 0)" : "status: success (exit 0)"), !result.isFailure {
                    kind = .verification
                } else if header[1].hasPrefix("status: failed (exit "), header[1] != "status: failed (exit 0)" {
                    kind = .failure
                } else { return }
            } else if call.name == "local.readFile", !result.isFailure {
                guard !result.output.lowercased().contains("truncated"), result.output.count <= 2400 else { return }
                kind = .projectFile
                detail = result.output
            } else if ["local.editFile", "local.multiEdit", "local.writeFile"].contains(call.name), !result.isFailure {
                kind = .correction
                detail = call.argumentsJSON
            } else { return }
            guard MemoryLearningPrivacy.accepts(detail, limit: 2400),
                  MemoryLearningPrivacy.accepts(relative, limit: 300),
                  MemoryLearningPrivacy.accepts(call.id, limit: 150) else { return }
            evidence.append(.init(id: call.id, kind: kind, order: sequence, location: relative, detail: detail, invocation: invocation))
            recorded = true
        default: break
        }
    }
    func delta() -> [MemoryLearningEvidence] {
        guard !overflow, evidence.filter({ $0.kind == .failure }).allSatisfy({ failure in
            failure.invocation != nil && evidence.contains(where: {
                $0.kind == .verification && $0.invocation == failure.invocation && $0.order > failure.order
            })
        }) else { return [] }
        if evidence.contains(where: { $0.kind == .projectDecision }),
           evidence.contains(where: { $0.kind == .projectFile }) { return evidence }
        guard let lastCorrection = evidence.last(where: { $0.kind == .correction }),
              evidence.contains(where: { candidate in
                  candidate.kind == .verification && candidate.order > lastCorrection.order &&
                  !evidence.contains(where: { $0.kind == .failure && $0.order > candidate.order })
              }) else { return [] }
        return evidence
    }
}

struct MemoryLearningProposal: Codable, Sendable {
    enum Kind: String, Codable, Sendable { case lesson, decision, fact }
    let kind: Kind
    let content: String
    let references: [String]
    let causeReferences: [String]
    let prevention: String?
    let existingID: String?

    func validatedContent(evidence: [MemoryLearningEvidence], workspace: String) -> String? {
        guard MemoryLearningPrivacy.accepts(content, limit: 700), references.count >= 2,
              Set(references).count == references.count,
              references.allSatisfy({ id in evidence.contains { $0.id == id } }),
              causeReferences.allSatisfy(references.contains) else { return nil }
        let cited = evidence.filter { references.contains($0.id) }
        if kind == .decision {
            guard cited.contains(where: { $0.kind == .projectDecision }),
                  let file = cited.last(where: { $0.kind == .projectFile }),
                  !evidence.contains(where: { $0.kind == .correction && $0.order > file.order }) else { return nil }
        } else {
        guard let correction = cited.last(where: { $0.kind == .correction }),
              let verification = cited.last(where: { $0.kind == .verification }),
              verification.order > correction.order,
              // A later uncited correction invalidates a stale successful test.
              !evidence.contains(where: { ($0.kind == .correction || $0.kind == .failure) && $0.order > verification.order }),
              // All observed failing invocations need a later matching pass.
              // This establishes observations, never certain causality.
              evidence.filter({ $0.kind == .failure }).allSatisfy({ failure in
                  failure.invocation != nil && evidence.contains(where: {
                      $0.kind == .verification && $0.invocation == failure.invocation && $0.order > failure.order
                  })
              }) else { return nil }
        switch kind {
        case .lesson:
            guard let failure = cited.first(where: { $0.kind == .failure }),
                  failure.order < correction.order, failure.invocation != nil,
                  failure.invocation == verification.invocation, !causeReferences.isEmpty,
                  causeReferences.contains(where: { id in cited.contains { $0.id == id && ($0.kind == .projectFile || $0.kind == .correction) } }),
                  let prevention, MemoryLearningPrivacy.accepts(prevention, limit: 250),
                  prevention.contains(correction.location), correction.location != "." else { return nil }
        case .decision: return nil // handled above, without requiring a test
        case .fact: break
        }
        }
        let sources = cited.map { "\($0.id)@\($0.location)" }.joined(separator: ", ")
        let text = "Summary: \(content)\nState: verified project \(kind.rawValue)\nNext: \(prevention ?? "Recheck when project changes.")\nSources: \(sources)"
        guard MemoryLearningPrivacy.accepts(text, limit: 1000), MemoryLearningPrivacy.accepts(workspace, limit: 300) else { return nil }
        return text
    }
}
