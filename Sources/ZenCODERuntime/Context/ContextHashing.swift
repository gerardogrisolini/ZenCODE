//
//  ContextHashing.swift
//  ZenCODE
//
//  Created by Gerardo Grisolini on 30/05/26.
//

import Foundation

enum ContextFileReadState {
    case missing
    case loaded(String)
    case unreadable
}

func readContextFile(
    at fileURL: URL,
    fileManager: FileManager
) -> ContextFileReadState {
    guard fileManager.fileExists(atPath: fileURL.path) else {
        return .missing
    }

    do {
        return .loaded(try String(contentsOf: fileURL, encoding: .utf8))
    } catch {
        return .unreadable
    }
}
