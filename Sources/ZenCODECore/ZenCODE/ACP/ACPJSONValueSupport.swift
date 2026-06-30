//
//  ACPJSONValueSupport.swift
//  ZenCODE
//
//  Created by Gerardo Grisolini on 26/05/26.
//

import Foundation

extension JSONValue {
    public static func acpValue(from value: Any?) -> JSONValue {
        JSONValue(jsonObject: value)
    }

    public static func acpRequestID(from value: Any?) -> JSONValue? {
        guard let value else {
            return nil
        }
        return acpValue(from: value)
    }

    public var acpStringValue: String? {
        guard case let .string(value) = self else {
            return nil
        }
        return value
    }

    public var acpJSONObject: Any {
        jsonObject
    }
}
