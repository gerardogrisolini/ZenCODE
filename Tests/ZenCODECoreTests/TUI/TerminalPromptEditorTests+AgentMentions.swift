//
//  TerminalPromptEditorTests+AgentMentions.swift
//  ZenCODE
//
//  Tests of the handles the prompt editor offers for mentioning the active
//  agents of a shared chat.
//

import Foundation
import Synchronization
import Testing
@testable import ZenCODECore
@testable import ZenCODERuntime

extension TerminalPromptEditorTests {
    @Test
    func activeAgentMentionHandlesAreUniqueSafeReadableAndRouteByID() async {
        let catalog = SharedChatMentionCatalog()
        let participants = [
            AgentSharedChat.Participant(id: "planner-1", name: "Planning Agent", kind: .agent),
            AgentSharedChat.Participant(id: "planner-2", name: "Planning Agent", kind: .agent),
            AgentSharedChat.Participant(id: "reviewer", name: "Code Reviewer", kind: .agent),
            AgentSharedChat.Participant(id: "\u{1B}[31m odd", name: "review\r\u{7F}\u{85}", kind: .agent),
            AgentSharedChat.Participant(id: "inactive", name: "inactive", kind: .agent, isActive: false),
            AgentSharedChat.Participant(id: "coordinator", name: "coordinator", kind: .coordinator)
        ]
        let handleMap = await catalog.handleMap(for: participants)
        let suggestions = TerminalChat.sharedChatMentionSuggestions(
            for: participants,
            handleMap: handleMap
        )
        let commands = suggestions.map(\.command)

        // Reserved (@all, @coordinator) + 4 active agents.
        #expect(commands.count == 6)
        #expect(Set(commands).count == commands.count)
        #expect(commands.contains("@all "))
        #expect(commands.contains("@coordinator "))
        // Readable handles are derived from the display name, not opaque Base64.
        #expect(commands.contains("@planning-agent "))
        #expect(commands.contains("@planning-agent-2 "))
        #expect(commands.contains("@code-reviewer "))
        // Sanitised: control/escape characters dropped, leaving a clean slug.
        let oddHandle = handleMap.first(where: { $0.value == "\u{1B}[31m odd" })?.key
        #expect(oddHandle == "review")
        #expect(commands.contains("@review "))
        // Every suggestion is terminal-safe: no ESC, DEL, CR or control bytes.
        #expect(suggestions.allSatisfy { suggestion in
            !suggestion.command.unicodeScalars.contains { scalar in
                scalar.value == 0x1B
                    || scalar.value == 0x7F
                    || scalar.value < 0x20
                    || (0x80...0x9F).contains(scalar.value)
            }
            && !suggestion.summary.unicodeScalars.contains { scalar in
                scalar.value == 0x1B
                    || scalar.value == 0x7F
                    || scalar.value == 0x0D
                    || scalar.value < 0x20
                    || (0x80...0x9F).contains(scalar.value)
            }
        })

        // Routing is always by stable id behind the readable handle.
        for participant in participants where participant.kind == .agent && participant.isActive {
            let handle = handleMap.first(where: { $0.value == participant.id })?.key
            let resolved = handle.flatMap { handleMap[$0] }
            #expect(resolved == participant.id)
            #expect(
                TerminalChat.parseSharedChatMention(
                    from: "@\(handle ?? "x") inspect the work",
                    readableHandles: handleMap
                ) == .route(TerminalChat.SharedChatMentionRoute(
                    destination: .direct([participant.id]),
                    text: "inspect the work"
                ))
            )
        }
        #expect(TerminalChat.parseSharedChatMention(
            from: "@all report status",
            readableHandles: handleMap
        ) == .route(TerminalChat.SharedChatMentionRoute(destination: .all, text: "report status")))
        #expect(TerminalChat.parseSharedChatMention(
            from: "@COORDINATOR report status",
            readableHandles: handleMap
        ) == .route(TerminalChat.SharedChatMentionRoute(destination: .coordinator, text: "report status")))
        // A raw display name is not a handle: only catalogue handles route.
        #expect(TerminalChat.parseSharedChatMention(
            from: "@Planning Agent ambiguous",
            readableHandles: handleMap
        ) == .none)
        #expect(TerminalChat.parseSharedChatMention(from: "@all", readableHandles: handleMap)
            == .missingText(destination: .all))
        #expect(TerminalChat.parseSharedChatMention(
            from: "@coordinator   ",
            readableHandles: handleMap
        ) == .missingText(destination: .coordinator))
        let firstHandle = handleMap.first(where: { $0.value == participants[0].id })?.key
        #expect(TerminalChat.parseSharedChatMention(
            from: "@\(firstHandle ?? "x")",
            readableHandles: handleMap
        ) == .missingText(destination: .direct([participants[0].id])))
        #expect(TerminalChat.parseSharedChatMention(
            from: "@not-a-live-mention",
            readableHandles: handleMap
        ) == .none)

        // Hidden backward compatibility: the legacy @agent-Base64 spelling
        // still resolves to the same stable id, even though it is never offered
        // by the autocomplete list.
        let compatHandle = SharedChatMentionParser.mentionHandle(forParticipantID: participants[0].id)
        #expect(
            TerminalChat.parseSharedChatMention(
                from: "@\(compatHandle) legacy routing",
                readableHandles: [:]
            ) == .route(TerminalChat.SharedChatMentionRoute(
                destination: .direct([participants[0].id]),
                text: "legacy routing"
            ))
        )

        // Aliases are never recycled: a second participant with the same name
        // gets a fresh suffix even after the first left the roster.
        let staleMap = await catalog.handleMap(for: [participants[0]])
        #expect(staleMap["planning-agent"] == participants[0].id)
        let reissueMap = await catalog.handleMap(
            for: [AgentSharedChat.Participant(id: "planner-3", name: "Planning Agent", kind: .agent)]
        )
        #expect(reissueMap["planning-agent-3"] != nil)
        // A session reset clears the alias space.
        await catalog.reset()
        let freshMap = await catalog.handleMap(
            for: [AgentSharedChat.Participant(id: "planner-3", name: "Planning Agent", kind: .agent)]
        )
        #expect(freshMap["planning-agent"] == "planner-3")
    }

    @Test
    func agentsNamedAllOrCoordinatorGetSuffixedHandlesThatRouteToTheirId() async {
        let catalog = SharedChatMentionCatalog()
        let participants = [
            AgentSharedChat.Participant(id: "all-id", name: "all", kind: .agent),
            AgentSharedChat.Participant(id: "coord-id", name: "Coordinator", kind: .agent),
        ]
        let handleMap = await catalog.handleMap(for: participants)
        let suggestions = TerminalChat.sharedChatMentionSuggestions(
            for: participants,
            handleMap: handleMap
        )
        let commands = suggestions.map(\.command)

        // The colliding agents are still suggested, under their suffixed
        // handles; the bare broadcast spellings appear exactly once as the
        // reserved mentions and are never duplicated as direct-agent handles.
        #expect(commands.contains("@all-2 "))
        #expect(commands.contains("@coordinator-2 "))
        #expect(commands.filter { $0 == "@all " }.count == 1)
        #expect(commands.filter { $0 == "@coordinator " }.count == 1)

        // The parser routes the suffixed handles to the right agent ids…
        #expect(
            TerminalChat.parseSharedChatMention(
                from: "@all-2 inspect the diff",
                readableHandles: handleMap
            ) == .route(TerminalChat.SharedChatMentionRoute(
                destination: .direct(["all-id"]),
                text: "inspect the diff"
            ))
        )
        #expect(
            TerminalChat.parseSharedChatMention(
                from: "@coordinator-2 inspect the diff",
                readableHandles: handleMap
            ) == .route(TerminalChat.SharedChatMentionRoute(
                destination: .direct(["coord-id"]),
                text: "inspect the diff"
            ))
        )
        // …while the unsuffixed spellings keep their broadcast meaning.
        #expect(
            TerminalChat.parseSharedChatMention(
                from: "@all inspect the diff",
                readableHandles: handleMap
            ) == .route(TerminalChat.SharedChatMentionRoute(destination: .all, text: "inspect the diff"))
        )
        #expect(
            TerminalChat.parseSharedChatMention(
                from: "@coordinator inspect the diff",
                readableHandles: handleMap
            ) == .route(TerminalChat.SharedChatMentionRoute(
                destination: .coordinator,
                text: "inspect the diff"
            ))
        )
    }
}
