import Foundation
import Testing
import ToolCore
@testable import ZenCODECore

@Suite("Remote tool catalog compilation")
struct RemoteToolCatalogCompilationTests {
    private static let dialects: [RemoteToolWireDialect] = [
        .chatCompletions, .responses, .anthropicMessages, .anthropicSubscription
    ]
    private static let schema = #"{"type":"object","properties":{"path":{"type":"string"}},"required":["path"]}"#

    @Test(arguments: dialects)
    func unchangedRoundsAndRetriesCompileOnceWithLiveMetadata(dialect: RemoteToolWireDialect) throws {
        var cache = RemoteToolWireCatalogCache()
        var expectedWire: Data?
        for round in 0..<8 {
            let presentation = ToolPresentationDefinition(title: "Presentation \(round)", kind: .read)
            let descriptor = DirectToolDescriptor(
                name: "local.readFile", description: "Read a file", inputSchema: Self.schema,
                title: "Title \(round)", outputSchema: "output-\(round)", presentation: presentation
            )
            let catalog = cache.catalog(descriptors: [descriptor], dialect: dialect)
            let wire = try bytes(payloads(catalog, dialect: dialect))
            if let expectedWire { #expect(wire == expectedWire) }
            expectedWire = wire
            #expect(cache.compilationCount == 1)
            let binding = try #require(catalog.binding(forToolName: "local.readFile"))
            #expect(binding.descriptor.title == descriptor.title)
            #expect(binding.descriptor.outputSchema == descriptor.outputSchema)
            #expect(binding.descriptor.presentation == presentation)
            let call = catalog.localToolCall(from: DirectAgentToolCall(
                id: "call", name: binding.wireName, argumentsObject: ["path": "a"], argumentsJSON: #"{"path":"a"}"#
            ))
            #expect(call.name == descriptor.name)
            #expect(call.descriptorTitle == descriptor.title)
            #expect(call.presentation == presentation)
        }
    }

    @Test(arguments: dialects)
    func exactWireInputChangesInvalidate(dialect: RemoteToolWireDialect) throws {
        let original = DirectToolDescriptor(name: "tool.a", description: "Café", inputSchema: Self.schema)
        let variants = [
            DirectToolDescriptor(name: "tool.b", description: original.description, inputSchema: original.inputSchema),
            DirectToolDescriptor(name: original.name, description: "Changed", inputSchema: original.inputSchema),
            // Swift String equality considers these descriptions equal; their
            // outgoing UTF-8 is different and must not hit the cache.
            DirectToolDescriptor(name: original.name, description: "Cafe\u{301}", inputSchema: original.inputSchema),
            DirectToolDescriptor(name: original.name, description: original.description, inputSchema: " " + original.inputSchema),
            DirectToolDescriptor(name: original.name, description: original.description, inputSchema: #"{"type":"object","properties":{"count":{"type":"integer"}}}"#),
            DirectToolDescriptor(name: original.name, description: original.description, inputSchema: "invalid JSON")
        ]
        for changed in variants {
            var cache = RemoteToolWireCatalogCache()
            _ = cache.catalog(descriptors: [original], dialect: dialect)
            let catalog = cache.catalog(descriptors: [changed], dialect: dialect)
            #expect(cache.compilationCount == 2)
            #expect(try bytes(payloads(catalog, dialect: dialect)) == bytes(legacyPayloads(catalog, dialect: dialect)))
            let hit = cache.catalog(descriptors: [changed], dialect: dialect)
            #expect(cache.compilationCount == 2)
            #expect(try bytes(payloads(hit, dialect: dialect)) == bytes(payloads(catalog, dialect: dialect)))
        }
    }

    @Test
    func canonicalEquivalentNamesAndSchemasStillInvalidate() {
        for field in ["name", "schema"] {
            var cache = RemoteToolWireCatalogCache()
            for spelling in ["Café", "Cafe\u{301}"] {
                let descriptor = DirectToolDescriptor(
                    name: field == "name" ? spelling : "tool.a",
                    description: "Tool",
                    inputSchema: field == "schema"
                        ? "{\"type\":\"object\",\"description\":\"\(spelling)\"}"
                        : Self.schema
                )
                _ = cache.catalog(descriptors: [descriptor], dialect: .responses)
            }
            #expect(cache.compilationCount == 2)
        }
    }

    @Test
    func dialectChangesAndCatalogEvictionAreBoundedToOneEntry() throws {
        let a = DirectToolDescriptor(name: "tool.a", description: "A", inputSchema: Self.schema)
        let b = DirectToolDescriptor(name: "tool.b", description: "B", inputSchema: Self.schema)
        var cache = RemoteToolWireCatalogCache()
        var count = 0
        for dialect in Self.dialects {
            for descriptors in [[a], [a, b], [b, a], [], [a]] {
                let catalog = cache.catalog(descriptors: descriptors, dialect: dialect)
                count += 1
                #expect(cache.compilationCount == count)
                #expect(try bytes(payloads(catalog, dialect: dialect)) == bytes(legacyPayloads(catalog, dialect: dialect)))
                _ = cache.catalog(descriptors: descriptors, dialect: dialect)
                #expect(cache.compilationCount == count)
            }
        }
        var otherBackend = RemoteToolWireCatalogCache()
        _ = otherBackend.catalog(descriptors: [a], dialect: .anthropicSubscription)
        #expect(otherBackend.compilationCount == 1)
        #expect(cache.compilationCount == count)
    }

    @Test(arguments: dialects)
    func cachedWireMatchesLegacyTransformationsAndNames(dialect: RemoteToolWireDialect) throws {
        let schemas = [
            Self.schema,
            #"{"oneOf":[{"type":"object","properties":{"a":{"type":"string"}},"required":["a"]},{"type":"object","properties":{"b":{"type":"number"}}}],"additionalProperties":false}"#,
            #"{"allOf":[{"properties":{"count":{"type":"integer","minimum":1}},"required":["count"]}],"properties":{"flag":{"type":"boolean","default":true},"value":{"default":null},"decimal":{"type":"number","minimum":1.5}}}"#,
            "[]", "null", "invalid JSON"
        ]
        let names = ["a.b", "a-b", "tool_a_b", "A_B", "schema.null", "schema.invalid"]
        let descriptors = zip(names, schemas).map { name, schema in
            DirectToolDescriptor(name: name, description: "Description \(name)", inputSchema: schema)
        }
        let reference = RemoteToolWireCatalog(descriptors: descriptors)
        var cache = RemoteToolWireCatalogCache()
        for _ in 0..<3 {
            let catalog = cache.catalog(descriptors: descriptors, dialect: dialect)
            #expect(catalog.bindings.map(\.wireName) == reference.bindings.map(\.wireName))
            #expect(Set(catalog.bindings.map(\.wireName)).count == descriptors.count)
            #expect(try bytes(payloads(catalog, dialect: dialect)) == bytes(legacyPayloads(reference, dialect: dialect)))
            for binding in catalog.bindings {
                #expect(catalog.wireName(forToolName: binding.descriptor.name) == binding.wireName)
                let local = catalog.localToolCall(from: DirectAgentToolCall(id: "call", name: binding.wireName, argumentsObject: [:], argumentsJSON: "{}"))
                #expect(local.name == binding.descriptor.name)
            }
            let messages: [[String: Any]] = [
                ["role": "assistant", "tool_calls": [["id": "call", "type": "function", "function": ["name": "a.b", "arguments": "{}"]]]],
                ["role": "tool", "name": "a.b", "tool_call_id": "call", "content": "done"]
            ]
            #expect(try bytes(catalog.wireMessages(from: messages)) == bytes(reference.wireMessages(from: messages)))
        }
        #expect(cache.compilationCount == 1)
    }

    @Test
    func returnedPayloadMutationsCannotPoisonCachedPayloads() throws {
        var cache = RemoteToolWireCatalogCache()
        let descriptors = [DirectToolDescriptor(name: "tool.a", description: "A", inputSchema: Self.schema)]
        let catalog = cache.catalog(descriptors: descriptors, dialect: .responses)
        let expected = try bytes(catalog.responsesToolPayloads)
        var changed = catalog.responsesToolPayloads
        var parameters = try #require(changed[0]["parameters"] as? [String: Any])
        parameters["properties"] = ["injected": ["type": "string"]]
        changed[0]["parameters"] = parameters
        changed[0]["name"] = "injected"
        #expect(try bytes(changed) != expected)
        #expect(try bytes(catalog.responsesToolPayloads) == expected)
        #expect(try bytes(cache.catalog(descriptors: descriptors, dialect: .responses).responsesToolPayloads) == expected)
        #expect(cache.compilationCount == 1)
    }

    @Test
    func invalidSchemasRemainInvalidAfterCacheHits() throws {
        var cache = RemoteToolWireCatalogCache()
        let descriptors = [DirectToolDescriptor(name: "broken", description: "Broken", inputSchema: "invalid JSON")]
        for _ in 0..<3 {
            let catalog = cache.catalog(descriptors: descriptors, dialect: .responses)
            #expect(catalog.responsesToolPayloads.isEmpty)
            #expect(catalog.bindings.first?.responsesToolPayload == nil)
            #expect(throws: RemoteGenerationClientError.self) {
                try RemoteGenerationClient.validateRemoteToolPayloads(bindings: catalog.bindings, endpoint: .responses)
            }
        }
        #expect(cache.compilationCount == 1)
    }

    @Test
    func genericBackendRediscoversCurrentAllowedCatalogBeforeCacheLookup() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let client = RemoteGenerationClient(
            configuration: AgentRuntimeConfiguration(modelID: "test", workingDirectory: directory, maxToolRounds: 4, toolAuthorizationHandler: nil),
            provider: AgentRemoteProvider(name: "Test", baseURL: "https://example.com/v1", modelID: "test", chatEndpoint: .responses),
            apiKey: nil
        )
        // No network request: exercise the actual descriptor/discovery boundary.
        for _ in 0..<3 {
            let catalog = await client.remoteToolCatalog(
                allowedToolNames: ["local.readFile"], preferredWorkspaceRootURL: directory,
                sessionID: "catalog", dialect: .responses, onEvent: { _ in }
            )
            #expect(catalog.bindings.map(\.descriptor.name) == ["local.readFile"])
            #expect(await client.toolCatalogCache.compilationCount == 1)
        }
        let revoked = await client.remoteToolCatalog(
            allowedToolNames: [], preferredWorkspaceRootURL: directory,
            sessionID: "catalog", dialect: .responses, onEvent: { _ in }
        )
        #expect(revoked.bindings.isEmpty)
        #expect(await client.toolCatalogCache.compilationCount == 2)
        let restored = await client.remoteToolCatalog(
            allowedToolNames: ["local.readFile"], preferredWorkspaceRootURL: directory,
            sessionID: "catalog", dialect: .responses, onEvent: { _ in }
        )
        #expect(restored.bindings.map(\.descriptor.name) == ["local.readFile"])
        #expect(await client.toolCatalogCache.compilationCount == 3)
        await client.shutdown()
    }

