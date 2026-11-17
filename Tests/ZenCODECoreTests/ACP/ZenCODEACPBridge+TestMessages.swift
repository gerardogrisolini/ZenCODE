//
//  ZenCODEACPBridge+TestMessages.swift
//  ZenCODE
//
//  Sends a JSON-RPC message to the bridge as a client does, one line, from a
//  dictionary literal.
//

import Foundation
import Testing
import ToolCore
@testable import ZenCODECore

extension ZenCODEACPBridge {
    /// Dispatches `message` through ``handleLine(_:)``, encoded as the single
    /// JSON line a client writes.
    func handleMessage(_ message: [String: Any]) async {
        let object = JSONValue.object(message.mapValues { JSONValue(jsonObject: $0) })
        guard let data = try? JSONEncoder().encode(object) else {
            Issue.record("The ACP test message cannot be encoded as JSON.")
            return
        }
        await handleLine(String(decoding: data, as: UTF8.self))
    }
}
