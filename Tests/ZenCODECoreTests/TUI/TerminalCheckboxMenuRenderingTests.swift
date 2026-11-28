//
//  TerminalCheckboxMenuRenderingTests.swift
//  ZenCODE
//

import Foundation
import Synchronization
import Testing
@testable import ZenCODECore

@Suite
struct TerminalCheckboxMenuRenderingTests {
    @Test
    func promptKeepsTextWhenResizeRequestsRepaint() {
        var results: [TerminalCheckboxMenu.InputLineReadResult] = [
            .resized("draft"),
            .submitted("draft")
        ]
        let value = TerminalCheckboxMenu.readPromptLine(
            title: "Title",
            prompt: "Prompt",
            defaultValue: nil,
            allowEmpty: false,
            help: nil,
            reservedBottomRows: 0,
            screen: TerminalPrimaryScreen(reports: TerminalCursorReport(), resizeGeneration: { 0 }, output: { _ in })
        ) {
            results.removeFirst()
        }

        #expect(value == "draft")
    }

    @Test
    func resizeCoordinatorPublishedLayoutAdvancesTheGeneration() {
        let coordinator = TerminalResizeCoordinator()
        let initialGeneration = coordinator.currentGeneration()

        coordinator.publishLayout()
        #expect(coordinator.currentGeneration() == initialGeneration &+ 1)
    }

    @Test
    func outputSynchronizationDoesNotDiscardNormalWritesDuringOverlays() {
        let writes = Mutex<[String]>([])
        let sink: @Sendable (String) -> Void = { text in writes.withLock { $0.append(text) } }
        TerminalOutputSynchronization.write("status", output: nil, sink: sink)
        TerminalOutputSynchronization.write("menu", output: nil, sink: sink)
        TerminalOutputSynchronization.write("transcript", output: nil, sink: sink)
        #expect(writes.withLock { $0 } == ["status", "menu", "transcript"])
    }

    @Test
    func resizeDoesNotChangeSingleOrMultipleSelection() {
        let items = [
            TerminalCheckboxMenuItem(value: 0, title: "界🙂", detail: nil),
            TerminalCheckboxMenuItem(value: 1, title: "Second", detail: nil)
        ]
        var single = TerminalCheckboxMenu.SelectionState<Int>.single(1)
        var multiple = TerminalCheckboxMenu.SelectionState<Int>.multiple([0, 1])
        var focused = 1
        _ = TerminalCheckboxMenu.apply(key: .resize, items: items, state: &single, focusedIndex: &focused)
        _ = TerminalCheckboxMenu.apply(key: .resize, items: items, state: &multiple, focusedIndex: &focused)
        #expect(focused == 1)
        if case let .single(value) = single { #expect(value == 1) }
        else { Issue.record("Single selection changed mode on resize") }
        if case let .multiple(values) = multiple { #expect(values == [0, 1]) }
        else { Issue.record("Multiple selection changed mode on resize") }
        #expect(TerminalANSIText.visibleWidth(TerminalCheckboxMenu.fitLine("界🙂abcdef", width: 6)) <= 6)
    }
}
