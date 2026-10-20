import Foundation
import ToolCore

enum MessagesController {
    // MARK: - Scripts

    private static let chatsScript = #"""
    function main(p) {
      const app = Application("Messages");
      const limit = clampLimit(p.limit, 50, 500);
      const query = p.query ? String(p.query) : "";
      const ids = safeArray(() => app.chats.id());
      const names = safeArray(() => app.chats.name());
      const rows = [];
      for (let i = 0; i < ids.length; i++) {
        const chat = app.chats[i];
        const handles = safeArray(() => chat.participants.handle()).map(str);
        const participantNames = safeArray(() => chat.participants.name()).map(str);
        const participants = handles.map((h, j) => ({handle: h, name: participantNames[j] !== undefined ? participantNames[j] : null}));
        const name = (names[i] === undefined) ? null : str(names[i]);
        if (query) {
          const hit = contains(ids[i], query) || contains(name, query)
            || participants.some(x => contains(x.handle, query) || contains(x.name, query));
          if (!hit) { continue; }
        }
        rows.push({id: str(ids[i]), name: name, participants: participants});
      }
      return {total: rows.length, chats: rows.slice(0, limit)};
    }
    """#

    private static let sendScript = #"""
    function main(p) {
      const app = Application("Messages");
      let target = null;
      let label = null;
      if (p.chat_id) {
        target = app.chats.byId(String(p.chat_id));
        label = safe(() => str(target.name()), null) || String(p.chat_id);
        try { target.id(); } catch (e) { fail("No chat has id '" + p.chat_id + "'. Use action=chats to look it up."); }
      } else {
        const needle = lower(p.to);
        const handles = safeArray(() => app.participants.handle()).map(str);
        let matches = [];
        handles.forEach((h, i) => { if (lower(h) === needle) { matches.push(i); } });
        if (matches.length === 0) {
          const names = safeArray(() => app.participants.name()).map(str);
          names.forEach((n, i) => { if (lower(n) === needle) { matches.push(i); } });
          if (matches.length === 0) {
            names.forEach((n, i) => { if (contains(n, needle)) { matches.push(i); } });
          }
          if (matches.length > 1) {
            const candidates = matches.slice(0, 8).map(i => names[i] + " <" + handles[i] + ">");
            fail("Several contacts match '" + p.to + "': " + candidates.join(", ") + ". Pass the exact handle (phone number or email).");
          }
        }
        if (matches.length >= 1) {
          target = app.participants[matches[0]];
          label = handles[matches[0]];
        } else {
          const chatIds = safeArray(() => app.chats.id()).map(str);
          const chatIndex = chatIds.findIndex(id => lower(id.split(";").pop()) === needle);
          if (chatIndex === -1) {
            fail("No conversation or known participant matches '" + p.to + "'. Start the conversation once in Messages, or pass chat_id from action=chats.");
          }
          target = app.chats[chatIndex];
          label = chatIds[chatIndex];
        }
      }
      app.send(String(p.text), {to: target});
      return {sent: true, target: label};
    }
    """#

    private struct ChatsResult: Decodable {
        let total: Int
        let chats: [ChatInfo]
    }

    private struct SendResult: Decodable {
        let sent: Bool
        let target: String?
    }

    // MARK: - Actions

    static func chats(_ input: MacOSRunInput) async throws -> MacOSRunOutput {
        var parameters: [String: JSONValue] = [
            "limit": .number(Double(input.boundedLimit(default: 50, maximum: 500))),
        ]
        if let query = input.query?.trimmingCharacters(in: .whitespacesAndNewlines), !query.isEmpty {
            parameters["query"] = .string(query)
        }
        let result = try await JXARunner.run(chatsScript, parameters: parameters, as: ChatsResult.self)
        var output = MacOSRunOutput(
            action: .messagesChats,
            summary: "\(result.total) conversations" + (result.total > result.chats.count ? " (showing \(result.chats.count))." : ".")
        )
        output.chats = result.chats
        output.count = result.total
        output.hint = "Use action=read with chat_id or handle to read a conversation; it needs Full Disk Access for the application hosting ZenCODE."
        return output
    }

    static func read(_ input: MacOSRunInput) async throws -> MacOSRunOutput {
        let since = try MacOSDate.parse(input.since ?? input.start, argument: "since", action: input.action)
        let limit = input.boundedLimit(default: 30, maximum: 500)
        let query = input.query?.trimmingCharacters(in: .whitespacesAndNewlines)
        let selector = input.chat_id ?? input.handle ?? input.to?.values.first
        let result = try MessagesDatabase.read(
            selector: selector,
            since: since,
            query: (query?.isEmpty ?? true) ? nil : query,
            limit: limit
        )
        var output = MacOSRunOutput(
            action: .messagesRead,
            summary: "\(result.texts.count) messages"
                + (selector.map { " in conversation '\($0)'" } ?? "")
                + (since.map { " since \(MacOSDate.format($0) ?? "")" } ?? "")
                + (result.scannedLimitReached ? " (only the most recent \(MessagesDatabase.scanWindow) messages were searched)." : ".")
        )
        output.texts = result.texts
        output.count = result.texts.count
        return output
    }

    static func send(_ input: MacOSRunInput) async throws -> MacOSRunOutput {
        let text = try input.require(input.text ?? input.body, "text")
        var parameters: [String: JSONValue] = ["text": .string(text)]
        if let chatID = input.chat_id?.trimmingCharacters(in: .whitespacesAndNewlines), !chatID.isEmpty {
            parameters["chat_id"] = .string(chatID)
        } else if let recipient = (input.to?.values.first ?? input.handle)?.trimmingCharacters(in: .whitespacesAndNewlines), !recipient.isEmpty {
            parameters["to"] = .string(recipient)
        } else {
            throw MacOSControlError.missingArgument("to (handle) or chat_id", input.action)
        }
        let result = try await JXARunner.run(sendScript, parameters: parameters, as: SendResult.self)
        guard result.sent else {
            throw MacOSControlError.operationFailed("Messages did not send the text.")
        }
        return MacOSRunOutput(
            action: .messagesSend,
            summary: "Sent message to \(result.target ?? input.chat_id ?? input.to?.values.first ?? "recipient") (\(text.count) characters)."
        )
    }
}
