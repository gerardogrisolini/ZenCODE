import Foundation
import Testing
@testable import ToolCore

/// Parity of `SubAgentToolRequestCompatibility.canonicalToolName(for:)` with
/// the regex-and-folding implementation it replaced.
///
/// `LegacyCanonicalToolName` is that implementation verbatim, except that its
/// folding locale is pinned to `en_US_POSIX`: the legacy code folded with
/// `Locale.current`, so its expected values would otherwise depend on the
/// locale of the test process (a Turkish locale folds `I` to a dotless `ı`).
@Suite
struct SubAgentToolRequestCompatibilityParityTests {
    @Test
    func canonicalNamesAndKnownAliasesMatchTheLegacyImplementation() {
        let names = Self.canonicalNames + Self.knownAliases
        Self.expectLegacyParity(names)
        for name in Self.canonicalNames {
            #expect(SubAgentToolRequestCompatibility.canonicalToolName(for: name) == name)
        }
    }

    @Test
    func structuredAliasCombinationsMatchTheLegacyImplementation() {
        let names = Self.structuredAliases()
        let recognized = names.filter {
            SubAgentToolRequestCompatibility.canonicalToolName(for: $0) != nil
        }
        // The corpus must exercise both recognized and rejected names.
        #expect(recognized.count > 10_000)
        #expect(names.count - recognized.count > 10_000)
        Self.expectLegacyParity(names)
    }

    @Test
    func tokenTriplesMatchTheLegacyImplementation() {
        let vocabulary = Self.domainWords + Self.actionWords + ["tool", "functions", "x", "2"]
        var names: [String] = []
        names.reserveCapacity(vocabulary.count * vocabulary.count * vocabulary.count)
        for first in vocabulary {
            for second in vocabulary {
                for third in vocabulary {
                    names.append("\(first).\(second)_\(third)")
                }
            }
        }
        Self.expectLegacyParity(names)
    }

    @Test
    func everyASCIICharacterMatchesTheLegacyImplementation() {
        var names: [String] = []
        for value in UInt8(0)..<UInt8(128) {
            let character = String(UnicodeScalar(value))
            names.append("todo\(character)read")
            names.append("TODO\(character)READ")
            names.append("\(character)agent.create")
            names.append("agent.create\(character)")
            names.append("ag\(character)ent.create")
            names.append("tasks.cre\(character)ate")
            names.append("tool\(character)agent\(character)wait\(character)2")
        }
        Self.expectLegacyParity(names)
    }

    @Test
    func nonASCIICharactersMatchTheLegacyImplementation() {
        let ranges: [ClosedRange<UInt32>] = [
            0x80...0x24F,     // Latin-1 Supplement, Latin Extended-A/B
            0x300...0x36F,    // Combining Diacritical Marks
            0x370...0x3FF,    // Greek
            0x400...0x45F,    // Cyrillic
            0x1E00...0x1EFF,  // Latin Extended Additional
            0x2000...0x206F,  // General Punctuation
            0x2100...0x214F,  // Letterlike Symbols (Kelvin, Angstrom)
            0xFB00...0xFB06,  // Latin ligatures
            0xFF01...0xFF5E,  // Fullwidth ASCII
        ]
        var names: [String] = [
            "tódo.réad", "TÓDO.RÉAD", "AGENT.CRÉATE", "ágent_spawn", "agent\u{301}.create",
            "todo\u{301}.read", "to\u{301}do.read", "tasks.lïst", "subagénts.wäit.2",
            "ｔｏｄｏ.read", "agent.\u{212A}ill", "tasks.ﬁx", "İnspect.agent", "agent.ınspect",
            "agent.inspect\u{0130}", "agent.straße", "agent🚀create", "agent.创建", "agent\u{200B}.create",
            "tool\u{00A0}agent\u{00A0}close", "\u{FEFF}tasks.cancel", "tasks.cancel\r\n", "tasks\u{2028}list",
        ]
        for range in ranges {
            for value in range {
                guard let scalar = UnicodeScalar(value) else { continue }
                let character = String(scalar)
                names.append("todo\(character)read")
                names.append("agent.cr\(character)ate")
                names.append("t\(character)sks.list")
                names.append("\(character)tasks.get")
                names.append("TODO\(character)WRITE")
            }
        }
        Self.expectLegacyParity(names)
    }

