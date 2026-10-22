import Foundation
import ToolCore

enum PhotosController {
    // MARK: - Scripts

    private static let helpers = #"""
    function itemInfo(item) {
      const location = safe(() => item.location(), null);
      const hasLocation = Array.isArray(location) && location.length >= 2 && location[0] !== null && location[1] !== null;
      return {
        id: str(item.id()),
        filename: safe(() => str(item.filename()), null),
        title: safe(() => str(item.name()), null),
        description: safe(() => str(item.description()), null),
        date: safe(() => iso(item.date()), null),
        favorite: safe(() => item.favorite(), null),
        width: safe(() => num(item.width()), null),
        height: safe(() => num(item.height()), null),
        keywords: safeArray(() => item.keywords()).map(str),
        latitude: hasLocation ? num(location[0]) : null,
        longitude: hasLocation ? num(location[1]) : null,
        altitude: safe(() => num(item.altitude()), null)
      };
    }
    function walkAlbums(photos) {
      const rows = [];
      const seen = {};
      function push(album, prefix) {
        const id = safe(() => str(album.id()), null);
        if (!id || seen[id]) { return; }
        seen[id] = true;
        rows.push({id: id, name: safe(() => str(album.name()), null), path: prefix, album: album});
      }
      safeArray(() => photos.albums()).forEach(a => push(a, ""));
      function walkFolder(folder, prefix, depth) {
        if (depth > 4) { return; }
        const name = safe(() => str(folder.name()), "");
        const path = prefix ? prefix + "/" + name : name;
        safeArray(() => folder.albums()).forEach(a => push(a, path));
        safeArray(() => folder.folders()).forEach(f => walkFolder(f, path, depth + 1));
      }
      safeArray(() => photos.folders()).forEach(f => walkFolder(f, "", 0));
      return rows;
    }
    function findAlbum(photos, selector) {
      const rows = walkAlbums(photos);
      const needle = lower(selector);
      let match = rows.find(r => r.id === selector);
      if (!match) { match = rows.find(r => lower(r.name) === needle || lower(r.path ? r.path + "/" + r.name : r.name) === needle); }
      if (!match) {
        const partial = rows.filter(r => contains(r.name, needle));
        if (partial.length === 1) { match = partial[0]; }
        else if (partial.length > 1) { fail("Several albums match '" + selector + "': " + partial.map(r => r.name).join(", ") + ". Use the exact name or the id."); }
      }
      if (!match) { fail("No album matches '" + selector + "'. Use action=albums to list albums."); }
      return match.album;
    }
    function itemById(photos, id) {
      const item = photos.mediaItems.byId(String(id));
      try { item.id(); } catch (e) { fail("No media item has id '" + id + "'. Use action=search or action=list to look it up."); }
      return item;
    }
    function sortedSlice(items, limit, maxScan) {
      const rows = [];
      const count = Math.min(items.length, maxScan);
      for (let i = 0; i < count; i++) {
        const item = items[i];
        const d = safe(() => item.date(), null);
        rows.push({item: item, t: d instanceof Date ? d.getTime() : 0});
      }
      rows.sort((a, b) => b.t - a.t);
      return {total: items.length, scanned: count, items: rows.slice(0, limit).map(r => itemInfo(r.item))};
    }
    """#

    private static let albumsScript = helpers + #"""
    function main(p) {
      const photos = Application("Photos");
      const rows = walkAlbums(photos).map(r => ({
        id: r.id,
        name: r.path ? r.path + "/" + r.name : r.name,
        item_count: safe(() => r.album.mediaItems.length, null)
      }));
      return {
        albums: rows,
        favorites_count: safe(() => photos.favoritesAlbum.mediaItems.length, null),
        library_count: safe(() => photos.mediaItems.length, null)
      };
    }
    """#

    private static let searchScript = helpers + #"""
    function main(p) {
      const photos = Application("Photos");
      const found = safeArray(() => photos.search({for: String(p.query)}));
      const limit = clampLimit(p.limit, 25, 200);
      const result = sortedSlice(found, limit, 1000);
      return {total: result.total, scanned: result.scanned, media_items: result.items};
    }
    """#

    private static let listScript = helpers + #"""
    function main(p) {
      const photos = Application("Photos");
      let collection;
      if (p.album) { collection = findAlbum(photos, p.album).mediaItems; }
      else if (p.favorites_only) { collection = photos.favoritesAlbum.mediaItems; }
      else { collection = photos.mediaItems; }
      // Bulk property fetches are cheap; `whose` date filters are re-evaluated
      // by Photos on every fetch and take tens of seconds on large libraries.
      const since = date(p.since);
      const until = date(p.until);
      const ids = safeArray(() => collection.id()).map(str);
      const dates = safeArray(() => collection.date());
      const rows = [];
      for (let i = 0; i < ids.length; i++) {
        const d = dates[i] instanceof Date ? dates[i] : null;
        if (since && (!d || d <= since)) { continue; }
        if (until && (!d || d >= until)) { continue; }
        rows.push({id: ids[i], t: d ? d.getTime() : 0});
      }
      rows.sort((a, b) => b.t - a.t);
      const limit = clampLimit(p.limit, 50, 500);
      const selected = rows.slice(0, limit).map(r => itemInfo(photos.mediaItems.byId(r.id)));
      return {total: rows.length, media_items: selected};
    }
    """#

    private static let exportScript = helpers + #"""
    function main(p) {
      const photos = Application("Photos");
      const items = p.media_ids.map(id => itemById(photos, id));
      photos.export(items, {to: Path(String(p.directory)), usingOriginals: !!p.use_originals});
      return {exported: items.length};
    }
    """#

    private static let importScript = helpers + #"""
    function main(p) {
      const photos = Application("Photos");
      const files = p.paths.map(x => Path(String(x)));
      const options = {skipCheckDuplicates: !!p.skip_duplicates};
      if (p.album) { options.into = findAlbum(photos, p.album); }
      const imported = safeArray(() => photos.import(files, options));
      return {imported: imported.length, media_items: imported.map(itemInfo)};
    }
    """#

    private static let createAlbumScript = helpers + #"""
    function main(p) {
      const photos = Application("Photos");
      const album = photos.make({new: "album", named: String(p.name)});
      return {id: safe(() => str(album.id()), null), name: safe(() => str(album.name()), String(p.name)), item_count: 0};
    }
    """#

    private static let addToAlbumScript = helpers + #"""
    function main(p) {
      const photos = Application("Photos");
      const album = findAlbum(photos, p.album);
      const items = p.media_ids.map(id => itemById(photos, id));
      photos.add(items, {to: album});
      return {id: safe(() => str(album.id()), null), name: safe(() => str(album.name()), null), item_count: safe(() => album.mediaItems.length, null)};
    }
    """#

    private static let updateScript = helpers + #"""
    function main(p) {
      const photos = Application("Photos");
      const item = itemById(photos, p.media_id);
      if (typeof p.favorite === "boolean") { item.favorite = p.favorite; }
      if (typeof p.title === "string") { item.name = p.title; }
      if (typeof p.description === "string") { item.description = p.description; }
      if (Array.isArray(p.keywords)) { item.keywords = p.keywords; }
      return itemInfo(item);
    }
    """#

    // MARK: - Wire models

    private struct AlbumsResult: Decodable {
        let albums: [AlbumInfo]
        let favorites_count: Int?
        let library_count: Int?
    }

    private struct ItemsResult: Decodable {
        let total: Int
        let scanned: Int?
        let media_items: [MediaItemInfo]
    }

    private struct ExportResult: Decodable {
        let exported: Int
    }

    private struct ImportResult: Decodable {
        let imported: Int
        let media_items: [MediaItemInfo]
    }

    // MARK: - Actions

    static func albums(_ input: MacOSRunInput) async throws -> MacOSRunOutput {
        let result = try await JXARunner.run(albumsScript, parameters: [:], as: AlbumsResult.self)
        var output = MacOSRunOutput(
            action: .photosAlbums,
            summary: "\(result.albums.count) albums"
                + (result.library_count.map { ", \($0) items in the library" } ?? "")
                + (result.favorites_count.map { ", \($0) favorites." } ?? ".")
        )
        output.albums = result.albums
        output.count = result.albums.count
        return output
    }

    static func search(_ input: MacOSRunInput) async throws -> MacOSRunOutput {
        let query = try input.require(input.query, "query")
        let parameters: [String: JSONValue] = [
            "query": .string(query),
            "limit": .number(Double(input.boundedLimit(default: 25, maximum: 200))),
        ]
        let result = try await JXARunner.run(searchScript, parameters: parameters, as: ItemsResult.self)
        var output = MacOSRunOutput(
            action: .photosSearch,
            summary: "\(result.total) items match '\(query)'" + (result.total > result.media_items.count ? " (showing the \(result.media_items.count) most recent)." : ".")
        )
        output.media_items = result.media_items.map(localized)
        output.count = result.total
        return output
    }

    static func list(_ input: MacOSRunInput) async throws -> MacOSRunOutput {
        let (since, until) = try MacOSDate.listBounds(since: input.since ?? input.start, until: input.until ?? input.end, action: input.action)
        var parameters: [String: JSONValue] = [
            "limit": .number(Double(input.boundedLimit(default: 50, maximum: 500))),
            "favorites_only": .bool(input.favorites_only ?? false),
        ]
        if let album = input.album { parameters["album"] = .string(album) }
        if let since { parameters["since"] = .string(MacOSDate.javaScript(since)) }
        if let until { parameters["until"] = .string(MacOSDate.javaScript(until)) }
        let result = try await JXARunner.run(listScript, parameters: parameters, as: ItemsResult.self)
        var scope = input.album.map { "album '\($0)'" } ?? (input.favorites_only == true ? "favorites" : "the library")
        if let since { scope += " since \(MacOSDate.formatDay(since) ?? "")" }
        var output = MacOSRunOutput(
            action: .photosList,
            summary: "\(result.total) items in \(scope)" + (result.total > result.media_items.count ? " (showing the \(result.media_items.count) most recent)." : ".")
        )
        output.media_items = result.media_items.map(localized)
        output.count = result.total
        return output
    }

    static func export(_ input: MacOSRunInput, context workingDirectory: URL) async throws -> MacOSRunOutput {
        let ids = input.media_ids?.values ?? (input.media_id.map { [$0] } ?? [])
        guard !ids.isEmpty else {
            throw MacOSControlError.missingArgument("media_ids", input.action)
        }
        guard ids.count <= 100 else {
            throw MacOSControlError.invalidArgument("media_ids", "export at most 100 items per call.")
        }
        let directory = try exportDirectory(input, workingDirectory: workingDirectory)
        let before = Set((try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? [])
        let parameters: [String: JSONValue] = [
            "media_ids": .array(ids.map(JSONValue.string)),
            "directory": .string(directory.path),
            "use_originals": .bool(input.use_originals ?? false),
        ]
        let result = try await JXARunner.run(exportScript, parameters: parameters, as: ExportResult.self)
        let after = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        let files = after
            .filter { !before.contains($0) && !$0.hasPrefix(".") }
            .sorted()
            .map { directory.appendingPathComponent($0).path }
        var output = MacOSRunOutput(
            action: .photosExport,
            summary: "Exported \(result.exported) item(s) to \(directory.path)" + (files.isEmpty ? "." : " (\(files.count) new files).")
        )
        output.exported_files = files
        output.count = files.count
        return output
    }

    static func importItems(_ input: MacOSRunInput, context workingDirectory: URL) async throws -> MacOSRunOutput {
        let rawPaths = input.paths?.values ?? []
        guard !rawPaths.isEmpty else {
            throw MacOSControlError.missingArgument("paths", input.action)
        }
        let paths = try rawPaths.map { raw -> String in
            let url = resolve(raw, workingDirectory: workingDirectory)
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory), !isDirectory.boolValue else {
                throw MacOSControlError.invalidArgument("paths", "'\(raw)' is not an existing file.")
            }
            return url.path
        }
        var parameters: [String: JSONValue] = [
            "paths": .array(paths.map(JSONValue.string)),
            "skip_duplicates": .bool(input.skip_duplicates ?? false),
        ]
        if let album = input.album { parameters["album"] = .string(album) }
        let result = try await JXARunner.run(importScript, parameters: parameters, as: ImportResult.self)
        var output = MacOSRunOutput(
            action: .photosImport,
            summary: "Imported \(result.imported) item(s) into Photos" + (input.album.map { " (album '\($0)')." } ?? ".")
        )
        output.media_items = result.media_items.map(localized)
        output.count = result.imported
        return output
    }

    static func createAlbum(_ input: MacOSRunInput) async throws -> MacOSRunOutput {
        let name = try input.require(input.name ?? input.album, "name")
        let album = try await JXARunner.run(createAlbumScript, parameters: ["name": .string(name)], as: AlbumInfo.self)
        var output = MacOSRunOutput(action: .photosCreateAlbum, summary: "Created album '\(album.name ?? name)'.")
        output.albums = [album]
        return output
    }

    static func addToAlbum(_ input: MacOSRunInput) async throws -> MacOSRunOutput {
        let album = try input.require(input.album, "album")
        let ids = input.media_ids?.values ?? (input.media_id.map { [$0] } ?? [])
        guard !ids.isEmpty else {
            throw MacOSControlError.missingArgument("media_ids", input.action)
        }
        let parameters: [String: JSONValue] = [
            "album": .string(album),
            "media_ids": .array(ids.map(JSONValue.string)),
        ]
        let result = try await JXARunner.run(addToAlbumScript, parameters: parameters, as: AlbumInfo.self)
        var output = MacOSRunOutput(action: .photosAddToAlbum, summary: "Added \(ids.count) item(s) to album '\(result.name ?? album)'.")
        output.albums = [result]
        return output
    }

    static func update(_ input: MacOSRunInput) async throws -> MacOSRunOutput {
        let id = try input.require(input.media_id ?? input.media_ids?.values.first, "media_id")
        var parameters: [String: JSONValue] = ["media_id": .string(id)]
        var changes: [String] = []
        if let favorite = input.favorite { parameters["favorite"] = .bool(favorite); changes.append(favorite ? "favorite" : "not favorite") }
        if let title = input.title ?? input.name { parameters["title"] = .string(title); changes.append("title") }
        if let description = input.description { parameters["description"] = .string(description); changes.append("description") }
        if let keywords = input.keywords { parameters["keywords"] = .array(keywords.values.map(JSONValue.string)); changes.append("keywords") }
        guard !changes.isEmpty else {
            throw MacOSControlError.missingArgument("favorite, title, description, or keywords", input.action)
        }
        let item = try await JXARunner.run(updateScript, parameters: parameters, as: MediaItemInfo.self)
        var output = MacOSRunOutput(action: .photosUpdate, summary: "Updated \(changes.joined(separator: ", ")) of '\(item.filename ?? id)'.")
        output.media_items = [localized(item)]
        return output
    }

    // MARK: - Helpers

    private static func localized(_ item: MediaItemInfo) -> MediaItemInfo {
        MediaItemInfo(
            id: item.id, filename: item.filename, title: item.title, description: item.description,
            date: MacOSDate.localize(item.date), favorite: item.favorite, width: item.width, height: item.height,
            keywords: item.keywords, latitude: item.latitude, longitude: item.longitude, altitude: item.altitude
        )
    }

    private static func resolve(_ raw: String, workingDirectory: URL) -> URL {
        let expanded = NSString(string: raw).expandingTildeInPath
        if expanded.hasPrefix("/") {
            return URL(fileURLWithPath: expanded).standardizedFileURL
        }
        return workingDirectory.appendingPathComponent(expanded).standardizedFileURL
    }

    private static func exportDirectory(_ input: MacOSRunInput, workingDirectory: URL) throws -> URL {
        let directory: URL
        if let raw = input.directory?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty {
            directory = resolve(raw, workingDirectory: workingDirectory)
        } else {
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.dateFormat = "yyyyMMdd-HHmmss"
            directory = FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Downloads/ZenCODE Photos/\(formatter.string(from: Date()))")
        }
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        } catch {
            throw MacOSControlError.invalidArgument("directory", "cannot create '\(directory.path)': \(error.localizedDescription)")
        }
        return directory
    }
}
