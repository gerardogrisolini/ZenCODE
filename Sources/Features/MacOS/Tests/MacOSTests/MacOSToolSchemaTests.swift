import FeatureKit
import Foundation
import Testing

@testable import MacOS

@Suite
struct MacOSToolSchemaTests {
    private static let tools: [AnyFeatureTool] = [
        AnyFeatureTool(MacOSPermissionsTool()),
        AnyFeatureTool(MacOSCalendarTool()),
        AnyFeatureTool(MacOSRemindersTool()),
        AnyFeatureTool(MacOSContactsTool()),
        AnyFeatureTool(MacOSMailTool()),
        AnyFeatureTool(MacOSMessagesTool()),
        AnyFeatureTool(MacOSPhotosTool()),
        AnyFeatureTool(MacOSNotesTool()),
    ]

    private func object(_ json: String?) throws -> [String: Any] {
        let data = Data(try #require(json).utf8)
        return try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    private func storedProperties(of value: Any) -> Set<String> {
        Set(Mirror(reflecting: value).children.compactMap(\.label))
    }

    @Test
    func everyAppHasATool() {
        let names = Set(Self.tools.map(\.descriptor.name))
        #expect(names == Set(MacOSApp.allCases.map(\.toolName)))
    }

    @Test
    func inputSchemasAreValidAndListTheActionsOfTheirApp() throws {
        for tool in Self.tools {
            let descriptor = tool.descriptor
            let app = try #require(MacOSApp.allCases.first { $0.toolName == descriptor.name })
            let schema = try object(descriptor.inputSchema)
            let properties = try #require(schema["properties"] as? [String: Any])
            let action = try #require(properties["action"] as? [String: Any])
            #expect(action["enum"] as? [String] == app.actionNames)
            #expect(schema["required"] as? [String] == ["action"])
            #expect(schema["additionalProperties"] as? Bool == false)

            let hasConfirm = properties["confirm"] != nil
            #expect(hasConfirm == !app.confirmedActionNames.isEmpty, "\(descriptor.name) confirm property")
            if hasConfirm {
                let confirm = try #require(properties["confirm"] as? [String: Any])
                let text = try #require(confirm["description"] as? String)
                #expect(text.contains(app.confirmedActionNames.joined(separator: ", ")))
                #expect(descriptor.description.contains(app.confirmedActionNames.joined(separator: ", ")))
            }

            // Every declared property is decodable: MacOSRunInput knows it.
            let known = storedProperties(of: try JSONDecoder().decode(MacOSRunInput.self, from: Data(#"{"action": "x"}"#.utf8)))
            for name in properties.keys {
                #expect(known.contains(name), "\(descriptor.name) declares unknown argument \(name)")
            }
        }
    }

    @Test
    func outputSchemasAreValidAndResolveTheirReferences() throws {
        var declaredFields = Set<String>()
        for tool in Self.tools {
            let descriptor = tool.descriptor
            let schema = try object(descriptor.outputSchema)
            let properties = try #require(schema["properties"] as? [String: Any])
            for envelope in ["ok", "action", "summary", "hint", "count"] {
                #expect(properties[envelope] != nil, "\(descriptor.name) lacks \(envelope)")
            }
            #expect(schema["required"] as? [String] == ["ok", "action", "summary"])
            declaredFields.formUnion(properties.keys)

            let defs = (schema["$defs"] as? [String: Any]) ?? [:]
            let serialized = try #require(descriptor.outputSchema)
            for match in serialized.ranges(of: "#/$defs/") {
                let name = String(serialized[match.upperBound...].prefix { $0.isLetter || $0 == "_" })
                #expect(defs[name] != nil, "\(descriptor.name) references undefined $defs/\(name)")
            }
        }
        #expect(declaredFields == storedProperties(of: MacOSRunOutput(action: .permissions, summary: "")))
    }

    @Test
    func outputEnvelopeMatchesTheSchema() throws {
        var output = MacOSRunOutput(action: .calendarEvents, summary: "2 events.")
        output.count = 2
        output.hint = "Narrow the range."
        let data = try JSONEncoder().encode(output)
        let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(object["ok"] as? Bool == true)
        #expect(object["action"] as? String == "events")
        #expect(object["summary"] as? String == "2 events.")
        #expect(object["count"] as? Int == 2)
        #expect(object["hint"] as? String == "Narrow the range.")
        #expect(object["events"] == nil)
        #expect(object.count == 5)
    }
}