    private func bytes(_ payload: [[String: Any]]) throws -> Data {
        try JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys, .fragmentsAllowed])
    }

    private func payloads(_ catalog: RemoteToolWireCatalog, dialect: RemoteToolWireDialect) -> [[String: Any]] {
        switch dialect {
        case .chatCompletions: catalog.chatCompletionToolPayloads
        case .responses: catalog.responsesToolPayloads
        case .anthropicMessages: catalog.bindings.compactMap(\.anthropicMessagesToolPayload)
        case .anthropicSubscription: AnthropicSubscriptionGenerationClient.anthropicTools(from: catalog.bindings)
        }
    }

    /// Independent copies of the pre-cache provider transformations: do not
    /// call Binding payload accessors here, since those are the cache under test.
    private func legacyPayloads(_ catalog: RemoteToolWireCatalog, dialect: RemoteToolWireDialect) -> [[String: Any]] {
        catalog.bindings.compactMap { binding in
            guard let schema = binding.descriptor.schemaObject else { return nil }
            switch dialect {
            case .chatCompletions:
                return ["type": "function", "function": [
                    "name": binding.wireName, "description": binding.descriptor.description,
                    "parameters": RemoteToolSchemaCompatibility.chatCompletionsFunctionParameters(from: schema)
                ]]
            case .responses:
                guard let parameters = RemoteToolSchemaCompatibility.responsesFunctionParameters(from: schema) else { return nil }
                return ["type": "function", "name": binding.wireName, "description": binding.descriptor.description, "parameters": parameters]
            case .anthropicMessages:
                return ["name": binding.wireName, "description": binding.descriptor.description,
                        "input_schema": RemoteToolSchemaCompatibility.chatCompletionsFunctionParameters(from: schema)]
            case .anthropicSubscription:
                return ["name": binding.wireName, "description": binding.descriptor.description,
                        "eager_input_streaming": true, "input_schema": schema]
            }
        }
    }
}
