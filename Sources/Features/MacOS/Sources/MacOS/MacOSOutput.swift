import Foundation

struct MacOSRunOutput: Encodable, Sendable {
    let ok = true
    let action: String
    let summary: String
    var hint: String?
    var count: Int?

    var permissions: MacOSPermissions?

    var calendars: [CalendarInfo]?
    var events: [EventInfo]?
    var event: EventInfo?

    var reminder_lists: [ReminderListInfo]?
    var reminders: [ReminderInfo]?
    var reminder: ReminderInfo?

    var contacts: [ContactInfo]?
    var contact: ContactInfo?

    var mail_accounts: [MailAccountInfo]?
    var messages: [MailMessageInfo]?
    var message: MailMessageDetail?

    var chats: [ChatInfo]?
    var texts: [TextMessageInfo]?

    var albums: [AlbumInfo]?
    var media_items: [MediaItemInfo]?
    var exported_files: [String]?

    var note_folders: [NoteFolderInfo]?
    var notes: [NoteInfo]?
    var note: NoteDetail?

    init(action: MacOSAction, summary: String) {
        self.action = action.shortName
        self.summary = summary
    }
}

struct MacOSPermissions: Codable, Sendable {
    let calendar: String
    let reminders: String
    let contacts: String
    let messages_database: String
    let automation: String
}

// MARK: - Calendar

struct CalendarInfo: Codable, Sendable {
    let id: String
    let title: String
    let type: String
    let source: String?
    let color: String?
    let allows_modifications: Bool
    let is_subscribed: Bool
    let is_default: Bool
}

struct ParticipantInfo: Codable, Sendable {
    let name: String?
    let email: String?
    let status: String
    let is_current_user: Bool
}

struct EventInfo: Codable, Sendable {
    let id: String
    let calendar: String
    let calendar_id: String
    let title: String?
    let start: String?
    let end: String?
    let all_day: Bool
    let location: String?
    let notes: String?
    let url: String?
    let status: String
    let availability: String
    let organizer: ParticipantInfo?
    let attendees: [ParticipantInfo]?
    let is_recurring: Bool
    let recurrence: String?
    let is_detached_occurrence: Bool
    let alarm_minutes_before: [Int]?
    let time_zone: String?
    let created: String?
    let modified: String?
}

// MARK: - Reminders

struct ReminderListInfo: Codable, Sendable {
    let id: String
    let title: String
    let source: String?
    let color: String?
    let allows_modifications: Bool
    let is_default: Bool
}

struct ReminderInfo: Codable, Sendable {
    let id: String
    let list: String
    let list_id: String
    let title: String?
    let notes: String?
    let completed: Bool
    let completion_date: String?
    let due: String?
    let due_has_time: Bool
    let priority: String
    let priority_value: Int
    let alarms: [String]?
    let url: String?
    let is_recurring: Bool
    let created: String?
    let modified: String?
}

// MARK: - Contacts

struct LabeledValueInfo: Codable, Sendable {
    let label: String?
    let value: String
}

struct PostalAddressInfo: Codable, Sendable {
    let label: String?
    let street: String?
    let city: String?
    let state: String?
    let postal_code: String?
    let country: String?
}

struct SocialProfileInfo: Codable, Sendable {
    let service: String?
    let username: String?
    let url: String?
}

struct ContactInfo: Codable, Sendable {
    let id: String
    let name: String
    let given_name: String?
    let family_name: String?
    let middle_name: String?
    let nickname: String?
    let organization: String?
    let job_title: String?
    let department: String?
    let is_company: Bool
    let emails: [LabeledValueInfo]
    let phones: [LabeledValueInfo]
    let addresses: [PostalAddressInfo]
    let urls: [LabeledValueInfo]
    let social_profiles: [SocialProfileInfo]
    let birthday: String?
    let has_image: Bool
}

// MARK: - Mail

struct MailMailboxInfo: Codable, Sendable {
    let name: String
    let unread_count: Int?
}

struct MailAccountInfo: Codable, Sendable {
    let name: String
    let id: String?
    let type: String?
    let email_addresses: [String]
    let full_name: String?
    let enabled: Bool?
    let mailboxes: [MailMailboxInfo]
}

struct MailMessageInfo: Codable, Sendable {
    let id: Int
    let account: String?
    let mailbox: String?
    let subject: String?
    let sender: String?
    let date_received: String?
    let date_sent: String?
    let read: Bool?
    let flagged: Bool?
    let message_id: String?
}

struct MailAttachmentInfo: Codable, Sendable {
    let name: String?
    let mime_type: String?
    let size: Int?
    let downloaded: Bool?
}

struct MailMessageDetail: Codable, Sendable {
    let id: Int
    let account: String?
    let mailbox: String?
    let subject: String?
    let sender: String?
    let reply_to: String?
    let date_received: String?
    let date_sent: String?
    let read: Bool?
    let flagged: Bool?
    let to: [String]
    let cc: [String]
    let message_id: String?
    let content: String
    let content_truncated: Bool
    let attachments: [MailAttachmentInfo]
}

// MARK: - Messages

struct ChatParticipantInfo: Codable, Sendable {
    let handle: String?
    let name: String?
}

struct ChatInfo: Codable, Sendable {
    let id: String
    let name: String?
    let participants: [ChatParticipantInfo]
}

struct TextMessageInfo: Codable, Sendable {
    let id: Int
    let chat_identifier: String?
    let chat_name: String?
    let sender: String
    let is_from_me: Bool
    let date: String?
    let text: String?
    let service: String?
    let has_attachments: Bool
    let is_read: Bool?
}

// MARK: - Photos

struct AlbumInfo: Codable, Sendable {
    let id: String
    let name: String?
    let item_count: Int?
}

struct MediaItemInfo: Codable, Sendable {
    let id: String
    let filename: String?
    let title: String?
    let description: String?
    let date: String?
    let favorite: Bool?
    let width: Int?
    let height: Int?
    let keywords: [String]?
    let latitude: Double?
    let longitude: Double?
    let altitude: Double?
}

// MARK: - Notes

struct NoteFolderInfo: Codable, Sendable {
    let account: String
    let name: String
    let id: String
    let note_count: Int?
}

struct NoteInfo: Codable, Sendable {
    let id: String
    let name: String?
    let folder: String?
    let account: String?
    let created: String?
    let modified: String?
    let snippet: String?
    let password_protected: Bool?
    let shared: Bool?
}

struct NoteDetail: Codable, Sendable {
    let id: String
    let name: String?
    let folder: String?
    let account: String?
    let created: String?
    let modified: String?
    let format: String
    let content: String
    let content_truncated: Bool
    let password_protected: Bool?
    let shared: Bool?
}
