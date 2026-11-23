import CoreGraphics
import FeatureKit
import Foundation
import Testing

@testable import desktop_tools_feature

@Suite
struct DesktopCompactElementTests {
    private func element(
        role: String = "AXButton",
        title: String? = nil,
        description: String? = nil,
        placeholder: String? = nil,
        value: String? = nil,
        actions: [String]? = ["AXPress"],
        enabled: Bool? = true,
        focused: Bool? = false,
        ref: String? = "p1.w2:0.1:AXButton:fbbf52e3"
    ) -> DesktopElementInfo {
        DesktopElementPolicy.makeInfo(
            role: role, subrole: "AXSubrole", roleDescription: "button", title: title, description: description,
            value: value, placeholder: placeholder, identifier: "id", enabled: enabled, focused: focused,
            valueSettable: true, frame: CGRect(x: 1, y: 2, width: 30, height: 40), actions: actions,
            pid: 9, appName: "Calculator", windowTitle: "Calculator", hostsZen: true, ref: ref
        )
    }

    private func keys(_ info: DesktopElementInfo) throws -> Set<String> {
        let object = try #require(try JSONSerialization.jsonObject(with: JSONEncoder().encode(info)) as? [String: Any])
        return Set(object.keys)
    }

    // MARK: label

    @Test
    func labelJoinsTheDistinctTextsInOrder() {
        #expect(DesktopElementPolicy.listLabel(title: "Save", description: "Save the file", placeholder: "Name")
            == "Save | Save the file | Name")
        #expect(DesktopElementPolicy.listLabel(title: nil, description: "Clear", placeholder: "Type") == "Clear | Type")
        #expect(DesktopElementPolicy.listLabel(title: nil, description: nil, placeholder: "Search") == "Search")
    }

    @Test
    func labelDropsEmptyBlankAndRepeatedTexts() {
        #expect(DesktopElementPolicy.listLabel(title: "7", description: "7", placeholder: "7") == "7")
        #expect(DesktopElementPolicy.listLabel(title: "", description: "  \n", placeholder: nil) == nil)
        #expect(DesktopElementPolicy.listLabel(title: " Close ", description: "Close", placeholder: "Close") == "Close")
        #expect(DesktopElementPolicy.listLabel(title: "A", description: "B", placeholder: "A") == "A | B")
        // Distinct means a different text: a different case is kept.
        #expect(DesktopElementPolicy.listLabel(title: "Close", description: "close", placeholder: nil) == "Close | close")
        #expect(DesktopElementPolicy.listLabel(title: nil, description: nil, placeholder: nil) == nil)
    }

    @Test
    func labelOfAnElementIgnoresValueAndIdentifier() {
        let info = element(title: "Add", description: "plus", value: "42")
        #expect(DesktopElementPolicy.listLabel(of: info) == "Add | plus")
    }

    // MARK: compact projection

    @Test
    func compactKeepsOnlyTheListFields() throws {
        let info = element(title: "Add", description: "plus", value: "42", actions: ["AXPress", "AXShowMenu"], enabled: false, focused: true)
        let compact = DesktopElementPolicy.compact(info)
        #expect(try keys(compact) == ["ref", "role", "label", "value", "actions", "enabled", "focused"])
        #expect(compact.ref == "p1.w2:0.1:AXButton:fbbf52e3")
        #expect(compact.role == "AXButton")
        #expect(compact.label == "Add | plus")
        #expect(compact.value == "42")
        #expect(compact.actions == ["AXPress", "AXShowMenu"])
        #expect(compact.enabled == false)
        #expect(compact.focused == true)
        #expect(compact.title == nil && compact.description == nil && compact.frame == nil && compact.center == nil)
        #expect(compact.pid == nil && compact.app_name == nil && compact.window_title == nil && compact.hosts_zen == nil)
        #expect(compact.subrole == nil && compact.identifier == nil && compact.value_settable == nil)
    }

    @Test
    func compactOmitsEnabledUnlessFalseAndFocusedUnlessTrue() throws {
        let plain = DesktopElementPolicy.compact(element(title: "OK", enabled: true, focused: false))
        #expect(plain.enabled == nil && plain.focused == nil)
        let unknown = DesktopElementPolicy.compact(element(title: "OK", enabled: nil, focused: nil))
        #expect(unknown.enabled == nil && unknown.focused == nil)
        #expect(try keys(plain) == ["ref", "role", "label", "actions"])
    }

    @Test
    func compactOmitsTheValueWhenItEqualsTheLabel() {
        #expect(DesktopElementPolicy.compact(element(title: "Total", value: "Total")).value == nil)
        // A label made of several texts is not the value, even if it contains it.
        #expect(DesktopElementPolicy.compact(element(title: "Total", description: "sum", value: "Total")).value == "Total")
        #expect(DesktopElementPolicy.compact(element(title: "Total", value: "12")).value == "12")
        // Without a label the value stays.
        let valueOnly = DesktopElementPolicy.compact(element(value: "0"))
        #expect(valueOnly.label == nil)
        #expect(valueOnly.value == "0")
    }

    @Test
    func compactKeepsOnlyTheUsefulActionsInTheirOrder() {
        let all = [
            "AXScrollToVisible", "AXCancel", "AXPress", "AXShowDefaultUI", "AXShowMenu", "AXDecrement",
            "AXRaise", "AXIncrement", "AXPick", "AXConfirm", "AXZoomWindow"
        ]
        let compact = DesktopElementPolicy.compact(element(title: "x", actions: all))
        #expect(compact.actions == ["AXCancel", "AXPress", "AXShowMenu", "AXDecrement", "AXIncrement", "AXPick", "AXConfirm"])
        #expect(Set(DesktopElementPolicy.compactActions) == [
            "AXPress", "AXConfirm", "AXPick", "AXIncrement", "AXDecrement", "AXShowMenu", "AXCancel"
        ])
    }

    @Test
    func compactOmitsActionsWhenNoneIsLeft() throws {
        #expect(DesktopElementPolicy.compact(element(title: "x", actions: ["AXScrollToVisible", "AXRaise"])).actions == nil)
        #expect(DesktopElementPolicy.compact(element(title: "x", actions: nil)).actions == nil)
        #expect(DesktopElementPolicy.compact(element(title: "x", actions: [])).actions == nil)
        let object = try #require(try JSONSerialization.jsonObject(
            with: JSONEncoder().encode(DesktopElementPolicy.compact(element(title: "x", actions: ["AXRaise"])))
        ) as? [String: Any])
        #expect(object["actions"] == nil)
    }

    @Test
    func compactWithoutAnyTextKeepsRoleAndRef() throws {
        let compact = DesktopElementPolicy.compact(element(role: "AXGroup", actions: nil, ref: nil))
        #expect(try keys(compact) == ["role"])
    }

    @Test
    func compactElementEncodesToTheDocumentedExample() throws {
        let info = element(title: "Add", description: "plus", actions: ["AXPress", "AXShowDefaultUI"])
        let json = String(decoding: try FeatureProcessProtocol.renderJSON(DesktopElementPolicy.compact(info)), as: UTF8.self)
        #expect(json == #"{"actions":["AXPress"],"label":"Add | plus","ref":"p1.w2:0.1:AXButton:fbbf52e3","role":"AXButton"}"#)
    }

    // MARK: detailed projection

    @Test
    func detailedKeepsEveryFieldAndAddsTheLabel() throws {
        let info = element(title: "Add", description: "plus", placeholder: "Add", value: "42", actions: ["AXPress", "AXRaise"])
        let detailed = DesktopElementPolicy.detailed(info)
        #expect(detailed.label == "Add | plus")
        var withoutLabel = detailed
        withoutLabel.label = nil
        #expect(try FeatureProcessProtocol.renderJSON(withoutLabel) == FeatureProcessProtocol.renderJSON(info))
        #expect(detailed.actions == ["AXPress", "AXRaise"])
        #expect(detailed.frame != nil && detailed.center != nil && detailed.pid == 9 && detailed.hosts_zen == true)
        #expect(detailed.value == "42")
    }

    @Test
    func detailedKeepsTheValueEvenWhenItEqualsTheLabel() {
        #expect(DesktopElementPolicy.detailed(element(title: "Total", value: "Total")).value == "Total")
    }

    @Test
    func projectedChoosesTheFormByIncludeDetails() {
        let info = element(title: "Add", value: "Add")
        #expect(DesktopElementPolicy.projected(info, includeDetails: false).title == nil)
        #expect(DesktopElementPolicy.projected(info, includeDetails: true).title == "Add")
    }

    @Test
    func otherActionsKeepTheElementWithoutALabel() throws {
        let info = element(title: "Add", description: "plus")
        #expect(info.label == nil)
        #expect(try !keys(info).contains("label"))
    }

    // MARK: size

    @Test
    func aCalculatorSizedCompactListFitsTheRuntimeOutputLimit() throws {
        let entries = (0..<26).map { index in
            DesktopElementPolicy.compact(element(
                title: nil, description: "button \(index)", value: nil,
                actions: ["AXPress", "AXShowMenu", "AXScrollToVisible"],
                ref: "p812.w5309:0.1.\(index).0:AXButton:fbbf52e3"
            ))
        }
        let detailed = (0..<26).map { index in
            DesktopElementPolicy.detailed(element(
                title: nil, description: "button \(index)", actions: ["AXPress", "AXShowMenu", "AXScrollToVisible"],
                ref: "p812.w5309:0.1.\(index).0:AXButton:fbbf52e3"
            ))
        }
        let compactTotal = entries.map(DesktopListPaging.encodedLength).reduce(0, +)
        let detailedTotal = detailed.map(DesktopListPaging.encodedLength).reduce(0, +)
        #expect(compactTotal < DesktopSafetyPolicy.maximumListPayloadCharacters)
        #expect(detailedTotal > 2 * compactTotal)
    }

    // MARK: input and output

    @Test
    func inputDecodesTheListingFields() throws {
        let json = #"{"action":"list_apps","offset":40,"limit":20,"include_background":true,"include_details":true,"query":"calc"}"#
        let input = try JSONDecoder().decode(DesktopRunInput.self, from: Data(json.utf8))
        #expect(input.offset == 40 && input.limit == 20)
        #expect(input.include_background == true && input.include_details == true)
        #expect(input.query == "calc")
        let bare = try JSONDecoder().decode(DesktopRunInput.self, from: Data(#"{"action":"list_apps"}"#.utf8))
        #expect(bare.offset == nil && bare.include_background == nil && bare.include_details == nil)
    }

    @Test
    func nextOffsetIsOmittedUnlessMoreEntriesRemain() throws {
        var output = DesktopRunOutput(action: "list_apps", summary: "Listed.")
        output.count = 3
        var object = try #require(try JSONSerialization.jsonObject(with: JSONEncoder().encode(output)) as? [String: Any])
        #expect(object["next_offset"] == nil)
        output.next_offset = 3
        object = try #require(try JSONSerialization.jsonObject(with: JSONEncoder().encode(output)) as? [String: Any])
        #expect(object["next_offset"] as? Int == 3)
    }
}
