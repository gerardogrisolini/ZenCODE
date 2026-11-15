//
//  ZenChoicePopoverLayoutTests.swift
//  ZenApp
//
//  The size of the choice popover: a fixed width, and a list that grows with
//  the items up to its cap and scrolls the rest, so a menu of any length
//  leaves the popover shorter than the smallest window.
//

import AppKit
import CoreGraphics
import Foundation
import SwiftUI
import Testing
import ZenCODECore

@testable import ZenAppControls

@Suite("Choice popover height")
@MainActor
struct ZenChoicePopoverHeightTests {
    @Test("the list follows its rows, at least the minimum and at most the cap")
    func listHeight() {
        #expect(ZenChoicePopover.width == 460)
        #expect(ZenChoicePopover.padding == 16)
        #expect(ZenChoicePopover.maximumListHeight == 360)
        #expect(ZenChoicePopover.minimumListHeight == 32)
        // Not measured yet, or shorter than the minimum: the minimum.
        #expect(ZenChoicePopover.listHeight(contentHeight: 0) == 32)
        #expect(ZenChoicePopover.listHeight(contentHeight: 20) == 32)
        // Up to the cap: the rows' height.
        #expect(ZenChoicePopover.listHeight(contentHeight: 120) == 120)
        #expect(ZenChoicePopover.listHeight(contentHeight: 360) == 360)
        // A longer menu: the cap, and the rest scrolls.
        #expect(ZenChoicePopover.listHeight(contentHeight: 361) == 360)
        #expect(ZenChoicePopover.listHeight(contentHeight: 20_000) == 360)
    }

    @Test("the list keeps its tallest height while a search filters it")
    func retainedHeight() {
        // Opening: the first measure.
        #expect(ZenChoicePopover.retainedContentHeight(0, measured: 240) == 240)
        // A search hides rows: the list does not shrink.
        #expect(ZenChoicePopover.retainedContentHeight(240, measured: 40) == 240)
        // Rows measured taller (a lazy list refines its estimate): it grows.
        #expect(ZenChoicePopover.retainedContentHeight(240, measured: 300) == 300)
    }
}

@Suite("Choice popover layout")
@MainActor
struct ZenChoicePopoverLayoutTests {
    private func items(_ count: Int) -> [ChatChoiceItem] {
        (0..<count).map { index in
            ChatChoiceItem(
                id: "item-\(index)",
                title: "Item \(index)",
                detail: index.isMultiple(of: 3) ? "A detail line" : nil,
                group: index < count / 2 ? "First" : "Second"
            )
        }
    }

    /// The fitting size of the popover's content in a window, once the list
    /// has measured its rows: its height follows its scroll geometry, a pass
    /// after the first layout.
    private func fittingSize(itemCount: Int, scheme: ColorScheme) async -> CGSize {
        let state = ZenChoiceMenuState(title: "Choose an item", items: items(itemCount), mode: .single)
        let host = NSHostingView(rootView: ZenChoicePopover(state: state) { _ in }
            .environment(\.colorScheme, scheme))
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 600, height: 900),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        window.contentView = host
        var size = host.fittingSize
        for _ in 0..<20 {
            host.layoutSubtreeIfNeeded()
            try? await Task.sleep(for: .milliseconds(10))
            size = host.fittingSize
        }
        window.contentView = nil
        return size
    }

    @Test(
        "the popover grows with the items up to its cap and scrolls the rest",
        arguments: [ColorScheme.light, .dark]
    )
    func listIsCapped(scheme: ColorScheme) async {
        let few = await fittingSize(itemCount: 3, scheme: scheme)
        let many = await fittingSize(itemCount: 200, scheme: scheme)
        let more = await fittingSize(itemCount: 400, scheme: scheme)

        // A short menu leaves the popover shorter than a long one.
        #expect(few.height < many.height)
        // Past the cap the list scrolls: twice the items, the same height.
        #expect(abs(more.height - many.height) <= 1)
        // Shorter than the smallest window (520 points).
        #expect(many.height < 520)
        #expect(more.height < 520)
        // The width does not follow the items.
        #expect(few.width == ZenChoicePopover.width)
        #expect(many.width == ZenChoicePopover.width)
    }
}
