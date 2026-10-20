import Contacts
import Foundation

enum ContactsController {
    static func authorizationLabel() -> String {
        switch CNContactStore.authorizationStatus(for: .contacts) {
        case .notDetermined: return "not_determined"
        case .restricted: return "restricted"
        case .denied: return "denied"
        case .authorized: return "authorized"
        case .limited: return "limited"
        @unknown default: return "unknown"
        }
    }

    /// Computed on each access: `CNKeyDescriptor` values are not `Sendable`.
    private static var fetchKeys: [CNKeyDescriptor] {
        [
        CNContactFormatter.descriptorForRequiredKeys(for: .fullName),
        CNContactGivenNameKey as CNKeyDescriptor,
        CNContactFamilyNameKey as CNKeyDescriptor,
        CNContactMiddleNameKey as CNKeyDescriptor,
        CNContactNicknameKey as CNKeyDescriptor,
        CNContactOrganizationNameKey as CNKeyDescriptor,
        CNContactJobTitleKey as CNKeyDescriptor,
        CNContactDepartmentNameKey as CNKeyDescriptor,
        CNContactTypeKey as CNKeyDescriptor,
        CNContactEmailAddressesKey as CNKeyDescriptor,
        CNContactPhoneNumbersKey as CNKeyDescriptor,
        CNContactPostalAddressesKey as CNKeyDescriptor,
        CNContactUrlAddressesKey as CNKeyDescriptor,
        CNContactSocialProfilesKey as CNKeyDescriptor,
        CNContactBirthdayKey as CNKeyDescriptor,
        CNContactImageDataAvailableKey as CNKeyDescriptor,
        ]
    }

    private static func store() async throws -> CNContactStore {
        let store = CNContactStore()
        let granted: Bool
        do {
            granted = try await store.requestAccess(for: .contacts)
        } catch {
            throw MacOSControlError.permissionRequired(
                "Contacts access failed (\(authorizationLabel())): \(error.localizedDescription). Grant access to the application hosting ZenCODE in System Settings > Privacy & Security > Contacts."
            )
        }
        guard granted else {
            throw MacOSControlError.permissionRequired(
                "Contacts access is \(authorizationLabel()). Grant access to the application hosting ZenCODE in System Settings > Privacy & Security > Contacts, then retry."
            )
        }
        return store
    }

    static func search(_ input: MacOSRunInput) async throws -> MacOSRunOutput {
        let store = try await store()
        let limit = input.boundedLimit(default: 25, maximum: 500)
        let query = input.query?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        var contacts: [CNContact] = []
        var strategy = "all"

        if query.isEmpty {
            let request = CNContactFetchRequest(keysToFetch: fetchKeys)
            request.sortOrder = .givenName
            request.unifyResults = true
            var collected: [CNContact] = []
            try store.enumerateContacts(with: request) { contact, stop in
                collected.append(contact)
                if collected.count >= limit {
                    stop.pointee = true
                }
            }
            contacts = collected
        } else if query.contains("@") {
            strategy = "email"
            contacts = try store.unifiedContacts(
                matching: CNContact.predicateForContacts(matchingEmailAddress: query),
                keysToFetch: fetchKeys
            )
        } else if looksLikePhoneNumber(query) {
            strategy = "phone"
            contacts = try store.unifiedContacts(
                matching: CNContact.predicateForContacts(matching: CNPhoneNumber(stringValue: query)),
                keysToFetch: fetchKeys
            )
        } else {
            strategy = "name"
            contacts = try store.unifiedContacts(
                matching: CNContact.predicateForContacts(matchingName: query),
                keysToFetch: fetchKeys
            )
            if contacts.isEmpty {
                // Fall back to a broad scan on organization, nickname and emails.
                strategy = "scan"
                let request = CNContactFetchRequest(keysToFetch: fetchKeys)
                request.sortOrder = .givenName
                request.unifyResults = true
                var collected: [CNContact] = []
                try store.enumerateContacts(with: request) { contact, stop in
                    if matches(contact, query: query) {
                        collected.append(contact)
                        if collected.count >= limit {
                            stop.pointee = true
                        }
                    }
                }
                contacts = collected
            }
        }

        let total = contacts.count
        let infos = contacts.prefix(limit).map(info)
        var output = MacOSRunOutput(
            action: .contactsSearch,
            summary: query.isEmpty
                ? "\(infos.count) contacts (first \(limit))."
                : "\(total) contacts match '\(query)' by \(strategy)" + (total > limit ? " (showing \(limit))." : ".")
        )
        output.contacts = infos
        output.count = total
        return output
    }

    static func get(_ input: MacOSRunInput) async throws -> MacOSRunOutput {
        let store = try await store()
        let contact = try fetch(try input.require(input.contact_id, "contact_id"), store: store)
        var output = MacOSRunOutput(action: .contactsGet, summary: "Contact '\(displayName(contact))'.")
        output.contact = info(contact)
        return output
    }

