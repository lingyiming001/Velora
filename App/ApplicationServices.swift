import AppKit
import SwiftUI
import Security
import UniformTypeIdentifiers

enum AppError: LocalizedError {
    case message(String)
    var errorDescription: String? { switch self { case .message(let text): return L10n.text(text) } }
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
    @Published var mcpStatus = L10n.tr("已关闭")
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
            // Keep valid workspace metadata available to the recovery screen.
            catalog = loaded
            storagePath = loaded.storageRoot ?? self.catalogURL.deletingLastPathComponent().path
            if existing && !FileManager.default.fileExists(atPath: loaded.active.databasePath) {
                throw AppError.message(L10n.tr("当前工作空间数据库不存在，请恢复文件：") + loaded.active.databasePath)
            }
            let database = try SQLiteStore(databaseURL: URL(fileURLWithPath: loaded.active.databasePath))
            try loaded.save(to: self.catalogURL)
            catalog = loaded
            store = database
            model = WorkspaceModel(store: database)
            storagePath = loaded.storageRoot ?? self.catalogURL.deletingLastPathComponent().path
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

    var canCreateStartupWorkspace: Bool { model == nil && catalog != nil && !busy }
    var availableStartupWorkspaces: [WorkspaceProfile] {
        guard model == nil else { return [] }
        return workspaces.filter { FileManager.default.fileExists(atPath: $0.databasePath) }
    }

    func retryStartup(opening workspaceID: UUID? = nil) async throws {
        guard model == nil, !busy else { return }
        busy = true
        defer { finishTransition() }
        // Reload the catalog so restoring the files externally can be retried
        // without restarting, and never implicitly create a missing database.
        var updated = try WorkspaceCatalog.load(from: catalogURL,
            legacyDatabaseURL: workspaceStorageRoot.appendingPathComponent("velora.sqlite"))
        if let workspaceID {
            guard updated.workspaces.contains(where: { $0.id == workspaceID }) else { throw AppError.message(L10n.tr("工作空间不存在")) }
            updated.activeID = workspaceID
        }
        guard FileManager.default.fileExists(atPath: updated.active.databasePath) else {
            throw AppError.message(L10n.tr("当前工作空间数据库不存在，请恢复文件：") + updated.active.databasePath)
        }
        let database = try SQLiteStore(databaseURL: URL(fileURLWithPath: updated.active.databasePath))
        try activate(updated, database: database)
    }

    func createStartupWorkspace() async throws {
        guard canCreateStartupWorkspace, var updated = catalog else { return }
        busy = true
        defer { finishTransition() }
        let id = UUID()
        let directory = workspaceStorageRoot.appendingPathComponent("Workspaces").appendingPathComponent(id.uuidString)
        let path = directory.appendingPathComponent("velora.sqlite")
        guard !FileManager.default.fileExists(atPath: directory.path) else { throw StoreError.database(L10n.tr("目标文件已存在，未覆盖")) }
        var committed = false
        defer { if !committed { try? FileManager.default.removeItem(at: directory) } }
        // Missing workspaces remain recoverable as metadata; they must not block
        // creating documents or later migration of the usable workspaces.
        let missing = updated.workspaces.filter { !FileManager.default.fileExists(atPath: $0.databasePath) }
        updated.workspaces.removeAll { item in missing.contains { $0.id == item.id } }
        for item in missing where !updated.removedWorkspaces.contains(where: { $0.id == item.id }) {
            updated.removedWorkspaces.append(item)
        }
        let base = L10n.tr("新工作空间")
        var name = base, suffix = 2
        while updated.workspaces.contains(where: { $0.name.caseInsensitiveCompare(name) == .orderedSame }) {
            name = base + " \(suffix)"; suffix += 1
        }
        let profile = try updated.validated(WorkspaceProfile(id: id, name: name, summary: "", symbol: WorkspaceProfile.symbols[0],
            color: "indigo", databasePath: path.path, createdAt: Date()))
        let database = try SQLiteStore(databaseURL: path)
        let page = try await database.createPage()
        _ = try await database.createBlock(pageID: page.id, kind: .paragraph)
        updated.workspaces.append(profile); updated.activeID = id
        try activate(updated, database: database)
        committed = true
        await model?.refreshPages()
        model?.select(page.id)
    }

