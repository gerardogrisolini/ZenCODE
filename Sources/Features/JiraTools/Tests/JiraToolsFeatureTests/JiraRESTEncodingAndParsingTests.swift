import FeatureKit
import Foundation
import Testing
import ToolCore
@testable import jira_tools_feature

@Suite
struct JiraRESTEncodingTests {
    @Test
    func queryEncodingEscapesPlusAmpersandAndEqualsAndUnicode() throws {
        let encoded = try #require(JiraRESTService.percentEncodedQuery([
            URLQueryItem(name: "query", value: "C++ login & sign=on é"),
            URLQueryItem(name: "currentJQL", value: ""),
            URLQueryItem(name: "fields", value: "*all")
        ]))
        #expect(encoded == "query=C%2B%2B%20login%20%26%20sign%3Don%20%C3%A9&currentJQL=&fields=%2Aall")

        var components = URLComponents(string: "https://example.atlassian.net/rest/api/3/issue/picker")!
        components.percentEncodedQuery = encoded
        let url = try #require(components.url)
        // Round-trips through URLComponents without being mangled.
        let decoded = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems
        #expect(decoded?.first(where: { $0.name == "query" })?.value == "C++ login & sign=on é")
    }

    @Test
    func emptyQueryItemsProduceNoQueryString() {
        #expect(JiraRESTService.percentEncodedQuery([]) == nil)
    }

    @Test
    func issueKeyExtractionUppercasesAndIgnoresNoise() {
        #expect(JiraIssueKeyExtractor.issueKey(in: "proj-12") == "PROJ-12")
        #expect(JiraIssueKeyExtractor.issueKey(in: "https://example.atlassian.net/browse/ABC-7?x=1") == "ABC-7")
        #expect(JiraIssueKeyExtractor.issueKey(in: "login page is broken") == nil)
        #expect(JiraIssueKeyExtractor.issueKey(in: "") == nil)
    }

    @Test
    func searchQueryItemsRequestRenderedFieldsAndEncodeJQL() throws {
        let encoded = try #require(JiraRESTService.percentEncodedQuery(
            JiraRESTService.searchQueryItems(jql: #"project = ABC AND text ~ "C++""#)
        ))
        #expect(
            encoded
                == "jql=project%20%3D%20ABC%20AND%20text%20~%20%22C%2B%2B%22&maxResults=12&fields=summary%2Cstatus%2Cissuetype%2Cassignee"
        )
    }
}

@Suite
struct JiraSearchRequestTests {
    @Test
    func issueKeysAndURLsInQueryReadTheIssueDirectly() throws {
        #expect(try JiraSearchRequest.resolve(query: "proj-12", jql: nil) == .issueKey("PROJ-12"))
        #expect(
            try JiraSearchRequest.resolve(query: "https://example.atlassian.net/browse/ABC-7", jql: nil)
                == .issueKey("ABC-7")
        )
    }

    @Test
    func freeTextQueryBecomesFullTextJQL() throws {
        #expect(
            try JiraSearchRequest.resolve(query: "  login page broken ", jql: nil)
                == .jql(#"text ~ "login page broken" ORDER BY updated DESC"#)
        )
    }

    @Test
    func jqlIsSentAsIsEvenWhenItMentionsAnIssueKey() throws {
        #expect(
            try JiraSearchRequest.resolve(query: nil, jql: " key = ABC-1 ORDER BY created ")
                == .jql("key = ABC-1 ORDER BY created")
        )
        #expect(try JiraSearchRequest.resolve(query: "  ", jql: "project = ABC") == .jql("project = ABC"))
    }

    @Test
    func searchRequiresExactlyOneOfQueryAndJQL() {
        let missing = #expect(throws: JiraToolsError.self) {
            try JiraSearchRequest.resolve(query: " ", jql: nil)
        }
        #expect(missing?.errorDescription == "Missing Jira tool argument: query or jql.")

        let both = #expect(throws: JiraToolsError.self) {
            try JiraSearchRequest.resolve(query: "login", jql: "project = ABC")
        }
        #expect(both?.errorDescription?.contains("not both") == true)
    }

    @Test
    func textSearchEscapesTheJQLStringLiteralOnly() {
        #expect(
            JiraJQL.textSearch(#"say "hi" C:\temp"# + "\nnext\tline")
                == #"text ~ "say \"hi\" C:\\temp next line" ORDER BY updated DESC"#
        )
        // Quotes inside the query keep Jira's exact-phrase syntax.
        #expect(
            JiraJQL.textSearch(#""jira software" crash*"#)
                == #"text ~ "\"jira software\" crash*" ORDER BY updated DESC"#
        )
    }
}

@Suite
struct JiraIssueParserTests {
    private static let siteURL = URL(string: "https://example.atlassian.net")!

