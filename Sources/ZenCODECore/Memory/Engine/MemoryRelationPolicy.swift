//
//  MemoryRelationPolicy.swift
//  ZenCODE
//
//  How co-relevance (`relatesTo`) links are born, grow and are capped. Nothing
//  here is persisted: the wire format of the edges is unchanged.
//

import Foundation

/// Bounds and weights of the `relatesTo` links that recall maintenance
/// discovers between memories selected together.
///
/// A link is born at ``initialWeight``; every further co-selection of the same
/// pair adds ``reinforcementStep`` up to ``maximumWeight`` (a heavier existing
/// weight is never lowered). Each memory keeps at most
/// ``maximumLinksPerMemory`` outgoing links: making room for a new one drops
/// the weakest, the oldest among equals, together with its mirror link.
struct MemoryRelationPolicy: Sendable, Equatable {
    /// Maximum outgoing `relatesTo` links of one memory.
    var maximumLinksPerMemory: Int
    /// Weight of a link created by a first co-selection.
    var initialWeight: Float
    /// Weight added by every further co-selection of the same pair.
    var reinforcementStep: Float
    /// Weight reinforcement never goes past.
    var maximumWeight: Float

    static let `default` = MemoryRelationPolicy(
        maximumLinksPerMemory: 12,
        initialWeight: 0.7,
        reinforcementStep: 0.05,
        maximumWeight: 0.9
    )

    init(
        maximumLinksPerMemory: Int = 12,
        initialWeight: Float = 0.7,
        reinforcementStep: Float = 0.05,
        maximumWeight: Float = 0.9
    ) {
        self.maximumLinksPerMemory = max(1, maximumLinksPerMemory)
        self.initialWeight = Self.clamped(initialWeight)
        self.reinforcementStep = max(0, reinforcementStep)
        self.maximumWeight = max(Self.clamped(maximumWeight), self.initialWeight)
    }

    /// Weight of a pair that already exists with `existing` as its heaviest
    /// link: one step up, capped at ``maximumWeight`` and never below
    /// `existing`, so a legacy weight above the cap survives untouched.
    ///
    /// The sum is rounded to three decimals so repeated reinforcement cannot
    /// accumulate binary floating point noise in the stored weight.
    func reinforcedWeight(from existing: Float) -> Float {
        let stepped = ((existing + reinforcementStep) * 1_000).rounded() / 1_000
        return max(existing, min(stepped, maximumWeight))
    }

    private static func clamped(_ weight: Float) -> Float {
        min(max(weight, 0), 1)
    }
}
