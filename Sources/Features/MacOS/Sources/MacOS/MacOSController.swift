import Contacts
import EventKit
import FeatureKit
import Foundation

enum MacOSController {
    /// Runs `action` of the tool `app` and reports the short action name in the output.
    static func execute(_ app: MacOSApp, _ input: MacOSRunInput, context: FeatureContext) async throws -> MacOSRunOutput {
        let action = try MacOSAction.resolve(input.action, in: app)
        if action.requiresConfirmation, input.confirm != true {
            throw MacOSControlError.confirmationRequired(action.shortName)
        }
        return try await execute(action, input, context: context)
    }

    private static func execute(_ action: MacOSAction, _ input: MacOSRunInput, context: FeatureContext) async throws -> MacOSRunOutput {
        switch action {
        case .permissions:
            return await permissions(request: false)
        case .requestPermissions:
            return await permissions(request: true)

        case .calendarList: return try await CalendarController.list(input)
        case .calendarEvents: return try await CalendarController.events(input)
        case .calendarCreateEvent: return try await CalendarController.create(input)
        case .calendarUpdateEvent: return try await CalendarController.update(input)
        case .calendarDeleteEvent: return try await CalendarController.delete(input)

        case .remindersLists: return try await RemindersController.lists(input)
        case .remindersList: return try await RemindersController.list(input)
        case .remindersCreate: return try await RemindersController.create(input)
        case .remindersUpdate: return try await RemindersController.update(input)
        case .remindersComplete: return try await RemindersController.complete(input)
        case .remindersDelete: return try await RemindersController.delete(input)

        case .contactsSearch: return try await ContactsController.search(input)
        case .contactsGet: return try await ContactsController.get(input)
        case .contactsCreate: return try await ContactsController.create(input)
        case .contactsUpdate: return try await ContactsController.update(input)
        case .contactsDelete: return try await ContactsController.delete(input)

        case .mailAccounts: return try await MailController.accounts(input)
        case .mailList: return try await MailController.list(input)
        case .mailGet: return try await MailController.get(input)
        case .mailSend: return try await MailController.send(input)
        case .mailReply: return try await MailController.reply(input)
        case .mailMark: return try await MailController.mark(input)
        case .mailMove: return try await MailController.move(input)
        case .mailDelete: return try await MailController.delete(input)

        case .messagesChats: return try await MessagesController.chats(input)
        case .messagesRead: return try await MessagesController.read(input)
        case .messagesSend: return try await MessagesController.send(input)

        case .photosAlbums: return try await PhotosController.albums(input)
        case .photosSearch: return try await PhotosController.search(input)
        case .photosList: return try await PhotosController.list(input)
        case .photosExport: return try await PhotosController.export(input, context: context.workingDirectory)
        case .photosImport: return try await PhotosController.importItems(input, context: context.workingDirectory)
        case .photosCreateAlbum: return try await PhotosController.createAlbum(input)
        case .photosAddToAlbum: return try await PhotosController.addToAlbum(input)
        case .photosUpdate: return try await PhotosController.update(input)

        case .notesFolders: return try await NotesController.folders(input)
        case .notesList: return try await NotesController.list(input)
        case .notesSearch: return try await NotesController.search(input)
        case .notesGet: return try await NotesController.get(input)
        case .notesCreate: return try await NotesController.create(input)
        case .notesUpdate: return try await NotesController.update(input)
        case .notesDelete: return try await NotesController.delete(input)
        }
    }

    private static func permissions(request: Bool) async -> MacOSRunOutput {
        var problems: [String] = []
        if request {
            let store = EKEventStore()
            do {
                _ = try await store.requestFullAccessToEvents()
            } catch {
                problems.append("Calendar request failed: \(error.localizedDescription)")
            }
            do {
                _ = try await store.requestFullAccessToReminders()
            } catch {
                problems.append("Reminders request failed: \(error.localizedDescription)")
            }
            do {
                _ = try await CNContactStore().requestAccess(for: .contacts)
            } catch {
                problems.append("Contacts request failed: \(error.localizedDescription)")
            }
        }

        let permissions = MacOSPermissions(
            calendar: EventKitSupport.authorizationLabel(for: .event),
            reminders: EventKitSupport.authorizationLabel(for: .reminder),
            contacts: ContactsController.authorizationLabel(),
            messages_database: MessagesDatabase.accessibility(),
            automation: "Mail, Messages, Photos, and Notes are driven through Apple Events; macOS asks for Automation consent per app on first use (System Settings > Privacy & Security > Automation)."
        )

        var missing: [String] = []
        if permissions.calendar != "full_access" { missing.append("Calendars: \(permissions.calendar)") }
        if permissions.reminders != "full_access" { missing.append("Reminders: \(permissions.reminders)") }
        if permissions.contacts != "authorized" { missing.append("Contacts: \(permissions.contacts)") }
        if permissions.messages_database != "readable" { missing.append("Messages history: \(permissions.messages_database)") }

        var output = MacOSRunOutput(
            action: request ? .requestPermissions : .permissions,
            summary: missing.isEmpty
                ? "Calendar, Reminders, Contacts, and the Messages history are accessible."
                : "Some access is missing: \(missing.joined(separator: "; "))."
        )
        output.permissions = permissions
        var hints: [String] = []
        if !missing.isEmpty {
            hints.append("Grants are per hosting application (Terminal, iTerm, Xcode, ...). Use action=request to trigger the Calendar/Reminders/Contacts prompts; a denied status must be changed in System Settings > Privacy & Security.")
        }
        if permissions.messages_database != "readable" {
            hints.append(MessagesDatabase.fullDiskAccessHint)
        }
        hints.append(contentsOf: problems)
        output.hint = hints.isEmpty ? nil : hints.joined(separator: " ")
        return output
    }
}
