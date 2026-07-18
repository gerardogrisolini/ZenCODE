import Foundation
import Testing
@testable import ZenCODECore

@Suite
struct DirectToolCatalogSchemaTests {
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
