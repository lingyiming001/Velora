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
              let version = Int(try scalar("PRAGMA user_version")), (2...SQLiteStore.currentSchemaVersion).contains(version),
              try scalar("SELECT count(*) FROM sqlite_master WHERE type='table' AND name IN ('pages','blocks')") == "2" else {
            throw AppError.message(L10n.text("备份数据库损坏或版本不兼容"))
        }
        _ = try scalar("SELECT count(id || parent_id || title || sort_order || archived || updated_at) FROM pages")
        _ = try scalar("SELECT count(id || page_id || kind || body || sort_order || checked || language || collapsed) FROM blocks")
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, "PRAGMA foreign_key_check", -1, &statement, nil) == SQLITE_OK else {
            throw AppError.message(L10n.text("备份数据库结构无效"))
        }
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_DONE else { throw AppError.message(L10n.text("备份数据库关联关系无效")) }
    }
}