    static func create(_ input: MacOSRunInput) async throws -> MacOSRunOutput {
        let store = try await store()
        let contact = CNMutableContact()
        try apply(input, to: contact)
        guard !(contact.givenName.isEmpty && contact.familyName.isEmpty && contact.organizationName.isEmpty) else {
            throw MacOSControlError.missingArgument("given_name, family_name, or organization", input.action)
        }
        if contact.givenName.isEmpty, contact.familyName.isEmpty, !contact.organizationName.isEmpty {
            contact.contactType = .organization
        }
        let request = CNSaveRequest()
        request.add(contact, toContainerWithIdentifier: nil)
        do {
            try store.execute(request)
        } catch {
            throw MacOSControlError.operationFailed("Contacts refused to create the contact: \(error.localizedDescription)")
        }
        let saved = (try? fetch(contact.identifier, store: store)) ?? contact
        var output = MacOSRunOutput(action: .contactsCreate, summary: "Created contact '\(displayName(saved))'.")
        output.contact = info(saved)
        return output
    }

    static func update(_ input: MacOSRunInput) async throws -> MacOSRunOutput {
        let store = try await store()
        let existing = try fetch(try input.require(input.contact_id, "contact_id"), store: store)
        guard let contact = existing.mutableCopy() as? CNMutableContact else {
            throw MacOSControlError.operationFailed("The contact could not be edited.")
        }
        try apply(input, to: contact)
        let request = CNSaveRequest()
        request.update(contact)
        do {
            try store.execute(request)
        } catch {
            throw MacOSControlError.operationFailed("Contacts refused to update the contact: \(error.localizedDescription)")
        }
        let saved = (try? fetch(contact.identifier, store: store)) ?? contact
        var output = MacOSRunOutput(action: .contactsUpdate, summary: "Updated contact '\(displayName(saved))'.")
        output.contact = info(saved)
        return output
    }

    static func delete(_ input: MacOSRunInput) async throws -> MacOSRunOutput {
        let store = try await store()
        let existing = try fetch(try input.require(input.contact_id, "contact_id"), store: store)
        guard let contact = existing.mutableCopy() as? CNMutableContact else {
            throw MacOSControlError.operationFailed("The contact could not be edited.")
        }
        let name = displayName(contact)
        let request = CNSaveRequest()
        request.delete(contact)
        do {
            try store.execute(request)
        } catch {
            throw MacOSControlError.operationFailed("Contacts refused to delete the contact: \(error.localizedDescription)")
        }
        return MacOSRunOutput(action: .contactsDelete, summary: "Deleted contact '\(name)'.")
    }

    // MARK: - Helpers

    private static func fetch(_ identifier: String, store: CNContactStore) throws -> CNContact {
        do {
            return try store.unifiedContact(withIdentifier: identifier, keysToFetch: fetchKeys)
        } catch {
            throw MacOSControlError.notFound("No contact has id '\(identifier)'. Use action=search to look it up.")
        }
    }

    private static func looksLikePhoneNumber(_ query: String) -> Bool {
        let digits = query.filter(\.isNumber).count
        let allowed = CharacterSet(charactersIn: "+0123456789 ()-.")
        return digits >= 3 && query.unicodeScalars.allSatisfy { allowed.contains($0) }
    }

    private static func matches(_ contact: CNContact, query: String) -> Bool {
        let fields: [String] = [
            contact.givenName, contact.familyName, contact.middleName, contact.nickname,
            contact.organizationName, contact.jobTitle, contact.departmentName,
        ] + contact.emailAddresses.map { String($0.value) }
            + contact.urlAddresses.map { String($0.value) }
            + contact.phoneNumbers.map { $0.value.stringValue }
        return fields.contains { $0.range(of: query, options: [.caseInsensitive, .diacriticInsensitive]) != nil }
    }

    private static func apply(_ input: MacOSRunInput, to contact: CNMutableContact) throws {
        if let value = input.given_name { contact.givenName = value }
        if let value = input.family_name { contact.familyName = value }
        if let value = input.middle_name { contact.middleName = value }
        if let value = input.nickname { contact.nickname = value }
        if let value = input.organization { contact.organizationName = value }
        if let value = input.job_title { contact.jobTitle = value }
        if let emails = input.emails {
            contact.emailAddresses = emails.filter { !$0.value.isEmpty }.map {
                CNLabeledValue(label: label($0.label, kind: .email), value: $0.value as NSString)
            }
        }
        if let phones = input.phones {
            contact.phoneNumbers = phones.filter { !$0.value.isEmpty }.map {
                CNLabeledValue(label: label($0.label, kind: .phone), value: CNPhoneNumber(stringValue: $0.value))
            }
        }
        if let urls = input.urls {
            contact.urlAddresses = urls.filter { !$0.value.isEmpty }.map {
                CNLabeledValue(label: label($0.label, kind: .url), value: $0.value as NSString)
            }
        }
        if let addresses = input.addresses {
            contact.postalAddresses = addresses.map { address in
                let postal = CNMutablePostalAddress()
                postal.street = address.street ?? ""
                postal.city = address.city ?? ""
                postal.state = address.state ?? ""
                postal.postalCode = address.postal_code ?? ""
                postal.country = address.country ?? ""
                return CNLabeledValue(label: label(address.label, kind: .address), value: postal)
            }
        }
        if let birthday = input.birthday {
            if birthday.isEmpty {
                contact.birthday = nil
            } else if let date = MacOSDate.parse(birthday) {
                var components = Calendar(identifier: .gregorian).dateComponents([.year, .month, .day], from: date)
                components.calendar = Calendar(identifier: .gregorian)
                contact.birthday = components
            } else if let components = monthDay(birthday) {
                contact.birthday = components
            } else {
                throw MacOSControlError.invalidArgument("birthday", "use yyyy-MM-dd or --MM-dd.")
            }
        }
    }

