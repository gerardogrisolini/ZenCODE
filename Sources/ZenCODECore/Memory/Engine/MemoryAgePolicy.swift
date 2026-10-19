//
//  MemoryAgePolicy.swift
//  ZenCODE
//
//  Created by Gerardo Grisolini on 19/10/26.
//
//  How the age of an entry discounts its retrieval score.
//

import Foundation

/// Age discount applied to retrieval scores.
///
/// A project journal is maintained in place: a long-lived entry that is kept
/// current is worth as much as a new one, and an old entry still matched by
/// the query should lose to a newer one only moderately, never to a weakly
/// matching recent note. The discount therefore measures age from the last
/// content change, halves slowly (months, not weeks) and never falls below a
/// floor, so between two old entries relevance decides rather than a
/// near-zero factor.
struct MemoryAgePolicy: Sendable, Equatable {
    /// Days after which the discount of an entry of each category halves.
    var factHalfLifeDays: Float
    var preferenceHalfLifeDays: Float
    var entityHalfLifeDays: Float
    var correctionHalfLifeDays: Float
    var customHalfLifeDays: Float
    /// Lowest value the discount can reach, in [0, 1].
    var floor: Float

    init(
        factHalfLifeDays: Float = 120,
        preferenceHalfLifeDays: Float = 90,
        entityHalfLifeDays: Float = 120,
        correctionHalfLifeDays: Float = 365,
        customHalfLifeDays: Float = 120,
        floor: Float = 0.2
    ) {
        self.factHalfLifeDays = max(factHalfLifeDays, 1)
        self.preferenceHalfLifeDays = max(preferenceHalfLifeDays, 1)
        self.entityHalfLifeDays = max(entityHalfLifeDays, 1)
        self.correctionHalfLifeDays = max(correctionHalfLifeDays, 1)
        self.customHalfLifeDays = max(customHalfLifeDays, 1)
        self.floor = min(max(floor, 0), 1)
    }

    static let `default` = MemoryAgePolicy()

    func halfLifeDays(for category: EngineMemoryCategory) -> Float {
        switch category {
        case .fact: factHalfLifeDays
        case .preference: preferenceHalfLifeDays
        case .entity: entityHalfLifeDays
        case .correction: correctionHalfLifeDays
        case .custom: customHalfLifeDays
        }
    }

    /// Discount in `[floor, 1]` for an entry whose content last changed
    /// `ageDays` ago: exponential decay with the category's half-life, lifted
    /// onto the floor.
    func discount(ageDays: Float, category: EngineMemoryCategory) -> Float {
        let decay = expf(-max(ageDays, 0) / halfLifeDays(for: category) * 0.693)
        return floor + (1 - floor) * decay
    }
}
