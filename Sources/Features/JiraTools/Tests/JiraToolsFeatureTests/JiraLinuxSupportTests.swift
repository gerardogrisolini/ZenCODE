import Foundation
import Testing
@testable import jira_tools_feature

@Suite(.serialized)
struct JiraLinuxSupportTests {
    private func makeStore() -> (JiraFileCredentialStore, URL) {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("jira-store-\(UUID().uuidString)", isDirectory: true)
        let directory = root.appendingPathComponent("credentials", isDirectory: true)
        return (JiraFileCredentialStore(directoryURL: directory), directory)
    }

    private func permissions(_ url: URL) throws -> Int {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        return (attributes[.posixPermissions] as? NSNumber)?.intValue ?? -1
    }

    @Test
    func fileStoreSavesLoadsAndRemovesWithStrictPermissions() throws {
        let (store, directory) = makeStore()
        defer { try? FileManager.default.removeItem(at: directory.deletingLastPathComponent()) }
        let account = "example.atlassian.net|user@example.com"

        try store.save("secret-token", account: account)
        #expect(try store.load(account: account) == "secret-token")
        #expect(try permissions(store.fileURL(account: account)) == 0o600)
        #expect(try permissions(directory) == 0o700)

        try store.remove(account: account)
        try store.remove(account: account)
        #expect(throws: JiraToolsError.self) { try store.load(account: account) }
    }

    @Test
    func fileStoreOverwritesAndLeavesNoTemporaryFiles() throws {
        let (store, directory) = makeStore()
        defer { try? FileManager.default.removeItem(at: directory.deletingLastPathComponent()) }
        try store.save("first", account: "a|b")
        try store.save("second", account: "a|b")
        #expect(try store.load(account: "a|b") == "second")
        #expect(try permissions(store.fileURL(account: "a|b")) == 0o600)
        let entries = try FileManager.default.contentsOfDirectory(atPath: directory.path)
        #expect(entries.count == 1)
    }

    @Test
    func specialAccountCharactersCannotEscapeTheDirectory() throws {
        let (store, directory) = makeStore()
        defer { try? FileManager.default.removeItem(at: directory.deletingLastPathComponent()) }
        let accounts = ["host|user@example.com", "../../evil|x", "a/b\\c|..", ""]
        for account in accounts {
            let url = store.fileURL(account: account)
            #expect(url.deletingLastPathComponent().standardizedFileURL.path == directory.standardizedFileURL.path)
            #expect(!url.lastPathComponent.contains("/"))
            try store.save("t-\(account.count)", account: account)
            #expect(try store.load(account: account) == "t-\(account.count)")
        }
        #expect(JiraFileCredentialStore.fileName(forAccount: "a|b") != JiraFileCredentialStore.fileName(forAccount: "a_b"))
    }

    @Test
    func missingFileReportsMissingCredentials() {
        let (store, directory) = makeStore()
        defer { try? FileManager.default.removeItem(at: directory.deletingLastPathComponent()) }
        do {
            _ = try store.load(account: "none|x")
            Issue.record("Expected missingCredentials")
        } catch let error as JiraToolsError {
            guard case .missingCredentials = error else {
                Issue.record("Unexpected error \(error)")
                return
            }
        } catch {
            Issue.record("Unexpected error \(error)")
        }
    }

    @Test
    func emptyFileReportsInvalidConfiguration() throws {
        let (store, directory) = makeStore()
        defer { try? FileManager.default.removeItem(at: directory.deletingLastPathComponent()) }
        try store.save("x", account: "e|f")
        let url = store.fileURL(account: "e|f")
        try Data().write(to: url)
        do {
            _ = try store.load(account: "e|f")
            Issue.record("Expected invalidConfiguration")
        } catch let error as JiraToolsError {
            guard case let .invalidConfiguration(message) = error else {
                Issue.record("Unexpected error \(error)")
                return
            }
            #expect(message.contains(url.path))
        }
    }

    @Test
    func environmentWithoutVariablesResolvesToNil() throws {
        #expect(try JiraEnvironmentConfiguration.resolve(environment: [:]) == nil)
        #expect(try JiraEnvironmentConfiguration.resolve(environment: [
            "ZENCODE_JIRA_SITE_URL": "  ", "ZENCODE_JIRA_EMAIL": ""
        ]) == nil)
    }

    @Test
    func partialEnvironmentListsMissingVariables() {
        do {
            _ = try JiraEnvironmentConfiguration.resolve(environment: [
                "ZENCODE_JIRA_SITE_URL": "https://example.atlassian.net"
            ])
            Issue.record("Expected an error")
        } catch let error as JiraToolsError {
            guard case let .environmentConfigurationRequired(missing, _) = error else {
                Issue.record("Unexpected error \(error)")
                return
            }
            #expect(missing == ["ZENCODE_JIRA_EMAIL", "ZENCODE_JIRA_API_TOKEN"])
            #expect(error.authenticationReason == nil)
        } catch {
            Issue.record("Unexpected error \(error)")
        }
    }

    @Test
    func fullEnvironmentBuildsConfigurationAndEnforcesHTTPS() throws {
        let resolved = try #require(try JiraEnvironmentConfiguration.resolve(environment: [
            "ZENCODE_JIRA_SITE_URL": " example.atlassian.net ",
            "ZENCODE_JIRA_EMAIL": " user@example.com ",
            "ZENCODE_JIRA_API_TOKEN": " tok "
        ]))
        #expect(resolved.configuration.siteURL.scheme == "https")
        #expect(resolved.configuration.email == "user@example.com")
        #expect(resolved.apiToken == "tok")

        #expect(throws: JiraToolsError.self) {
            _ = try JiraEnvironmentConfiguration.resolve(environment: [
                "ZENCODE_JIRA_SITE_URL": "http://example.atlassian.net",
                "ZENCODE_JIRA_EMAIL": "user@example.com",
                "ZENCODE_JIRA_API_TOKEN": "tok"
            ])
        }
    }

    @Test
    func environmentErrorDescriptionNamesAllVariables() {
        let description = JiraToolsError.environmentConfigurationRequired(
            missing: JiraEnvironmentConfiguration.allKeys,
            reason: JiraAuthenticationReason.manual.message
        ).localizedDescription
        for key in ["ZENCODE_JIRA_SITE_URL", "ZENCODE_JIRA_EMAIL", "ZENCODE_JIRA_API_TOKEN"] {
            #expect(description.contains(key))
        }
        #expect(description.contains(JiraAuthenticationReason.manual.message))
    }
}