    @Test
    func issueDetailIsDeterministicAcrossIdenticalPayloads() throws {
        var fields: [String: JSONValue] = [
            "summary": .string("Fix login"),
            "status": .object(["name": .string("In Progress")]),
            "issuetype": .object(["name": .string("Bug")]),
            "priority": .object(["name": .string("High")]),
            "description": .object([
                "type": .string("doc"),
                "content": .array([
                    .object([
                        "type": .string("paragraph"),
                        "content": .array([.object(["type": .string("text"), "text": .string("Users cannot log in.")])])
                    ])
                ])
            ])
        ]
        var names: [String: JSONValue] = [:]
        for index in 0..<30 {
            fields["customfield_\(10_000 + index)"] = .string("value \(index)")
            names["customfield_\(10_000 + index)"] = .string("Sprint \(index)")
        }
        let payload = JSONValue.object([
            "key": .string("PROJ-1"),
            "fields": .object(fields),
            "names": .object(names)
        ])

        let first = try #require(JiraIssueParser.issueDetail(from: payload, siteURL: Self.siteURL))
        #expect(first.key == "PROJ-1")
        #expect(first.summary == "Fix login")
        #expect(first.status == "In Progress")
        #expect(first.description == "Users cannot log in.")
        #expect(first.url.absoluteString == "https://example.atlassian.net/browse/PROJ-1")
        #expect(first.notableFields.count == 12)

        for _ in 0..<5 {
            let again = try #require(JiraIssueParser.issueDetail(from: payload, siteURL: Self.siteURL))
            #expect(again.notableFields.map(\.name) == first.notableFields.map(\.name))
            #expect(again.notableFields.map(\.value) == first.notableFields.map(\.value))
        }
    }

    @Test
    func issueDetailRequiresKeyAndFields() {
        #expect(JiraIssueParser.issueDetail(from: .object(["key": .string("X-1")]), siteURL: Self.siteURL) == nil)
        #expect(JiraIssueParser.issueDetail(from: .object(["fields": .object([:])]), siteURL: Self.siteURL) == nil)
    }

    @Test
    func searchSummariesReadRequestedFieldsAndSkipIssuesWithoutKeys() {
        let payload = JSONValue.object([
            "issues": .array([
                .object([
                    "id": .string("10001"),
                    "key": .string("A-1"),
                    "fields": .object([
                        "summary": .string("First"),
                        "status": .object(["name": .string("In Progress")]),
                        "issuetype": .object(["name": .string("Bug")]),
                        "assignee": .object(["displayName": .string("Ada Lovelace")])
                    ])
                ]),
                .object(["id": .string("10002"), "fields": .object(["summary": .string("No key")])]),
                .object(["id": .string("10003"), "key": .string("A-2"), "fields": .object(["assignee": .null])])
            ]),
            "isLast": .bool(true)
        ])
        let summaries = JiraIssueParser.issueSummaries(fromSearchResult: payload, siteURL: Self.siteURL)
        #expect(summaries.map(\.key) == ["A-1", "A-2"])
        #expect(summaries.map(\.summary) == ["First", "A-2"])
        #expect(summaries.first?.status == "In Progress")
        #expect(summaries.first?.issueType == "Bug")
        #expect(summaries.first?.assignee == "Ada Lovelace")
        #expect(summaries.last?.status == nil)
        #expect(summaries.last?.assignee == nil)
        #expect(summaries.first?.url.absoluteString == "https://example.atlassian.net/browse/A-1")
    }

    @Test
    func searchSummariesAreEmptyWithoutIssues() {
        #expect(JiraIssueParser.issueSummaries(fromSearchResult: .object(["issues": .array([])]), siteURL: Self.siteURL).isEmpty)
        #expect(JiraIssueParser.issueSummaries(fromSearchResult: .object([:]), siteURL: Self.siteURL).isEmpty)
    }

    @Test
    func flattenedTextKeepsIntegralNumbersIntact() {
        #expect(JSONValue.number(1_234_567).flattenedText() == "1234567")
        #expect(JSONValue.number(5).flattenedText() == "5")
        #expect(JSONValue.number(-42).flattenedText() == "-42")
        #expect(JSONValue.number(2.5).flattenedText() == "2.5")
    }
}

// Nested in `JiraProcessEnvironmentSuite` (serialized) because it mutates
// `ZENCODE_SUPPORT_DIRECTORY`; see that type for the rationale.
extension JiraProcessEnvironmentSuite {
    @Suite
    struct JiraSignOutTests {
        @Test
        func signOutWithoutConfigurationDoesNotFail() async throws {
            let directory = FileManager.default.temporaryDirectory
                .appendingPathComponent("jira-signout-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: directory) }
            setenv("ZENCODE_SUPPORT_DIRECTORY", directory.path, 1)
            defer { unsetenv("ZENCODE_SUPPORT_DIRECTORY") }

            let context = FeatureContext(workingDirectory: directory, environment: [:])
            let output = try await JiraSignOutTool().run(JiraSignOutTool.Input(), context: context)
            #expect(output.contains("not configured"))
        }
    }
}
