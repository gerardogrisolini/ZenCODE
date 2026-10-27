import Foundation
import Testing
@testable import jira_tools_feature

// Nested in `JiraProcessEnvironmentSuite` (serialized) because it mutates
// `ZENCODE_SUPPORT_DIRECTORY`; see that type for the rationale.
extension JiraProcessEnvironmentSuite {
    @Suite
    struct JiraCredentialStoreTests {
        @Test
        func tokenRoundTripsThroughTheFileBackedStoreOnEveryPlatform() throws {
            let directory = FileManager.default.temporaryDirectory
                .appendingPathComponent("jira-credential-store-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: directory) }
            setenv("ZENCODE_SUPPORT_DIRECTORY", directory.path, 1)
            defer { unsetenv("ZENCODE_SUPPORT_DIRECTORY") }

            let account = "person@example.com"
            let credentialsDirectory = directory
                .appendingPathComponent("jira", isDirectory: true)
                .appendingPathComponent("credentials", isDirectory: true)
            let tokenFile = credentialsDirectory
                .appendingPathComponent(JiraFileCredentialStore.fileName(forAccount: account), isDirectory: false)

            try JiraCredentialStore.save("secret-api-token", account: account)

            #expect(FileManager.default.fileExists(atPath: tokenFile.path))
            #expect(try Self.permissions(atPath: tokenFile.path) == 0o600)
            #expect(try Self.permissions(atPath: credentialsDirectory.path) == 0o700)
            #expect(try JiraCredentialStore.load(account: account) == "secret-api-token")

            try JiraCredentialStore.remove(account: account)

            #expect(!FileManager.default.fileExists(atPath: tokenFile.path))
            do {
                _ = try JiraCredentialStore.load(account: account)
                Issue.record("Expected load to throw JiraToolsError.missingCredentials after remove.")
            } catch let error as JiraToolsError {
                guard case .missingCredentials = error else {
                    Issue.record("Expected JiraToolsError.missingCredentials, got \(error).")
                    return
                }
            }
        }

        private static func permissions(atPath path: String) throws -> Int {
            let attributes = try FileManager.default.attributesOfItem(atPath: path)
            let permissions = try #require(attributes[.posixPermissions] as? NSNumber)
            return permissions.intValue & 0o777
        }
    }
}