    private static func monthDay(_ raw: String) -> DateComponents? {
        let parts = raw.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: "--", with: "").split(separator: "-")
        guard parts.count == 2, let month = Int(parts[0]), let day = Int(parts[1]),
              (1...12).contains(month), (1...31).contains(day) else {
            return nil
        }
        var components = DateComponents()
        components.calendar = Calendar(identifier: .gregorian)
        components.month = month
        components.day = day
        return components
    }

    private enum LabelKind { case email, phone, url, address }

    private static func label(_ raw: String?, kind: LabelKind) -> String {
        switch raw?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case nil, "":
            switch kind {
            case .phone: return CNLabelPhoneNumberMobile
            case .email, .url, .address: return CNLabelHome
            }
        case "home", "casa": return CNLabelHome
        case "work", "lavoro", "ufficio": return CNLabelWork
        case "school", "scuola": return CNLabelSchool
        case "other", "altro": return CNLabelOther
        case "mobile", "cell", "cellulare": return CNLabelPhoneNumberMobile
        case "iphone": return CNLabelPhoneNumberiPhone
        case "main", "principale": return CNLabelPhoneNumberMain
        case "home fax": return CNLabelPhoneNumberHomeFax
        case "work fax": return CNLabelPhoneNumberWorkFax
        case "pager": return CNLabelPhoneNumberPager
        case "homepage", "home page": return CNLabelURLAddressHomePage
        case "icloud": return CNLabelEmailiCloud
        case let custom?: return custom
        }
    }

    private static func displayName(_ contact: CNContact) -> String {
        if let formatted = CNContactFormatter.string(from: contact, style: .fullName), !formatted.isEmpty {
            return formatted
        }
        if !contact.organizationName.isEmpty {
            return contact.organizationName
        }
        return contact.emailAddresses.first.map { String($0.value) } ?? contact.identifier
    }

    static func info(_ contact: CNContact) -> ContactInfo {
        func localized(_ label: String?) -> String? {
            guard let label, !label.isEmpty else { return nil }
            return CNLabeledValue<NSString>.localizedString(forLabel: label)
        }
        let birthday: String? = contact.birthday.map { components in
            if let year = components.year, let month = components.month, let day = components.day {
                return String(format: "%04d-%02d-%02d", year, month, day)
            }
            if let month = components.month, let day = components.day {
                return String(format: "--%02d-%02d", month, day)
            }
            return ""
        }.flatMap { $0.isEmpty ? nil : $0 }
        return ContactInfo(
            id: contact.identifier,
            name: displayName(contact),
            given_name: contact.givenName.isEmpty ? nil : contact.givenName,
            family_name: contact.familyName.isEmpty ? nil : contact.familyName,
            middle_name: contact.middleName.isEmpty ? nil : contact.middleName,
            nickname: contact.nickname.isEmpty ? nil : contact.nickname,
            organization: contact.organizationName.isEmpty ? nil : contact.organizationName,
            job_title: contact.jobTitle.isEmpty ? nil : contact.jobTitle,
            department: contact.departmentName.isEmpty ? nil : contact.departmentName,
            is_company: contact.contactType == .organization,
            emails: contact.emailAddresses.map { LabeledValueInfo(label: localized($0.label), value: String($0.value)) },
            phones: contact.phoneNumbers.map { LabeledValueInfo(label: localized($0.label), value: $0.value.stringValue) },
            addresses: contact.postalAddresses.map {
                PostalAddressInfo(
                    label: localized($0.label),
                    street: $0.value.street.isEmpty ? nil : $0.value.street,
                    city: $0.value.city.isEmpty ? nil : $0.value.city,
                    state: $0.value.state.isEmpty ? nil : $0.value.state,
                    postal_code: $0.value.postalCode.isEmpty ? nil : $0.value.postalCode,
                    country: $0.value.country.isEmpty ? nil : $0.value.country
                )
            },
            urls: contact.urlAddresses.map { LabeledValueInfo(label: localized($0.label), value: String($0.value)) },
            social_profiles: contact.socialProfiles.map {
                SocialProfileInfo(
                    service: $0.value.service.isEmpty ? nil : $0.value.service,
                    username: $0.value.username.isEmpty ? nil : $0.value.username,
                    url: $0.value.urlString.isEmpty ? nil : $0.value.urlString
                )
            },
            birthday: birthday,
            has_image: contact.imageDataAvailable
        )
    }
}
