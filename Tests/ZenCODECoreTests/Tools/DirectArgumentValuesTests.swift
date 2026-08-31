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
    func requestedTodosFallsBackToSnakeCaseStringListWhenCamelCaseListIsEmpty() throws {
        let todos = try DirectTodoRuntime.requestedTodos(from: [
            "content": .string("Use the dependency alias"),
            "dependsOn": .array([]),
            "depends_on": .array([.string("setup")])
        ])

        #expect(todos.count == 1)
        #expect(todos[0].dependsOn == ["setup"])
    }

    @Test
    func requestedTodosPreservesFirstNonEmptyArrayAliasPrecedence() throws {
        let todos = try DirectTodoRuntime.requestedTodos(from: [
            "todos": .array([
                .object(["content": .string("Preferred alias")])
            ]),
            "items": .array([
                .object(["content": .string("Fallback alias")])
            ])
        ])

        #expect(todos.count == 1)
        #expect(todos[0].content == "Preferred alias")
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
    func firstStringListSkipsBlankArrayElementsBeforeFallback() throws {
        let values = DirectArgumentValues.firstStringList(
            ["primary", "fallback"],
            in: [
                "primary": .array([
                    .string(""),
                    .string(" \t\n")
                ]),
                "fallback": .array([.string("from-fallback")])
            ]
        ) { value in
            if case let .string(string) = value { return string }
            return nil
        }

        #expect(values == ["from-fallback"])
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

    @Test
    func firstStringListPreservesNonBlankScalarAliasPrecedence() throws {
        let values = DirectArgumentValues.firstStringList(
            ["primary", "fallback"],
            in: [
                "primary": .string("preferred"),
                "fallback": .string("fallback")
            ]
        ) { value in
            if case let .string(string) = value { return string }
            return nil
        }

        #expect(values == ["preferred"])
    }
}
