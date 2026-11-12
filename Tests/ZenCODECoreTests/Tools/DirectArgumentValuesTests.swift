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

    /// The todo.write schema shows the model only the canonical `todos` array;
    /// the root single-item form and the `title`/`depends_on` aliases stay
    /// accepted for models that still send them.
    @Test
    func requestedTodosStillAcceptsTheRootSingleItemFormAndLegacyAliases() throws {
        let root = try DirectTodoRuntime.requestedTodos(from: [
            "id": .string("root"),
            "title": .string("Root form with the title alias"),
            "status": .string("pending"),
            "depends_on": .array([.string("first")])
        ])
        #expect(root.count == 1)
        #expect(root[0].id == "root")
        #expect(root[0].content == "Root form with the title alias")
        #expect(root[0].dependsOn == ["first"])

        let aliasedItem = try DirectTodoRuntime.requestedTodos(from: [
            "todos": .array([
                .object([
                    "id": .string("item"),
                    "title": .string("Item with the title alias"),
                    "depends_on": .array([])
                ])
            ])
        ])
        #expect(aliasedItem.count == 1)
        #expect(aliasedItem[0].content == "Item with the title alias")
        #expect(aliasedItem[0].dependsOn == [])
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
