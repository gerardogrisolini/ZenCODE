//
//  ZenChoiceMenuStateTests.swift
//  ZenApp
//
//  The pure logic of the single, multiple and focused choice menus.
//

import Foundation
import Testing
import ZenCODECore

@testable import ZenAppControls

@Suite("ZenChoiceMenuState")
struct ZenChoiceMenuStateTests {
    private let items: [ChatChoiceItem] = [
        ChatChoiceItem(id: "qwen", title: "Qwen3-Coder", detail: "local 4bit", group: "MLX"),
        ChatChoiceItem(id: "devstral", title: "Devstral", detail: "local 8bit", group: "MLX", isCurrent: true),
        ChatChoiceItem(id: "gpt", title: "gpt-5", detail: "subscription", group: "OpenAI"),
        ChatChoiceItem(id: "mini", title: "gpt-5-mini", group: "OpenAI"),
        ChatChoiceItem(id: "loose", title: "Ungrouped")
    ]

    // MARK: - Kinds

    @Test("a menu exists for the three menu kinds only")
    func menuKinds() throws {
        let single = try #require(ZenChoiceMenuState(kind: .chooseOne(title: "Model", items: items, selectedID: "gpt")))
        #expect(single.mode == .single)
        #expect(single.title == "Model")
        #expect(single.highlightedID == "gpt")

        let multiple = try #require(ZenChoiceMenuState(kind: .chooseMany(title: "Tools", items: items, selectedIDs: ["qwen"])))
        #expect(multiple.mode == .multiple)
        #expect(multiple.selectedIDs == ["qwen"])

        let focused = try #require(ZenChoiceMenuState(kind: .chooseManyWithFocus(
            title: "Agents",
            items: items,
            selectedIDs: ["mini"],
            focusedID: "gpt",
            toggleLabel: "agents",
            confirmLabel: "use agent"
        )))
        #expect(focused.mode == .focused(toggleLabel: "agents", confirmLabel: "use agent"))
        #expect(focused.highlightedID == "gpt")
        #expect(focused.selectedIDs == ["mini"])

        #expect(ZenChoiceMenuState(kind: .readLine(prompt: "Name")) == nil)
        #expect(ZenChoiceMenuState(kind: .pickAttachment(startingAt: URL(filePath: "/tmp"))) == nil)
        #expect(ZenChoiceMenuState(kind: .workspaceAccess(
            ChatWorkspaceAccessRequest(workspaceURL: URL(filePath: "/tmp"), toolTitles: [])
        )) == nil)
    }

    // MARK: - Initial highlight

    @Test("the initial highlight is the selected/focused item, else the current one, else the first")
    func initialHighlight() throws {
        #expect(ZenChoiceMenuState(title: "", items: items, mode: .single, preferredHighlightID: "mini").highlightedID == "mini")
        // An unknown preferred ID falls back to the current item.
        #expect(ZenChoiceMenuState(title: "", items: items, mode: .single, preferredHighlightID: "nope").highlightedID == "devstral")
        #expect(ZenChoiceMenuState(title: "", items: items, mode: .single).highlightedID == "devstral")
        // A multiple menu has no preferred row: the current one, else the first.
        let multiple = try #require(ZenChoiceMenuState(kind: .chooseMany(title: "", items: items, selectedIDs: ["gpt"])))
        #expect(multiple.highlightedID == "devstral")
        let plain = [ChatChoiceItem(id: "a", title: "A"), ChatChoiceItem(id: "b", title: "B")]
        #expect(ZenChoiceMenuState(title: "", items: plain, mode: .multiple).highlightedID == "a")
        #expect(ZenChoiceMenuState(title: "", items: [], mode: .single).highlightedID == nil)
    }

    // MARK: - Navigation and toggling

    @Test("the highlight moves clamped at the ends")
    func highlightMovesClamped() {
        var state = ZenChoiceMenuState(title: "", items: items, mode: .single, preferredHighlightID: "qwen")
        state.moveHighlight(by: -1)
        #expect(state.highlightedID == "qwen")
        state.moveHighlight(by: 1)
        #expect(state.highlightedID == "devstral")
        state.moveHighlight(by: 10)
        #expect(state.highlightedID == "loose")
        state.moveHighlight(by: 1)
        #expect(state.highlightedID == "loose")
        state.highlight("gpt")
        #expect(state.highlightedID == "gpt")
        state.highlight("unknown")
        #expect(state.highlightedID == "gpt")
    }

    @Test("multiple and focused menus toggle, a single menu does not")
    func toggling() {
        var multiple = ZenChoiceMenuState(title: "", items: items, mode: .multiple, selectedIDs: ["qwen"])
        multiple.toggle("gpt")
        multiple.toggle("qwen")
        #expect(multiple.selectedIDs == ["gpt"])
        #expect(multiple.isSelected("gpt"))
        #expect(!multiple.isSelected("qwen"))
        multiple.toggleHighlighted()
        #expect(multiple.selectedIDs == ["gpt", "devstral"])
        #expect(multiple.showsCheckboxes)

        var focused = ZenChoiceMenuState(
            title: "",
            items: items,
            mode: .focused(toggleLabel: "agents", confirmLabel: "use agent"),
            preferredHighlightID: "mini"
        )
        focused.toggleHighlighted()
        #expect(focused.selectedIDs == ["mini"])

        var single = ZenChoiceMenuState(title: "", items: items, mode: .single, selectedIDs: ["qwen"])
        single.toggle("gpt")
        #expect(single.selectedIDs == ["qwen"])
        #expect(!single.showsCheckboxes)
    }

    // MARK: - Answers

    @Test("a single menu answers the highlighted item")
    func singleAnswer() {
        var state = ZenChoiceMenuState(title: "", items: items, mode: .single, preferredHighlightID: "gpt")
        #expect(state.confirmAnswer == .choice("gpt"))
        state.moveHighlight(by: 1)
        #expect(state.confirmAnswer == .choice("mini"))
        #expect(state.activationAnswer(for: "qwen") == .choice("qwen"))
        #expect(ZenChoiceMenuState(title: "", items: [], mode: .single).confirmAnswer == nil)
    }

    @Test("a multiple menu answers the ticked items")
    func multipleAnswer() {
        var state = ZenChoiceMenuState(title: "", items: items, mode: .multiple, selectedIDs: ["qwen", "outside"])
        state.toggle("mini")
        #expect(state.confirmAnswer == .choices(["qwen", "outside", "mini"]))
        #expect(state.activationAnswer(for: "qwen") == nil)
        // An empty menu still confirms its (empty) selection.
        #expect(ZenChoiceMenuState(title: "", items: [], mode: .multiple).confirmAnswer == .choices([]))
    }

    @Test("a focused menu answers the ticked items and the focused row")
    func focusedAnswer() {
        var state = ZenChoiceMenuState(
            title: "",
            items: items,
            mode: .focused(toggleLabel: "agents", confirmLabel: "use agent"),
            selectedIDs: ["qwen"],
            preferredHighlightID: "gpt"
        )
        state.toggleHighlighted()
        #expect(state.confirmAnswer == .focusedChoice(ChatFocusedChoice(selectedIDs: ["qwen", "gpt"], focusedID: "gpt")))
        #expect(state.activationAnswer(for: "mini") == .focusedChoice(ChatFocusedChoice(selectedIDs: ["qwen", "gpt"], focusedID: "mini")))
        let empty = ZenChoiceMenuState(title: "", items: [], mode: .focused(toggleLabel: "a", confirmLabel: "b"))
        #expect(empty.confirmAnswer == nil)
        #expect(!empty.canConfirm)
    }

    // MARK: - Filtering and sections

    @Test("the search filters by title and detail, case-insensitively")
    func filtering() {
        var state = ZenChoiceMenuState(title: "", items: items, mode: .multiple, selectedIDs: ["qwen"])
        state.query = "GPT"
        #expect(state.visibleItems.map(\.id) == ["gpt", "mini"])
        state.query = "local"
        #expect(state.visibleItems.map(\.id) == ["qwen", "devstral"])
        state.query = "  "
        #expect(state.visibleItems.count == items.count)
        state.query = "zzz"
        #expect(state.visibleItems.isEmpty)
        #expect(state.highlightedID == nil)
        // The selection survives filtering.
        #expect(state.confirmAnswer == .choices(["qwen"]))
    }

    @Test("the highlight stays on a visible item while filtering")
    func filteringKeepsHighlightVisible() {
        var state = ZenChoiceMenuState(title: "", items: items, mode: .single, preferredHighlightID: "qwen")
        state.query = "gpt"
        #expect(state.highlightedID == "gpt")
        #expect(state.confirmAnswer == .choice("gpt"))
        state.moveHighlight(by: 1)
        #expect(state.highlightedID == "mini")
        state.query = ""
        #expect(state.highlightedID == "mini")
        state.query = "nothing"
        #expect(state.confirmAnswer == nil)
        #expect(!state.canConfirm)
        state.moveHighlight(by: 1)
        #expect(state.highlightedID == nil)
    }

    @Test("sections group consecutive items of the same group")
    func sections() {
        let state = ZenChoiceMenuState(title: "", items: items, mode: .single)
        #expect(state.sections.map(\.title) == ["MLX", "OpenAI", nil])
        #expect(state.sections.map { $0.items.map(\.id) } == [["qwen", "devstral"], ["gpt", "mini"], ["loose"]])
        #expect(state.sections.map(\.id) == [0, 1, 2])

        var filtered = state
        filtered.query = "gpt-5-mini"
        #expect(filtered.sections.map(\.title) == ["OpenAI"])

        let interleaved = [
            ChatChoiceItem(id: "1", title: "1", group: "A"),
            ChatChoiceItem(id: "2", title: "2", group: "B"),
            ChatChoiceItem(id: "3", title: "3", group: "A")
        ]
        #expect(ZenChoiceMenuState(title: "", items: interleaved, mode: .single).sections.map(\.title) == ["A", "B", "A"])
    }

    @Test("the confirm button of a focused menu uses the request label")
    @MainActor
    func confirmTitle() {
        #expect(ZenChoiceSheet.capitalizedFirst("use agent") == "Use agent")
        #expect(ZenChoiceSheet.capitalizedFirst("") == "")
    }
}
