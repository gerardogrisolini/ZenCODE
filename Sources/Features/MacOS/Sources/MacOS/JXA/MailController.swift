import Foundation
import ToolCore

enum MailController {
    // MARK: - Scripts

    private static let helpers = #"""
    function specialMailbox(mail, name) {
      switch (lower(name)) {
        case "": case "inbox": return mail.inbox;
        case "sent": return mail.sentMailbox;
        case "drafts": return mail.draftsMailbox;
        case "trash": case "deleted": case "bin": return mail.trashMailbox;
        case "junk": case "spam": return mail.junkMailbox;
        case "outbox": return mail.outbox;
        default: return null;
      }
    }
    function findAccount(mail, name) {
      const accounts = mail.accounts();
      for (const a of accounts) { if (lower(a.name()) === lower(name)) { return a; } }
      for (const a of accounts) { const emails = safeArray(() => a.emailAddresses()); if (emails.some(e => lower(e) === lower(name))) { return a; } }
      for (const a of accounts) { if (contains(a.name(), name)) { return a; } }
      fail("No Mail account matches '" + name + "'. Use action=accounts to list accounts.");
    }
    function resolveMailboxes(mail, mailboxName, accountName) {
      if (!accountName) {
        const special = specialMailbox(mail, mailboxName || "");
        if (special) { return [special]; }
      }
      const boxes = [];
      const accounts = accountName ? [findAccount(mail, accountName)] : mail.accounts();
      for (const account of accounts) {
        const names = safeArray(() => account.mailboxes.name());
        for (let i = 0; i < names.length; i++) {
          if (!mailboxName || lower(names[i]) === lower(mailboxName)) { boxes.push(account.mailboxes[i]); }
        }
      }
      if (boxes.length === 0 && mailboxName && accountName) {
        const special = specialMailbox(mail, mailboxName);
        if (special) {
          for (const sub of safeArray(() => special.mailboxes())) {
            if (lower(safe(() => sub.account().name(), "")) === lower(accounts[0].name())) { boxes.push(sub); }
          }
        }
      }
      if (boxes.length === 0) {
        fail("No mailbox named '" + mailboxName + "'" + (accountName ? " in account '" + accountName + "'" : "") + ". Use action=accounts to list mailboxes.");
      }
      return boxes;
    }
    function tryMessage(box, id) {
      try { const m = box.messages.byId(id); m.subject(); return m; } catch (e) { return null; }
    }
    function findMessage(mail, id, mailboxName, accountName) {
      if (!Number.isFinite(Number(id))) { fail("message_id must be the integer id returned by action=list."); }
      const boxes = (mailboxName || accountName) ? resolveMailboxes(mail, mailboxName, accountName) : [mail.inbox];
      for (const box of boxes) { const m = tryMessage(box, Number(id)); if (m) { return m; } }
      if (!mailboxName && !accountName) {
        for (const account of mail.accounts()) {
          for (const box of safeArray(() => account.mailboxes())) { const m = tryMessage(box, Number(id)); if (m) { return m; } }
        }
      }
      fail("No message with id " + id + " was found" + (mailboxName ? " in mailbox '" + mailboxName + "'" : "") + ". Use action=list first; pass mailbox and account for messages outside the inbox.");
    }
    function summarize(m) {
      return {
        id: m.id(),
        account: safe(() => str(m.mailbox().account().name()), null),
        mailbox: safe(() => str(m.mailbox().name()), null),
        subject: safe(() => str(m.subject()), null),
        sender: safe(() => str(m.sender()), null),
        date_received: safe(() => iso(m.dateReceived()), null),
        date_sent: safe(() => iso(m.dateSent()), null),
        read: safe(() => m.readStatus(), null),
        flagged: safe(() => m.flaggedStatus(), null),
        message_id: safe(() => str(m.messageId()), null)
      };
    }
    """#

    private static let accountsScript = helpers + #"""
    function main(p) {
      const mail = Application("Mail");
      const out = [];
      for (const a of mail.accounts()) {
        const names = safeArray(() => a.mailboxes.name());
        const unread = safeArray(() => a.mailboxes.unreadCount());
        out.push({
          name: str(a.name()),
          id: safe(() => str(a.id()), null),
          type: safe(() => str(a.accountType()), null),
          email_addresses: safeArray(() => a.emailAddresses()).map(str),
          full_name: safe(() => str(a.fullName()), null),
          enabled: safe(() => a.enabled(), null),
          mailboxes: names.map((n, i) => ({name: str(n), unread_count: (typeof unread[i] === "number") ? unread[i] : null}))
        });
      }
      return {accounts: out, inbox_unread: safe(() => mail.inbox.unreadCount(), null)};
    }
    """#

    private static let listScript = helpers + #"""
    function main(p) {
      const mail = Application("Mail");
      const boxes = resolveMailboxes(mail, p.mailbox, p.account);
      const limit = clampLimit(p.limit, 25, 200);
      const since = date(p.since);
      const until = date(p.until);
      const rows = [];
      boxes.forEach((box, boxIndex) => {
        const conds = [];
        if (since) { conds.push({dateReceived: {_greaterThan: since}}); }
        if (until) { conds.push({dateReceived: {_lessThan: until}}); }
        if (p.unread_only) { conds.push({readStatus: false}); }
        if (p.query) { conds.push({_or: [{subject: {_contains: p.query}}, {sender: {_contains: p.query}}]}); }
        let msgs = box.messages;
        if (conds.length === 1) { msgs = msgs.whose(conds[0]); } else if (conds.length > 1) { msgs = msgs.whose({_and: conds}); }
        const ids = msgs.id();
        if (ids.length === 0) { return; }
        const subjects = msgs.subject();
        const senders = msgs.sender();
        const dates = msgs.dateReceived();
        const reads = msgs.readStatus();
        const flags = msgs.flaggedStatus();
        const boxName = safe(() => str(box.name()), null);
        const accountName = safe(() => str(box.account().name()), null);
        for (let i = 0; i < ids.length; i++) {
          rows.push({
            id: ids[i], account: accountName, mailbox: boxName,
            subject: str(subjects[i]), sender: str(senders[i]), date_received: iso(dates[i]), date_sent: null,
            read: reads[i], flagged: flags[i], message_id: null,
            _t: dates[i] instanceof Date ? dates[i].getTime() : 0, _box: boxIndex
          });
        }
      });
      rows.sort((a, b) => b._t - a._t);
      const total = rows.length;
      const selected = rows.slice(0, limit);
      for (const row of selected) {
        if (row.account === null) {
          const m = tryMessage(boxes[row._box], row.id);
          if (m) {
            row.account = safe(() => str(m.mailbox().account().name()), null);
            row.mailbox = safe(() => str(m.mailbox().name()), row.mailbox);
          }
        }
        delete row._t;
        delete row._box;
      }
      return {total: total, messages: selected};
    }
    """#

    private static let getScript = helpers + #"""
    function main(p) {
      const mail = Application("Mail");
      const m = findMessage(mail, p.message_id, p.mailbox, p.account);
      const maxChars = clampLimit(p.max_chars, 20000, 200000);
      let content = safe(() => str(m.content()), "") || "";
      const truncated = content.length > maxChars;
      if (truncated) { content = content.slice(0, maxChars); }
      const attachments = safeArray(() => m.mailAttachments()).map(a => ({
        name: safe(() => str(a.name()), null),
        mime_type: safe(() => str(a.mimeType()), null),
        size: safe(() => num(a.fileSize()), null),
        downloaded: safe(() => a.downloaded(), null)
      }));
      const s = summarize(m);
      s.reply_to = safe(() => str(m.replyTo()), null);
      s.to = safeArray(() => m.toRecipients.address()).map(str);
      s.cc = safeArray(() => m.ccRecipients.address()).map(str);
      s.content = content;
      s.content_truncated = truncated;
      s.attachments = attachments;
      return s;
    }
    """#

    private static let sendScript = helpers + #"""
    function main(p) {
      const mail = Application("Mail");
      const msg = mail.OutgoingMessage({subject: p.subject || "", content: p.body || "", visible: false});
      mail.outgoingMessages.push(msg);
      try {
        if (p.from) { msg.sender = p.from; }
        (p.to || []).forEach(a => msg.toRecipients.push(mail.ToRecipient({address: a})));
        (p.cc || []).forEach(a => msg.ccRecipients.push(mail.CcRecipient({address: a})));
        (p.bcc || []).forEach(a => msg.bccRecipients.push(mail.BccRecipient({address: a})));
        (p.attachments || []).forEach(path => msg.attachments.push(mail.Attachment({fileName: Path(path)})));
      } catch (e) {
        safe(() => mail.delete(msg), null);
        throw e;
      }
      mail.send(msg);
      return {sent: true, id: safe(() => msg.id(), null)};
    }
    """#

    private static let replyScript = helpers + #"""
    function main(p) {
      const mail = Application("Mail");
      const m = findMessage(mail, p.message_id, p.mailbox, p.account);
      const reply = mail.reply(m, {openingWindow: false, replyToAll: !!p.reply_all});
      try {
        // Never read reply.content() before assigning it: Mail silently ignores a
        // content assignment on a reply whose content was read first, so the reply
        // went out with an empty body. A window-less reply starts empty anyway.
        reply.content = p.body || "";
        (p.cc || []).forEach(a => reply.ccRecipients.push(mail.CcRecipient({address: a})));
        (p.attachments || []).forEach(path => reply.attachments.push(mail.Attachment({fileName: Path(path)})));
        const written = safe(() => str(reply.content()), "") || "";
        if ((p.body || "").trim() && !written.trim()) { fail("Mail did not accept the reply body; the reply was not sent."); }
      } catch (e) {
        safe(() => reply.close({saving: "no"}), null);
        throw e;
      }
      const subject = safe(() => str(reply.subject()), null);
      const to = safeArray(() => reply.toRecipients.address()).map(str);
      mail.send(reply);
      return {sent: true, id: safe(() => reply.id(), null), subject: subject, to: to};
    }
    """#

    private static let markScript = helpers + #"""
    function main(p) {
      const mail = Application("Mail");
      const m = findMessage(mail, p.message_id, p.mailbox, p.account);
      if (typeof p.read === "boolean") { m.readStatus = p.read; }
      if (typeof p.flagged === "boolean") { m.flaggedStatus = p.flagged; }
      return summarize(m);
    }
    """#

    private static let moveScript = helpers + #"""
    function main(p) {
      const mail = Application("Mail");
      const m = findMessage(mail, p.message_id, p.mailbox, p.account);
      const sourceAccount = safe(() => str(m.mailbox().account().name()), null);
      const targets = resolveMailboxes(mail, p.target_mailbox, p.target_account || sourceAccount);
      if (targets.length !== 1) { fail("Mailbox '" + p.target_mailbox + "' is ambiguous; pass target_account."); }
      mail.move(m, {to: targets[0]});
      return {id: Number(p.message_id), mailbox: safe(() => str(targets[0].name()), null), account: safe(() => str(targets[0].account().name()), null)};
    }
    """#

    private static let deleteScript = helpers + #"""
    function main(p) {
      const mail = Application("Mail");
      const m = findMessage(mail, p.message_id, p.mailbox, p.account);
      const summary = summarize(m);
      mail.delete(m);
      return summary;
    }
    """#

    // MARK: - Wire models

    private struct AccountsResult: Decodable {
        struct Account: Decodable {
            let name: String
            let id: String?
            let type: String?
            let email_addresses: [String]
            let full_name: String?
            let enabled: Bool?
            let mailboxes: [MailMailboxInfo]
        }
        let accounts: [Account]
        let inbox_unread: Int?
    }

    private struct Summary: Decodable {
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

        var info: MailMessageInfo {
            MailMessageInfo(
                id: id, account: account, mailbox: mailbox, subject: subject, sender: sender,
                date_received: MacOSDate.localize(date_received), date_sent: MacOSDate.localize(date_sent),
                read: read, flagged: flagged, message_id: message_id
            )
        }
    }

    private struct ListResult: Decodable {
        let total: Int
        let messages: [Summary]
    }

    private struct Detail: Decodable {
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

    private struct SendResult: Decodable {
        let sent: Bool
        let id: Int?
        let subject: String?
        let to: [String]?
    }

    private struct MoveResult: Decodable {
        let id: Int
        let mailbox: String?
        let account: String?
    }

    // MARK: - Actions

    static func accounts(_ input: MacOSRunInput) async throws -> MacOSRunOutput {
        let result = try await JXARunner.run(accountsScript, parameters: [:], as: AccountsResult.self)
        var output = MacOSRunOutput(
            action: .mailAccounts,
            summary: "\(result.accounts.count) Mail accounts" + (result.inbox_unread.map { ", \($0) unread in the inbox." } ?? ".")
        )
        output.mail_accounts = result.accounts.map {
            MailAccountInfo(
                name: $0.name, id: $0.id, type: $0.type, email_addresses: $0.email_addresses,
                full_name: $0.full_name, enabled: $0.enabled, mailboxes: $0.mailboxes
            )
        }
        output.count = result.accounts.count
        return output
    }

    static func list(_ input: MacOSRunInput) async throws -> MacOSRunOutput {
        let since = try MacOSDate.parse(input.since ?? input.start, argument: "since", action: input.action)
        let until = try MacOSDate.parse(input.until ?? input.end, argument: "until", action: input.action)
        var parameters: [String: JSONValue] = [
            "limit": .number(Double(input.boundedLimit(default: 25, maximum: 200))),
            "unread_only": .bool(input.unread_only ?? false),
        ]
        if let mailbox = input.mailbox { parameters["mailbox"] = .string(mailbox) }
        if let account = input.account { parameters["account"] = .string(account) }
        if let since { parameters["since"] = .string(javaScriptDate(since)) }
        if let until { parameters["until"] = .string(javaScriptDate(until)) }
        if let query = input.query?.trimmingCharacters(in: .whitespacesAndNewlines), !query.isEmpty {
            parameters["query"] = .string(query)
        }
        let result = try await JXARunner.run(listScript, parameters: parameters, as: ListResult.self)
        let shown = result.messages.count
        var output = MacOSRunOutput(
            action: .mailList,
            summary: "\(result.total) messages in \(input.mailbox ?? "inbox")"
                + (input.account.map { " (\($0))" } ?? "")
                + (result.total > shown ? " (showing the \(shown) most recent)." : ".")
        )
        output.messages = result.messages.map(\.info)
        output.count = result.total
        if since == nil, input.query == nil, input.unread_only != true {
            output.hint = "Pass since (ISO date), query, or unread_only to focus the list."
        }
        return output
    }

    static func get(_ input: MacOSRunInput) async throws -> MacOSRunOutput {
        let detail = try await JXARunner.run(
            getScript,
            parameters: try messageParameters(input, extra: ["max_chars": .number(Double(input.boundedMaxChars()))]),
            as: Detail.self
        )
        var output = MacOSRunOutput(
            action: .mailGet,
            summary: "Message \(detail.id): '\(detail.subject ?? "")' from \(detail.sender ?? "unknown")."
        )
        output.message = MailMessageDetail(
            id: detail.id, account: detail.account, mailbox: detail.mailbox, subject: detail.subject,
            sender: detail.sender, reply_to: detail.reply_to,
            date_received: MacOSDate.localize(detail.date_received), date_sent: MacOSDate.localize(detail.date_sent),
            read: detail.read, flagged: detail.flagged, to: detail.to, cc: detail.cc, message_id: detail.message_id,
            content: detail.content, content_truncated: detail.content_truncated, attachments: detail.attachments
        )
        return output
    }

    static func send(_ input: MacOSRunInput) async throws -> MacOSRunOutput {
        let recipients = input.to?.values ?? []
        guard !recipients.isEmpty else {
            throw MacOSControlError.missingArgument("to", input.action)
        }
        let subject = try input.require(input.subject, "subject")
        let body = input.body ?? ""
        let attachments = try validatedAttachments(input)
        var parameters: [String: JSONValue] = [
            "subject": .string(subject),
            "body": .string(body),
            "to": .array(recipients.map(JSONValue.string)),
            "cc": .array((input.cc?.values ?? []).map(JSONValue.string)),
            "bcc": .array((input.bcc?.values ?? []).map(JSONValue.string)),
            "attachments": .array(attachments.map(JSONValue.string)),
        ]
        if let from = input.from { parameters["from"] = .string(from) }
        let result = try await JXARunner.run(sendScript, parameters: parameters, as: SendResult.self)
        guard result.sent else {
            throw MacOSControlError.operationFailed("Mail did not send the message.")
        }
        return MacOSRunOutput(
            action: .mailSend,
            summary: "Sent '\(subject)' to \(recipients.joined(separator: ", "))"
                + (attachments.isEmpty ? "." : " with \(attachments.count) attachment(s).")
        )
    }

    static func reply(_ input: MacOSRunInput) async throws -> MacOSRunOutput {
        let body = try input.require(input.body, "body")
        let attachments = try validatedAttachments(input)
        let parameters = try messageParameters(input, extra: [
            "body": .string(body),
            "reply_all": .bool(input.reply_all ?? false),
            "cc": .array((input.cc?.values ?? []).map(JSONValue.string)),
            "attachments": .array(attachments.map(JSONValue.string)),
        ])
        let result = try await JXARunner.run(replyScript, parameters: parameters, as: SendResult.self)
        guard result.sent else {
            throw MacOSControlError.operationFailed("Mail did not send the reply.")
        }
        return MacOSRunOutput(
            action: .mailReply,
            summary: "Replied to message \(input.message_id ?? 0)"
                + (result.subject.map { " ('\($0)')" } ?? "")
                + (result.to.map { $0.isEmpty ? "" : " to \($0.joined(separator: ", "))" } ?? "")
                + "."
        )
    }

    static func mark(_ input: MacOSRunInput) async throws -> MacOSRunOutput {
        guard input.read != nil || input.flagged != nil else {
            throw MacOSControlError.missingArgument("read or flagged", input.action)
        }
        var extra: [String: JSONValue] = [:]
        if let read = input.read { extra["read"] = .bool(read) }
        if let flagged = input.flagged { extra["flagged"] = .bool(flagged) }
        let summary = try await JXARunner.run(markScript, parameters: try messageParameters(input, extra: extra), as: Summary.self)
        var changes: [String] = []
        if let read = input.read { changes.append(read ? "read" : "unread") }
        if let flagged = input.flagged { changes.append(flagged ? "flagged" : "unflagged") }
        var output = MacOSRunOutput(
            action: .mailMark,
            summary: "Marked message \(summary.id) ('\(summary.subject ?? "")') as \(changes.joined(separator: " and "))."
        )
        output.messages = [summary.info]
        return output
    }

    static func move(_ input: MacOSRunInput) async throws -> MacOSRunOutput {
        let target = try input.require(input.target_mailbox, "target_mailbox")
        var extra: [String: JSONValue] = ["target_mailbox": .string(target)]
        if let account = input.target_account { extra["target_account"] = .string(account) }
        let result = try await JXARunner.run(moveScript, parameters: try messageParameters(input, extra: extra), as: MoveResult.self)
        return MacOSRunOutput(
            action: .mailMove,
            summary: "Moved message \(result.id) to '\(result.mailbox ?? target)'" + (result.account.map { " (\($0))." } ?? ".")
        )
    }

    static func delete(_ input: MacOSRunInput) async throws -> MacOSRunOutput {
        let summary = try await JXARunner.run(deleteScript, parameters: try messageParameters(input, extra: [:]), as: Summary.self)
        return MacOSRunOutput(
            action: .mailDelete,
            summary: "Deleted message \(summary.id) ('\(summary.subject ?? "")') from \(summary.mailbox ?? "its mailbox"); Mail moved it to the trash according to the account settings."
        )
    }

    // MARK: - Helpers

    private static func messageParameters(_ input: MacOSRunInput, extra: [String: JSONValue]) throws -> [String: JSONValue] {
        guard let messageID = input.message_id, messageID > 0 else {
            throw MacOSControlError.missingArgument("message_id", input.action)
        }
        var parameters: [String: JSONValue] = ["message_id": .number(Double(messageID))]
        if let mailbox = input.mailbox { parameters["mailbox"] = .string(mailbox) }
        if let account = input.account { parameters["account"] = .string(account) }
        for (key, value) in extra {
            parameters[key] = value
        }
        return parameters
    }

    private static func validatedAttachments(_ input: MacOSRunInput) throws -> [String] {
        let paths = input.attachments?.values ?? []
        return try paths.map { raw in
            let path = NSString(string: raw).expandingTildeInPath
            let url = path.hasPrefix("/")
                ? URL(fileURLWithPath: path)
                : URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent(path)
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory), !isDirectory.boolValue else {
                throw MacOSControlError.invalidArgument("attachments", "'\(raw)' is not an existing file.")
            }
            return url.standardizedFileURL.path
        }
    }

    static func javaScriptDate(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        return formatter.string(from: date)
    }
}
