import FeatureKit
import Foundation
import LocalToolsSupport
import Testing
import ToolCore
@testable import ZenCODECore

@Suite
struct DirectToolCatalogSchemaTests {
    @Test
    func everyBuiltInDirectToolOwnsAValidPresentationDefinition() {
        let descriptors = DirectToolCatalog.baseDescriptors
        let missing = descriptors
            .filter { $0.presentation == nil }
            .map(\.name)
            .sorted()
        let invalid = descriptors
            .filter { $0.presentation?.isSemanticallyValid == false }
            .map(\.name)
            .sorted()

        #expect(missing.isEmpty)
        #expect(invalid.isEmpty)
    }

    @Test
    func coreReadAndMutatingDescriptorsPartitionTheClassifiedCoreCatalog() {
        let readNames = Set(DirectToolCatalog.coreReadDescriptors.map(\.name))
        let mutatingNames = Set(DirectToolCatalog.coreMutatingDescriptors.map(\.name))
        let expectedReadNames: Set<String> = [
            "local.pwd", "local.ls", "local.readFile", "local.readFiles", "local.inspectFile",
            "search.glob", "search.grep", "search.locate",
            "text.head", "text.tail", "text.sort", "text.wc",
            "skills.list", "skills.read",
            "memory.read", "memory.search", "memory.get",
            "todo.read", "tasks.list", "tasks.get", "tasks.update",
            "agent.list", "agent.get", "agent.wait"
        ]
        var expectedMutatingNames: Set<String> = [
            "local.writeFile", "local.replace", "local.editFile", "local.multiEdit",
            "local.append", "local.mkdir", "local.delete", "local.move", "local.applyPatch",
            "memory.write", "memory.update", "memory.archive", "memory.restore",
            "todo.write", "tasks.create", "tasks.retry", "tasks.cancel",
            "agent.create", "agent.message", "agent.close"
        ]
#if canImport(Darwin) || canImport(Glibc)
        expectedMutatingNames.formUnion(["local.exec", "exec.job"])
#endif
        let coreNames = Set(DirectToolCatalog.coreDescriptors.map(\.name))
        let unclassifiedNames = Set(DirectToolCatalog.featureDescriptors.map(\.name))

        #expect(readNames == expectedReadNames)
        #expect(mutatingNames == expectedMutatingNames)
        #expect(readNames.isDisjoint(with: mutatingNames))
        #expect(coreNames == readNames.union(mutatingNames))
        #expect(coreNames.isDisjoint(with: unclassifiedNames))
        #expect(
            Set(
                DirectToolCatalog.coreLocalFileAndTextDescriptors
                    .map(\.name)
                    .filter { $0.hasPrefix("search.") }
            ).isSubset(of: readNames)
        )
    }

    @Test
    func localEditSchemasExposeOnlyCanonicalTokenEfficientProperties() throws {
        for name in ["local.editFile", "local.replace"] {
            let descriptor = try #require(
                DirectToolCatalog.coreDescriptors.first { $0.name == name }
            )
            let schema = try #require(descriptor.schemaObject as? [String: Any])
            let properties = try #require(schema["properties"] as? [String: Any])
            #expect(Set(properties.keys) == ["path", "old", "new"])
            #expect(schema["required"] as? [String] == ["path", "old", "new"])
        }

        let descriptor = try #require(
            DirectToolCatalog.coreDescriptors.first { $0.name == "local.multiEdit" }
        )
        let schema = try #require(descriptor.schemaObject as? [String: Any])
        let properties = try #require(schema["properties"] as? [String: Any])
        #expect(Set(properties.keys) == ["path", "edits"])
        let edits = try #require(properties["edits"] as? [String: Any])
        let item = try #require(edits["items"] as? [String: Any])
        let itemProperties = try #require(item["properties"] as? [String: Any])
        #expect(Set(itemProperties.keys) == ["old", "new"])
        #expect(item["required"] as? [String] == ["old", "new"])
    }

    @Test
    func agentMessageSchemaExposesCanonicalLiveChatDestination() throws {
        let descriptor = try #require(
            DirectToolCatalog.subAgentDescriptors.first { $0.name == "agent.message" }
        )
        let schema = try #require(descriptor.schemaObject as? [String: Any])
        let properties = try #require(schema["properties"] as? [String: Any])
        let to = try #require(properties["to"] as? [String: Any])

        #expect(to["type"] as? String == "string")
        #expect(to["enum"] as? [String] == ["direct", "operator", "coordinator", "peers", "all"])
        #expect(Set(properties.keys) == [
            "id", "name", "task_id", "ids", "to", "message", "awaitReply", "replyTimeoutSeconds"
        ])
        #expect(properties["target"] == nil)
        #expect(properties["prompt"] == nil)
        #expect(properties["input"] == nil)
        let awaitReply = try #require(properties["awaitReply"] as? [String: Any])
        #expect(awaitReply["type"] as? String == "boolean")
        let replyTimeout = try #require(properties["replyTimeoutSeconds"] as? [String: Any])
        #expect(replyTimeout["type"] as? String == "number")
        #expect(schema["required"] as? [String] == ["message"])
    }

    @Test
    func taskToolSchemasExposeOnlyCanonicalTokenEfficientProperties() throws {
        let expectedProperties: [String: Set<String>] = [
            "tasks.create": ["graphID", "tasks"],
            "tasks.list": [
                "graphID", "status", "assigneeAgentID", "runnableOnly", "includeTerminal", "limit"
            ],
            "tasks.get": ["id", "graphID"],
            "tasks.update": [
                "id", "graphID", "title", "description", "status", "statusReason", "priority",
                "complexity", "dependsOn", "output", "error", "workflow", "evidence",
                "expectedRevision"
            ],
            "tasks.retry": ["id", "graphID", "expectedRevision"],
            "tasks.cancel": ["id", "graphID", "reason"]
        ]
        // Only tasks.create, tasks.get, tasks.retry and tasks.cancel require a field:
        // tasks.list takes none and tasks.update also has the id-less workflow mode.
        let expectedRequired: [String: [String]] = [
            "tasks.create": ["tasks"],
            "tasks.get": ["id"],
            "tasks.retry": ["id"],
            "tasks.cancel": ["id"]
        ]

        for (name, keys) in expectedProperties {
            let descriptor = try #require(
                DirectToolCatalog.coreDescriptors.first { $0.name == name }
            )
            let schema = try #require(descriptor.schemaObject as? [String: Any])
            let properties = try #require(schema["properties"] as? [String: Any])
            #expect(Set(properties.keys) == keys, "\(name) properties")
            #expect(schema["required"] as? [String] == expectedRequired[name], "\(name) required")
        }

        let create = try schemaProperties(of: "tasks.create")
        let tasks = try #require(create["tasks"] as? [String: Any])
        #expect(tasks["type"] as? String == "array")
        let item = try #require(tasks["items"] as? [String: Any])
        let itemProperties = try #require(item["properties"] as? [String: Any])
        #expect(Set(itemProperties.keys) == [
            "id", "title", "description", "order", "priority", "complexity",
            "dependsOn", "acceptanceCriteria", "execution"
        ])
        let priority = try #require(itemProperties["priority"] as? [String: Any])
        #expect(priority["enum"] as? [String] == ["low", "normal", "high"])
        let execution = try #require(itemProperties["execution"] as? [String: Any])
        let executionProperties = try #require(execution["properties"] as? [String: Any])
        #expect(Set(executionProperties.keys) == ["executor", "profile", "role", "fileScopes"])
        let executor = try #require(executionProperties["executor"] as? [String: Any])
        #expect(executor["enum"] as? [String] == ["coordinator", "sub_agent"])

        // The agent selection policy lives in the prompt, not in every complexity field.
        try expectCanonicalComplexityDescription(itemProperties["complexity"])
        let update = try schemaProperties(of: "tasks.update")
        try expectCanonicalComplexityDescription(update["complexity"])

        let description = try #require(update["description"] as? [String: Any])
        #expect(description["type"] as? [String] == ["string", "null"])
        let workflow = try #require(update["workflow"] as? [String: Any])
        let workflowProperties = try #require(workflow["properties"] as? [String: Any])
        #expect(Set(workflowProperties.keys) == ["state", "message"])
        #expect(workflow["required"] as? [String] == ["state"])
        #expect(workflow["additionalProperties"] as? Bool == false)
        let evidence = try #require(update["evidence"] as? [String: Any])
        #expect(evidence["type"] as? String == "array")
        #expect((evidence["items"] as? [String: Any])?.isEmpty == true)
    }

    @Test
    func todoWriteSchemaExposesOnlyTheCanonicalTodosArray() throws {
        let descriptor = try #require(
            DirectTodoRuntime.toolDescriptors.first { $0.name == "todo.write" }
        )
        let schema = try #require(descriptor.schemaObject as? [String: Any])
        let properties = try #require(schema["properties"] as? [String: Any])
        #expect(Set(properties.keys) == ["todos", "mode"])
        #expect(schema["required"] as? [String] == ["todos"])

        let todos = try #require(properties["todos"] as? [String: Any])
        #expect(todos["type"] as? String == "array")
        let item = try #require(todos["items"] as? [String: Any])
        let itemProperties = try #require(item["properties"] as? [String: Any])
        #expect(Set(itemProperties.keys) == ["id", "content", "status", "dependsOn"])
        #expect(item["required"] as? [String] == ["content"])
        #expect(descriptor.description.contains("Supports replace, append, and upsert modes."))
    }

    /// The descriptions keep each tool's own contract and leave the workflow,
    /// delegation, and chat policies to the prompt sections that state them
    /// once, so the same rule is not paid for several times per request.
    @Test
    func taskAndAgentDescriptionsKeepToolContractsWithoutRepeatingPromptPolicy() throws {
        func description(_ name: String) throws -> String {
            try #require(
                (DirectToolCatalog.subAgentDescriptors + DirectTodoRuntime.toolDescriptors)
                    .first { $0.name == name }
            ).description
        }

        let create = try description("tasks.create")
        #expect(create.contains("dependencies must reference tasks in the same graph"))
        #expect(create.contains("prefer safe, useful parallelism over list-order sequencing"))
        #expect(create.contains("keep direct work in the DAG with execution.executor coordinator"))
        #expect(create.contains("Delegation is optional: only for delegated work use execution.executor sub_agent"))
        #expect(create.contains("agent.create agents item's taskID field"))
        // The schema now exposes only the canonical `tasks` array, so the
        // description no longer warns against forms the model cannot see.
        #expect(!create.contains("legacy items alias"))

        let update = try description("tasks.update")
        #expect(update.contains("pass only graphID, expectedRevision (from tasks.list), and workflow"))
        #expect(update.contains("with no task field; originalGoal is immutable"))
        #expect(update.contains("Paused states require a message."))
        #expect(update.contains("Completing tasks does not close /goal"))
        #expect(update.contains("Text headings do not suspend or complete a workflow."))

        let agentCreate = try description("agent.create")
        #expect(agentCreate.contains("exactly one of profile or profileRole"))
        #expect(agentCreate.contains("model is required"))
        #expect(agentCreate.contains(
            "Different profiles retain their own tool grant; a child resolved to the coordinator's same profile "
                + "inherits the coordinator's effective session allowlist, including session-local additions and removals."
        ))
        #expect(agentCreate.contains(
            "Child-intrinsic skills, collaboration, and applicable task-reporting tools are added automatically."
        ))
        #expect(agentCreate.contains("claims its task atomically"))
        #expect(!agentCreate.contains("Legacy root fields"))

        let message = try description("agent.message")
        #expect(message.contains("wake idle or standby recipients immediately"))
        #expect(message.contains("Use the chat to clarify, steer, and query agents, including standby ones"))
        #expect(message.contains("a closed attempt cannot resume implementation"))
        #expect(message.contains("`awaitReply` true"))
        #expect(!message.contains("compatibility alias"))

        // tasks.retry now carries the retry mechanics on its own: the task
        // workflow and collaboration policies refer to it instead.
        let retry = try description("tasks.retry")
        #expect(retry.contains("Start a new direct attempt with tasks.update status in_progress"))
        #expect(retry.contains("a new delegated attempt through a canonical agent.create agents item containing `taskID`"))
        #expect(retry.contains("new implementation work needs this new attempt"))
    }

    @Test
    func coreLocalToolsAndDescriptorsFollowTheRegistryOrder() {
        let registryNames = (
            LocalFeatureTools.fileTools()
                + LocalFeatureTools.searchTools()
                + LocalFeatureTools.textTools()
        ).map(\.descriptor.name)

        #expect(DirectToolCatalog.coreLocalFileAndTextTools.map(\.descriptor.name) == registryNames)
        #expect(DirectToolCatalog.coreLocalFileAndTextDescriptors.map(\.name) == registryNames)
        for name in registryNames {
            #expect(DirectToolExecutor.isCoreLocalFileOrTextToolName(name))
        }
        #expect(!DirectToolExecutor.isCoreLocalFileOrTextToolName("local.exec"))
        #expect(!DirectToolExecutor.isCoreLocalFileOrTextToolName("search."))
    }

    private func schemaProperties(of name: String) throws -> [String: Any] {
        let descriptor = try #require(
            DirectToolCatalog.coreDescriptors.first { $0.name == name }
        )
        let schema = try #require(descriptor.schemaObject as? [String: Any])
        return try #require(schema["properties"] as? [String: Any])
    }

    private func expectCanonicalComplexityDescription(_ value: Any?) throws {
        let complexity = try #require(value as? [String: Any])
        #expect(complexity["type"] as? String == "integer")
        #expect((complexity["minimum"] as? NSNumber)?.intValue == 1)
        #expect((complexity["maximum"] as? NSNumber)?.intValue == 10)
        let description = try #require(complexity["description"] as? String)
        #expect(description.contains(TaskRecord.complexityRubric))
        #expect(!description.contains(TaskRecord.agentSelectionPolicy))
    }

    @Test
    func schemaObjectIsStableAcrossCallsAndRejectsMalformedSchemas() throws {
        let descriptor = DirectToolDescriptor(
            name: "fixture.schema",
            description: "Fixture",
            inputSchema: #"{"type":"object","required":["path"],"properties":{"path":{"type":"string"}}}"#
        )
        let first = try #require(descriptor.schemaObject as? [String: Any])
        let second = try #require(descriptor.schemaObject as? [String: Any])
        #expect(NSDictionary(dictionary: first).isEqual(to: second))
        #expect(first["required"] as? [String] == ["path"])

        let malformed = DirectToolDescriptor(
            name: "fixture.malformed",
            description: "Fixture",
            inputSchema: "{"
        )
        #expect(malformed.schemaObject == nil)
        #expect(malformed.schemaObject == nil)
    }

    @Test
    func schemaObjectStaysCorrectPastTheDecodedSchemaCacheLimit() throws {
        for index in 0..<600 {
            let descriptor = DirectToolDescriptor(
                name: "fixture.schema.\(index)",
                description: "Fixture",
                inputSchema: #"{"type":"object","title":"schema-\#(index)"}"#
            )
            let schema = try #require(descriptor.schemaObject as? [String: Any])
            #expect(schema["title"] as? String == "schema-\(index)")
        }
    }
}
