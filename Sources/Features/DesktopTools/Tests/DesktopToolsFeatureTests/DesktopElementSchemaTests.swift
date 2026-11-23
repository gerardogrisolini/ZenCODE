import CoreGraphics
import Foundation
import Testing

@testable import desktop_tools_feature

@Suite
struct DesktopElementSchemaTests {
    private func object(_ json: String) throws -> [String: Any] {
        try #require(try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
    }

    @Test
    func elementActionsAreDeclaredAndParsed() throws {
        let properties = try #require(try object(DesktopRunTool.inputSchema)["properties"] as? [String: Any])
        let action = try #require(properties["action"] as? [String: Any])
        let values = try #require(action["enum"] as? [String])
        for name in ["list_elements", "press_element", "focus_element", "set_value"] {
            #expect(values.contains(name))
            #expect(DesktopAction(rawValue: name) != nil)
        }
    }

    @Test
    func elementInputsAreDeclaredWithBounds() throws {
        let properties = try #require(try object(DesktopRunTool.inputSchema)["properties"] as? [String: Any])
        let reference = try #require(properties["element_ref"] as? [String: Any])
        #expect(reference["type"] as? String == "string")
        #expect(reference["maxLength"] as? Int == DesktopElementReference.maximumLength)
        let query = try #require(properties["query"] as? [String: Any])
        #expect(query["maxLength"] as? Int == DesktopElementPolicy.maximumQueryCharacters)
        let role = try #require(properties["role"] as? [String: Any])
        #expect(role["maxLength"] as? Int == DesktopElementPolicy.maximumRoleFilterCharacters)
        let interactive = try #require(properties["interactive_only"] as? [String: Any])
        #expect(interactive["type"] as? String == "boolean")
        let depth = try #require(properties["max_depth"] as? [String: Any])
        #expect(depth["type"] as? String == "integer")
        #expect(depth["minimum"] as? Int == 1)
        #expect(depth["maximum"] as? Int == 60)
    }

    @Test
    func elementSelectorDescriptionsStateWhatTheyRefuse() throws {
        let properties = try #require(try object(DesktopRunTool.inputSchema)["properties"] as? [String: Any])
        let reference = try #require((properties["element_ref"] as? [String: Any])?["description"] as? String)
        for fragment in ["query, identifier, or x/y", "title or window_index", "window_id is accepted only when it is that window",
                         "scroll, drag, move_mouse, and press_key do not accept it", "relocated", "never relocated into another window or app"] {
            #expect(reference.contains(fragment), "element_ref: \(fragment)")
        }
        let query = try #require((properties["query"] as? [String: Any])?["description"] as? String)
        #expect(query.contains("skips nodes that do not respond, so the visit is incomplete"))
        #expect(query.contains("scroll, drag, move_mouse, and press_key do not accept it"))
    }

    @Test
    func inputDecodesElementFields() throws {
        let json = #"{"action":"list_elements","element_ref":"p1.w2:0:AXButton:fbbf52e3","query":"Save","role":"button","interactive_only":false,"max_depth":12}"#
        let input = try JSONDecoder().decode(DesktopRunInput.self, from: Data(json.utf8))
        #expect(input.element_ref == "p1.w2:0:AXButton:fbbf52e3")
        #expect(input.query == "Save")
        #expect(input.role == "button")
        #expect(input.interactive_only == false)
        #expect(input.max_depth == 12)
    }

    @Test
    func outputSchemaDescribesElements() throws {
        let root = try object(try #require(DesktopRunTool.outputSchema))
        let properties = try #require(root["properties"] as? [String: Any])
        for name in ["elements", "element", "focused_element", "focus_method"] {
            #expect(properties[name] != nil)
        }
        let defs = try #require(root["$defs"] as? [String: Any])
        let element = try #require(defs["element"] as? [String: Any])
        #expect(element["required"] as? [String] == ["role"])
        let elementProperties = try #require(element["properties"] as? [String: Any])
        let expected = [
            "ref", "role", "subrole", "role_description", "title", "description", "value", "placeholder",
            "identifier", "enabled", "focused", "value_settable", "frame", "center", "actions", "pid",
            "app_name", "window_title", "hosts_zen", "label"
        ]
        #expect(Set(elementProperties.keys) == Set(expected))
        let app = try #require(defs["app"] as? [String: Any])
        let appProperties = try #require(app["properties"] as? [String: Any])
        #expect(appProperties["hosts_zen"] != nil)
    }

    @Test
    func encodedElementKeysMatchTheSchema() throws {
        let info = DesktopElementPolicy.makeInfo(
            role: "AXButton", subrole: "AXCloseButton", roleDescription: "button", title: "Close",
            description: "close", value: "1", placeholder: "p", identifier: "id", enabled: true, focused: false,
            valueSettable: false, frame: CGRect(x: 1, y: 2, width: 3, height: 4), actions: ["AXPress"],
            pid: 9, appName: "App", windowTitle: "Window", hostsZen: true, ref: "p9.w1::AXButton", label: "Close | p"
        )
        let encoded = try #require(try JSONSerialization.jsonObject(with: JSONEncoder().encode(info)) as? [String: Any])
        let root = try object(try #require(DesktopRunTool.outputSchema))
        let defs = try #require(root["$defs"] as? [String: Any])
        let element = try #require(defs["element"] as? [String: Any])
        let schemaKeys = Set(try #require(element["properties"] as? [String: Any]).keys)
        #expect(Set(encoded.keys) == schemaKeys)
    }

    @Test
    func outputOmitsNilFields() throws {
        let minimal = DesktopRunOutput(action: "click", summary: "Clicked.")
        let encoded = try #require(try JSONSerialization.jsonObject(with: JSONEncoder().encode(minimal)) as? [String: Any])
        #expect(Set(encoded.keys) == ["ok", "action", "summary"])

        var withElement = DesktopRunOutput(action: "click", summary: "Clicked.")
        withElement.element = DesktopElementInfo(role: "AXGroup")
        let nested = try #require(try JSONSerialization.jsonObject(with: JSONEncoder().encode(withElement)) as? [String: Any])
        let element = try #require(nested["element"] as? [String: Any])
        #expect(Set(element.keys) == ["role"])
        #expect(nested["focused_element"] == nil)
        #expect(nested["focus_method"] == nil)

        let app = DesktopAppInfo(
            pid: 1, name: "App", bundle_id: nil, bundle_path: nil, activation_policy: "regular",
            is_active: true, is_hidden: false, is_terminated: false
        )
        let appJSON = try #require(try JSONSerialization.jsonObject(with: JSONEncoder().encode(app)) as? [String: Any])
        #expect(appJSON["hosts_zen"] == nil)
        var host = app
        host.hosts_zen = true
        let hostJSON = try #require(try JSONSerialization.jsonObject(with: JSONEncoder().encode(host)) as? [String: Any])
        #expect(hostJSON["hosts_zen"] as? Bool == true)
    }
}
