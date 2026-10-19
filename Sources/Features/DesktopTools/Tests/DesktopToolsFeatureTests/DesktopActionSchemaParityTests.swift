import Foundation
import Testing
@testable import desktop_tools_feature

@Suite
struct DesktopActionSchemaParityTests {
    @Test
    func inputActionEnumMatchesDesktopAction() throws {
        let root = try #require(try JSONSerialization.jsonObject(with: Data(DesktopRunTool.inputSchema.utf8)) as? [String: Any])
        let properties = try #require(root["properties"] as? [String: Any])
        let action = try #require(properties["action"] as? [String: Any])
        let values = try #require(action["enum"] as? [String])
        #expect(values.count == Set(values).count)
        #expect(Set(values) == Set(DesktopAction.allCases.map(\.rawValue)))
        #expect(values.contains("zoom"))
    }

    @Test
    func outputSchemaDescribesMappingFields() throws {
        let schema = try #require(DesktopRunTool.outputSchema)
        let root = try #require(try JSONSerialization.jsonObject(with: Data(schema.utf8)) as? [String: Any])
        let defs = try #require(root["$defs"] as? [String: Any])
        let artifact = try #require(defs["artifact"] as? [String: Any])
        let properties = try #require(artifact["properties"] as? [String: Any])
        #expect(properties["desktop_bounds"] != nil)
        #expect(properties["points_per_pixel"] != nil)
    }
}
