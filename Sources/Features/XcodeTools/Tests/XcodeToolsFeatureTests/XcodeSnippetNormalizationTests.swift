import Foundation
import ToolCore
@testable import XcodeToolsFeature
import Testing

/// Request-normalization and indentation-retry regressions. Everything here is
/// pure string/JSON work and never touches Xcode.
@Suite
struct XcodeSnippetNormalizationTests {
    // MARK: - Member-access prefix restoration

    @Test(arguments: [
        "Task {\n    await load()\n}\nreload()",
        "withAnimation {\n    expanded.toggle()\n}\nfoo()",
        "DispatchQueue.main.async {\n    update()\n}\nfoo()",
        "lock.withLock {\n    counter += 1\n}\nfoo()",
        "Task.detached {\n    await work()\n}\nfoo()",
        "if isReady {\n    start()\n}\nfinish()",
        "Thread {\n    run()\n}\nstart()"
    ])
    func ordinaryCallsAfterClosuresAreNotTurnedIntoModifiers(snippet: String) {
        #expect(restoredLikelySwiftMemberAccessPrefixes(in: snippet) == snippet)
    }

    @Test
    func swiftUIContainerFollowedByDroppedModifierIsRestored() {
        #expect(
            restoredLikelySwiftMemberAccessPrefixes(in: "VStack {\n    Text(\"a\")\n}\npadding()")
                == "VStack {\n    Text(\"a\")\n}\n.padding()"
        )
        #expect(
            restoredLikelySwiftMemberAccessPrefixes(
                in: "Button(action: foo) {\n    Text(\"Go\")\n}\npadding()"
            ) == "Button(action: foo) {\n    Text(\"Go\")\n}\n.padding()"
        )
        #expect(
            restoredLikelySwiftMemberAccessPrefixes(in: ".onTapGesture {\n    tap()\n}\npadding()")
                == ".onTapGesture {\n    tap()\n}\n.padding()"
        )
    }

    @Test
    func modifierChainsKeepTheirRestorationRules() {
        // Rule 2: previous line is a modifier at the same indentation.
        #expect(
            restoredLikelySwiftMemberAccessPrefixes(
                in: "Text(\"x\")\n    .onAppear {\n        load()\n    }\n    padding()"
            ) == "Text(\"x\")\n    .onAppear {\n        load()\n    }\n    .padding()"
        )
        #expect(
            restoredLikelySwiftMemberAccessPrefixes(in: "Text(\"x\")\n    .bold()\n    padding()")
                == "Text(\"x\")\n    .bold()\n    .padding()"
        )
        // Rule 3: deeper indentation under an expression anchor.
        #expect(
            restoredLikelySwiftMemberAccessPrefixes(in: "Text(\"x\")\n    padding()")
                == "Text(\"x\")\n    .padding()"
        )
        // A later block at the same indentation replaces the earlier anchor.
        #expect(
            restoredLikelySwiftMemberAccessPrefixes(
                in: "VStack {\n    Text(\"a\")\n}\nTask {\n    await load()\n}\nreload()"
            ) == "VStack {\n    Text(\"a\")\n}\nTask {\n    await load()\n}\nreload()"
        )
    }

    // MARK: - Argument aliases

    @Test
    func tabIdentifierAliasesSurviveForPassThroughTools() throws {
        for toolName in ["BuildProject", "GetTestList", "RunAllTests", "XcodeListNavigatorIssues"] {
            let normalized = try #require(XcodeToolRequestCompatibility.normalize(ToolRequest(
                name: toolName,
                arguments: ["tab_id": .string("tab-1"), "extra": .bool(true)]
            )))
            #expect(normalized.arguments["tabIdentifier"]?.stringValue == "tab-1", "\(toolName)")
        }
        let passThrough = try #require(XcodeToolRequestCompatibility.normalize(ToolRequest(
            name: "BuildProject",
            arguments: ["tab_id": .string("tab-1"), "extra": .bool(true)]
        )))
        #expect(passThrough.arguments["extra"]?.boolValue == true)
        #expect(passThrough.arguments["tab_id"]?.stringValue == "tab-1")
    }

    @Test
    func unknownPrefixedToolsAreForwardedAndUnknownNamesAreRejected() throws {
        // Already accepted by the `Xcode` prefix rule at HEAD; must keep working.
        let prefixed = try XcodeToolsFeatureRunner.bridgeRequest(
            toolName: "xcode.XcodeNewTool",
            inputData: Data(#"{"tab_id":"t"}"#.utf8),
            toolNamePrefix: XcodeToolIntegration.toolPrefix
        )
        #expect(prefixed.name == "XcodeNewTool")
        #expect(prefixed.arguments["tab_id"]?.stringValue == "t")

        // Not in the compatibility table at all: forwarded verbatim instead of
        // being reported as "Xcode MCP is not available".
        let forwarded = try XcodeToolsFeatureRunner.bridgeRequest(
            toolName: "xcode.ListSchemes",
            inputData: Data(#"{"a":1}"#.utf8),
            toolNamePrefix: XcodeToolIntegration.toolPrefix
        )
        #expect(forwarded.name == "ListSchemes")
        #expect(forwarded.arguments["a"]?.numberValue == 1)

        let aliased = try XcodeToolsFeatureRunner.bridgeRequest(
            toolName: "xcode.read",
            inputData: Data(#"{"path":"Sources/App.swift"}"#.utf8),
            toolNamePrefix: XcodeToolIntegration.toolPrefix
        )
        #expect(aliased.name == "XcodeRead")
        #expect(aliased.arguments["filePath"]?.stringValue == "Sources/App.swift")

        #expect(throws: XcodeFeatureError.unknownTool("figma.get_node")) {
            try XcodeToolsFeatureRunner.bridgeRequest(
                toolName: "figma.get_node",
                inputData: Data(),
                toolNamePrefix: XcodeToolIntegration.toolPrefix
            )
        }
        #expect(throws: XcodeFeatureError.unknownTool("xcode.")) {
            try XcodeToolsFeatureRunner.bridgeRequest(
                toolName: "xcode.",
                inputData: Data(),
                toolNamePrefix: XcodeToolIntegration.toolPrefix
            )
        }
    }

    // MARK: - Indentation retry

    private func request(old: String, new: String) -> ToolRequest {
        ToolRequest(
            name: "XcodeUpdate",
            arguments: [
                "filePath": .string("Sources/App.swift"),
                "oldString": .string(old),
                "newString": .string(new)
            ]
        )
    }

    @Test
    func closestMatchIsReadFromContentArrayErrorResults() {
        let failure: JSONValue = .object([
            "isError": .bool(true),
            "content": .array([
                .object([
                    "type": .string("text"),
                    "text": .string("No exact edit match. Closest match found:\n    let answer = 1")
                ])
            ])
        ])

        let retry = retriedXcodeUpdateRequestForIndentationMismatch(
            originalRequest: request(old: "let answer = 1", new: "let answer = 2"),
            failureResult: failure
        )

        #expect(retry?.arguments["oldString"]?.stringValue == "    let answer = 1")
        #expect(retry?.arguments["newString"]?.stringValue == "    let answer = 2")
        #expect(retry?.arguments["filePath"]?.stringValue == "Sources/App.swift")
    }

    @Test
    func closestMatchKeepsNumericCodeAndStripsRealLineNumbers() {
        #expect(
            xcodeClosestMatchSnippetFromMessage("Closest match found:\n    0.5 * x\n    1 + y")
                == "    0.5 * x\n    1 + y"
        )
        #expect(
            xcodeClosestMatchSnippetFromMessage("Closest match found at line 12:\n12\t    let a = 1\n13\t    let b = 2")
                == "    let a = 1\n    let b = 2"
        )
        #expect(xcodeClosestMatchSnippetFromMessage("Closest match found:\n\n") == nil)
        #expect(xcodeClosestMatchSnippetFromMessage("No match") == nil)
        #expect(xcodeClosestMatchSnippetFromMessage(nil) == nil)
    }

    @Test
    func noRetryWhenTheMatchIsIdenticalOrNotIndentationOnly() {
        let identical: JSONValue = .object([
            "success": .bool(false),
            "message": .string("Closest match found:\nlet answer = 1")
        ])
        #expect(retriedXcodeUpdateRequestForIndentationMismatch(
            originalRequest: request(old: "let answer = 1", new: "let answer = 2"),
            failureResult: identical
        ) == nil)

        let different: JSONValue = .object([
            "success": .bool(false),
            "message": .string("Closest match found:\n    let answer = 10")
        ])
        #expect(retriedXcodeUpdateRequestForIndentationMismatch(
            originalRequest: request(old: "let answer = 1", new: "let answer = 2"),
            failureResult: different
        ) == nil)

        let applied: JSONValue = .object([
            "structuredContent": .object([
                "editsApplied": .number(1),
                "message": .string("Closest match found:\n    let answer = 1")
            ])
        ])
        #expect(retriedXcodeUpdateRequestForIndentationMismatch(
            originalRequest: request(old: "let answer = 1", new: "let answer = 2"),
            failureResult: applied
        ) == nil)

        #expect(retriedXcodeUpdateRequestForIndentationMismatch(
            originalRequest: request(old: "let answer = 1", new: "let answer = 2"),
            failureResult: .string("not an object")
        ) == nil)
    }

    @Test
    func retryReindentsMultiLineReplacementsUsingTheMatchedBlock() {
        let failure: JSONValue = .object([
            "success": .bool(false),
            "message": .string("Closest match found:\n        if a {\n            b()\n        }")
        ])
        let retry = retriedXcodeUpdateRequestForIndentationMismatch(
            originalRequest: request(
                old: "if a {\n    b()\n}",
                new: "if a {\n    b()\n    c()\n}"
            ),
            failureResult: failure
        )
        #expect(retry?.arguments["oldString"]?.stringValue == "        if a {\n            b()\n        }")
        #expect(retry?.arguments["newString"]?.stringValue == "        if a {\n            b()\n            c()\n        }")
    }
}