    @Test
    func seededRandomNamesMatchTheLegacyImplementation() {
        var generator = SplitMix64(seed: 0x5EED_CAFE_F00D)
        let words = Self.domainWords + Self.actionWords + ["tool", "functions", "mcp", "2", "10", "x", ""]
        let separators = [".", "_", "-", " ", "/", ":", "__", "", "\t", "é", "·", "—", "\u{301}", "ı", "İ"]
        var names: [String] = []
        for _ in 0..<20_000 {
            var name = ""
            for index in 0..<Int.random(in: 1...4, using: &generator) {
                if index > 0 || Bool.random(using: &generator) {
                    name += separators.randomElement(using: &generator)!
                }
                let word = words.randomElement(using: &generator)!
                name += String(word.map { character in
                    Bool.random(using: &generator) ? Character(character.uppercased()) : character
                })
            }
            names.append(name)
        }
        Self.expectLegacyParity(names)
    }

    @Test
    func uppercaseAliasesResolveWithoutTheProcessLocale() {
        // The legacy folding used `Locale.current`: under a Turkish locale it
        // folded `I` to a dotless `ı`, which then split `LIST` into `l`/`st`.
        // ASCII names are now lowercased by a fixed ASCII mapping.
        #expect(SubAgentToolRequestCompatibility.canonicalToolName(for: "TASKS.LIST") == "tasks.list")
        #expect(SubAgentToolRequestCompatibility.canonicalToolName(for: "AGENT.INSPECT") == "agent.get")
        #expect(SubAgentToolRequestCompatibility.canonicalToolName(for: "TODO.WRITE") == "todo.write")
    }

    // MARK: - Corpus

    private static let canonicalNames = [
        "todo.read", "todo.write",
        "tasks.create", "tasks.list", "tasks.get", "tasks.update", "tasks.retry", "tasks.cancel",
        "agent.create", "agent.list", "agent.get", "agent.message", "agent.wait", "agent.close",
    ]

    /// Aliases asserted by the existing executor, allowlist, and adapter tests.
    private static let knownAliases = [
        "agent.spawn", "agent_spawn", "subagent.create", "todo.update", "todo_update", "tasks_update",
        "AGENT.SPAWN", "Agent.Create", "tool_agent_create", "agents.wait.2", "agent_send",
        "external.agent.create", "tasks.stop", "tasks_list", "task.update", "task.create", "task_create",
        "task.list", "task_list", "task.get", "task_get", "task.retry", "task_retry", "task.cancel",
        "task_cancel", "tasks", "agents", "send_input", "retry_task", "cancel_task", "local.readFile",
        "LOCAL.readFile", "figma.get_code", "git.commit", "remote.tool", "", " ", "tool", "tool_",
        "todo", "todos.list", "subagents.join", "agents.input", "tool_tool_agent_create",
    ]

    private static let domainWords = [
        "todo", "todos", "task", "tasks", "agent", "agents", "subagent", "subagents",
    ]

    private static let actionWords = [
        "read", "write", "update", "upsert", "append", "replace", "create", "add", "new", "list",
        "get", "status", "show", "inspect", "set", "retry", "rerun", "restart", "cancel", "stop",
        "close", "spawn", "message", "send", "input", "wait", "join", "foo",
    ]

    private static func structuredAliases() -> [String] {
        let separators = [".", "_", "-", " ", "/", "::", ""]
        let casings: [(String) -> String] = [
            { $0 },
            { $0.uppercased() },
            { $0.prefix(1).uppercased() + $0.dropFirst() },
        ]
        let prefixes = ["", "tool_", "tool.", "TOOL-", "functions.", "mcp__server__", "tool_tool_"]
        let suffixes = ["", ".2", "_10", " 3 4", "-v2"]
        var names: [String] = []
        for domain in domainWords {
            for action in actionWords {
                let orders = [(domain, action), (action, domain)]
                for (first, second) in orders {
                    for separator in separators {
                        for casing in casings {
                            names.append(casing(first) + separator + casing(second))
                        }
                    }
                    for prefix in prefixes {
                        for suffix in suffixes {
                            names.append("\(prefix)\(first)_\(second)\(suffix)")
                        }
                    }
                }
            }
        }
        return names
    }