    private func prepareTransition() async throws {
        guard !busy, let model, !model.automationBusy else { throw AppError.message(L10n.tr("正在处理其他操作，请稍后重试")) }
        busy = true
        model.workspaceTransitioning = true
        server?.stop(); server = nil
        await model.flushAll()
        guard !model.saving else { throw AppError.message(L10n.tr("尚有内容未保存，工作空间未切换")) }
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
        startupError = nil
        model = WorkspaceModel(store: database)
        storagePath = updated.storageRoot ?? catalogURL.deletingLastPathComponent().path
    }

    func switchWorkspace(_ id: UUID) async throws {
        guard var updated = catalog, let target = updated.workspaces.first(where: { $0.id == id }) else {
            throw AppError.message(L10n.tr("工作空间不存在"))
        }
        guard id != updated.activeID else { return }
        guard !busy else { throw AppError.message(L10n.tr("正在处理其他操作，请稍后重试")) }
        defer { finishTransition() }
        try await prepareTransition()
        guard FileManager.default.fileExists(atPath: target.databasePath) else { throw AppError.message(L10n.tr("工作空间数据库不存在：") + target.databasePath) }
        let database = try SQLiteStore(databaseURL: URL(fileURLWithPath: target.databasePath))
        updated.activeID = id
        try activate(updated, database: database)
        status = L10n.tr("已切换到「\(target.name)」")
    }

    private var workspaceStorageRoot: URL {
        catalog?.storageRoot.map { URL(fileURLWithPath: $0, isDirectory: true) } ?? catalogURL.deletingLastPathComponent()
    }

    func createWorkspace(name: String, summary: String, symbol: String, color: String) async throws {
        guard var updated = catalog else { throw AppError.message(L10n.tr("工作空间尚未加载")) }
        let id = UUID()
        let path = workspaceStorageRoot.appendingPathComponent("Workspaces", isDirectory: true)
            .appendingPathComponent(id.uuidString, isDirectory: true).appendingPathComponent("velora.sqlite")
        let profile = try updated.validated(WorkspaceProfile(id: id, name: name, summary: summary, symbol: symbol,
            color: color, databasePath: path.path, createdAt: Date()))
        guard !busy else { throw AppError.message(L10n.tr("正在处理其他操作，请稍后重试")) }
        defer { finishTransition() }
        try await prepareTransition()
        let database = try SQLiteStore(databaseURL: path)
        updated.workspaces.append(profile)
        updated.activeID = id
        try activate(updated, database: database)
        status = L10n.tr("已创建「\(profile.name)」")
    }

    func updateWorkspace(_ profile: WorkspaceProfile) throws {
        guard !busy, var updated = catalog, let index = updated.workspaces.firstIndex(where: { $0.id == profile.id }) else {
            throw AppError.message(L10n.tr("工作空间不可用，请稍后重试"))
        }
        var validated = try updated.validated(profile)
        validated.databasePath = updated.workspaces[index].databasePath
        validated.createdAt = updated.workspaces[index].createdAt
        updated.workspaces[index] = validated
        try updated.save(to: catalogURL)
        catalog = updated
        status = L10n.tr("工作空间信息已保存")
    }

    func deleteWorkspace(_ id: UUID) async throws {
        guard var updated = catalog else { throw AppError.message(L10n.tr("工作空间尚未加载")) }
        let wasActive = updated.activeID == id
        try updated.remove(id)
        guard !busy else { throw AppError.message(L10n.tr("正在处理其他操作，请稍后重试")) }
        defer { finishTransition() }
        try await prepareTransition()
        if wasActive {
            guard FileManager.default.fileExists(atPath: updated.active.databasePath) else { throw AppError.message(L10n.tr("替代工作空间数据库不存在，未删除")) }
            let database = try SQLiteStore(databaseURL: URL(fileURLWithPath: updated.active.databasePath))
            try activate(updated, database: database)
        } else {
            try updated.save(to: catalogURL)
            catalog = updated
        }
        status = L10n.tr("工作空间已删除，本地数据文件保留")
    }

    func chooseStorage() {
        guard !busy, let directory = chooseDirectory(message: L10n.tr("选择所有工作空间的统一存储文件夹。原位置副本保留，不覆盖已有数据库。")) else { return }
        Task {
            do { try await relocateStorage(to: directory) }
            catch { status = error.localizedDescription }
        }
    }

