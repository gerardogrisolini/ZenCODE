//
//  PlanCommandTests+Collector.swift
//  ZenCODE
//
//  Plan command tests for the shared planning kernel, structured planner
//  responses, and the collector that derives plan points and sections from
//  final planner text.
//

import Foundation
import Testing
@testable import ZenCODECore
@testable import ZenCODERuntime

extension PlanCommandTests {
    @Test
    func sharedKernelRejectsTextTaskMismatchAndInvalidDependencyBootstrap() {
        let text = """
        Specifiche concordate
        - Keep compatibility.

        Implementation plan
        1. Implement shared routing.
           Dependencies: none
        2. Validate every frontend.
           Dependencies: 1
        """
        let coherent = [
            TerminalSessionPlanPoint(
                id: "plan-coherent-1",
                text: "Implement shared routing.",
                dependsOn: [],
                hasExplicitDependencies: true
            ),
            TerminalSessionPlanPoint(
                id: "plan-coherent-2",
                text: "Validate every frontend.",
                dependsOn: ["plan-coherent-1"],
                hasExplicitDependencies: true
            ),
        ]
        #expect(PlanningCommandKernel.structuredPlanOutputIsCoherent(
            text: text,
            points: coherent
        ))
        #expect(!PlanningCommandKernel.structuredPlanOutputIsCoherent(
            text: text,
            points: [coherent[0]]
        ))

        var wrongText = coherent
        wrongText[1] = TerminalSessionPlanPoint(
            id: "plan-coherent-2",
            text: "Publish a release instead.",
            dependsOn: ["plan-coherent-1"],
            hasExplicitDependencies: true
        )
        #expect(!PlanningCommandKernel.structuredPlanOutputIsCoherent(
            text: text,
            points: wrongText
        ))

        var wrongDependencies = coherent
        wrongDependencies[1] = TerminalSessionPlanPoint(
            id: "plan-coherent-2",
            text: "Validate every frontend.",
            dependsOn: [],
            hasExplicitDependencies: true
        )
        #expect(!PlanningCommandKernel.structuredPlanOutputIsCoherent(
            text: text,
            points: wrongDependencies
        ))

        var terminalStatus = coherent
        terminalStatus[0] = TerminalSessionPlanPoint(
            id: "plan-coherent-1",
            text: "Implement shared routing.",
            status: .completed,
            dependsOn: [],
            hasExplicitDependencies: true
        )
        #expect(!PlanningCommandKernel.structuredPlanOutputIsCoherent(
            text: text,
            points: terminalStatus
        ))

        var mixedToken = coherent
        mixedToken[1] = TerminalSessionPlanPoint(
            id: "plan-other-2",
            text: "Validate every frontend.",
            dependsOn: ["plan-coherent-1"],
            hasExplicitDependencies: true
        )
        #expect(!PlanningCommandKernel.structuredPlanOutputIsCoherent(
            text: text,
            points: mixedToken
        ))
        #expect(!PlanningCommandKernel.structuredPlanOutputIsCoherent(
            text: "1. Implement shared routing.",
            points: [coherent[0]]
        ))
        for invalidDependency in ["2", "1, 1", "3"] {
            #expect(!PlanningCommandKernel.structuredPlanOutputIsCoherent(
                text: text.replacingOccurrences(
                    of: "Dependencies: 1",
                    with: "Dependencies: \(invalidDependency)"
                ),
                points: coherent
            ))
        }

        let symbolText = """
        Specifiche concordate
        - Preserve concrete identifiers.

        Implementation plan
        1. Update `foo_bar.swift` and preserve C# behavior.
           Dependencies: none
        """
        let symbolPoint = TerminalSessionPlanPoint(
            id: "plan-symbol-1",
            text: "Update `foo_bar.swift` and preserve C# behavior.",
            dependsOn: [],
            hasExplicitDependencies: true
        )
        #expect(PlanningCommandKernel.structuredPlanOutputIsCoherent(
            text: symbolText,
            points: [symbolPoint]
        ))
        #expect(!PlanningCommandKernel.structuredPlanOutputIsCoherent(
            text: symbolText,
            points: [TerminalSessionPlanPoint(
                id: "plan-symbol-1",
                text: "Update foobar.swift and preserve C behavior.",
                dependsOn: [],
                hasExplicitDependencies: true
            )]
        ))

        let cyclic = [
            TerminalSessionPlanPoint(
                id: "plan-cycle-1",
                text: "Implement shared routing.",
                dependsOn: ["plan-cycle-2"],
                hasExplicitDependencies: true
            ),
            TerminalSessionPlanPoint(
                id: "plan-cycle-2",
                text: "Validate every frontend.",
                dependsOn: ["plan-cycle-1"],
                hasExplicitDependencies: true
            ),
        ]
        #expect(!PlanningCommandKernel.structuredPlanOutputIsCoherent(
            text: text,
            points: cyclic
        ))
    }

    private static let structuredThreePointPlannerFinalText = """
    Specifiche concordate
    - Keep compatibility.

    Implementation plan
    1. Add the shared model.
       Dependencies: none
    2. Wire the TUI command.
       Dependencies: 1
    3. Validate every frontend.
       Dependencies: 1, 2
    """

    @Test
    func promotedStructuredPlannerResponseKeepsEveryPointAndDependency() throws {
        let messages = [
            AgentRuntimeMessage(role: .user, content: "Ship the shared routing"),
            AgentRuntimeMessage(
                role: .assistant,
                content: Self.structuredThreePointPlannerFinalText
            ),
        ]

        let plan = try #require(
            PlanningCommandKernel.plansFromLatestAssistantMessage(in: messages).first
        )
        #expect(plan.originalGoal == "Ship the shared routing")
        #expect(plan.consolidatedText == Self.structuredThreePointPlannerFinalText)
        #expect(plan.isApproved == false)
        #expect(plan.id == PlanningCommandKernel.planID(from: plan.points))
        #expect(plan.id.hasPrefix("plan-"))
        #expect(plan.points.map(\.id) == (1...3).map { "\(plan.id)-\($0)" })
        #expect(plan.points.map(\.text) == [
            "Add the shared model.",
            "Wire the TUI command.",
            "Validate every frontend.",
        ])
        #expect(plan.points.map(\.dependsOn) == [
            [],
            ["\(plan.id)-1"],
            ["\(plan.id)-1", "\(plan.id)-2"],
        ])
        #expect(plan.points.allSatisfy { $0.hasExplicitDependencies })
        #expect(plan.points.allSatisfy { $0.status == .pending })
        #expect(PlanningCommandKernel.structuredPlanOutputIsCoherent(
            text: plan.consolidatedText,
            points: plan.points
        ))
    }

    private static let structuredPlannerFinalText = """
    Specifiche concordate
    - Keep compatibility.

    Implementation plan
    1. Implement shared routing.
       Dependencies: none
    2. Validate every frontend.
       Dependencies: 1
    """

    @Test
    func collectorDerivesFinalPlanPointsWhenCoordinatorSkippedTodoWrite() async throws {
        let collector = PlanningPointCollector()

        #expect(await collector.validFinalPlanPoints() == nil)
        let resolved = try #require(
            await collector.finalPlanSections(
                forFinalText: Self.structuredPlannerFinalText
            )?.flatMap(\.points)
        )
        #expect(resolved.count == 2)
        #expect(resolved.allSatisfy({ $0.hasExplicitDependencies }))
        #expect(resolved.allSatisfy({ $0.status == .pending }))
        #expect(resolved.last?.dependsOn == [resolved[0].id])
        #expect(PlanningCommandKernel.structuredPlanOutputIsCoherent(
            text: Self.structuredPlannerFinalText,
            points: resolved
        ))
        // The derived registration is stable and visible to later readers.
        #expect(await collector.snapshot() == resolved)
        #expect(await collector.finalPlanSections(
            forFinalText: Self.structuredPlannerFinalText
        )?.flatMap(\.points) == resolved)
    }

    private static let twoPlanPlannerFinalText = """
    Piano 1/2: Modello condiviso

    Specifiche concordate
    - Keep compatibility.

    Implementation plan
    1. Add the shared model.
       Dependencies: none
    2. Wire the TUI command.
       Dependencies: 1

    Piano 2/2: Validazione

    Specifiche concordate
    - Validate every frontend.

    Implementation plan
    1. Validate the ACP bridge.
       Dependencies: none
    """

    private static let twoPlanFirstSectionText = """
    Piano 1/2: Modello condiviso

    Specifiche concordate
    - Keep compatibility.

    Implementation plan
    1. Add the shared model.
       Dependencies: none
    2. Wire the TUI command.
       Dependencies: 1
    """

    private static let twoPlanSecondSectionText = """
    Piano 2/2: Validazione

    Specifiche concordate
    - Validate every frontend.

    Implementation plan
    1. Validate the ACP bridge.
       Dependencies: none
    """

    private static func registeredPoint(
        _ id: String,
        _ text: String,
        dependsOn: [String] = []
    ) -> TerminalSessionPlanPoint {
        TerminalSessionPlanPoint(
            id: id,
            text: text,
            dependsOn: dependsOn,
            hasExplicitDependencies: true
        )
    }

    private static let twoPlanRegisteredPoints = [
        registeredPoint("plan-alpha-1", "Add the shared model."),
        registeredPoint("plan-alpha-2", "Wire the TUI command.", dependsOn: ["plan-alpha-1"]),
        registeredPoint("plan-beta-1", "Validate the ACP bridge."),
    ]

    @Test
    func collectorResolvesPlanSectionsWithAndWithoutTodoWrite() async throws {
        let derivedCollector = PlanningPointCollector()
        let derived = try #require(await derivedCollector.finalPlanSections(
            forFinalText: Self.twoPlanPlannerFinalText
        ))
        #expect(derived.count == 2)
        #expect(derived.map(\.points.count) == [2, 1])
        #expect(await derivedCollector.snapshot() == derived.flatMap(\.points))
        // The cached derivation is reused for the same final text.
        #expect(await derivedCollector.finalPlanSections(
            forFinalText: Self.twoPlanPlannerFinalText
        ) == derived)
        #expect(await derivedCollector.finalPlanSections(
            forFinalText: Self.twoPlanPlannerFinalText
        )?.flatMap(\.points) == derived.flatMap(\.points))

        let registeredCollector = PlanningPointCollector()
        await registeredCollector.recordTodoWrite(
            (points: Self.twoPlanRegisteredPoints, mode: .upsert)
        )
        let registered = try #require(await registeredCollector.finalPlanSections(
            forFinalText: Self.twoPlanPlannerFinalText
        ))
        #expect(registered.map(\.heading) == ["Piano 1/2: Modello condiviso", "Piano 2/2: Validazione"])
        #expect(registered.map { $0.points.map(\.id) } == [
            ["plan-alpha-1", "plan-alpha-2"],
            ["plan-beta-1"],
        ])
        #expect(await registeredCollector.finalPlanSections(
            forFinalText: Self.twoPlanPlannerFinalText
        )?.flatMap(\.points) == Self.twoPlanRegisteredPoints)

        // A registration that does not split by plan is never replaced by a
        // derived fallback.
        let mismatchedCollector = PlanningPointCollector()
        await mismatchedCollector.recordTodoWrite(
            (points: Array(Self.twoPlanRegisteredPoints[0...1]), mode: .upsert)
        )
        #expect(await mismatchedCollector.finalPlanSections(
            forFinalText: Self.twoPlanPlannerFinalText
        ) == nil)
    }

    @Test
    func promotedMultiPlanResponseYieldsOnePlanPerSection() throws {
        let createdAt = Date(timeIntervalSince1970: 1_000)
        let messages = [
            AgentRuntimeMessage(role: .user, content: "Ship the shared routing"),
            AgentRuntimeMessage(role: .assistant, content: Self.twoPlanPlannerFinalText),
        ]

        let plans = PlanningCommandKernel.plansFromLatestAssistantMessage(
            in: messages,
            createdAt: createdAt
        )
        #expect(plans.count == 2)
        #expect(plans.map(\.originalGoal) == [
            "Piano 1/2: Modello condiviso — Ship the shared routing",
            "Piano 2/2: Validazione — Ship the shared routing",
        ])
        #expect(plans.map(\.consolidatedText) == [
            Self.twoPlanFirstSectionText,
            Self.twoPlanSecondSectionText,
        ])
        #expect(plans.map { $0.points.map(\.text) } == [
            ["Add the shared model.", "Wire the TUI command."],
            ["Validate the ACP bridge."],
        ])
        #expect(plans.allSatisfy { $0.id == PlanningCommandKernel.planID(from: $0.points) })
        #expect(Set(plans.map(\.id)).count == 2)
        #expect(plans.allSatisfy { $0.createdAt == createdAt && !$0.isApproved })
        #expect(plans[1].points.first?.dependsOn == [])
    }
}
