//
//  RemoteModelCatalogModels.swift
//  ZenCODE
//

import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

struct RemoteModelCatalogResponse: Decodable {
    let data: [RemoteModelCatalogEntry]
}

struct RemoteModelCatalogEntry: Decodable {
    let values: [String: JSONValue]

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: DynamicCodingKey.self)
        var values: [String: JSONValue] = [:]
        for key in container.allKeys {
            values[key.stringValue] = try container.decode(JSONValue.self, forKey: key)
        }
        self.values = values
    }
}

struct RemoteModelCatalogErrorEnvelope: Decodable {
    struct ErrorBody: Decodable {
        let message: String?
    }

    let error: ErrorBody?
}

struct DynamicCodingKey: CodingKey {
    let stringValue: String
    let intValue: Int?

    init?(stringValue: String) {
        self.stringValue = stringValue
        self.intValue = nil
    }

    init?(intValue: Int) {
        self.stringValue = String(intValue)
        self.intValue = intValue
    }
}

