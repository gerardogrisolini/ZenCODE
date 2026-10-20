import Foundation

/// One tool per macOS app. The raw value is the tool suffix (`macos.<app>`)
/// and the prefix of the full action names below.
enum MacOSApp: String, CaseIterable, Sendable {
    case permissions
    case calendar
    case reminders
    case contacts
    case mail
    case messages
    case photos
    case notes

    var toolName: String { "macos.\(rawValue)" }

    /// Actions handled by the tool of this app, in declaration order.
    var actions: [MacOSAction] {
        MacOSAction.allCases.filter { $0.app == self }
    }

    var actionNames: [String] {
        actions.map(\.shortName)
    }

    var confirmedActionNames: [String] {
        actions.filter(\.requiresConfirmation).map(\.shortName)
    }
}

/// Every operation exposed by the `macos.*` tools. The raw values are the
/// historical full names (`<app>_<action>`); each per-app tool accepts the
/// short form without the app prefix (see `shortName`), and still accepts the
/// full form for compatibility.
enum MacOSAction: String, CaseIterable, Sendable {
    case permissions
    case requestPermissions = "request_permissions"

    case calendarList = "calendar_list"
    case calendarEvents = "calendar_events"
    case calendarCreateEvent = "calendar_create_event"
    case calendarUpdateEvent = "calendar_update_event"
    case calendarDeleteEvent = "calendar_delete_event"

    case remindersLists = "reminders_lists"
    case remindersList = "reminders_list"
    case remindersCreate = "reminders_create"
    case remindersUpdate = "reminders_update"
    case remindersComplete = "reminders_complete"
    case remindersDelete = "reminders_delete"

    case contactsSearch = "contacts_search"
    case contactsGet = "contacts_get"
    case contactsCreate = "contacts_create"
    case contactsUpdate = "contacts_update"
    case contactsDelete = "contacts_delete"

    case mailAccounts = "mail_accounts"
    case mailList = "mail_list"
    case mailGet = "mail_get"
    case mailSend = "mail_send"
    case mailReply = "mail_reply"
    case mailMark = "mail_mark"
    case mailMove = "mail_move"
    case mailDelete = "mail_delete"

    case messagesChats = "messages_chats"
    case messagesRead = "messages_read"
    case messagesSend = "messages_send"

    case photosAlbums = "photos_albums"
    case photosSearch = "photos_search"
    case photosList = "photos_list"
    case photosExport = "photos_export"
    case photosImport = "photos_import"
    case photosCreateAlbum = "photos_create_album"
    case photosAddToAlbum = "photos_add_to_album"
    case photosUpdate = "photos_update"

    case notesFolders = "notes_folders"
    case notesList = "notes_list"
    case notesSearch = "notes_search"
    case notesGet = "notes_get"
    case notesCreate = "notes_create"
    case notesUpdate = "notes_update"
    case notesDelete = "notes_delete"

    var app: MacOSApp {
        switch self {
        case .permissions, .requestPermissions:
            return .permissions
        case .calendarList, .calendarEvents, .calendarCreateEvent, .calendarUpdateEvent, .calendarDeleteEvent:
            return .calendar
        case .remindersLists, .remindersList, .remindersCreate, .remindersUpdate, .remindersComplete, .remindersDelete:
            return .reminders
        case .contactsSearch, .contactsGet, .contactsCreate, .contactsUpdate, .contactsDelete:
            return .contacts
        case .mailAccounts, .mailList, .mailGet, .mailSend, .mailReply, .mailMark, .mailMove, .mailDelete:
            return .mail
        case .messagesChats, .messagesRead, .messagesSend:
            return .messages
        case .photosAlbums, .photosSearch, .photosList, .photosExport, .photosImport,
             .photosCreateAlbum, .photosAddToAlbum, .photosUpdate:
            return .photos
        case .notesFolders, .notesList, .notesSearch, .notesGet, .notesCreate, .notesUpdate, .notesDelete:
            return .notes
        }
    }

    /// The `action` value accepted and reported by the per-app tool.
    var shortName: String {
        switch self {
        case .permissions:
            return "check"
        case .requestPermissions:
            return "request"
        default:
            let prefix = app.rawValue + "_"
            return rawValue.hasPrefix(prefix) ? String(rawValue.dropFirst(prefix.count)) : rawValue
        }
    }

    /// Resolves the `action` argument of the tool for `app`, accepting the
    /// short name (`events`) or the full historical name (`calendar_events`).
    static func resolve(_ name: String, in app: MacOSApp) throws -> MacOSAction {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if let match = app.actions.first(where: { $0.shortName == trimmed || $0.rawValue == trimmed }) {
            return match
        }
        throw MacOSControlError.invalidAction(name, tool: app.toolName, allowed: app.actionNames)
    }

    /// Actions that destroy user data or send something on the user's behalf.
    /// They are refused unless the caller passes `confirm=true`.
    var requiresConfirmation: Bool {
        switch self {
        case .calendarDeleteEvent, .remindersDelete, .contactsDelete,
             .mailSend, .mailReply, .mailDelete, .messagesSend, .notesDelete:
            return true
        default:
            return false
        }
    }
}
