import Foundation

/// Accepts either a single string or an array of strings.
struct StringList: Decodable, Sendable {
    let values: [String]

    init(_ values: [String]) {
        self.values = values
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let single = try? container.decode(String.self) {
            self.values = single
                .split(whereSeparator: { $0 == "," || $0 == ";" })
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
        } else {
            self.values = try container.decode([String].self)
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
        }
    }
}

/// Accepts `"value"` or `{"label": "work", "value": "..."}`.
struct LabeledValueInput: Decodable, Sendable {
    let label: String?
    let value: String

    private enum CodingKeys: String, CodingKey {
        case label
        case value
    }

    init(from decoder: Decoder) throws {
        if let container = try? decoder.singleValueContainer(),
           let single = try? container.decode(String.self) {
            self.label = nil
            self.value = single.trimmingCharacters(in: .whitespacesAndNewlines)
            return
        }
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.label = try container.decodeIfPresent(String.self, forKey: .label)
        self.value = try container.decode(String.self, forKey: .value).trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

struct PostalAddressInput: Decodable, Sendable {
    let label: String?
    let street: String?
    let city: String?
    let state: String?
    let postal_code: String?
    let country: String?
}

struct MacOSRunInput: Decodable, Sendable {
    let action: String
    var confirm: Bool?
    var limit: Int?
    var query: String?

    // Dates and ranges.
    var start: String?
    var end: String?
    var since: String?
    var until: String?

    // Calendar.
    var calendar: String?
    var event_id: String?
    var occurrence_start: String?
    var span: String?
    var title: String?
    var all_day: Bool?
    var location: String?
    var notes: String?
    var url: String?
    var alarm_minutes: [Int]?
    var recurrence: String?
    var recurrence_interval: Int?
    var recurrence_end: String?
    var recurrence_count: Int?

    // Reminders.
    var list: String?
    var reminder_id: String?
    var due: String?
    var clear_due: Bool?
    var include_undated: Bool?
    var priority: String?
    var completed: Bool?
    var status: String?

    // Contacts.
    var contact_id: String?
    var given_name: String?
    var family_name: String?
    var middle_name: String?
    var organization: String?
    var job_title: String?
    var nickname: String?
    var emails: [LabeledValueInput]?
    var phones: [LabeledValueInput]?
    var addresses: [PostalAddressInput]?
    var urls: [LabeledValueInput]?
    var birthday: String?

    // Mail.
    var account: String?
    var mailbox: String?
    var message_id: Int?
    var unread_only: Bool?
    var to: StringList?
    var cc: StringList?
    var bcc: StringList?
    var subject: String?
    var body: String?
    var from: String?
    var attachments: StringList?
    var reply_all: Bool?
    var read: Bool?
    var flagged: Bool?
    var max_chars: Int?
    var target_mailbox: String?
    var target_account: String?

    // Messages.
    var chat_id: String?
    var handle: String?
    var text: String?

    // Photos.
    var album: String?
    var media_id: String?
    var media_ids: StringList?
    var directory: String?
    var use_originals: Bool?
    var paths: StringList?
    var skip_duplicates: Bool?
    var favorite: Bool?
    var favorites_only: Bool?
    var keywords: StringList?
    var name: String?
    var description: String?

    // Notes.
    var folder: String?
    var note_id: String?
    var append: String?
    var format: String?

    func require(_ value: String?, _ argument: String) throws -> String {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else {
            throw MacOSControlError.missingArgument(argument, action)
        }
        return value
    }

    func boundedLimit(default defaultValue: Int, maximum: Int) -> Int {
        guard let limit, limit > 0 else { return defaultValue }
        return min(limit, maximum)
    }

    func boundedMaxChars(default defaultValue: Int = 20_000, maximum: Int = 200_000) -> Int {
        guard let max_chars, max_chars > 0 else { return defaultValue }
        return min(max_chars, maximum)
    }
}
