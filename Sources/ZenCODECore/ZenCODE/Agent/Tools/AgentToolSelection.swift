//
//  AgentToolSelection.swift
//  ZenCODE
//
//  Created by Gerardo Grisolini on 27/05/26.
//
import Foundation

public enum AgentToolSelection {
    public static func selectableDescriptors(
        additionalDescriptors: [DirectToolDescriptor] = []
    ) -> [DirectToolDescriptor] {
        DirectToolExecutor.canonicalized(
            DirectToolCatalog.selectableDescriptors
                + SwiftFeatureRuntime.defaultFeatureToolDescriptors(includeDisabled: true)
                + additionalDescriptors
        )
    }
}
