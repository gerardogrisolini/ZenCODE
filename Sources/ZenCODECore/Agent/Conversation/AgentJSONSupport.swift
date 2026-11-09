//
//  AgentJSONSupport.swift
//  ZenCODE
//
//  Created by Gerardo Grisolini on 30/05/26.
//

import Foundation
import ToolCore

public enum AgentJSONSupport {
    public static func jsonString(from value: Any) -> String {
        JSONValue(jsonObject: value).compactString(sortedKeys: true)
    }
}