    func relocateStorage(to directory: URL) async throws {
        guard !busy, var updated = catalog else { throw AppError.message(L10n.tr("正在处理其他操作，请稍后重试")) }
        let root = directory.standardizedFileURL.resolvingSymlinksInPath()
        let profiles = updated.workspaces + updated.removedWorkspaces.filter { FileManager.default.fileExists(atPath: $0.databasePath) }
        var targets: [UUID: URL] = [:]
        for profile in profiles {
            let source = URL(fileURLWithPath: profile.databasePath).standardizedFileURL.resolvingSymlinksInPath()
            guard FileManager.default.fileExists(atPath: source.path) else { throw AppError.message(L10n.tr("工作空间数据库不存在：") + source.path) }
            let target = root.appendingPathComponent("Workspaces").appendingPathComponent(profile.id.uuidString).appendingPathComponent("velora.sqlite")
            if target != source && ["", "-wal", "-shm"].contains(where: { FileManager.default.fileExists(atPath: target.path + $0) }) {
                throw StoreError.database(L10n.tr("目标文件已存在，未覆盖"))
            }
            targets[profile.id] = target
        }
        defer { finishTransition() }
        try await prepareTransition()
        var created: [URL] = []
        var committed = false
        defer {
            if !committed {
                for file in created {
                    for suffix in ["", "-wal", "-shm"] { try? FileManager.default.removeItem(atPath: file.path + suffix) }
                }
            }
        }
        for profile in profiles {
            guard let target = targets[profile.id] else { continue }
            let source = URL(fileURLWithPath: profile.databasePath).standardizedFileURL.resolvingSymlinksInPath()
            if source != target {
                let database: SQLiteStore
                if profile.id == updated.activeID, let store { database = store }
                else { database = try SQLiteStore(databaseURL: source) }
                try await database.snapshot(to: target)
                created.append(target)
            }
        }
        for index in updated.workspaces.indices {
            updated.workspaces[index].databasePath = targets[updated.workspaces[index].id]!.path
        }
        for index in updated.removedWorkspaces.indices {
            if let target = targets[updated.removedWorkspaces[index].id] { updated.removedWorkspaces[index].databasePath = target.path }
        }
        updated.storageRoot = root.path
        let database = try SQLiteStore(databaseURL: URL(fileURLWithPath: updated.active.databasePath))
        try activate(updated, database: database)
        committed = true
        status = L10n.tr("所有工作空间存储位置已切换，原位置副本保留。")
    }

    func chooseBackup() {
        guard let directory = chooseDirectory(message: L10n.tr("选择备份保存位置")) else { return }
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
        do {
            let destination = try await createBackup()
            status = L10n.format("已备份：%@", destination.lastPathComponent)
        } catch { status = error.localizedDescription }
    }

    @discardableResult
    func createBackup(in directory: URL? = nil) async throws -> URL {
        guard let profile = currentWorkspace, let store else { throw AppError.message(L10n.text("工作空间尚未加载")) }
        guard !busy else { throw AppError.message(L10n.text("正在处理其他操作，请稍后重试")) }
        defer { finishTransition() }
        try await prepareTransition()
        let temporary = FileManager.default.temporaryDirectory.appendingPathComponent("Velora-backup-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: temporary) }
        let snapshot = temporary.appendingPathComponent("workspace.sqlite")
        status = L10n.text("正在创建 ZIP 备份…")
        try await store.snapshot(to: snapshot)
        let formatter = DateFormatter(); formatter.locale = Locale(identifier: "en_US_POSIX"); formatter.dateFormat = "yyyy-MM-dd_HH-mm-ss"
        let destination = (directory ?? URL(fileURLWithPath: backupPath, isDirectory: true))
            .appendingPathComponent("Velora-\(profile.id.uuidString.prefix(8))-\(formatter.string(from: Date()))-\(UUID().uuidString.prefix(6)).zip")
        try await Task.detached(priority: .userInitiated) {
            try WorkspaceBackup.write(snapshot: snapshot, profile: profile, to: destination)
        }.value
        UserDefaults.standard.set(Date(), forKey: lastBackupKey)
        return destination
    }

    func chooseRestore() {
        guard !busy else { return }
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.zip]; panel.allowsMultipleSelection = false; panel.canChooseDirectories = false
        panel.message = L10n.text("选择 Velora ZIP 备份，恢复为新工作空间，保留现有数据。")
        panel.prompt = L10n.text("恢复备份")
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task {
            let access = url.startAccessingSecurityScopedResource()
            defer { if access { url.stopAccessingSecurityScopedResource() } }
            do {
                try await restoreBackup(from: url)
                status = L10n.format("已恢复到新工作空间：%@", currentWorkspace?.name ?? "")
            } catch { status = error.localizedDescription }
        }
    }

