import Foundation
import Testing
import ToolCore
@testable import ZenCODECore

extension DirectSubAgentRuntimeTests {
    @Test
    func agentCreateDescriptorUsesOneCanonicalBatchContract() throws {
        let descriptor = try #require(
            DirectToolCatalog.subAgentDescriptors.first { $0.name == "agent.create" }
        )

        #expect(descriptor.description.contains("canonical agents array"))
        #expect(descriptor.description.contains("each item requires exactly one of profile or profileRole."))
        #expect(descriptor.description.contains("omit model to inherit the main session model"))
        #expect(!descriptor.description.contains("each item requires profile and model"))
        #expect(descriptor.description.contains("exact profile and binding references"))
        #expect(descriptor.description.contains("taskID is never a root argument"))
        #expect(descriptor.description.contains("same profile inherits the coordinator's effective session allowlist"))
        #expect(!descriptor.description.contains("The selected profile owns the child tool grant"))
        #expect(!descriptor.description.contains(TaskRecord.agentSelectionPolicy))
        #expect(!descriptor.inputSchema.contains("\"modelID\""))
        #expect(!descriptor.inputSchema.contains("toolNames"))
        #expect(!descriptor.inputSchema.contains("oneOf"))
        #expect(!descriptor.inputSchema.contains("not"))
    }

    @Test
    func agentCreateDescriptorAdvertisesProviderNeutralBatchSchema() throws {
        let descriptor = try #require(
            DirectToolCatalog.subAgentDescriptors.first { $0.name == "agent.create" }
        )
        let schema = try #require(descriptor.schemaObject as? [String: Any])
        let properties = try #require(schema["properties"] as? [String: Any])

        #expect(Set(properties.keys) == ["agents"])
        #expect(schema["required"] as? [String] == ["agents"])
        #expect(schema["additionalProperties"] as? Bool == false)
        #expect(schema["oneOf"] == nil)
        #expect(schema["not"] == nil)

        let agents = try #require(properties["agents"] as? [String: Any])
        #expect(agents["type"] as? String == "array")
        #expect((agents["minItems"] as? NSNumber)?.intValue == 1)
        #expect((agents["maxItems"] as? NSNumber)?.intValue == 8)

        let item = try #require(agents["items"] as? [String: Any])
        let itemProperties = try #require(item["properties"] as? [String: Any])
        #expect(
            Set(itemProperties.keys) == [
                "profile", "model", "taskID", "prompt", "name", "role",
                "profileRole", "complexity", "workingDirectory",
            ]
        )
        // Exactly one of profile/profileRole is enforced at runtime, so the
        // item schema must not mark either as required.
        #expect(item["required"] == nil)
        #expect(item["additionalProperties"] as? Bool == false)

        let profileRole = try #require(itemProperties["profileRole"] as? [String: Any])
        #expect(profileRole["type"] as? String == "string")
        #expect(
            profileRole["enum"] as? [String] == AgentProfileRole.allCases.map(\.rawValue)
        )
        #expect(
            (profileRole["description"] as? String)?.contains("Exclusive with profile") == true
        )

        let complexity = try #require(itemProperties["complexity"] as? [String: Any])
        #expect(complexity["type"] as? String == "integer")
        #expect((complexity["minimum"] as? NSNumber)?.intValue == 1)
        #expect((complexity["maximum"] as? NSNumber)?.intValue == 10)
        #expect(
            (complexity["description"] as? String)?.contains(TaskRecord.complexityRubric) == true
        )

        let workingDirectory = try #require(
            itemProperties["workingDirectory"] as? [String: Any]
        )
        #expect(workingDirectory["type"] as? String == "string")

        for legacyKey in [
            "agent", "agentName", "agent_name", "agentID", "agent_id",
            "profileName", "profile_name", "modelID", "model_id", "task_id",
            "message", "initialPrompt", "initial_prompt", "title", "items",
        ] {
            #expect(properties[legacyKey] == nil)
            #expect(itemProperties[legacyKey] == nil)
        }

        let wireCatalog = RemoteToolWireCatalog(descriptors: [descriptor])
        let responsesPayload = try #require(wireCatalog.responsesToolPayloads.first)
        let responsesParameters = try #require(
            responsesPayload["parameters"] as? [String: Any]
        )
        let chatPayload = try #require(wireCatalog.chatCompletionToolPayloads.first)
        let function = try #require(chatPayload["function"] as? [String: Any])
        let chatParameters = try #require(function["parameters"] as? [String: Any])
        for parameters in [responsesParameters, chatParameters] {
            #expect(parameters["required"] as? [String] == ["agents"])
            #expect(parameters["oneOf"] == nil)
            let wireProperties = try #require(parameters["properties"] as? [String: Any])
            let wireAgents = try #require(wireProperties["agents"] as? [String: Any])
            let wireItem = try #require(wireAgents["items"] as? [String: Any])
            #expect(wireItem["required"] == nil)
            let wireItemProperties = try #require(wireItem["properties"] as? [String: Any])
            #expect(
                Set(wireItemProperties.keys) == Set(itemProperties.keys)
            )
            let wireProfileRole = try #require(
                wireItemProperties["profileRole"] as? [String: Any]
            )
            #expect(
                wireProfileRole["enum"] as? [String] == AgentProfileRole.allCases.map(\.rawValue)
            )
        }
    }

    @Test
    func agentCreateParserSupportsCanonicalRootAndBatchForms() throws {
        let root = try DirectSubAgentRuntime.requestedAgentPayloads(
            from: [
                "name": .string("root-worker"),
                "profile": .string("Developer"),
                "model": .string("balanced"),
            ]
        )
        #expect(root.count == 1)
        #expect(root[0].name == "root-worker")
        #expect(root[0].profileReference == "Developer")

        let batch = try DirectSubAgentRuntime.requestedAgentPayloads(
            from: [
                "agents": .array([
                    .object([
                        "name": .string("first"),
                        "profile": .string("Developer"),
                        "model": .string("balanced"),
                    ]),
                    .object([
                        "name": .string("second"),
                        "profile": .string("Reviewer"),
                        "model": .string("fast"),
                    ]),
                ]),
            ]
        )
        #expect(batch.map(\.name) == ["first", "second"])
        #expect(batch.map(\.profileReference) == ["Developer", "Reviewer"])

        let legacyObjectBatch = try DirectSubAgentRuntime.requestedAgentPayloads(
            from: [
                "items": .object([
                    "title": .string("legacy-batch-worker"),
                    "agent": .string("Developer"),
                    "modelID": .string("balanced"),
                ]),
            ]
        )
        #expect(legacyObjectBatch.count == 1)
        #expect(legacyObjectBatch[0].name == "legacy-batch-worker")
        #expect(legacyObjectBatch[0].profileReference == "Developer")
        #expect(legacyObjectBatch[0].requestedModelID == "balanced")

        let matchingCanonicalAndLegacyBatches = try DirectSubAgentRuntime.requestedAgentPayloads(
            from: [
                "agents": .array([
                    .object([
                        "name": .string("equivalent"),
                        "profile": .string("Developer"),
                        "model": .string("balanced"),
                    ]),
                ]),
                "items": .array([
                    .object([
                        "title": .string("equivalent"),
                        "agent": .string("developer"),
                        "modelID": .string("BALANCED"),
                    ]),
                ]),
            ]
        )
        #expect(matchingCanonicalAndLegacyBatches.count == 1)
        #expect(matchingCanonicalAndLegacyBatches[0].name == "equivalent")

        do {
            _ = try DirectSubAgentRuntime.requestedAgentPayloads(
                from: [
                    "profile": .string("Developer"),
                    "agents": .array([
                        .object(["profile": .string("Reviewer")]),
                    ]),
                ]
            )
            Issue.record("Expected mixed root and batch forms to be rejected.")
        } catch DirectSubAgentRuntimeError.invalidArgument(let message) {
            #expect(message.contains("root agent fields"))
        }
    }

    @Test
    func agentCreateParserIgnoresBlankAliasesAndAcceptsEquivalentLegacyValues() throws {
        let payload = try DirectSubAgentRuntime.requestedAgentPayload(
            from: .object([
                "name": .string("   "),
                "title": .string("legacy-worker"),
                "profile": .string("  "),
                "agent": .string("Developer"),
                "agentName": .string("developer"),
                "model": .string("  "),
                "modelID": .string("Deep"),
                "model_id": .string("deep"),
                "taskID": .string("\n"),
                "task_id": .string("task-1"),
                "prompt": .string("\t"),
                "message": .string("Inspect the parser"),
            ]),
            fallbackIndex: 0
        )

        #expect(payload.name == "legacy-worker")
        #expect(payload.profileReference == "Developer")
        #expect(payload.requestedModelID == "Deep")
        #expect(payload.taskID == "task-1")
        #expect(payload.prompt == "Inspect the parser")
    }

    @Test
    func agentCreateParserRejectsConflictingAliasesAndBatches() throws {
        do {
            _ = try DirectSubAgentRuntime.requestedAgentPayload(
                from: .object([
                    "profile": .string("Developer"),
                    "agent": .string("Reviewer"),
                ]),
                fallbackIndex: 0
            )
            Issue.record("Expected conflicting profile aliases to be rejected.")
        } catch DirectSubAgentRuntimeError.invalidArgument(let message) {
            #expect(message.contains("profile aliases"))
            #expect(message.contains("profile, agent"))
        }

        do {
            _ = try DirectSubAgentRuntime.requestedAgentPayloads(
                from: [
                    "agents": .array([.object(["profile": .string("Developer")])]),
                    "items": .array([.object(["profile": .string("Reviewer")])]),
                ]
            )
            Issue.record("Expected conflicting batch aliases to be rejected.")
        } catch DirectSubAgentRuntimeError.invalidArgument(let message) {
            #expect(message.contains("batch aliases"))
            #expect(message.contains("agents, items"))
        }
    }

    @Test
    func agentCreateParserRejectsMalformedAliasesAndBatchRootOverrides() throws {
        #expect(throws: DirectSubAgentRuntimeError.self) {
            try DirectSubAgentRuntime.requestedAgentPayloads(
                from: [
                    "agents": .string("not-a-batch"),
                    "items": .array([
                        .object([
                            "profile": .string("Developer"),
                            "model": .string("binding:developer"),
                        ]),
                    ]),
                ]
            )
        }

        #expect(throws: DirectSubAgentRuntimeError.self) {
            try DirectSubAgentRuntime.requestedAgentPayloads(
                from: [
                    "agents": .array([.string("not-an-object")]),
                ]
            )
        }

        #expect(throws: DirectSubAgentRuntimeError.self) {
            try DirectSubAgentRuntime.requestedAgentPayloads(
                from: [
                    "agents": .array([
                        .object([
                            "profile": .string("Developer"),
                            "model": .string("binding:developer"),
                        ]),
                    ]),
                    "tools": .array([.string("local.exec")]),
                ]
            )
        }

        #expect(throws: DirectSubAgentRuntimeError.self) {
            try DirectSubAgentRuntime.requestedAgentPayload(
                from: .object([
                    "profile": .string("Developer"),
                    "model": .object(["unexpected": .bool(true)]),
                ]),
                fallbackIndex: 0
            )
        }
    }

    @Test
    func agentCreateParserReadsNewFieldsFromCanonicalAndSnakeCaseKeys() throws {
        let canonical = try DirectSubAgentRuntime.requestedAgentPayload(
            from: .object([
                "profileRole": .string("planner"),
                "complexity": .number(7),
                "workingDirectory": .string("Sources/ZenCODECore"),
            ]),
            fallbackIndex: 0
        )
        #expect(canonical.profileRole == .planner)
        #expect(canonical.complexity == 7)
        #expect(canonical.workingDirectory == "Sources/ZenCODECore")
        // An item without profile still parses: the "exactly one of profile
        // and profileRole" rule and the missing-profile error are runtime concerns.
        #expect(canonical.profileReference == nil)

        let snakeCase = try DirectSubAgentRuntime.requestedAgentPayload(
            from: .object([
                "profile_role": .string("  Reviewer  "),
                "working_directory": .string("  Tests  "),
            ]),
            fallbackIndex: 0
        )
        #expect(snakeCase.profileRole == .reviewer)
        #expect(snakeCase.workingDirectory == "Tests")
        #expect(snakeCase.complexity == nil)

        let matchingAliases = try DirectSubAgentRuntime.requestedAgentPayload(
            from: .object([
                "profileRole": .string("builder"),
                "profile_role": .string("BUILDER"),
                "workingDirectory": .string("Docs"),
                "working_directory": .string("Docs"),
            ]),
            fallbackIndex: 0
        )
        #expect(matchingAliases.profileRole == .builder)
        #expect(matchingAliases.workingDirectory == "Docs")

        // Blank values are ignored so they cannot shadow an informative alias.
        let blankShadow = try DirectSubAgentRuntime.requestedAgentPayload(
            from: .object([
                "profileRole": .string("  "),
                "profile_role": .string("promoter"),
                "workingDirectory": .string("\n"),
                "working_directory": .string("Sources"),
                "complexity": .string("  "),
            ]),
            fallbackIndex: 0
        )
        #expect(blankShadow.profileRole == .promoter)
        #expect(blankShadow.workingDirectory == "Sources")
        #expect(blankShadow.complexity == nil)

        let absent = try DirectSubAgentRuntime.requestedAgentPayload(
            from: .object(["profile": .string("Developer")]),
            fallbackIndex: 0
        )
        #expect(absent.profileRole == nil)
        #expect(absent.complexity == nil)
        #expect(absent.workingDirectory == nil)

        for role in AgentProfileRole.allCases {
            let payload = try DirectSubAgentRuntime.requestedAgentPayload(
                from: .object(["profileRole": .string(role.rawValue)]),
                fallbackIndex: 0
            )
            #expect(payload.profileRole == role)
        }
    }

    @Test
    func agentCreateParserAcceptsIntegerComplexityFromOneToTen() throws {
        for value in 1...10 {
            for json in [JSONValue.number(Double(value)), .string(" \(value) ")] {
                let payload = try DirectSubAgentRuntime.requestedAgentPayload(
                    from: .object(["complexity": json]),
                    fallbackIndex: 0
                )
                #expect(payload.complexity == value)
            }
        }
    }

    @Test
    func agentCreateParserRejectsUnknownProfileRole() throws {
        for json in [
            JSONValue.string("architect"),
            .string("developers"),
            .object(["role": .string("developer")]),
        ] {
            #expect(throws: DirectSubAgentRuntimeError.self) {
                try DirectSubAgentRuntime.requestedAgentPayload(
                    from: .object(["profileRole": json]),
                    fallbackIndex: 0
                )
            }
        }

        do {
            _ = try DirectSubAgentRuntime.requestedAgentPayload(
                from: .object(["profile_role": .string("architect")]),
                fallbackIndex: 0
            )
            Issue.record("Expected an unknown profileRole to be rejected.")
        } catch DirectSubAgentRuntimeError.invalidArgument(let message) {
            #expect(
                message == "agent.create profileRole must be one of: "
                    + "developer, builder, minimal, planner, reviewer, reporter, organizer, promoter, tester"
            )
        }
    }

    @Test
    func agentCreateParserRejectsOutOfRangeOrNonIntegerComplexity() throws {
        for json in [
            JSONValue.number(0),
            .number(11),
            .number(-3),
            .number(2.5),
            .number(.nan),
            .string("0"),
            .string("11"),
            .string("3.5"),
            .string("high"),
            .bool(true),
            .null,
            .array([.number(5)]),
        ] {
            do {
                _ = try DirectSubAgentRuntime.requestedAgentPayload(
                    from: .object(["complexity": json]),
                    fallbackIndex: 0
                )
                Issue.record("Expected complexity \(json) to be rejected.")
            } catch DirectSubAgentRuntimeError.invalidArgument(let message) {
                #expect(message == "agent.create complexity must be an integer from 1 to 10")
            }
        }
    }

    @Test
    func agentCreateParserRejectsConflictingNewFieldAliases() throws {
        do {
            _ = try DirectSubAgentRuntime.requestedAgentPayload(
                from: .object([
                    "profileRole": .string("developer"),
                    "profile_role": .string("reviewer"),
                ]),
                fallbackIndex: 0
            )
            Issue.record("Expected conflicting profileRole aliases to be rejected.")
        } catch DirectSubAgentRuntimeError.invalidArgument(let message) {
            #expect(message.contains("profileRole aliases"))
            #expect(message.contains("profileRole, profile_role"))
        }

        do {
            _ = try DirectSubAgentRuntime.requestedAgentPayload(
                from: .object([
                    "workingDirectory": .string("Sources"),
                    "working_directory": .string("Tests"),
                ]),
                fallbackIndex: 0
            )
            Issue.record("Expected conflicting workingDirectory aliases to be rejected.")
        } catch DirectSubAgentRuntimeError.invalidArgument(let message) {
            #expect(message.contains("workingDirectory aliases"))
            #expect(message.contains("workingDirectory, working_directory"))
        }
    }

    @Test
    func agentCreateParserTreatsNewFieldsAsRootFieldsInBatchesAndComparesThemAcrossAliases() throws {
        let rootFields: [(String, JSONValue)] = [
            ("profileRole", .string("developer")),
            ("profile_role", .string("developer")),
            ("complexity", .number(5)),
            ("workingDirectory", .string("Sources")),
            ("working_directory", .string("Sources")),
        ]
        for (key, value) in rootFields {
            do {
                _ = try DirectSubAgentRuntime.requestedAgentPayloads(
                    from: [
                        key: value,
                        "agents": .array([.object(["profile": .string("Developer")])]),
                    ]
                )
                Issue.record("Expected root \(key) mixed with a batch to be rejected.")
            } catch DirectSubAgentRuntimeError.invalidArgument(let message) {
                #expect(message.contains("root agent fields"))
            }
        }

        // The same fields at the root alone form a single agent.
        let root = try DirectSubAgentRuntime.requestedAgentPayloads(
            from: [
                "profile_role": .string("reviewer"),
                "complexity": .number(4),
                "working_directory": .string("Tests"),
            ]
        )
        #expect(root.count == 1)
        #expect(root[0].profileRole == .reviewer)
        #expect(root[0].complexity == 4)
        #expect(root[0].workingDirectory == "Tests")

        let matching = try DirectSubAgentRuntime.requestedAgentPayloads(
            from: [
                "agents": .array([
                    .object([
                        "profileRole": .string("planner"),
                        "complexity": .number(6),
                        "workingDirectory": .string("Sources"),
                    ]),
                ]),
                "items": .array([
                    .object([
                        "profile_role": .string("Planner"),
                        "complexity": .string("6"),
                        "working_directory": .string("Sources"),
                    ]),
                ]),
            ]
        )
        #expect(matching.count == 1)
        #expect(matching[0].profileRole == .planner)
        #expect(matching[0].complexity == 6)
        #expect(matching[0].workingDirectory == "Sources")

        let variations: [[String: JSONValue]] = [
            ["profile_role": .string("reviewer"), "complexity": .number(6), "working_directory": .string("Sources")],
            ["profile_role": .string("planner"), "complexity": .number(7), "working_directory": .string("Sources")],
            ["profile_role": .string("planner"), "complexity": .number(6), "working_directory": .string("Tests")],
        ]
        for variation in variations {
            do {
                _ = try DirectSubAgentRuntime.requestedAgentPayloads(
                    from: [
                        "agents": .array([
                            .object([
                                "profileRole": .string("planner"),
                                "complexity": .number(6),
                                "workingDirectory": .string("Sources"),
                            ]),
                        ]),
                        "items": .array([.object(variation)]),
                    ]
                )
                Issue.record("Expected batches differing in a new field to be rejected.")
            } catch DirectSubAgentRuntimeError.invalidArgument(let message) {
                #expect(message.contains("batch aliases"))
            }
        }
    }

    @Test
    func createRejectsOversizedBatches() async throws {
        let runtime = DirectSubAgentRuntime(
            contextualBackendFactory: { _ in CapturingSubAgentRuntimeBackend() },
            profileResolver: builtInDirectSubAgentProfileResolver
        )
        let oversized = (0...DirectSubAgentRuntime.maximumAgentsPerCreate).map { index in
            JSONValue.object(["name": .string("report-\(index)")])
        }

        await #expect(throws: DirectSubAgentRuntimeError.self) {
            _ = try await runtime.createAgents(
                arguments: ["agents": .array(oversized)],
                workingDirectory: URL(fileURLWithPath: "/tmp/ZenCODE-sub-agent-tests"),
                parentAllowedToolNames: nil
            )
        }
        #expect(await runtime.snapshots().isEmpty)
    }
}
