import AppKit
import SwiftUI
import Security

enum AppError: LocalizedError {
    case message(String)
    var errorDescription: String? { switch self { case .message(let text): return text } }
}

@MainActor
final class ApplicationServices: ObservableObject {
    let aiModels = AIModelStore.shared
    private(set) var store: SQLiteStore?
    @Published private(set) var model: WorkspaceModel?
    @Published private(set) var startupError: String?
    @Published private(set) var catalog: WorkspaceCatalog?
    private var catalogURL: URL
    private let backgroundServicesEnabled: Bool
    var workspaces: [WorkspaceProfile] { catalog?.workspaces ?? [] }
    var currentWorkspace: WorkspaceProfile? { catalog?.active }
    var lastBackupKey: String { "lastBackupDate." + (currentWorkspace?.id.uuidString ?? "default") }
    @Published var storagePath = ""
    @Published var backupPath = ""
    @Published var status = ""
    @Published var busy = false
    @Published var mcpStatus = "已关闭"
    private var backupLoop: Task<Void, Never>?
    private var server: LocalMCPServer?

    init(catalogURL: URL? = nil, legacyDatabaseURL: URL? = nil, startBackgroundServices: Bool = true) {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Velora", isDirectory: true)
        self.catalogURL = catalogURL ?? support.appendingPathComponent("workspaces.json")
        backgroundServicesEnabled = startBackgroundServices
        do {
            let legacyDirectory = UserDefaults.standard.string(forKey: "storageDirectory")
                .flatMap { $0.isEmpty ? nil : URL(fileURLWithPath: $0, isDirectory: true) } ?? support
            let existing = FileManager.default.fileExists(atPath: self.catalogURL.path)
            let loaded = try WorkspaceCatalog.load(from: self.catalogURL,
                legacyDatabaseURL: legacyDatabaseURL ?? legacyDirectory.appendingPathComponent("velora.sqlite"))
            if existing && !FileManager.default.fileExists(atPath: loaded.active.databasePath) {
                throw AppError.message("当前工作空间数据库不存在，请恢复文件：" + loaded.active.databasePath)
            }
            let database = try SQLiteStore(databaseURL: URL(fileURLWithPath: loaded.active.databasePath))
            try loaded.save(to: self.catalogURL)
            catalog = loaded
            store = database
            model = WorkspaceModel(store: database)
            storagePath = URL(fileURLWithPath: loaded.active.databasePath).deletingLastPathComponent().path
        } catch {
            store = nil; model = nil; startupError = error.localizedDescription
        }
        let defaultBackup = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Velora Backups", isDirectory: true).path
        backupPath = UserDefaults.standard.string(forKey: "backupDirectory") ?? defaultBackup
        guard startBackgroundServices else { return }
        configureMCP()
        backupLoop = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(60))
                guard !Task.isCancelled, let self else { return }
                let defaults = UserDefaults.standard
                let last = defaults.object(forKey: self.lastBackupKey) as? Date ?? .distantPast
                if defaults.bool(forKey: "automaticBackup"), Date().timeIntervalSince(last) > 86400, !self.busy {
                    await self.backup()
                }
            }
        }
    }

    private func prepareTransition() async throws {
        guard !busy, let model, !model.automationBusy else { throw AppError.message("正在处理其他操作，请稍后重试") }
        busy = true
        model.workspaceTransitioning = true
        server?.stop(); server = nil
        await model.flushAll()
        guard !model.saving else { throw AppError.message("尚有内容未保存，工作空间未切换") }
    }

    private func finishTransition() {
        model?.workspaceTransitioning = false
        busy = false
        if backgroundServicesEnabled { configureMCP() }
    }

    private func activate(_ updated: WorkspaceCatalog, database: SQLiteStore) throws {
        try updated.save(to: catalogURL)
        model?.workspaceTransitioning = false
        store = database
        catalog = updated
        model = WorkspaceModel(store: database)
        storagePath = URL(fileURLWithPath: updated.active.databasePath).deletingLastPathComponent().path
    }

    func switchWorkspace(_ id: UUID) async throws {
        guard var updated = catalog, let target = updated.workspaces.first(where: { $0.id == id }) else {
            throw AppError.message("工作空间不存在")
        }
        guard id != updated.activeID else { return }
        guard !busy else { throw AppError.message("正在处理其他操作，请稍后重试") }
        defer { finishTransition() }
        try await prepareTransition()
        guard FileManager.default.fileExists(atPath: target.databasePath) else { throw AppError.message("工作空间数据库不存在：" + target.databasePath) }
        let database = try SQLiteStore(databaseURL: URL(fileURLWithPath: target.databasePath))
        updated.activeID = id
        try activate(updated, database: database)
        status = "已切换到「\(target.name)」"
    }

    func createWorkspace(name: String, summary: String, symbol: String, color: String) async throws {
        guard var updated = catalog else { throw AppError.message("工作空间尚未加载") }
        let id = UUID()
        let path = catalogURL.deletingLastPathComponent().appendingPathComponent("Workspaces", isDirectory: true)
            .appendingPathComponent(id.uuidString, isDirectory: true).appendingPathComponent("velora.sqlite")
        let profile = try updated.validated(WorkspaceProfile(id: id, name: name, summary: summary, symbol: symbol,
            color: color, databasePath: path.path, createdAt: Date()))
        guard !busy else { throw AppError.message("正在处理其他操作，请稍后重试") }
        defer { finishTransition() }
        try await prepareTransition()
        let database = try SQLiteStore(databaseURL: path)
        updated.workspaces.append(profile)
        updated.activeID = id
        try activate(updated, database: database)
        status = "已创建「\(profile.name)」"
    }

    func updateWorkspace(_ profile: WorkspaceProfile) throws {
        guard !busy, var updated = catalog, let index = updated.workspaces.firstIndex(where: { $0.id == profile.id }) else {
            throw AppError.message("工作空间不可用，请稍后重试")
        }
        var validated = try updated.validated(profile)
        validated.databasePath = updated.workspaces[index].databasePath
        validated.createdAt = updated.workspaces[index].createdAt
        updated.workspaces[index] = validated
        try updated.save(to: catalogURL)
        catalog = updated
        status = "工作空间信息已保存"
    }

    func deleteWorkspace(_ id: UUID) async throws {
        guard var updated = catalog else { throw AppError.message("工作空间尚未加载") }
        let wasActive = updated.activeID == id
        try updated.remove(id)
        guard !busy else { throw AppError.message("正在处理其他操作，请稍后重试") }
        defer { finishTransition() }
        try await prepareTransition()
        if wasActive {
            guard FileManager.default.fileExists(atPath: updated.active.databasePath) else { throw AppError.message("替代工作空间数据库不存在，未删除") }
            let database = try SQLiteStore(databaseURL: URL(fileURLWithPath: updated.active.databasePath))
            try activate(updated, database: database)
        } else {
            try updated.save(to: catalogURL)
            catalog = updated
        }
        status = "工作空间已删除，本地数据文件保留"
    }

    func chooseStorage() {
        guard !busy, let directory = chooseDirectory(message: "选择当前工作空间的新存储文件夹。迁移数据库，保留原文件，不覆盖已有数据库。") else { return }
        Task {
            guard !busy else { return }
            defer { finishTransition() }
            do {
                try await prepareTransition()
                guard let store, var updated = catalog,
                      let index = updated.workspaces.firstIndex(where: { $0.id == updated.activeID }) else { return }
                let target = directory.appendingPathComponent("velora.sqlite")
                guard target.standardizedFileURL.path != updated.active.databasePath else { return }
                try await store.snapshot(to: target)
                let database = try SQLiteStore(databaseURL: target)
                updated.workspaces[index].databasePath = target.path
                try activate(updated, database: database)
                status = "当前工作空间存储位置已切换，原位置副本保留。"
            } catch { status = error.localizedDescription }
        }
    }

    func chooseBackup() {
        guard let directory = chooseDirectory(message: "选择备份保存位置") else { return }
        backupPath = directory.path
        UserDefaults.standard.set(directory.path, forKey: "backupDirectory")
    }

    private func chooseDirectory(message: String) -> URL? {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false; panel.canChooseDirectories = true
        panel.canCreateDirectories = true; panel.allowsMultipleSelection = false
        panel.message = message
        return panel.runModal() == .OK ? panel.url : nil
    }

    func backup() async {
        guard !busy, let store, let model else { return }
        busy = true; defer { busy = false }
        do {
            await model.flushAll()
            if model.saving { throw AppError.message("尚有内容未保存，备份已取消") }
            let formatter = DateFormatter(); formatter.dateFormat = "yyyy-MM-dd_HH-mm-ss"
            let destination = URL(fileURLWithPath: backupPath, isDirectory: true)
                .appendingPathComponent("Velora-\(currentWorkspace?.id.uuidString.prefix(8) ?? "default")-\(formatter.string(from: Date()))-\(UUID().uuidString.prefix(6)).sqlite")
            try await store.snapshot(to: destination)
            UserDefaults.standard.set(Date(), forKey: lastBackupKey)
            status = "已备份：\(destination.lastPathComponent)"
        } catch { status = error.localizedDescription }
    }

    func configureMCP() {
        server?.stop(); server = nil
        guard UserDefaults.standard.bool(forKey: "mcpEnabled"), let model else { mcpStatus = "已关闭"; return }
        do {
            var token = try SecretStore.read("mcp-token")
            if token.isEmpty { token = UUID().uuidString + UUID().uuidString; try SecretStore.save(token, account: "mcp-token") }
            let rawPort = UserDefaults.standard.integer(forKey: "mcpPort")
            let port = rawPort == 0 ? 18427 : rawPort
            guard (1024...65535).contains(port) else { throw AppError.message("端口应在 1024–65535 之间") }
            let service = try LocalMCPServer(port: UInt16(port), token: token, model: model)
            service.onStatus = { [weak self] in self?.mcpStatus = $0 }
            server = service
            mcpStatus = "正在启动…"
            service.start()
        } catch { mcpStatus = error.localizedDescription }
    }

    func copyMCPConfig() {
        do {
            let token = try SecretStore.read("mcp-token")
            guard !token.isEmpty else { status = "请先启用 MCP 以生成令牌"; return }
            let port = UserDefaults.standard.integer(forKey: "mcpPort")
            let value: [String: Any] = ["mcpServers": ["velora": ["type": "http", "url": "http://127.0.0.1:\(port == 0 ? 18427 : port)/mcp", "headers": ["Authorization": "Bearer \(token)"]]]]
            let data = try JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted, .sortedKeys])
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(String(decoding: data, as: UTF8.self), forType: .string)
            status = "MCP 配置已复制（包含访问令牌）"
        } catch { status = error.localizedDescription }
    }

    func rotateMCPToken() {
        do { try SecretStore.save(UUID().uuidString + UUID().uuidString, account: "mcp-token"); configureMCP(); status = "令牌已更新，原客户端需重新配置" }
        catch { status = error.localizedDescription }
    }
}

enum SecretStore {
    static func read(_ account: String) throws -> String {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "com.velora.app", kSecAttrAccount as String: account,
            kSecReturnData as String: true, kSecMatchLimit as String: kSecMatchLimitOne]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecItemNotFound { return "" }
        guard status == errSecSuccess, let data = item as? Data else { throw AppError.message("无法读取钥匙串：\(status)") }
        return String(decoding: data, as: UTF8.self)
    }

    static func save(_ value: String, account: String) throws {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "com.velora.app", kSecAttrAccount as String: account]
        let status: OSStatus
        if value.isEmpty {
            status = SecItemDelete(query as CFDictionary)
        } else {
            let update = SecItemUpdate(query as CFDictionary, [kSecValueData as String: Data(value.utf8)] as CFDictionary)
            if update == errSecItemNotFound {
                var item = query
                item[kSecValueData as String] = Data(value.utf8)
                item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
                status = SecItemAdd(item as CFDictionary, nil)
            } else { status = update }
        }
        guard status == errSecSuccess || status == errSecItemNotFound else { throw AppError.message("无法保存钥匙串：\(status)") }
    }
}
