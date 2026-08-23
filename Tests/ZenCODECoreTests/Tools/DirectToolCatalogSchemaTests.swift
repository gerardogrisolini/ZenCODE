import Foundation
import Testing
import ToolCore
@testable import ZenCODECore

@Suite
struct DirectToolCatalogSchemaTests {
    @Test
    func everyBuiltInDirectToolOwnsAValidPresentationDefinition() {
        let descriptors = DirectToolCatalog.baseDescriptors
            + DirectToolCatalog.localSearchDescriptors
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
            "text.head", "text.tail", "text.sort", "text.wc",
            "skills.list", "skills.read",
            "memory.read", "memory.search",
            "todo.read", "tasks.list", "tasks.get", "tasks.update",
            "agent.list", "agent.get", "agent.wait"
        ]
        var expectedMutatingNames: Set<String> = [
            "local.writeFile", "local.replace", "local.editFile", "local.multiEdit",
            "local.append", "local.mkdir", "local.delete", "local.move", "local.applyPatch",
            "memory.write", "memory.update", "memory.archive",
            "todo.write", "tasks.create", "tasks.retry", "tasks.cancel",
            "agent.create", "agent.message", "agent.close"
        ]
#if canImport(Darwin) || canImport(Glibc)
        expectedMutatingNames.formUnion(["local.exec", "exec.job"])
#endif
        let coreNames = Set(DirectToolCatalog.coreDescriptors.map(\.name))
        let unclassifiedNames = Set(DirectToolCatalog.featureDescriptors.map(\.name))
            .union(DirectToolCatalog.localSearchDescriptors.map(\.name))

        #expect(readNames == expectedReadNames)
        #expect(mutatingNames == expectedMutatingNames)
        #expect(readNames.isDisjoint(with: mutatingNames))
        #expect(coreNames == readNames.union(mutatingNames))
        #expect(coreNames.isDisjoint(with: unclassifiedNames))
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
        #expect(properties["target"] != nil)
    }

    @Test
    func tasksCreateBatchSchemaExposesExecutionExecutor() throws {
        let descriptor = try #require(
            DirectToolCatalog.todoTaskDescriptors.first { $0.name == "tasks.create" }
        )
        let schema = try #require(descriptor.schemaObject as? [String: Any])
        let properties = try #require(schema["properties"] as? [String: Any])

        for batchKey in ["tasks", "items"] {
            let batch = try #require(properties[batchKey] as? [String: Any])
            let item = try #require(batch["items"] as? [String: Any])
            let itemProperties = try #require(item["properties"] as? [String: Any])
            let execution = try #require(itemProperties["execution"] as? [String: Any])
            let executionProperties = try #require(execution["properties"] as? [String: Any])
            let executor = try #require(executionProperties["executor"] as? [String: Any])

            #expect(executor["type"] as? String == "string")
            #expect(executor["enum"] as? [String] == ["coordinator", "sub_agent"])
        }
    }
}
