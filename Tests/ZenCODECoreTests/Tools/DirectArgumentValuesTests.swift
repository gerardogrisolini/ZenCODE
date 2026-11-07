import Testing
import ToolCore
@testable import ZenCODECore

@Suite
struct DirectArgumentValuesTests {
    @Test
    func requestedTodosFallsBackToItemsWhenTodosIsEmpty() throws {
        let todos = try DirectTodoRuntime.requestedTodos(from: [
            "todos": .array([]),
            "items": .array([
                .object([
                    "id": .string("from-items"),
                    "content": .string("Use the fallback alias")
                ])
            ])
        ])

        #expect(todos.count == 1)
        #expect(todos[0].id == "from-items")
        #expect(todos[0].content == "Use the fallback alias")
    }

    @Test
    func firstStringListSkipsBlankScalarAliasesBeforeFallback() throws {
        let empty = DirectArgumentValues.firstStringList(
            ["primary", "fallback"],
            in: [
                "primary": .string(""),
                "fallback": .string("from-fallback")
            ]
        ) { value in
            if case let .string(string) = value { return string }
            return nil
        }
        let whitespace = DirectArgumentValues.firstStringList(
            ["primary", "fallback"],
            in: [
                "primary": .string(" \t\n"),
                "fallback": .string("from-fallback")
            ]
        ) { value in
            if case let .string(string) = value { return string }
            return nil
        }

        #expect(empty == ["from-fallback"])
        #expect(whitespace == ["from-fallback"])
    }

    @Test
    func firstStringListPreservesNonBlankArrayElementsAndAliasPrecedence() throws {
        let values = DirectArgumentValues.firstStringList(
            ["primary", "fallback"],
            in: [
                "primary": .array([
                    .string("  preferred  "),
                    .string("\n\t"),
                    .string("second value")
                ]),
                "fallback": .array([.string("from-fallback")])
            ]
        ) { value in
            if case let .string(string) = value { return string }
            return nil
        }

        #expect(values == ["  preferred  ", "second value"])
    }
}
