import Foundation
import Testing
import FeatureMCPBridgeKit
import ToolCore

@Suite
struct MCPRemoteToolDescriptorContractTests {
    @Test
    func convertsRemoteToolToDescriptorWithCanonicalSchemasAndFallbackDescription() throws {
        let remoteTool = try JSONDecoder().decode(
            MCPRemoteTool.self,
            from: Data(#"""
            {
              "name": "files/read",
              "title": "Read file",
              "inputSchema": {
                "type": "object",
                "properties": { "path": { "type": "string" } }
              },
              "outputSchema": { "type": "string" }
            }
            """#.utf8)
        )

        let descriptor = ToolDescriptor(remoteTool: remoteTool)

        #expect(descriptor.name == "files/read")
        #expect(descriptor.title == "Read file")
        #expect(descriptor.description == "No description provided by the tool backend.")
        #expect(descriptor.inputSchema == """
        {
          "properties" : {
            "path" : {
              "type" : "string"
            }
          },
          "type" : "object"
        }
        """)
        #expect(descriptor.outputSchema == """
        {
          "type" : "string"
        }
        """)
    }
}
