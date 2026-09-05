import Testing
@testable import ZenCODECore

@Suite
struct ZenCODESetupPromptingTests {
    @Test
    func yesNoDisplaysHelpBeforeSelection() throws {
        let help = "This operation removes configuration."
        var events: [String] = []
        let result = try ZenCODESetupRunner.promptYesNo(
            "Continue?",
            defaultValue: false,
            help: help,
            writeHelp: { events.append($0) },
            selectOne: { title, items, selected in
                events.append("selection")
                #expect(title == "Continue?")
                #expect(items.map(\.value) == [true, false])
                #expect(!selected)
                return selected
            }
        )
        #expect(!result)
        #expect(events == ["\(help)\n", "selection"])
    }

    @Test
    func yesNoWithoutHelpDoesNotWriteAnAdvisory() throws {
        let result = try ZenCODESetupRunner.promptYesNo(
            "Continue?",
            defaultValue: true,
            writeHelp: { _ in Issue.record("Unexpected help output") },
            selectOne: { _, _, selected in selected }
        )
        #expect(result)
    }

    @Test
    func yesNoCancellationDoesNotAcceptDefault() {
        do {
            _ = try ZenCODESetupRunner.promptYesNo(
                "Continue?",
                defaultValue: true,
                selectOne: { _, _, _ in nil }
            )
            Issue.record("Cancellation must throw, not accept the default")
        } catch ZenCODESetupError.cancelled {
            // Expected setup cancellation.
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
    }

    @Test(arguments: [Set<Int>(), Set([0])])
    func multipleSelectionCancellationDoesNotAcceptDefault(defaults: Set<Int>) {
        do {
            _ = try ZenCODESetupRunner.promptMenuSelection(
                title: "Models",
                items: modelItems,
                selected: defaults,
                select: { _, _, selected in
                    #expect(selected == defaults)
                    return nil
                }
            )
            Issue.record("Cancellation must throw, not accept the default")
        } catch ZenCODESetupError.cancelled {
            // Expected for Esc/Q or end of input reported as nil by the menu.
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
    }

    @Test(arguments: [Set<Int>(), Set([0]), Set([1])])
    func multipleSelectionPreservesExplicitConfirmation(selection: Set<Int>) throws {
        let result = try ZenCODESetupRunner.promptMenuSelection(
            title: "Models",
            items: modelItems,
            selected: [0],
            select: { _, _, _ in selection }
        )
        #expect(result == selection)
    }

    @Test
    func resetWarningDescribesIndexOnlyAndDefaultsToNo() throws {
        let result = try ZenCODESetupRunner.confirmRemoteConfigurationReset(
            prompt: { title, selected, help in
                #expect(title == "Reset remote configuration?")
                #expect(!selected)
                #expect(help == "This removes provider settings, profiles, permissions, global ZenCODE context, and the saved-session index (sessions.json). Per-project session files (.session) are not removed.")
                var displayedHelp = ""
                return try ZenCODESetupRunner.promptYesNo(
                    title,
                    defaultValue: selected,
                    help: help,
                    writeHelp: { displayedHelp += $0 },
                    selectOne: { _, _, defaultValue in
                        #expect(displayedHelp == "\(help ?? "")\n")
                        return defaultValue
                    }
                )
            }
        )
        #expect(!result)
    }

    private var modelItems: [TerminalCheckboxMenuItem<Int>] {
        [
            TerminalCheckboxMenuItem(value: 0, title: "First model", detail: nil),
            TerminalCheckboxMenuItem(value: 1, title: "Second model", detail: nil)
        ]
    }
}
