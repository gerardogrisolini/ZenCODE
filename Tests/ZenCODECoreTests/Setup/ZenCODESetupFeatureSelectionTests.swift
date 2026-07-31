//
//  ZenCODESetupFeatureSelectionTests.swift
//  ZenCODE
//

import Foundation
@testable import ZenCODECore
import Testing

@Suite
struct ZenCODESetupFeatureSelectionTests {
    @Test
    func featurePlanSeparatesInstallUpdateAndToggleIntents() {
        let plan = ZenCODESetupRunner.featureSelectionPlan(
            requested: [
                .toggle("git-tools"),
                .toggle("swift-tools"),
                .install("web-tools"),
                .update("swift-tools")
            ],
            enabledIDs: ["swift-tools", "figma-tools"]
        )

        #expect(plan.idsToInstall == ["web-tools"])
        #expect(plan.idsToUpdate == ["swift-tools"])
        // git-tools was checked and is not enabled yet, so it is enabled here.
        #expect(plan.idsToEnable == ["git-tools"])
        // figma-tools lost its check and is not being reinstalled.
        #expect(plan.idsToDisable == ["figma-tools"])
        // The reinstall carries the enabled intent instead of a separate toggle.
        #expect(plan.enabledAfterUpdate == ["swift-tools"])
    }

    @Test
    func updatedFeatureIsNeverEnabledOrDisabledOutsideItsReinstall() {
        let plan = ZenCODESetupRunner.featureSelectionPlan(
            requested: [.update("git-tools")],
            enabledIDs: ["git-tools"]
        )

        #expect(plan.idsToUpdate == ["git-tools"])
        #expect(plan.idsToEnable.isEmpty)
        // Unchecking the feature row while updating means "reinstall disabled",
        // which the install itself applies through the rewritten manifest.
        #expect(plan.idsToDisable.isEmpty)
        #expect(plan.enabledAfterUpdate.isEmpty)
    }

    @Test
    func unchangedSelectionProducesNoActions() {
        let plan = ZenCODESetupRunner.featureSelectionPlan(
            requested: [.toggle("git-tools"), .toggle("swift-tools")],
            enabledIDs: ["git-tools", "swift-tools"]
        )

        #expect(plan == ZenCODESetupRunner.FeatureSelectionPlan())
    }
}
