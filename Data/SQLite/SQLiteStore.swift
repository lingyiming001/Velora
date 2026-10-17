import Foundation
import SQLite3

actor SQLiteStore {
    private var db: OpaquePointer?
    private(set) var databaseURL: URL

    init(databaseURL: URL? = nil) throws {
        let defaultDirectory = try FileManager.default.url(
            for: .applicationSupportDirectory, in: .userDomainMask,
            appropriateFor: nil, create: true
        ).appendingPathComponent("Velora", isDirectory: true)
        let configured = UserDefaults.standard.string(forKey: "storageDirectory").flatMap { $0.isEmpty ? nil : URL(fileURLWithPath: $0, isDirectory: true) }
        let directory = databaseURL?.deletingLastPathComponent() ?? configured ?? defaultDirectory
        self.databaseURL = databaseURL ?? directory.appendingPathComponent("velora.sqlite")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let path = self.databaseURL.path
        guard sqlite3_open_v2(path, &db, SQLITE_OPEN_CREATE | SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK else {
            throw StoreError.database("无法打开本地数据库")
        }
        try Self.exec(db, "PRAGMA foreign_keys=ON")
        try Self.exec(db, "PRAGMA journal_mode=WAL")
        try Self.exec(db, "PRAGMA busy_timeout=3000")
        try Self.exec(db, """
            CREATE TABLE IF NOT EXISTS pages (
                id TEXT PRIMARY KEY, parent_id TEXT REFERENCES pages(id),
                title TEXT NOT NULL, sort_order INTEGER NOT NULL,
                archived INTEGER NOT NULL DEFAULT 0, updated_at REAL NOT NULL
            )
            """)
        try Self.exec(db, "CREATE INDEX IF NOT EXISTS pages_tree ON pages(parent_id, archived, sort_order)")
        try Self.exec(db, """
            CREATE TABLE IF NOT EXISTS blocks (
                id TEXT PRIMARY KEY, page_id TEXT NOT NULL REFERENCES pages(id) ON DELETE CASCADE,
                kind TEXT NOT NULL, body TEXT NOT NULL, sort_order INTEGER NOT NULL,
                checked INTEGER NOT NULL DEFAULT 0
            )
            """)
        try Self.exec(db, "CREATE INDEX IF NOT EXISTS blocks_page ON blocks(page_id, sort_order)")
        var version: OpaquePointer?
        guard sqlite3_prepare_v2(db, "PRAGMA user_version", -1, &version, nil) == SQLITE_OK else {
            throw StoreError.database("无法读取数据库版本")
        }
        let schemaVersion = sqlite3_step(version) == SQLITE_ROW ? sqlite3_column_int(version, 0) : 0
        sqlite3_finalize(version)
        if schemaVersion < 2 {
            try Self.exec(db, "BEGIN IMMEDIATE")
            do {
                try Self.exec(db, "ALTER TABLE blocks ADD COLUMN language TEXT NOT NULL DEFAULT 'Plain Text'")
                try Self.exec(db, "ALTER TABLE blocks ADD COLUMN collapsed INTEGER NOT NULL DEFAULT 0")
                try Self.exec(db, "PRAGMA user_version=2")
                try Self.exec(db, "COMMIT")
            } catch {
                try? Self.exec(db, "ROLLBACK")
                throw error
            }
        }
        if schemaVersion < 3 {
            try Self.exec(db, "BEGIN IMMEDIATE")
            do {
                try Self.exec(db, "ALTER TABLE pages ADD COLUMN trash_batch TEXT")
                try Self.exec(db, "PRAGMA user_version=3")
                try Self.exec(db, "COMMIT")
            } catch {
                try? Self.exec(db, "ROLLBACK")
                throw error
            }
        }
        if schemaVersion < 4 {
            try Self.exec(db, "BEGIN IMMEDIATE")
            do {
                try Self.exec(db, "ALTER TABLE blocks ADD COLUMN formatting TEXT NOT NULL DEFAULT '[]'")
                try Self.exec(db, "PRAGMA user_version=4")
                try Self.exec(db, "COMMIT")
            } catch { try? Self.exec(db, "ROLLBACK"); throw error }
        }

    }

    deinit { if let db { sqlite3_close(db) } }

    private static func exec(_ db: OpaquePointer?, _ sql: String) throws {
        var error: UnsafeMutablePointer<CChar>?
        guard sqlite3_exec(db, sql, nil, nil, &error) == SQLITE_OK else {
            let message = error.map { String(cString: $0) } ?? "未知错误"
            sqlite3_free(error)
            throw StoreError.database(message)
        }
    }

    private func statement(_ sql: String) throws -> OpaquePointer {
        var result: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &result, nil) == SQLITE_OK, let result else {
            throw StoreError.database(String(cString: sqlite3_errmsg(db)))
        }
        return result
    }

    private func run(_ sql: String, _ values: [String]) throws {
        let stmt = try statement(sql)
        defer { sqlite3_finalize(stmt) }
        for (index, value) in values.enumerated() {
            let status = value.withCString { sqlite3_bind_text(stmt, Int32(index + 1), $0, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self)) }
            guard status == SQLITE_OK else { throw StoreError.database("参数绑定失败") }
        }
        guard sqlite3_step(stmt) == SQLITE_DONE else {
            throw StoreError.database(String(cString: sqlite3_errmsg(db)))
        }
    }

    private func text(_ stmt: OpaquePointer, _ column: Int32) -> String {
        guard let value = sqlite3_column_text(stmt, column) else { return "" }
        return String(cString: value)
    }

    func pages() throws -> [Page] {
        let stmt = try statement("SELECT id,parent_id,title,sort_order,archived,updated_at,trash_batch FROM pages ORDER BY sort_order,id")
        defer { sqlite3_finalize(stmt) }
        var result: [Page] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            guard let id = UUID(uuidString: text(stmt, 0)) else { continue }
            let parent = sqlite3_column_type(stmt, 1) == SQLITE_NULL ? nil : UUID(uuidString: text(stmt, 1))
            result.append(Page(id: id, parentID: parent, title: text(stmt, 2),
                               order: sqlite3_column_int64(stmt, 3),
                               archived: sqlite3_column_int(stmt, 4) != 0,
                               updatedAt: Date(timeIntervalSince1970: sqlite3_column_double(stmt, 5)),
                               trashBatch: sqlite3_column_type(stmt, 6) == SQLITE_NULL ? nil : text(stmt, 6)))
        }
        return result
    }

    func blocks(in pageID: UUID) throws -> [Block] {
        let stmt = try statement("SELECT id,kind,body,sort_order,checked,language,collapsed,formatting FROM blocks WHERE page_id=? ORDER BY sort_order,id")
        defer { sqlite3_finalize(stmt) }
        let key = pageID.uuidString
        _ = key.withCString { sqlite3_bind_text(stmt, 1, $0, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self)) }
        var result: [Block] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            guard let id = UUID(uuidString: text(stmt, 0)) else { continue }
            result.append(Block(id: id, pageID: pageID, kind: BlockKind(rawValue: text(stmt, 1)) ?? .paragraph,
                                text: text(stmt, 2), order: sqlite3_column_int64(stmt, 3),
                                checked: sqlite3_column_int(stmt, 4) != 0,
                                language: text(stmt, 5), collapsed: sqlite3_column_int(stmt, 6) != 0,
                                formatting: (try? JSONDecoder().decode([TextStyleRun].self, from: Data(text(stmt, 7).utf8))) ?? []))
        }
        return result
    }

    func createPage(parentID: UUID? = nil) throws -> Page {
        if let parentID, !(try pages()).contains(where: { $0.id == parentID && !$0.archived }) {
            throw StoreError.missingPage
        }
        let page = Page(id: UUID(), parentID: parentID, title: "未命名", order: Int64(Date().timeIntervalSince1970 * 1000), archived: false, updatedAt: Date())
        if let parentID {
            try run("INSERT INTO pages(id,parent_id,title,sort_order,archived,updated_at) VALUES(?,?,?,?,0,?)",
                    [page.id.uuidString, parentID.uuidString, page.title, String(page.order), String(page.updatedAt.timeIntervalSince1970)])
        } else {
            try run("INSERT INTO pages(id,parent_id,title,sort_order,archived,updated_at) VALUES(?,NULL,?,?,0,?)",
                    [page.id.uuidString, page.title, String(page.order), String(page.updatedAt.timeIntervalSince1970)])
        }
        return page
    }

    func renamePage(_ id: UUID, title: String) throws {
        try run("UPDATE pages SET title=?,updated_at=? WHERE id=?", [title, String(Date().timeIntervalSince1970), id.uuidString])
    }

    func archivePage(_ id: UUID, archived: Bool) throws {
        if !archived { try restorePage(id); return }
        try run("""
            WITH RECURSIVE descendants(id) AS (
                SELECT id FROM pages WHERE id=? AND archived=0
                UNION SELECT p.id FROM pages p JOIN descendants d ON p.parent_id=d.id WHERE p.archived=0
            )
            UPDATE pages SET archived=1,trash_batch=?,updated_at=? WHERE id IN (SELECT id FROM descendants)
            """, [id.uuidString, UUID().uuidString, String(Date().timeIntervalSince1970)])
    }

    private func transaction(_ operation: () throws -> Void) throws {
        try Self.exec(db, "BEGIN IMMEDIATE")
        do { try operation(); try Self.exec(db, "COMMIT") }
        catch { try? Self.exec(db, "ROLLBACK"); throw error }
    }

    func restorePage(_ id: UUID) throws {
        let all = try pages()
        guard let page = all.first(where: { $0.id == id && $0.archived }) else { return }
        try transaction {
            // A separately deleted child keeps its own batch and stays in the trash.
            if let batch = page.trashBatch {
                try run("UPDATE pages SET archived=0,trash_batch=NULL WHERE trash_batch=?", [batch])
            } else {
                try run("UPDATE pages SET archived=0 WHERE id=?", [id.uuidString])
            }
            let restored = try pages()
            for item in restored where !item.archived {
                if let parent = item.parentID, restored.first(where: { $0.id == parent })?.archived != false {
                    try run("UPDATE pages SET parent_id=NULL WHERE id=?", [item.id.uuidString])
                }
            }
        }
    }

    func permanentlyDeletePage(_ id: UUID) throws {
        guard try pages().contains(where: { $0.id == id && $0.archived }) else { return }
        try run("""
            WITH RECURSIVE descendants(id) AS (
                SELECT id FROM pages WHERE id=?
                UNION SELECT p.id FROM pages p JOIN descendants d ON p.parent_id=d.id
            ) DELETE FROM pages WHERE id IN (SELECT id FROM descendants)
            """, [id.uuidString])
    }

    func emptyTrash() throws { try run("DELETE FROM pages WHERE archived=1", []) }

    func movePage(_ id: UUID, toParent parentID: UUID?, before beforeID: UUID? = nil) throws {
        let all = try pages()
        guard let page = all.first(where: { $0.id == id && !$0.archived }) else { return }
        var ancestor = parentID
        var visited: Set<UUID> = [id]
        while let current = ancestor {
            guard !visited.contains(current), let parent = all.first(where: { $0.id == current && !$0.archived }) else {
                throw StoreError.invalidMove
            }
            visited.insert(current)
            ancestor = parent.parentID
        }
        var siblings = all.filter { !$0.archived && $0.parentID == parentID && $0.id != id }
        let index = beforeID.flatMap { before in siblings.firstIndex(where: { $0.id == before }) } ?? siblings.count
        siblings.insert(page, at: index)
        try transaction {
            if let parentID {
                try run("UPDATE pages SET parent_id=? WHERE id=?", [parentID.uuidString, id.uuidString])
            } else { try run("UPDATE pages SET parent_id=NULL WHERE id=?", [id.uuidString]) }
            for (position, item) in siblings.enumerated() {
                try run("UPDATE pages SET sort_order=? WHERE id=?", [String((position + 1) * 1024), item.id.uuidString])
            }
        }
    }

    func createBlock(pageID: UUID, kind: BlockKind, after: Block? = nil) throws -> Block {
        let existing = try blocks(in: pageID)
        let nextOrder = (existing.map(\.order).max() ?? 0) + 1024
        let block = Block(id: UUID(), pageID: pageID, kind: kind, text: "", order: nextOrder, checked: false)
        try run("INSERT INTO blocks(id,page_id,kind,body,sort_order,checked) VALUES(?,?,?,?,?,0)",
                [block.id.uuidString, pageID.uuidString, kind.rawValue, "", String(block.order)])
        return block
    }

    func updateBlock(_ id: UUID, text: String, formatting: [TextStyleRun] = []) throws {
        let valid = formatting.filter { $0.validRange(in: text) != nil }
        let encoded = String(decoding: try JSONEncoder().encode(valid), as: UTF8.self)
        try run("UPDATE blocks SET body=?,formatting=? WHERE id=?", [text, encoded, id.uuidString])
    }

    func deleteBlocks(_ ids: [UUID]) throws {
        try transaction { for id in ids { try run("DELETE FROM blocks WHERE id=?", [id.uuidString]) } }
    }

    func setBlockKind(_ id: UUID, kind: BlockKind) throws {
        try run("UPDATE blocks SET kind=? WHERE id=?", [kind.rawValue, id.uuidString])
    }

    func setBlockOptions(_ id: UUID, language: String, collapsed: Bool) throws {
        try run("UPDATE blocks SET language=?,collapsed=? WHERE id=?",
                [language, collapsed ? "1" : "0", id.uuidString])
    }

    func setChecked(_ id: UUID, checked: Bool) throws {
        try run("UPDATE blocks SET checked=? WHERE id=?", [checked ? "1" : "0", id.uuidString])
    }

    func deleteBlock(_ id: UUID) throws {
        try run("DELETE FROM blocks WHERE id=?", [id.uuidString])
    }

    /// SQLite online backup includes committed WAL data without copying a live database file.
    func snapshot(to destination: URL) throws {
        guard !FileManager.default.fileExists(atPath: destination.path) else {
            throw StoreError.database("目标文件已存在，未覆盖")
        }
        try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        var output: OpaquePointer?
        guard sqlite3_open_v2(destination.path, &output, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE, nil) == SQLITE_OK else {
            if output != nil { sqlite3_close(output) }
            throw StoreError.database("无法创建备份文件")
        }
        defer { sqlite3_close(output) }
        do {
            guard let backup = sqlite3_backup_init(output, "main", db, "main") else {
                throw StoreError.database("无法初始化数据库快照")
            }
            let result = sqlite3_backup_step(backup, -1)
            let finish = sqlite3_backup_finish(backup)
            guard result == SQLITE_DONE, finish == SQLITE_OK else {
                throw StoreError.database("备份未完成，请稍后重试")
            }
        } catch {
            try? FileManager.default.removeItem(at: destination)
            throw error
        }
    }

    func relocate(to directory: URL) throws -> URL {
        let target = directory.appendingPathComponent("velora.sqlite").standardizedFileURL
        if target == databaseURL.standardizedFileURL { return target }
        try snapshot(to: target)
        var replacement: OpaquePointer?
        guard sqlite3_open_v2(target.path, &replacement, SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK else {
            if replacement != nil { sqlite3_close(replacement) }
            throw StoreError.database("无法打开新存储位置，仍使用原位置")
        }
        do {
            try Self.exec(replacement, "PRAGMA foreign_keys=ON")
            try Self.exec(replacement, "PRAGMA journal_mode=WAL")
            try Self.exec(replacement, "PRAGMA busy_timeout=3000")
        } catch { sqlite3_close(replacement); throw error }
        sqlite3_close(db)
        db = replacement
        databaseURL = target
        return target
    }

    func transferSnapshot(name: String, pageID: UUID? = nil, includeChildren: Bool = true, includeArchived: Bool = false) throws -> TransferDocument {
        let all = try pages()
        var included: Set<UUID>
        if let pageID {
            guard all.contains(where: { $0.id == pageID }) else { throw StoreError.missingPage }
            included = [pageID]
            if includeChildren {
                var previous = -1
                while previous != included.count {
                    previous = included.count
                    for page in all where page.parentID.map(included.contains) == true { included.insert(page.id) }
                }
            }
        } else { included = Set(all.map(\.id)) }
        let selected = all.filter { included.contains($0.id) && (includeArchived || !$0.archived) }
        let selectedIDs = Set(selected.map(\.id))
        let exported = try selected.map { page in
            TransferPage(id: page.id, parentID: page.parentID.flatMap { selectedIDs.contains($0) ? $0 : nil }, title: page.title,
                         archived: page.archived, blocks: try blocks(in: page.id).map(TransferBlock.init))
        }
        let document = TransferDocument(name: name, pages: exported)
        _ = try document.orderedPages()
        return document
    }

    func importTransfer(_ document: TransferDocument) throws -> [UUID] {
        let ordered = try document.orderedPages()
        for page in ordered {
            guard page.title.count <= 10000 else { throw AppError.message("页面标题过长，未导入") }
            for block in page.blocks where block.kind == .image && !block.text.isEmpty { _ = try ImageSource.validated(block.text) }
        }
        let ids = Dictionary(uniqueKeysWithValues: ordered.map { ($0.id, UUID()) })
        var batches: [UUID: String] = [:]
        try transaction {
            for (index, page) in ordered.enumerated() {
                let id = ids[page.id]!.uuidString
                let parent = page.parentID.flatMap { ids[$0]?.uuidString } ?? ""
                let batch = page.archived ? (page.parentID.flatMap { batches[$0] } ?? UUID().uuidString) : ""
                if page.archived { batches[page.id] = batch }
                try run("INSERT INTO pages(id,parent_id,title,sort_order,archived,updated_at,trash_batch) VALUES(?,NULLIF(?,''),?,?,?,?,NULLIF(?,''))",
                        [id, parent, page.title, String(Int64(Date().timeIntervalSince1970 * 1000) + Int64(index)), page.archived ? "1" : "0", String(Date().timeIntervalSince1970), batch])
                for (position, block) in page.blocks.enumerated() {
                    try run("INSERT INTO blocks(id,page_id,kind,body,sort_order,checked,language,collapsed,formatting) VALUES(?,?,?,?,?,?,?,?,?)",
                            [UUID().uuidString, id, block.kind.rawValue, block.text, String(position), block.checked ? "1" : "0", block.language, block.collapsed ? "1" : "0", String(decoding: try JSONEncoder().encode(block.formatting), as: UTF8.self)])
                }
            }
        }
        return ordered.compactMap { ids[$0.id] }
    }

    func search(_ query: String) throws -> [Page] {
        let all = try pages().filter { !$0.archived }
        let term = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !term.isEmpty else { return all }
        let stmt = try statement("SELECT DISTINCT page_id FROM blocks WHERE body LIKE ? ESCAPE '\\'")
        defer { sqlite3_finalize(stmt) }
        let escaped = term.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "%", with: "\\%")
            .replacingOccurrences(of: "_", with: "\\_")
        _ = ("%" + escaped + "%").withCString {
            sqlite3_bind_text(stmt, 1, $0, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
        }
        var ids: Set<UUID> = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            if let id = UUID(uuidString: text(stmt, 0)) { ids.insert(id) }
        }
        return all.filter { $0.title.localizedCaseInsensitiveContains(term) || ids.contains($0.id) }
    }
}