    private static func expectLegacyParity(
        _ names: [String],
        sourceLocation: SourceLocation = #_sourceLocation
    ) {
        let mismatches = names.compactMap { name -> String? in
            let expected = LegacyCanonicalToolName.canonicalToolName(for: name)
            let actual = SubAgentToolRequestCompatibility.canonicalToolName(for: name)
            guard actual != expected else { return nil }
            return "\(name.debugDescription): expected \(expected ?? "nil"), got \(actual ?? "nil")"
        }
        #expect(
            mismatches.isEmpty,
            "\(mismatches.count) of \(names.count) names differ: \(mismatches.prefix(20).joined(separator: "; "))",
            sourceLocation: sourceLocation
        )
    }
}

/// Deterministic generator so the random corpus is reproducible.
private struct SplitMix64: RandomNumberGenerator {
    private var state: UInt64

    init(seed: UInt64) {
        state = seed
    }

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var value = state
        value = (value ^ (value >> 30)) &* 0xBF58_476D_1CE4_E5B9
        value = (value ^ (value >> 27)) &* 0x94D0_49BB_1331_11EB
        return value ^ (value >> 31)
    }
}

/// The replaced implementation, kept verbatim as the parity reference apart
/// from the pinned folding locale.
private enum LegacyCanonicalToolName {
    private static let locale = Locale(identifier: "en_US_POSIX")

    static func canonicalToolName(for rawName: String) -> String? {
        let tokens = normalizedNameTokens(from: rawName)
        guard let domain = primaryDomain(in: tokens),
              let action = canonicalAction(in: tokens, domain: domain) else {
            return nil
        }

        switch (domain, action) {
        case (.todo, .read):
            return "todo.read"
        case (.todo, .write):
            return "todo.write"
        case (.task, .create):
            return "tasks.create"
        case (.task, .list):
            return "tasks.list"
        case (.task, .get):
            return "tasks.get"
        case (.task, .update):
            return "tasks.update"
        case (.task, .retry):
            return "tasks.retry"
        case (.task, .cancel):
            return "tasks.cancel"
        case (.agent, .create):
            return "agent.create"
        case (.agent, .list):
            return "agent.list"
        case (.agent, .get):
            return "agent.get"
        case (.agent, .message):
            return "agent.message"
        case (.agent, .wait):
            return "agent.wait"
        case (.agent, .close):
            return "agent.close"
        default:
            return nil
        }
    }

    private enum ToolDomain {
        case todo
        case task
        case agent
    }

    private enum CanonicalAction {
        case read
        case write
        case create
        case list
        case get
        case update
        case retry
        case cancel
        case message
        case wait
        case close
    }

    private static func normalizedNameTokens(from rawName: String) -> [String] {
        let foldedName = rawName.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: locale)
        let separatedName = foldedName.replacingOccurrences(of: #"[^a-z0-9]+"#, with: " ", options: .regularExpression)
        var tokens = separatedName.split(whereSeparator: \.isWhitespace).map(String.init)

        if tokens.first == "tool" {
            tokens.removeFirst()
        }

        while let lastToken = tokens.last,
              lastToken.allSatisfy(\.isNumber) {
            tokens.removeLast()
        }

        return tokens
    }

    private static func primaryDomain(in tokens: [String]) -> ToolDomain? {
        for token in tokens {
            switch token {
            case "todo", "todos":
                return .todo
            case "tasks":
                return .task
            case "agent", "agents", "subagent", "subagents":
                return .agent
            default:
                continue
            }
        }

        return nil
    }

    private static func canonicalAction(in tokens: [String], domain: ToolDomain) -> CanonicalAction? {
        for token in tokens.reversed() {
            switch domain {
            case .todo:
                switch token {
                case "read", "list":
                    return .read
                case "write", "update", "upsert", "append", "replace":
                    return .write
                default:
                    continue
                }
            case .task:
                switch token {
                case "create", "add", "new":
                    return .create
                case "list":
                    return .list
                case "get", "status", "show", "inspect", "read":
                    return .get
                case "update", "write", "set":
                    return .update
                case "retry", "rerun", "restart":
                    return .retry
                case "cancel", "stop", "close":
                    return .cancel
                default:
                    continue
                }
            case .agent:
                switch token {
                case "create", "spawn", "new":
                    return .create
                case "list":
                    return .list
                case "get", "status", "show", "inspect", "read":
                    return .get
                case "message", "send", "input":
                    return .message
                case "wait", "join":
                    return .wait
                case "close", "stop", "cancel":
                    return .close
                default:
                    continue
                }
            }
        }

        return nil
    }
}
