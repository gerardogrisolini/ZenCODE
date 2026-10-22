import Foundation
import Testing

@testable import MacOS

@Suite
struct MacOSInputTests {
    private func decode(_ json: String) throws -> MacOSRunInput {
        try JSONDecoder().decode(MacOSRunInput.self, from: Data(json.utf8))
    }

    @Test
    func stringListAcceptsStringsAndArrays() throws {
        let fromString = try decode(#"{"action": "send", "to": " a@x.com, b@x.com ;; c@x.com "}"#)
        #expect(fromString.to?.values == ["a@x.com", "b@x.com", "c@x.com"])

        let fromArray = try decode(#"{"action": "send", "to": [" a@x.com ", "", "b@x.com"]}"#)
        #expect(fromArray.to?.values == ["a@x.com", "b@x.com"])

        #expect(throws: DecodingError.self) {
            try decode(#"{"action": "send", "to": 42}"#)
        }
    }

    @Test
    func labeledValueAcceptsStringsAndObjects() throws {
        let input = try decode(#"{"action": "create", "emails": ["plain@x.com", {"label": "work", "value": " obj@x.com "}]}"#)
        let emails = try #require(input.emails)
        #expect(emails.count == 2)
        #expect(emails[0].label == nil)
        #expect(emails[0].value == "plain@x.com")
        #expect(emails[1].label == "work")
        #expect(emails[1].value == "obj@x.com")

        #expect(throws: DecodingError.self) {
            try decode(#"{"action": "create", "emails": [{"label": "work"}]}"#)
        }
    }

    @Test
    func requireRejectsBlankValues() throws {
        let input = try decode(#"{"action": "get", "note_id": "   "}"#)
        #expect(throws: MacOSControlError.self) {
            try input.require(input.note_id, "note_id")
        }
        #expect(throws: MacOSControlError.self) {
            try input.require(nil, "note_id")
        }
        #expect(try input.require(" abc ", "note_id") == "abc")
    }

    @Test
    func boundsLimitsAndMaxChars() throws {
        #expect(try decode(#"{"action": "list"}"#).boundedLimit(default: 25, maximum: 200) == 25)
        #expect(try decode(#"{"action": "list", "limit": 0}"#).boundedLimit(default: 25, maximum: 200) == 25)
        #expect(try decode(#"{"action": "list", "limit": -3}"#).boundedLimit(default: 25, maximum: 200) == 25)
        #expect(try decode(#"{"action": "list", "limit": 7}"#).boundedLimit(default: 25, maximum: 200) == 7)
        #expect(try decode(#"{"action": "list", "limit": 9999}"#).boundedLimit(default: 25, maximum: 200) == 200)

        #expect(try decode(#"{"action": "get"}"#).boundedMaxChars() == 20_000)
        #expect(try decode(#"{"action": "get", "max_chars": 0}"#).boundedMaxChars() == 20_000)
        #expect(try decode(#"{"action": "get", "max_chars": 10}"#).boundedMaxChars() == 10)
        #expect(try decode(#"{"action": "get", "max_chars": 5000000}"#).boundedMaxChars() == 200_000)
    }
}

@Suite
struct MacOSActionTests {
    @Test
    func everyActionBelongsToExactlyOneToolWithUniqueShortNames() {
        for app in MacOSApp.allCases {
            let names = app.actionNames
            #expect(Set(names).count == names.count, "duplicate short names in \(app.toolName)")
            #expect(!names.isEmpty)
        }
        let total = MacOSApp.allCases.reduce(0) { $0 + $1.actions.count }
        #expect(total == MacOSAction.allCases.count)
    }

    @Test
    func resolvesShortAndFullNamesCaseInsensitively() throws {
        #expect(try MacOSAction.resolve("events", in: .calendar) == .calendarEvents)
        #expect(try MacOSAction.resolve(" Calendar_Events ", in: .calendar) == .calendarEvents)
        #expect(try MacOSAction.resolve("check", in: .permissions) == .permissions)
        #expect(try MacOSAction.resolve("request", in: .permissions) == .requestPermissions)
        #expect(try MacOSAction.resolve("list", in: .reminders) == .remindersList)
        #expect(try MacOSAction.resolve("lists", in: .reminders) == .remindersLists)
    }

    @Test
    func rejectsActionsOfOtherToolsWithAnActionableMessage() {
        do {
            _ = try MacOSAction.resolve("events", in: .mail)
            Issue.record("expected an error")
        } catch let error as MacOSControlError {
            let description = error.errorDescription ?? ""
            #expect(description.contains("macos.mail"))
            #expect(description.contains("accounts, list, get, send, reply, mark, move, delete"))
        } catch {
            Issue.record("unexpected error \(error)")
        }
    }

    @Test
    func destructiveAndOutboundActionsRequireConfirmation() {
        let confirmed = Set(MacOSAction.allCases.filter(\.requiresConfirmation))
        #expect(confirmed == [
            .calendarDeleteEvent, .remindersDelete, .contactsDelete,
            .mailSend, .mailReply, .mailDelete, .messagesSend, .notesDelete,
        ])
        #expect(MacOSApp.mail.confirmedActionNames == ["send", "reply", "delete"])
        #expect(MacOSApp.permissions.confirmedActionNames.isEmpty)
        #expect(MacOSApp.photos.confirmedActionNames.isEmpty)
    }

    @Test
    func controllerRefusesUnconfirmedDestructiveActionsBeforeTouchingAnyApp() async throws {
        let context = FeatureContextStub.make()
        for app in MacOSApp.allCases {
            for action in app.actions where action.requiresConfirmation {
                for json in [
                    #"{"action": "\#(action.shortName)"}"#,
                    #"{"action": "\#(action.shortName)", "confirm": false}"#,
                    #"{"action": "\#(action.rawValue)"}"#,
                ] {
                    let input = try JSONDecoder().decode(MacOSRunInput.self, from: Data(json.utf8))
                    do {
                        _ = try await MacOSController.execute(app, input, context: context)
                        Issue.record("\(app.toolName) \(action.shortName) ran without confirm=true")
                    } catch let error as MacOSControlError {
                        guard case .confirmationRequired(let name) = error else {
                            Issue.record("unexpected error \(error) for \(app.toolName) \(action.shortName)")
                            continue
                        }
                        #expect(name == action.shortName)
                    }
                }
            }
        }
    }

    @Test
    func controllerRejectsUnknownActionsBeforeTouchingAnyApp() async throws {
        let input = try JSONDecoder().decode(MacOSRunInput.self, from: Data(#"{"action": "explode"}"#.utf8))
        await #expect(throws: MacOSControlError.self) {
            _ = try await MacOSController.execute(.notes, input, context: FeatureContextStub.make())
        }
    }
}
