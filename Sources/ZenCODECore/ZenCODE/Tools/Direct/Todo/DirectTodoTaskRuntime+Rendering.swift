//
//  DirectTodoTaskRuntime+Rendering.swift
//  ZenCODE
//

import Foundation

extension DirectTodoRuntime {
    public static func renderTodos(_ todos: [Todo]) -> String {
        guard !todos.isEmpty else {
            return "No todos."
        }
        return todos.map { todo in
            "[\(todo.status.rawValue)] \(todo.id): \(todo.content)"
        }.joined(separator: "\n")
    }

    public static func orderedValues<T>(
        from valuesByID: [String: T],
        preserving identifiers: [String]
    ) -> [T] {
        var values: [T] = []
        var seenIdentifiers = Set<String>()
        for identifier in identifiers where seenIdentifiers.insert(identifier).inserted {
            if let value = valuesByID[identifier] {
                values.append(value)
            }
        }
        return values
    }
}
