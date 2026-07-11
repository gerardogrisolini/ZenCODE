//
//  DirectTodoTaskRuntime+Rendering.swift
//  ZenCODE
//

import Foundation

extension DirectTodoTaskRuntime {
    public static func renderTodos(_ todos: [Todo]) -> String {
        guard !todos.isEmpty else {
            return "No todos."
        }
        return todos.map { todo in
            "[\(todo.status.rawValue)] \(todo.id): \(todo.content)"
        }.joined(separator: "\n")
    }

    public static func renderTasks(_ tasks: [TaskItem]) -> String {
        guard !tasks.isEmpty else {
            return "No tasks."
        }
        return tasks.map { task in
            var fragments = [
                "[\(task.status.rawValue)] \(task.id): \(task.title)",
                "priority=\(task.priority.rawValue)"
            ]
            if let assigneeAgentID = task.assigneeAgentID {
                fragments.append("assignee=\(assigneeAgentID)")
            }
            if !task.dependsOn.isEmpty {
                fragments.append("depends_on=\(task.dependsOn.joined(separator: ","))")
            }
            if let details = task.details {
                fragments.append("details=\(details)")
            }
            if let output = task.output {
                fragments.append("output=\(output)")
            }
            return fragments.joined(separator: " | ")
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
