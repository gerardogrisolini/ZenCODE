//
//  TerminalCheckboxMenuRenderingTests.swift
//  ZenCODE
//

import Foundation
import Synchronization
import Testing
@testable import ZenCODECore

@Suite(.serialized)
struct TerminalCheckboxMenuRenderingTests {
    @Test
    func clearFrameSequenceClearsOnlyMenuRowsAndKeepsCursorInsideFrame() {
        let frame = TerminalCheckboxMenu.RenderedFrame(row: 10, height: 3)

        let sequence = TerminalCheckboxMenu.clearFrameSequence(
            frame: frame,
            terminalRows: 24
        )

        #expect(
            sequence == "\u{1B}[10;1H\u{1B}[2K"
                + "\u{1B}[11;1H\u{1B}[2K"
                + "\u{1B}[12;1H\u{1B}[2K"
                + "\u{1B}[12;1H"
        )
        #expect(!sequence.contains("\u{1B}[J"))
        #expect(!sequence.contains("\u{1B}[13;1H"))
    }

    @Test
    func clearFrameSequenceClearsReflowedRowsWhenNarrowing() {
        let frame = TerminalCheckboxMenu.RenderedFrame(
            row: 2,
            height: 2,
            terminalRows: 24,
            terminalColumns: 60
        )

        let sequence = TerminalCheckboxMenu.clearFrameSequence(
            frame: frame,
            terminalRows: 24,
            terminalColumns: 20
        )

        #expect(
            sequence == "\u{1B}[2;1H\u{1B}[2K"
                + "\u{1B}[3;1H\u{1B}[2K"
                + "\u{1B}[4;1H\u{1B}[2K"
                + "\u{1B}[5;1H\u{1B}[2K"
                + "\u{1B}[6;1H\u{1B}[2K"
                + "\u{1B}[7;1H\u{1B}[2K"
                + "\u{1B}[7;1H"
        )
    }

    @Test
    func clearFrameSequenceClipsReflowToCurrentTranscriptViewport() {
        let frame = TerminalCheckboxMenu.RenderedFrame(
            row: 3,
            height: 4,
            terminalRows: 24,
            terminalColumns: 100,
            reservedBottomRows: 6
        )

        let sequence = TerminalCheckboxMenu.clearFrameSequence(
            frame: frame,
            terminalRows: 24,
            terminalColumns: 20,
            transcriptBottomRow: 18
        )

        #expect(sequence.contains("\u{1B}[18;1H\u{1B}[2K"))
        #expect(!sequence.contains("\u{1B}[19;1H"))
        #expect(!sequence.contains("\u{1B}[24;1H"))
    }

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
    func resizeCoordinatorPublishesLatestOverlayReservation() {
        let coordinator = TerminalResizeCoordinator()
        let initialGeneration = coordinator.currentGeneration()

        coordinator.publishLayout(reservedBottomRows: 7)
        #expect(coordinator.currentGeneration() == initialGeneration &+ 1)
        #expect(coordinator.reservedBottomRows(fallback: 2) == 7)

        coordinator.publishLayout(reservedBottomRows: nil)
        #expect(coordinator.reservedBottomRows(fallback: 2) == 2)
    }

    @Test
    func outputSynchronizationDoesNotDiscardNormalWritesDuringOverlays() {
        let writes = Mutex<[String]>([])
        let sink: @Sendable (String) -> Void = { text in writes.withLock { $0.append(text) } }
        TerminalOutputSynchronization.write("status", output: nil, sink: sink)
        TerminalOutputSynchronization.writeOverlay("menu", output: nil, sink: sink)
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

    @Test
    func resizeCoordinatorRequestRefreshAdvancesGenerationAndNotifiesObservers() {
        let coordinator = TerminalResizeCoordinator()
        let callbackCount = Mutex(0)
        let subscription = coordinator.subscribe {
            callbackCount.withLock { $0 += 1 }
        }
        defer { subscription.cancel() }

        let initialGeneration = coordinator.currentGeneration()
        coordinator.requestRefresh()

        #expect(coordinator.currentGeneration() == initialGeneration &+ 1)
        #expect(callbackCount.withLock { $0 } == 1)
    }
}