    /// Restore into an isolated new workspace; publish only after archive and database validation.
    func restoreBackup(from archive: URL) async throws {
        guard !busy, var updated = catalog else { throw AppError.message(L10n.text("正在处理其他操作，请稍后重试")) }
        defer { finishTransition() }
        try await prepareTransition()
        let directory = workspaceStorageRoot.appendingPathComponent("Workspaces")
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let target = directory.appendingPathComponent("velora.sqlite")
        var committed = false
        defer { if !committed { try? FileManager.default.removeItem(at: directory) } }
        status = L10n.text("正在恢复备份…")
        let manifest = try await Task.detached(priority: .userInitiated) {
            let contents = try WorkspaceBackup.read(archive)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try contents.database.write(to: target, options: .withoutOverwriting)
            try WorkspaceBackup.validateDatabase(at: target)
            return contents.manifest
        }.value
        let baseName = String(manifest.name.prefix(44)) + L10n.text("（已恢复）")
        var name = baseName; var index = 2
        while updated.workspaces.contains(where: { $0.name.caseInsensitiveCompare(name) == .orderedSame }) {
            name = baseName + " \(index)"; index += 1
        }
        let profile = try updated.validated(WorkspaceProfile(id: UUID(), name: name, summary: manifest.summary,
            symbol: manifest.symbol, color: manifest.color, databasePath: target.path, createdAt: Date()))
        let database = try SQLiteStore(databaseURL: target)
        updated.workspaces.append(profile); updated.activeID = profile.id
        try activate(updated, database: database)
        committed = true
    }

    func configureMCP() {
        server?.stop(); server = nil
        guard UserDefaults.standard.bool(forKey: "mcpEnabled"), let model else { mcpStatus = L10n.tr("已关闭"); return }
        do {
            var token = try SecretStore.read("mcp-token")
            if token.isEmpty { token = UUID().uuidString + UUID().uuidString; try SecretStore.save(token, account: "mcp-token") }
            let rawPort = UserDefaults.standard.integer(forKey: "mcpPort")
            let port = rawPort == 0 ? 18427 : rawPort
            guard (1024...65535).contains(port) else { throw AppError.message(L10n.tr("端口应在 1024–65535 之间")) }
            let service = try LocalMCPServer(port: UInt16(port), token: token, model: model)
            service.onStatus = { [weak self] in self?.mcpStatus = $0 }
            server = service
            mcpStatus = L10n.tr("正在启动…")
            service.start()
        } catch { mcpStatus = error.localizedDescription }
    }

    func copyMCPConfig() {
        do {
            let token = try SecretStore.read("mcp-token")
            guard !token.isEmpty else { status = L10n.tr("请先启用 MCP 以生成令牌"); return }
            let port = UserDefaults.standard.integer(forKey: "mcpPort")
            let value: [String: Any] = ["mcpServers": ["velora": ["type": "http", "url": "http://127.0.0.1:\(port == 0 ? 18427 : port)/mcp", "headers": ["Authorization": "Bearer \(token)"]]]]
            let data = try JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted, .sortedKeys])
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(String(decoding: data, as: UTF8.self), forType: .string)
            status = L10n.tr("MCP 配置已复制（包含访问令牌）")
        } catch { status = error.localizedDescription }
    }

    func rotateMCPToken() {
        do { try SecretStore.save(UUID().uuidString + UUID().uuidString, account: "mcp-token"); configureMCP(); status = L10n.tr("令牌已更新，原客户端需重新配置") }
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
        guard status == errSecSuccess, let data = item as? Data else { throw AppError.message(L10n.tr("无法读取钥匙串：\(status)")) }
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
        guard status == errSecSuccess || status == errSecItemNotFound else { throw AppError.message(L10n.tr("无法保存钥匙串：\(status)")) }
    }
}
