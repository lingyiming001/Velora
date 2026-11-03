import Foundation
import CryptoKit
import SQLite3

/// A portable ZIP; attachments embedded in blocks travel with the consistent SQLite snapshot.
enum WorkspaceBackup {
    static let maximumSize = 512 * 1024 * 1024
    struct Manifest: Codable {
        var format = "com.velora.workspace-backup"
        var version = 1
        var createdAt: Date
        var name: String
        var summary: String
        var symbol: String
        var color: String
        var databaseSHA256: String
    }
    struct Contents {
        let manifest: Manifest
        let database: Data
    }
    private static func digest(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
    static func write(snapshot: URL, profile: WorkspaceProfile, to destination: URL) throws {
        let data = try Data(contentsOf: snapshot)
        guard data.count <= maximumSize - 65536 else { throw AppError.message(L10n.text("备份超过 512 MB 限制")) }
        try validateDatabase(at: snapshot)
        let manifest = Manifest(createdAt: Date(), name: profile.name, summary: profile.summary,
                                symbol: profile.symbol, color: profile.color, databaseSHA256: digest(data))
        let archive = try ZIPPackage.encode([("manifest.json", try JSONEncoder().encode(manifest)),
                                             ("workspace.sqlite", data)], compressed: true)
        guard archive.count <= maximumSize else { throw AppError.message(L10n.text("备份超过 512 MB 限制")) }
        try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        // A new backup must never replace a previous archive.
        try archive.write(to: destination, options: .withoutOverwriting)
    }
    static func read(_ url: URL) throws -> Contents {
        let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        guard size > 0, size <= maximumSize else { throw AppError.message(L10n.text("备份文件为空或超过 512 MB 限制")) }
        let files: [String: Data]
        do { files = try ZIPPackage.decode(Data(contentsOf: url), maximumSize: maximumSize) }
        catch { throw AppError.message(L10n.text("备份压缩包损坏或格式不受支持")) }
        guard Set(files.keys) == Set(["manifest.json", "workspace.sqlite"]),
              let metadata = files["manifest.json"], metadata.count <= 65536,
              let database = files["workspace.sqlite"],
              let manifest = try? JSONDecoder().decode(Manifest.self, from: metadata),
              manifest.format == "com.velora.workspace-backup", manifest.version == 1,
              !manifest.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              manifest.name.count <= 60, manifest.summary.count <= 500,
              WorkspaceProfile.symbols.contains(manifest.symbol), WorkspaceProfile.colors.contains(manifest.color),
              digest(database) == manifest.databaseSHA256 else {
            throw AppError.message(L10n.text("备份信息无效、版本不兼容或校验失败"))
        }
        return Contents(manifest: manifest, database: database)
    }
    struct ArchiveManifest: Codable {
        var format = "com.velora.all-workspaces-backup"
        var version = 2
        var createdAt = Date()
        var activeID: UUID
        var workspaces: [Entry]
    }
    struct Entry: Codable {
        var profile: WorkspaceProfile
        var databaseSHA256: String
        var removed: Bool
        var path: String { "Workspaces/\(profile.id.uuidString)/velora.sqlite" }
    }
    struct RestoredWorkspace {
        var profile: WorkspaceProfile
        var database: Data
        var removed: Bool
    }
    struct ArchiveContents {
        var activeID: UUID
        var workspaces: [RestoredWorkspace]
    }

    static func writeAll(snapshots: [(WorkspaceProfile, URL, Bool)], activeID: UUID, to destination: URL) throws {
        var entries: [(String, Data)] = []
        var metadata: [Entry] = []
        var total = 0
        for (profile, snapshot, removed) in snapshots {
            let size = try snapshot.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
            guard size <= maximumSize - total - 65536 else { throw AppError.message("备份超过 512 MB 限制") }
            try validateDatabase(at: snapshot)
            let data = try Data(contentsOf: snapshot)
            total += data.count
            var portable = profile
            portable.databasePath = "Workspaces/\(profile.id.uuidString)/velora.sqlite"
            let entry = Entry(profile: portable, databaseSHA256: digest(data), removed: removed)
            metadata.append(entry)
            entries.append((entry.path, data))
        }
        let manifest = ArchiveManifest(activeID: activeID, workspaces: metadata)
        let data = try JSONEncoder().encode(manifest)
        guard total + data.count <= maximumSize else { throw AppError.message("备份超过 512 MB 限制") }
        entries.append(("manifest.json", data))
        let archive = try ZIPPackage.encode(entries, compressed: true)
        guard archive.count <= maximumSize else { throw AppError.message("备份超过 512 MB 限制") }
        try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        try archive.write(to: destination, options: .withoutOverwriting)
    }

    static func readAll(_ url: URL) throws -> ArchiveContents {
        let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        guard size > 0, size <= maximumSize else { throw AppError.message("备份文件为空或超过 512 MB 限制") }
        let files = try ZIPPackage.decode(Data(contentsOf: url), maximumSize: maximumSize)
        guard let data = files["manifest.json"], data.count <= 4 * 1024 * 1024 else {
            throw AppError.message("备份信息无效、版本不兼容或校验失败")
        }
        if let manifest = try? JSONDecoder().decode(ArchiveManifest.self, from: data) {
            guard manifest.format == "com.velora.all-workspaces-backup", manifest.version == 2,
                  !manifest.workspaces.isEmpty,
                  Set(manifest.workspaces.map { $0.profile.id }).count == manifest.workspaces.count,
                  manifest.workspaces.contains(where: { $0.profile.id == manifest.activeID && !$0.removed }),
                  Set(files.keys) == Set(["manifest.json"] + manifest.workspaces.map(\.path)) else {
                throw AppError.message("备份信息无效、版本不兼容或校验失败")
            }
            let workspaces = try manifest.workspaces.map { entry -> RestoredWorkspace in
                let profile = entry.profile
                guard let database = files[entry.path], digest(database) == entry.databaseSHA256,
                      !profile.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                      profile.name.count <= 60, profile.summary.count <= 500,
                      WorkspaceProfile.symbols.contains(profile.symbol), WorkspaceProfile.colors.contains(profile.color) else {
                    throw AppError.message("备份信息无效、版本不兼容或校验失败")
                }
                return RestoredWorkspace(profile: profile, database: database, removed: entry.removed)
            }
            return ArchiveContents(activeID: manifest.activeID, workspaces: workspaces)
        }
        let legacy = try read(url)
        let profile = WorkspaceProfile(id: UUID(), name: legacy.manifest.name, summary: legacy.manifest.summary,
            symbol: legacy.manifest.symbol, color: legacy.manifest.color, databasePath: "", createdAt: Date())
        return ArchiveContents(activeID: profile.id, workspaces: [.init(profile: profile, database: legacy.database, removed: false)])
    }

    /// Take a consistent snapshot without migrating or writing to the source, including its WAL.
    static func copyDatabase(from source: URL, to destination: URL) throws {
        try validateDatabase(at: source)
        guard !FileManager.default.fileExists(atPath: destination.path) else { throw AppError.message("目标文件已存在，未覆盖") }
        try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        var input: OpaquePointer?, output: OpaquePointer?
        defer { if let input { sqlite3_close(input) }; if let output { sqlite3_close(output) } }
        guard sqlite3_open_v2(source.path, &input, SQLITE_OPEN_READONLY | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK,
              sqlite3_open_v2(destination.path, &output, SQLITE_OPEN_CREATE | SQLITE_OPEN_READWRITE, nil) == SQLITE_OK else {
            throw AppError.message("备份数据库无法打开")
        }
        var success = false
        defer { if !success { try? FileManager.default.removeItem(at: destination) } }
        sqlite3_busy_timeout(input, 3000); sqlite3_busy_timeout(output, 3000)
        guard let backup = sqlite3_backup_init(output, "main", input, "main") else { throw AppError.message("无法初始化数据库快照") }
        let result = sqlite3_backup_step(backup, -1)
        let finish = sqlite3_backup_finish(backup)
        guard result == SQLITE_DONE, finish == SQLITE_OK,
              sqlite3_exec(output, "PRAGMA journal_mode=DELETE", nil, nil, nil) == SQLITE_OK else {
            throw AppError.message("备份未完成，请稍后重试")
        }
        success = true
    }

    /// Inspect without creating or migrating tables in an untrusted archive.
    static func validateDatabase(at url: URL) throws {
        var db: OpaquePointer?
        guard sqlite3_open_v2(url.path, &db, SQLITE_OPEN_READONLY | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK else {
            if let db { sqlite3_close(db) }
            throw AppError.message(L10n.text("备份数据库无法打开"))
        }
        defer { sqlite3_close(db) }
        func scalar(_ sql: String) throws -> String {
            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
                throw AppError.message(L10n.text("备份数据库结构无效"))
            }
            defer { sqlite3_finalize(statement) }
            guard sqlite3_step(statement) == SQLITE_ROW, let value = sqlite3_column_text(statement, 0) else {
                throw AppError.message(L10n.text("备份数据库结构无效"))
            }
            return String(cString: value)
        }
        guard try scalar("PRAGMA quick_check") == "ok",
              let version = Int(try scalar("PRAGMA user_version")), (0...SQLiteStore.currentSchemaVersion).contains(version),
              try scalar("SELECT count(*) FROM sqlite_master WHERE type='table' AND name IN ('pages','blocks')") == "2" else {
            throw AppError.message(L10n.text("备份数据库损坏或版本不兼容"))
        }
        _ = try scalar("SELECT count(id || parent_id || title || sort_order || archived || updated_at) FROM pages")
        _ = try scalar("SELECT count(id || page_id || kind || body || sort_order || checked) FROM blocks")
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, "PRAGMA foreign_key_check", -1, &statement, nil) == SQLITE_OK else {
            throw AppError.message(L10n.text("备份数据库结构无效"))
        }
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_DONE else { throw AppError.message(L10n.text("备份数据库关联关系无效")) }
    }
}
