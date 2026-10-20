import Foundation
import ToolCore

enum NotesController {
    // MARK: - Scripts

    private static let helpers = #"""
    function findAccount(notes, name) {
      const accounts = safeArray(() => notes.accounts());
      for (const a of accounts) { if (lower(safe(() => a.name(), "")) === lower(name)) { return a; } }
      for (const a of accounts) { if (contains(safe(() => a.name(), ""), name)) { return a; } }
      fail("No Notes account matches '" + name + "'. Use action=folders to list accounts.");
    }
    function folderRows(notes, accountName) {
      const rows = [];
      const accounts = accountName ? [findAccount(notes, accountName)] : safeArray(() => notes.accounts());
      for (const account of accounts) {
        const accName = safe(() => str(account.name()), null);
        const walk = (container, prefix, depth) => {
          if (depth > 4) { return; }
          const ids = safeArray(() => container.folders.id()).map(str);
          const names = safeArray(() => container.folders.name()).map(str);
          ids.forEach((id, i) => {
            const path = prefix ? prefix + "/" + names[i] : names[i];
            const folder = container.folders[i];
            rows.push({account: accName, name: names[i], path: path, id: id, folder: folder});
            walk(folder, path, depth + 1);
          });
        };
        walk(account, "", 0);
      }
      return rows;
    }
    function folderIndex(notes) {
      const index = {};
      folderRows(notes, null).forEach(r => { index[r.id] = r; });
      return index;
    }
    function findFolder(notes, selector, accountName) {
      const rows = folderRows(notes, accountName);
      const needle = lower(selector);
      let match = rows.find(r => r.id === selector);
      if (!match) {
        const exact = rows.filter(r => lower(r.name) === needle || lower(r.path) === needle);
        if (exact.length === 1) { match = exact[0]; }
        else if (exact.length > 1) { fail("Several folders match '" + selector + "' (" + exact.map(r => r.account + ": " + r.path).join(", ") + "); pass account or the folder id."); }
      }
      if (!match) {
        const partial = rows.filter(r => contains(r.path, needle));
        if (partial.length === 1) { match = partial[0]; }
        else if (partial.length > 1) { fail("Several folders match '" + selector + "': " + partial.map(r => r.account + ": " + r.path).join(", ") + "."); }
      }
      if (!match) { fail("No Notes folder matches '" + selector + "'. Use action=folders to list folders."); }
      return match;
    }
    function noteById(notes, id) {
      const note = notes.notes.byId(String(id));
      try { note.id(); } catch (e) { fail("No note has id '" + id + "'. Use action=list or action=search to look it up."); }
      return note;
    }
    function locate(note, index) {
      const folderId = safe(() => str(note.container().id()), null);
      const row = folderId ? index[folderId] : null;
      return {folder: row ? row.path : safe(() => str(note.container().name()), null), account: row ? row.account : null};
    }
    function excerpt(text, query, maxLength) {
      if (!text) { return null; }
      const haystack = lower(text);
      const at = query ? haystack.indexOf(lower(query)) : -1;
      if (at === -1) { return text.length > maxLength ? text.slice(0, maxLength) + "…" : text; }
      const start = Math.max(0, at - Math.floor(maxLength / 3));
      const end = Math.min(text.length, at + maxLength);
      return (start > 0 ? "…" : "") + text.slice(start, end) + (end < text.length ? "…" : "");
    }
    function noteDetail(note, index, format, maxChars) {
      const where = locate(note, index);
      let content = format === "html" ? safe(() => str(note.body()), "") : safe(() => str(note.plaintext()), "");
      content = content || "";
      const truncated = content.length > maxChars;
      if (truncated) { content = content.slice(0, maxChars); }
      return {
        id: str(note.id()),
        name: safe(() => str(note.name()), null),
        folder: where.folder,
        account: where.account,
        created: safe(() => iso(note.creationDate()), null),
        modified: safe(() => iso(note.modificationDate()), null),
        format: format,
        content: content,
        content_truncated: truncated,
        password_protected: safe(() => note.passwordProtected(), null),
        shared: safe(() => note.shared(), null)
      };
    }
    """#

    private static let foldersScript = helpers + #"""
    function main(p) {
      const notes = Application("Notes");
      const rows = folderRows(notes, p.account || null).map(r => ({
        account: r.account, name: r.path, id: r.id, note_count: safe(() => r.folder.notes.length, null)
      }));
      const accounts = safeArray(() => notes.accounts.name()).map(str);
      return {accounts: accounts, folders: rows};
    }
    """#

    private static let listScript = helpers + #"""
    function main(p) {
      const notes = Application("Notes");
      const limit = clampLimit(p.limit, 50, 500);
      const folders = p.folder ? [findFolder(notes, p.folder, p.account || null)] : folderRows(notes, p.account || null);
      const rows = [];
      for (const f of folders) {
        const ids = safeArray(() => f.folder.notes.id()).map(str);
        const names = safeArray(() => f.folder.notes.name()).map(str);
        const modified = safeArray(() => f.folder.notes.modificationDate());
        const created = safeArray(() => f.folder.notes.creationDate());
        ids.forEach((id, i) => rows.push({
          id: id, name: names[i] === undefined ? null : names[i], folder: f.path, account: f.account,
          created: iso(created[i]), modified: iso(modified[i]), snippet: null, password_protected: null, shared: null,
          _t: modified[i] instanceof Date ? modified[i].getTime() : 0
        }));
      }
      rows.sort((a, b) => b._t - a._t);
      const selected = rows.slice(0, limit);
      for (const row of selected) {
        delete row._t;
        if (p.include_snippet) {
          const note = notes.notes.byId(row.id);
          row.snippet = excerpt(safe(() => str(note.plaintext()), ""), null, 200);
        }
      }
      return {total: rows.length, notes: selected};
    }
    """#

    private static let searchScript = helpers + #"""
    function main(p) {
      const notes = Application("Notes");
      const limit = clampLimit(p.limit, 25, 200);
      const query = String(p.query);
      let scope = notes.notes;
      if (p.folder) { scope = findFolder(notes, p.folder, p.account || null).folder.notes; }
      else if (p.account) { scope = findAccount(notes, p.account).notes; }
      const hits = scope.whose({_or: [{name: {_contains: query}}, {plaintext: {_contains: query}}]});
      const ids = safeArray(() => hits.id()).map(str);
      const names = safeArray(() => hits.name()).map(str);
      const modified = safeArray(() => hits.modificationDate());
      const created = safeArray(() => hits.creationDate());
      const rows = ids.map((id, i) => ({id: id, name: names[i], created: iso(created[i]), modified: iso(modified[i]), _t: modified[i] instanceof Date ? modified[i].getTime() : 0}));
      rows.sort((a, b) => b._t - a._t);
      const index = folderIndex(notes);
      const selected = rows.slice(0, limit).map(row => {
        const note = notes.notes.byId(row.id);
        const where = locate(note, index);
        return {
          id: row.id, name: row.name, folder: where.folder, account: where.account, created: row.created, modified: row.modified,
          snippet: excerpt(safe(() => str(note.plaintext()), ""), query, 240),
          password_protected: safe(() => note.passwordProtected(), null), shared: safe(() => note.shared(), null)
        };
      });
      return {total: rows.length, notes: selected};
    }
    """#

    private static let getScript = helpers + #"""
    function main(p) {
      const notes = Application("Notes");
      const note = noteById(notes, p.note_id);
      return noteDetail(note, folderIndex(notes), p.format === "html" ? "html" : "text", clampLimit(p.max_chars, 20000, 200000));
    }
    """#

    private static let createScript = helpers + #"""
    function main(p) {
      const notes = Application("Notes");
      let folder;
      if (p.folder) { folder = findFolder(notes, p.folder, p.account || null).folder; }
      else if (p.account) { folder = findAccount(notes, p.account).defaultFolder(); }
      else { folder = notes.defaultAccount().defaultFolder(); }
      const note = notes.Note({body: String(p.html)});
      folder.notes.push(note);
      return noteDetail(note, folderIndex(notes), "text", 20000);
    }
    """#

    private static let updateScript = helpers + #"""
    function main(p) {
      const notes = Application("Notes");
      const note = noteById(notes, p.note_id);
      if (typeof p.html === "string") {
        note.body = p.html;
      } else if (typeof p.append_html === "string") {
        note.body = (safe(() => str(note.body()), "") || "") + p.append_html;
      }
      if (typeof p.title === "string" && typeof p.html !== "string") {
        try { note.name = p.title; } catch (e) { fail("Notes refused to rename the note; pass body (and title) to rewrite it instead."); }
      }
      return noteDetail(note, folderIndex(notes), "text", 20000);
    }
    """#

    private static let deleteScript = helpers + #"""
    function main(p) {
      const notes = Application("Notes");
      const note = noteById(notes, p.note_id);
      const name = safe(() => str(note.name()), null);
      notes.delete(note);
      return {id: String(p.note_id), name: name};
    }
    """#

    // MARK: - Wire models

    private struct FoldersResult: Decodable {
        let accounts: [String]
        let folders: [NoteFolderInfo]
    }

    private struct NotesResult: Decodable {
        let total: Int
        let notes: [NoteInfo]
    }

    private struct DeleteResult: Decodable {
        let id: String
        let name: String?
    }

    // MARK: - Actions

    static func folders(_ input: MacOSRunInput) async throws -> MacOSRunOutput {
        var parameters: [String: JSONValue] = [:]
        if let account = input.account { parameters["account"] = .string(account) }
        let result = try await JXARunner.run(foldersScript, parameters: parameters, as: FoldersResult.self)
        var output = MacOSRunOutput(
            action: .notesFolders,
            summary: "\(result.folders.count) folders across \(result.accounts.count) accounts (\(result.accounts.joined(separator: ", ")))."
        )
        output.note_folders = result.folders
        output.count = result.folders.count
        return output
    }

    static func list(_ input: MacOSRunInput) async throws -> MacOSRunOutput {
        let limit = input.boundedLimit(default: 50, maximum: 500)
        var parameters: [String: JSONValue] = [
            "limit": .number(Double(limit)),
            "include_snippet": .bool(limit <= 50),
        ]
        if let folder = input.folder { parameters["folder"] = .string(folder) }
        if let account = input.account { parameters["account"] = .string(account) }
        let result = try await JXARunner.run(listScript, parameters: parameters, as: NotesResult.self)
        var output = MacOSRunOutput(
            action: .notesList,
            summary: "\(result.total) notes" + (input.folder.map { " in folder '\($0)'" } ?? "")
                + (result.total > result.notes.count ? " (showing the \(result.notes.count) most recently modified)." : ".")
        )
        output.notes = result.notes.map(localized)
        output.count = result.total
        return output
    }

    static func search(_ input: MacOSRunInput) async throws -> MacOSRunOutput {
        let query = try input.require(input.query, "query")
        var parameters: [String: JSONValue] = [
            "query": .string(query),
            "limit": .number(Double(input.boundedLimit(default: 25, maximum: 200))),
        ]
        if let folder = input.folder { parameters["folder"] = .string(folder) }
        if let account = input.account { parameters["account"] = .string(account) }
        let result = try await JXARunner.run(searchScript, parameters: parameters, as: NotesResult.self)
        var output = MacOSRunOutput(
            action: .notesSearch,
            summary: "\(result.total) notes match '\(query)'" + (result.total > result.notes.count ? " (showing \(result.notes.count))." : ".")
        )
        output.notes = result.notes.map(localized)
        output.count = result.total
        return output
    }

    static func get(_ input: MacOSRunInput) async throws -> MacOSRunOutput {
        let id = try input.require(input.note_id, "note_id")
        let format = (input.format ?? "text").lowercased() == "html" ? "html" : "text"
        let parameters: [String: JSONValue] = [
            "note_id": .string(id),
            "format": .string(format),
            "max_chars": .number(Double(input.boundedMaxChars())),
        ]
        let detail = try await JXARunner.run(getScript, parameters: parameters, as: NoteDetail.self)
        var output = MacOSRunOutput(action: .notesGet, summary: "Note '\(detail.name ?? id)' (\(detail.content.count) characters\(detail.content_truncated ? ", truncated" : "")).")
        output.note = localized(detail)
        return output
    }

    static func create(_ input: MacOSRunInput) async throws -> MacOSRunOutput {
        let title = input.title?.trimmingCharacters(in: .whitespacesAndNewlines)
        let body = input.body ?? input.text ?? ""
        guard !(title?.isEmpty ?? true) || !body.isEmpty else {
            throw MacOSControlError.missingArgument("title or body", input.action)
        }
        var parameters: [String: JSONValue] = [
            "html": .string(html(title: title, body: body, format: input.format)),
        ]
        if let folder = input.folder { parameters["folder"] = .string(folder) }
        if let account = input.account { parameters["account"] = .string(account) }
        let detail = try await JXARunner.run(createScript, parameters: parameters, as: NoteDetail.self)
        var output = MacOSRunOutput(
            action: .notesCreate,
            summary: "Created note '\(detail.name ?? title ?? "")'" + (detail.folder.map { " in folder '\($0)'" } ?? "") + "."
        )
        output.note = localized(detail)
        return output
    }

    static func update(_ input: MacOSRunInput) async throws -> MacOSRunOutput {
        let id = try input.require(input.note_id, "note_id")
        var parameters: [String: JSONValue] = ["note_id": .string(id)]
        var changes: [String] = []
        if let body = input.body ?? input.text {
            parameters["html"] = .string(html(title: input.title, body: body, format: input.format))
            changes.append("content")
        } else if let append = input.append {
            parameters["append_html"] = .string(html(title: nil, body: append, format: input.format))
            changes.append("appended text")
        }
        if let title = input.title, parameters["html"] == nil {
            parameters["title"] = .string(title)
            changes.append("title")
        }
        guard !changes.isEmpty else {
            throw MacOSControlError.missingArgument("body, append, or title", input.action)
        }
        let detail = try await JXARunner.run(updateScript, parameters: parameters, as: NoteDetail.self)
        var output = MacOSRunOutput(action: .notesUpdate, summary: "Updated \(changes.joined(separator: " and ")) of note '\(detail.name ?? id)'.")
        output.note = localized(detail)
        return output
    }

    static func delete(_ input: MacOSRunInput) async throws -> MacOSRunOutput {
        let id = try input.require(input.note_id, "note_id")
        let result = try await JXARunner.run(deleteScript, parameters: ["note_id": .string(id)], as: DeleteResult.self)
        return MacOSRunOutput(action: .notesDelete, summary: "Deleted note '\(result.name ?? id)' (moved to Recently Deleted).")
    }

    // MARK: - Helpers

    private static func localized(_ note: NoteInfo) -> NoteInfo {
        NoteInfo(
            id: note.id, name: note.name, folder: note.folder, account: note.account,
            created: MacOSDate.localize(note.created), modified: MacOSDate.localize(note.modified),
            snippet: note.snippet, password_protected: note.password_protected, shared: note.shared
        )
    }

    private static func localized(_ note: NoteDetail) -> NoteDetail {
        NoteDetail(
            id: note.id, name: note.name, folder: note.folder, account: note.account,
            created: MacOSDate.localize(note.created), modified: MacOSDate.localize(note.modified),
            format: note.format, content: note.content, content_truncated: note.content_truncated,
            password_protected: note.password_protected, shared: note.shared
        )
    }

    /// Notes stores HTML; the first line becomes the title. Plain text is
    /// escaped and split into paragraphs, HTML input is passed through.
    static func html(title: String?, body: String, format: String?) -> String {
        var parts: [String] = []
        if let title, !title.isEmpty {
            parts.append("<h1>\(escape(title))</h1>")
        }
        if (format ?? "").lowercased() == "html" {
            parts.append(body)
        } else {
            let lines = body.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n")
            for line in lines {
                parts.append(line.isEmpty ? "<div><br></div>" : "<div>\(escape(line))</div>")
            }
        }
        return parts.joined()
    }

    private static func escape(_ text: String) -> String {
        text
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
    }
}
