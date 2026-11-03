import AppKit
import SwiftUI
import Security
import UniformTypeIdentifiers

enum AppError: LocalizedError {
    case message(String)
    var errorDescription: String? { switch self { case .message(let text): return L10n.text(text) } }
}

enum WorkspaceImportPolicy: String, CaseIterable, Identifiable {
    case keep, skip, replace
    var id: String { rawValue }
    var label: String {
        switch self { case .keep: return L10n.tr("保留"); case .skip: return L10n.tr("跳过"); case .replace: return L10n.tr("替换") }
    }
}

struct WorkspaceImportPlan: Identifiable {
    let id = UUID()
    let contents: WorkspaceBackup.ArchiveContents
    let conflicts: [String]
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
    var lastBackupKey: String { "lastBackupDate.allWorkspaces" }
    @Published var storagePath = ""
    @Published var storageError: String?
    @Published var workspaceRefreshStatus = ""
    var workspaceDirectoryPath: String { workspaceDirectoryURL.path }
    private var workspaceDirectoryURL: URL { catalog?.directoryURL(fallbackRoot: catalogURL.deletingLastPathComponent()) ?? catalogURL.deletingLastPathComponent().appendingPathComponent("Workspaces", isDirectory: true) }
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
            var loaded = try WorkspaceCatalog.load(from: self.catalogURL,
                legacyDatabaseURL: legacyDatabaseURL ?? legacyDirectory.appendingPathComponent("velora.sqlite"))
            // Keep valid workspace metadata available to the recovery screen.
            catalog = loaded
            storagePath = loaded.storageRoot ?? self.catalogURL.deletingLastPathComponent().path
            if existing && !FileManager.default.fileExists(atPath: loaded.active.databasePath) {
                throw AppError.message(L10n.tr("当前工作空间数据库不存在，请恢复文件：") + loaded.active.databasePath)
            }
            // Normalize legacy flat databases into isolated folders, keeping the original intact.
            let root = URL(fileURLWithPath: loaded.storageRoot ?? self.catalogURL.deletingLastPathComponent().path)
            for index in loaded.workspaces.indices {
                let profile = loaded.workspaces[index]
                let source = URL(fileURLWithPath: profile.databasePath)
                let target = loaded.directoryURL(fallbackRoot: root).appendingPathComponent(profile.id.uuidString).appendingPathComponent("velora.sqlite")
                let dedicatedRoot = loaded.directoryURL(fallbackRoot: root).standardizedFileURL
                let alreadyDedicated = source.deletingLastPathComponent().deletingLastPathComponent().standardizedFileURL == dedicatedRoot
                if !alreadyDedicated, source.deletingLastPathComponent().lastPathComponent != profile.id.uuidString,
                   FileManager.default.fileExists(atPath: source.path) || !existing {
                    // Never revive a missing database from a potentially stale migration copy.
                    if FileManager.default.fileExists(atPath: target.path) { continue }
                    if FileManager.default.fileExists(atPath: source.path) {
                        try WorkspaceBackup.copyDatabase(from: source, to: target)
                    }
                    if FileManager.default.fileExists(atPath: target.path) { loaded.workspaces[index].databasePath = target.path }
                    else if !existing { loaded.workspaces[index].databasePath = target.path }
                }
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
        let backupRoot = UserDefaults.standard.string(forKey: "backupDirectory")
            .map { URL(fileURLWithPath: $0, isDirectory: true) } ?? URL(fileURLWithPath: storagePath.isEmpty ? support.path : storagePath, isDirectory: true)
        backupPath = backupRoot.appendingPathComponent("backup", isDirectory: true).path
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
        let directory = workspaceDirectoryURL.appendingPathComponent(id.uuidString)
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

    @discardableResult
    func movePage(_ pageID: UUID, toWorkspace workspaceID: UUID) async throws -> UUID {
        guard let catalog, let source = store, let model,
              workspaceID != catalog.activeID,
              let target = catalog.workspaces.first(where: { $0.id == workspaceID }),
              let page = model.pages.first(where: { $0.id == pageID && !$0.archived }) else {
            throw AppError.message(L10n.tr("请选择其他有效的工作空间和文档"))
        }
        let sourceURL = URL(fileURLWithPath: catalog.active.databasePath).resolvingSymlinksInPath().standardizedFileURL
        let targetURL = URL(fileURLWithPath: target.databasePath).resolvingSymlinksInPath().standardizedFileURL
        guard sourceURL != targetURL else { throw AppError.message(L10n.tr("源和目标不能使用同一个数据库")) }
        guard FileManager.default.fileExists(atPath: target.databasePath) else {
            throw AppError.message(L10n.tr("工作空间数据库不存在：") + target.databasePath)
        }
        guard !busy else { throw AppError.message(L10n.tr("正在处理其他操作，请稍后重试")) }
        defer { finishTransition() }
        try await prepareTransition()
        let destination = try SQLiteStore(databaseURL: targetURL)
        let snapshot = try await source.transferSnapshot(name: page.title, pageID: pageID, includeChildren: true)
        let ordered = try snapshot.orderedPages()
        guard let rootIndex = ordered.firstIndex(where: { $0.id == pageID }) else { throw StoreError.missingPage }
        // Destination commits its complete tree before the recoverable source
        // archive. A failure between databases can duplicate, never lose, data.
        let imported = try await destination.importTransfer(snapshot)
        let rootID = imported[rootIndex]
        do { try await source.archiveTransferredPage(pageID, matching: snapshot) }
        catch {
            await model.refreshPages()
            throw AppError.message(L10n.tr("目标工作空间已保存副本，但源文档未移走，请检查后重试：") + error.localizedDescription)
        }
        let movedIDs = Set(snapshot.pages.map(\.id))
        await model.refreshPages()
        if let selected = model.selectedPageID, movedIDs.contains(selected) { model.select(page.parentID) }
        status = L10n.tr("文档及子页面已移动到「\(target.name)」，源副本可从回收箱恢复")
        return rootID
    }

    private var workspaceStorageRoot: URL {
        catalog?.storageRoot.map { URL(fileURLWithPath: $0, isDirectory: true) } ?? catalogURL.deletingLastPathComponent()
    }

    func createWorkspace(name: String, summary: String, symbol: String, color: String) async throws {
        guard var updated = catalog else { throw AppError.message(L10n.tr("工作空间尚未加载")) }
        let id = UUID()
        let path = workspaceDirectoryURL.appendingPathComponent(id.uuidString, isDirectory: true).appendingPathComponent("velora.sqlite")
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

    var trashedWorkspaces: [WorkspaceProfile] {
        (catalog?.removedWorkspaces ?? []).filter { $0.trashedAt != nil }.sorted { ($0.trashedAt ?? .distantPast) > ($1.trashedAt ?? .distantPast) }
    }
    private var workspaceTrashURL: URL { workspaceDirectoryURL.appendingPathComponent(".Trash", isDirectory: true) }

    private func verifiedFolder(for profile: WorkspaceProfile, parent: URL) throws -> URL {
        let folder = URL(fileURLWithPath: profile.databasePath).deletingLastPathComponent().standardizedFileURL
        let resolved = folder.resolvingSymlinksInPath()
        guard resolved.deletingLastPathComponent() == parent.resolvingSymlinksInPath(),
              try folder.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink != true,
              (try? URL(fileURLWithPath: profile.databasePath).resourceValues(forKeys: [.isSymbolicLinkKey]))?.isSymbolicLink != true,
              let metadata = try? JSONDecoder().decode(WorkspaceProfile.self, from: Data(contentsOf: folder.appendingPathComponent("workspace.json"))),
              metadata.id == profile.id else {
            throw AppError.message("无法确认此文件夹仅属于该工作空间，未删除。请先刷新或迁移到独立空间目录。")
        }
        let others = ((catalog?.workspaces ?? []) + (catalog?.removedWorkspaces ?? [])).filter {
            $0.id != profile.id && FileManager.default.fileExists(atPath: $0.databasePath)
        }
        guard !others.contains(where: { URL(fileURLWithPath: $0.databasePath).resolvingSymlinksInPath().path.hasPrefix(resolved.path + "/") }) else {
            throw AppError.message("此文件夹仍被其他工作空间引用，未删除。")
        }
        return folder
    }

    private func unregisteredCopies(of profiles: [WorkspaceProfile]) throws -> [URL] {
        let fm = FileManager.default
        guard fm.fileExists(atPath: workspaceDirectoryURL.path) else { return [] }
        let ids = Set(profiles.map(\.id))
        let registered = (catalog?.workspaces ?? []) + (catalog?.removedWorkspaces ?? [])
        return try fm.contentsOfDirectory(at: workspaceDirectoryURL, includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey], options: [.skipsHiddenFiles]).filter { folder in
            let values = try folder.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            guard values.isDirectory == true, values.isSymbolicLink != true,
                  let data = try? Data(contentsOf: folder.appendingPathComponent("workspace.json")),
                  let metadata = try? JSONDecoder().decode(WorkspaceProfile.self, from: data), ids.contains(metadata.id),
                  fm.fileExists(atPath: folder.appendingPathComponent("velora.sqlite").path) else { return false }
            let prefix = folder.resolvingSymlinksInPath().path + "/"
            return !registered.contains { fm.fileExists(atPath: $0.databasePath) && URL(fileURLWithPath: $0.databasePath).resolvingSymlinksInPath().path.hasPrefix(prefix) }
        }
    }

    private func archiveUnregisteredCopies() throws {
        let copies = try unregisteredCopies(of: workspaces)
        guard !copies.isEmpty else { return }
        let archive = workspaceDirectoryURL.deletingLastPathComponent().appendingPathComponent("backup/WorkspaceCopies-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: archive, withIntermediateDirectories: true)
        var moved: [(URL, URL)] = []
        do {
            for source in copies {
                let target = archive.appendingPathComponent(source.lastPathComponent)
                try FileManager.default.moveItem(at: source, to: target)
                moved.append((source, target))
            }
        } catch {
            for (source, target) in moved.reversed() { try FileManager.default.moveItem(at: target, to: source) }
            throw error
        }
    }

    func deleteWorkspace(_ id: UUID) async throws {
        guard !busy, var updated = catalog, let profile = updated.workspaces.first(where: { $0.id == id }) else { throw AppError.message("工作空间不可用，请稍后重试") }
        let wasActive = updated.activeID == id
        try updated.remove(id)
        let source = try verifiedFolder(for: profile, parent: workspaceDirectoryURL)
        let copies = try unregisteredCopies(of: [profile])
        let fm = FileManager.default
        try fm.createDirectory(at: workspaceTrashURL, withIntermediateDirectories: true)
        guard workspaceTrashURL.resolvingSymlinksInPath().deletingLastPathComponent() == workspaceDirectoryURL.resolvingSymlinksInPath() else {
            throw AppError.message("回收箱目录无效")
        }
        let target = workspaceTrashURL.appendingPathComponent(id.uuidString + "-" + UUID().uuidString, isDirectory: true)
        var recycled = profile
        recycled.trashedAt = Date(); recycled.databasePath = target.appendingPathComponent("velora.sqlite").path
        updated.removedWorkspaces.removeAll { $0.id == id }
        updated.removedWorkspaces.append(recycled)
        defer { finishTransition() }
        try await prepareTransition()
        let previousStore = store
        let replacement: SQLiteStore?
        if wasActive {
            guard let available = updated.workspaces.first(where: { fm.fileExists(atPath: $0.databasePath) }) else { throw AppError.message("替代工作空间数据库不存在，未删除") }
            updated.activeID = available.id
            replacement = try SQLiteStore(databaseURL: URL(fileURLWithPath: available.databasePath))
        } else { replacement = nil }
        var moved = false, closed = false
        var movedCopies: [(URL, URL)] = []
        do {
            if wasActive, let previousStore { try await previousStore.closeForWorkspaceDeletion(); closed = true }
            try fm.moveItem(at: source, to: target); moved = true
            if !copies.isEmpty {
                let copyRoot = target.appendingPathComponent(".MigrationCopies", isDirectory: true)
                try fm.createDirectory(at: copyRoot, withIntermediateDirectories: true)
                for copy in copies {
                    let destination = copyRoot.appendingPathComponent(copy.lastPathComponent)
                    try fm.moveItem(at: copy, to: destination)
                    movedCopies.append((copy, destination))
                }
            }
            if let replacement { try activate(updated, database: replacement) }
            else { try updated.save(to: catalogURL); catalog = updated }
        } catch {
            let originalError = error
            do {
                for (copy, destination) in movedCopies.reversed() { try fm.moveItem(at: destination, to: copy) }
                if moved { try fm.moveItem(at: target, to: source) }
                if closed { try await previousStore?.reopenAfterDeletionFailure() }
            } catch {
                store = nil; model = nil; startupError = error.localizedDescription
                throw AppError.message("移入回收箱失败，请重新选择空间文件夹：" + error.localizedDescription)
            }
            throw originalError
        }
        workspaceRefreshStatus = ""
        status = L10n.tr("工作空间已移入回收箱")
    }

    func restoreWorkspace(_ id: UUID) async throws {
        guard !busy, var updated = catalog, var profile = updated.removedWorkspaces.first(where: { $0.id == id && $0.trashedAt != nil }) else { throw AppError.message("工作空间不存在") }
        let source = try verifiedFolder(for: profile, parent: workspaceTrashURL)
        var target = workspaceDirectoryURL.appendingPathComponent(id.uuidString, isDirectory: true)
        if FileManager.default.fileExists(atPath: target.path) { target = workspaceDirectoryURL.appendingPathComponent(id.uuidString + "-" + UUID().uuidString) }
        busy = true; defer { finishTransition() }
        profile.trashedAt = nil; profile.databasePath = target.appendingPathComponent("velora.sqlite").path
        let base = profile.name
        var index = 2
        while updated.workspaces.contains(where: { $0.name.caseInsensitiveCompare(profile.name) == .orderedSame }) {
            let suffix = " \(index)"; profile.name = String(base.prefix(60 - suffix.count)) + suffix; index += 1
        }
        profile = try updated.validated(profile)
        updated.removedWorkspaces.removeAll { $0.id == id }; updated.workspaces.append(profile)
        try FileManager.default.moveItem(at: source, to: target)
        do { try updated.save(to: catalogURL) }
        catch { try FileManager.default.moveItem(at: target, to: source); throw error }
        catalog = updated
        status = L10n.tr("工作空间已恢复")
    }

    func permanentlyDeleteWorkspace(_ id: UUID) async throws {
        guard !busy, var updated = catalog, let profile = updated.removedWorkspaces.first(where: { $0.id == id && $0.trashedAt != nil }) else { throw AppError.message("工作空间不存在") }
        let folder = URL(fileURLWithPath: profile.databasePath).deletingLastPathComponent()
        let exists = FileManager.default.fileExists(atPath: folder.path)
        if exists { _ = try verifiedFolder(for: profile, parent: workspaceTrashURL) }
        busy = true; defer { finishTransition() }
        updated.removedWorkspaces.removeAll { $0.id == id }
        let staged = workspaceTrashURL.appendingPathComponent(".purging-" + UUID().uuidString)
        if exists { try FileManager.default.moveItem(at: folder, to: staged) }
        do { try updated.save(to: catalogURL) }
        catch { if exists { try FileManager.default.moveItem(at: staged, to: folder) }; throw error }
        if exists {
            do { try FileManager.default.removeItem(at: staged) }
            catch {
                if FileManager.default.fileExists(atPath: staged.path) { try FileManager.default.moveItem(at: staged, to: folder) }
                try catalog?.save(to: catalogURL)
                throw error
            }
        }
        catalog = updated
        status = L10n.tr("工作空间已永久删除")
    }

    func restoreAllWorkspaces() async throws {
        for id in trashedWorkspaces.map(\.id) { try await restoreWorkspace(id) }
    }
    func emptyWorkspaceTrash() async throws {
        for id in trashedWorkspaces.map(\.id) { try await permanentlyDeleteWorkspace(id) }
    }
    func deleteAllWorkspaces() async throws {
        let ids = workspaces.map(\.id)
        var name = L10n.tr("空白工作空间"), suffix = 2
        while workspaces.contains(where: { $0.name.caseInsensitiveCompare(name) == .orderedSame }) {
            name = L10n.tr("空白工作空间") + " \(suffix)"; suffix += 1
        }
        try await createWorkspace(name: name, summary: "", symbol: WorkspaceProfile.symbols[0], color: "indigo")
        for id in ids { try await deleteWorkspace(id) }
    }

    func refreshWorkspaces() async throws {
        guard !busy, var updated = catalog else { throw AppError.message("正在处理其他操作，请稍后重试") }
        defer { finishTransition() }
        if model != nil { try await prepareTransition() } else { busy = true }
        try updated.reconnectMovedWorkspaces(in: workspaceDirectoryURL)
        let count = try updated.discoverWorkspaces(in: workspaceDirectoryURL, includingRemoved: true)
        let missing = updated.workspaces.filter { !FileManager.default.fileExists(atPath: $0.databasePath) }
        updated.workspaces.removeAll { profile in missing.contains { $0.id == profile.id } }
        for profile in missing where !updated.removedWorkspaces.contains(where: { $0.id == profile.id }) {
            updated.removedWorkspaces.append(profile)
        }
        if !updated.workspaces.contains(where: { $0.id == updated.activeID }) {
            guard let first = updated.workspaces.first else { throw AppError.message("所选位置没有找到工作空间数据库") }
            updated.activeID = first.id
        }
        if model == nil || updated.activeID != catalog?.activeID || updated.active.databasePath != catalog?.active.databasePath {
            let database = try SQLiteStore(databaseURL: URL(fileURLWithPath: updated.active.databasePath))
            try activate(updated, database: database)
        } else {
            try updated.save(to: catalogURL)
            catalog = updated
        }
        try archiveUnregisteredCopies()
        workspaceRefreshStatus = L10n.format("刷新完成，新增 %d 个工作空间", count)
        status = workspaceRefreshStatus
    }

    func chooseStorage() {
        guard !busy, let directory = chooseDirectory(message: L10n.tr("选择存储目录：已有空间文件夹将直接加载，空目录中会创建 Workspaces。移动后的空间会按 ID 重新连接。"), initialURL: URL(fileURLWithPath: workspaceDirectoryPath)) else { return }
        Task {
            do { try await relocateStorage(to: directory) }
            catch { storageError = error.localizedDescription; status = error.localizedDescription }
        }
    }

    func relocateStorage(to directory: URL) async throws {
        guard !busy, var updated = catalog else { throw AppError.message(L10n.tr("正在处理其他操作，请稍后重试")) }
        storageError = nil
        let workspaceRoot = try WorkspaceCatalog.selectedWorkspaceDirectory(directory)
        let root = workspaceRoot.deletingLastPathComponent()
        try updated.reconnectMovedWorkspaces(in: workspaceRoot)
        let missing = updated.workspaces.filter { !FileManager.default.fileExists(atPath: $0.databasePath) }
        updated.workspaces.removeAll { profile in missing.contains { $0.id == profile.id } }
        for profile in missing where !updated.removedWorkspaces.contains(where: { $0.id == profile.id }) {
            updated.removedWorkspaces.append(profile)
        }
        let profiles = updated.workspaces + updated.removedWorkspaces.filter { FileManager.default.fileExists(atPath: $0.databasePath) }
        var targets: [UUID: URL] = [:]
        for profile in profiles {
            let source = URL(fileURLWithPath: profile.databasePath).standardizedFileURL.resolvingSymlinksInPath()
            guard FileManager.default.fileExists(atPath: source.path) else { throw AppError.message(L10n.tr("工作空间数据库不存在：") + source.path) }
            let destinationRoot = profile.trashedAt == nil ? workspaceRoot : workspaceRoot.appendingPathComponent(".Trash", isDirectory: true)
            // Keep recycled spaces inside the destination recycle bin.
            if source.deletingLastPathComponent().deletingLastPathComponent() == destinationRoot {
                targets[profile.id] = source
                continue
            }
            var folder = destinationRoot.appendingPathComponent(profile.id.uuidString, isDirectory: true)
            // Prior migrations keep copies here. Allocate a fresh folder rather than overwrite or
            // silently reopen an older database; repeated selection above remains a no-op.
            while FileManager.default.fileExists(atPath: folder.path) {
                folder = destinationRoot.appendingPathComponent(profile.id.uuidString + "-" + UUID().uuidString, isDirectory: true)
            }
            targets[profile.id] = folder.appendingPathComponent("velora.sqlite")
        }
        defer { finishTransition() }
        if model != nil { try await prepareTransition() } else { busy = true }
        var created: [URL] = []
        var committed = false
        defer {
            if !committed {
                for file in created {
                    try? FileManager.default.removeItem(at: file.deletingLastPathComponent())
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
        updated.workspaceDirectory = workspaceRoot.path
        _ = try updated.discoverWorkspaces(in: workspaceRoot)
        if !updated.workspaces.contains(where: { $0.id == updated.activeID }) {
            guard let first = updated.workspaces.first else {
                throw AppError.message("没有找到可用工作空间，请选择移动后的文件夹或导入工作空间。")
            }
            updated.activeID = first.id
        }
        let database = try SQLiteStore(databaseURL: URL(fileURLWithPath: updated.active.databasePath))
        try activate(updated, database: database)
        committed = true
        try archiveUnregisteredCopies()
        if UserDefaults.standard.string(forKey: "backupDirectory") == nil {
            backupPath = root.appendingPathComponent("backup", isDirectory: true).path
        }
        status = missing.isEmpty ? L10n.tr("所有工作空间存储位置已切换，原位置副本保留。")
            : L10n.tr("可用工作空间已迁移。缺失数据库的空间记录已保留，可在找回文件后重新导入。")
    }

    func chooseBackup() {
        guard let directory = chooseDirectory(message: L10n.tr("选择备份保存位置")) else { return }
        backupPath = directory.appendingPathComponent("backup", isDirectory: true).path
        UserDefaults.standard.set(directory.path, forKey: "backupDirectory")
    }

    private func chooseDirectory(message: String, initialURL: URL? = nil) -> URL? {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false; panel.canChooseDirectories = true
        panel.canCreateDirectories = true; panel.allowsMultipleSelection = false
        panel.message = message
        panel.directoryURL = initialURL
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
        guard let catalog, let store else { throw AppError.message(L10n.text("工作空间尚未加载")) }
        guard !busy else { throw AppError.message(L10n.text("正在处理其他操作，请稍后重试")) }
        defer { finishTransition() }
        try await prepareTransition()
        let temporary = FileManager.default.temporaryDirectory.appendingPathComponent("Velora-backup-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: temporary) }
        status = L10n.text("正在创建 ZIP 备份…")
        var snapshots: [(WorkspaceProfile, URL, Bool)] = []
        let profiles = catalog.workspaces.map { ($0, false) } + catalog.removedWorkspaces.filter {
            FileManager.default.fileExists(atPath: $0.databasePath)
        }.map { ($0, true) }
        for (profile, removed) in profiles {
            guard FileManager.default.fileExists(atPath: profile.databasePath) else {
                throw AppError.message(L10n.tr("工作空间数据库不存在：") + profile.databasePath)
            }
            let snapshot = temporary.appendingPathComponent(profile.id.uuidString + ".sqlite")
            if profile.id == catalog.activeID { try await store.snapshot(to: snapshot) }
            else {
                try WorkspaceBackup.copyDatabase(from: URL(fileURLWithPath: profile.databasePath), to: snapshot)
            }
            snapshots.append((profile, snapshot, removed))
        }
        let formatter = DateFormatter(); formatter.locale = Locale(identifier: "en_US_POSIX"); formatter.dateFormat = "yyyy-MM-dd_HH-mm-ss"
        let folder = directory.map { $0.appendingPathComponent("backup", isDirectory: true) }
            ?? URL(fileURLWithPath: backupPath, isDirectory: true)
        let destination = folder.appendingPathComponent("Velora-All-\(formatter.string(from: Date()))-\(UUID().uuidString.prefix(6)).zip")
        let completedSnapshots = snapshots
        try await Task.detached(priority: .userInitiated) {
            try WorkspaceBackup.writeAll(snapshots: completedSnapshots, activeID: catalog.activeID, to: destination)
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

    /// Stage every workspace, then publish a single catalog update. Never overwrite existing data.
    func restoreBackup(from archive: URL) async throws {
        let contents = try await Task.detached(priority: .userInitiated) { try WorkspaceBackup.readAll(archive) }.value
        try await installWorkspaces(contents)
    }

    private func installWorkspaces(_ contents: WorkspaceBackup.ArchiveContents, importing: Bool = false, policy: WorkspaceImportPolicy = .keep) async throws {
        guard !busy, var updated = catalog else { throw AppError.message("工作空间尚未加载") }
        defer { finishTransition() }
        if model != nil { try await prepareTransition() } else { busy = true }
        var created: [URL] = []
        var committed = false
        defer { if !committed { for folder in created { try? FileManager.default.removeItem(at: folder) } } }
        status = L10n.text("正在恢复备份…")
        let discovered = importing ? try updated.discoverWorkspaces(in: workspaceDirectoryURL) : 0
        var changed = discovered > 0
        for item in contents.workspaces {
            let existing = importing ? importConflict(for: item.profile, in: updated) : nil
            if existing != nil, policy == .skip { continue }
            let replacing = importing && policy == .replace ? existing : nil
            let id = replacing?.id ?? UUID()
            let destinationRoot = item.removed && item.profile.trashedAt != nil ? workspaceTrashURL : workspaceDirectoryURL
            var target = destinationRoot.appendingPathComponent(id.uuidString).appendingPathComponent("velora.sqlite")
            if FileManager.default.fileExists(atPath: target.deletingLastPathComponent().path) {
                target = destinationRoot.appendingPathComponent(id.uuidString + "-" + UUID().uuidString).appendingPathComponent("velora.sqlite")
            }
            let directory = target.deletingLastPathComponent()
            guard !FileManager.default.fileExists(atPath: directory.path) else { throw AppError.message("目标文件已存在，未覆盖") }
            created.append(directory)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try item.database.write(to: target, options: .withoutOverwriting)
            try WorkspaceBackup.validateDatabase(at: target)
            _ = try SQLiteStore(databaseURL: target)
            if let replacing {
                updated.workspaces.removeAll { $0.id == replacing.id }
                updated.removedWorkspaces.removeAll { $0.id == replacing.id }
                var archived = replacing
                archived.id = UUID()
                archived.replacementArchive = true
                archived.name = String(replacing.name.prefix(44)) + L10n.tr("（替换前）")
                updated.removedWorkspaces.append(archived)
            }
            var profile = item.profile
            profile.id = id; profile.databasePath = target.path
            if !item.removed { profile.trashedAt = nil; profile.replacementArchive = nil }
            let baseName = importing ? String(profile.name.prefix(60)) : String(profile.name.prefix(44)) + L10n.text("（已恢复）")
            var name = baseName; var index = 2
            while (updated.workspaces + updated.removedWorkspaces).contains(where: { $0.name.caseInsensitiveCompare(name) == .orderedSame }) {
                let suffix = " \(index)"
                name = String(baseName.prefix(60 - suffix.count)) + suffix; index += 1
            }
            profile.name = name
            profile = try updated.validated(profile)
            if item.removed { updated.removedWorkspaces.append(profile) }
            else { updated.workspaces.append(profile) }
            if item.profile.id == contents.activeID { updated.activeID = id }
            changed = true
        }
        guard changed else { status = L10n.tr("所有重复工作空间已跳过"); committed = true; return }
        let missing = updated.workspaces.filter { !FileManager.default.fileExists(atPath: $0.databasePath) }
        updated.workspaces.removeAll { profile in missing.contains { $0.id == profile.id } }
        for profile in missing where !updated.removedWorkspaces.contains(where: { $0.id == profile.id }) {
            updated.removedWorkspaces.append(profile)
        }
        if !updated.workspaces.contains(where: { $0.id == updated.activeID }) {
            guard let first = updated.workspaces.first else { throw AppError.message("所选位置没有找到工作空间数据库") }
            updated.activeID = first.id
        }
        let database = try SQLiteStore(databaseURL: URL(fileURLWithPath: updated.active.databasePath))
        try activate(updated, database: database)
        committed = true
    }

    private func importConflict(for profile: WorkspaceProfile, in catalog: WorkspaceCatalog) -> WorkspaceProfile? {
        let known = catalog.workspaces + catalog.removedWorkspaces
        return known.first { URL(fileURLWithPath: $0.databasePath).standardizedFileURL == URL(fileURLWithPath: profile.databasePath).standardizedFileURL }
            ?? known.first { $0.id == profile.id }
            ?? known.first { $0.name.compare(profile.name, options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame }
    }

    func applyWorkspaceImport(_ plan: WorkspaceImportPlan, policy: WorkspaceImportPolicy) async throws {
        try await installWorkspaces(plan.contents, importing: true, policy: policy)
    }

    func importExistingWorkspace(from url: URL, policy: WorkspaceImportPolicy = .keep) async throws {
        let plan = try await prepareWorkspaceImport(from: url)
        try await applyWorkspaceImport(plan, policy: policy)
    }

    func prepareWorkspaceImport(from urls: [URL]) async throws -> WorkspaceImportPlan {
        guard !urls.isEmpty else { throw AppError.message("所选位置没有找到工作空间数据库") }
        var entries: [WorkspaceBackup.RestoredWorkspace] = []
        var seen: Set<String> = []
        var total = 0
        for url in urls {
            let plan = try await prepareWorkspaceImport(from: url)
            for item in plan.contents.workspaces {
                let path = URL(fileURLWithPath: item.profile.databasePath).resolvingSymlinksInPath().standardizedFileURL.path
                guard seen.insert(path).inserted else { continue }
                guard item.database.count <= WorkspaceBackup.maximumSize - total else { throw AppError.message("备份超过 512 MB 限制") }
                total += item.database.count
                entries.append(item)
            }
        }
        guard let first = entries.first else { throw AppError.message("所选位置没有找到工作空间数据库") }
        var comparison = catalog
        _ = try comparison?.discoverWorkspaces(in: workspaceDirectoryURL)
        var previous: [WorkspaceProfile] = []
        let conflicts = entries.compactMap { item -> String? in
            let existing = comparison.flatMap { importConflict(for: item.profile, in: $0) }
                ?? previous.first { $0.id == item.profile.id || $0.name.caseInsensitiveCompare(item.profile.name) == .orderedSame }
            previous.append(item.profile)
            return existing?.name
        }
        return WorkspaceImportPlan(contents: .init(activeID: first.profile.id, workspaces: entries), conflicts: conflicts)
    }

    func prepareWorkspaceImport(from url: URL) async throws -> WorkspaceImportPlan {
        guard !busy else { throw AppError.message("正在处理其他操作，请稍后重试") }
        defer { finishTransition() }
        if model != nil { try await prepareTransition() } else { busy = true }
        let knownProfiles = (catalog?.workspaces ?? []) + (catalog?.removedWorkspaces ?? [])
        let contents = try await Task.detached(priority: .userInitiated) {
            let fm = FileManager.default
            var isDirectory: ObjCBool = false
            guard fm.fileExists(atPath: url.path, isDirectory: &isDirectory) else { throw AppError.message("工作空间数据库不存在：" + url.path) }
            var sources: [URL] = []
            if !isDirectory.boolValue { sources = [url] }
            else if fm.fileExists(atPath: url.appendingPathComponent("velora.sqlite").path) { sources = [url.appendingPathComponent("velora.sqlite")] }
            else {
                let root = fm.fileExists(atPath: url.appendingPathComponent("Workspaces").path) ? url.appendingPathComponent("Workspaces") : url
                sources = try fm.contentsOfDirectory(at: root, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])
                    .map { $0.appendingPathComponent("velora.sqlite") }.filter { fm.fileExists(atPath: $0.path) }.sorted { $0.path < $1.path }
            }
            guard !sources.isEmpty else { throw AppError.message("所选位置没有找到工作空间数据库") }
            let temporary = fm.temporaryDirectory.appendingPathComponent("Velora-import-" + UUID().uuidString)
            defer { try? fm.removeItem(at: temporary) }
            var workspaces: [WorkspaceBackup.RestoredWorkspace] = []
            var total = 0
            for source in sources {
                var profile = WorkspaceCatalog.importedProfile(for: source, knownProfiles: knownProfiles)
                profile.databasePath = source.path
                if !fm.fileExists(atPath: source.deletingLastPathComponent().appendingPathComponent("workspace.json").path),
                   let folderID = UUID(uuidString: source.deletingLastPathComponent().lastPathComponent) { profile.id = folderID }
                let snapshot = temporary.appendingPathComponent(UUID().uuidString + ".sqlite")
                try WorkspaceBackup.copyDatabase(from: source, to: snapshot)
                let size = try snapshot.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
                guard size <= WorkspaceBackup.maximumSize - total else { throw AppError.message("备份超过 512 MB 限制") }
                let data = try Data(contentsOf: snapshot); total += data.count
                workspaces.append(.init(profile: profile, database: data, removed: false))
            }
            return WorkspaceBackup.ArchiveContents(activeID: workspaces[0].profile.id, workspaces: workspaces)
        }.value
        var comparison = catalog
        _ = try comparison?.discoverWorkspaces(in: workspaceDirectoryURL)
        let conflicts = contents.workspaces.compactMap { item in
            comparison.flatMap { importConflict(for: item.profile, in: $0) }.map { $0.name }
        }
        return WorkspaceImportPlan(contents: contents, conflicts: conflicts)
    }

    func configureMCP() {
        server?.stop(); server = nil
        guard UserDefaults.standard.bool(forKey: "mcpEnabled"), let model else { mcpStatus = L10n.tr("已关闭"); return }
        do {
            let token = try MCPTokenStore.loadOrCreate()
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

    func copyMCPConfig(stdio: Bool = false) {
        do {
            let token = try MCPTokenStore.loadOrCreate()
            let port = UserDefaults.standard.integer(forKey: "mcpPort")
            let configuration: [String: Any]
            if stdio {
                guard let bridge = Bundle.main.url(forResource: "velora_mcp_bridge", withExtension: "py") else { throw AppError.message("MCP stdio 桥接文件缺失") }
                configuration = ["command": "/usr/bin/env", "args": ["python3", bridge.path], "env": ["VELORA_MCP_TOKEN": token, "VELORA_MCP_PORT": String(port == 0 ? 18427 : port)]]
            } else {
                configuration = ["type": "http", "url": "http://127.0.0.1:\(port == 0 ? 18427 : port)/mcp", "headers": ["Authorization": "Bearer \(token)"]]
            }
            let value: [String: Any] = ["mcpServers": ["velora": configuration]]
            let data = try JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted, .sortedKeys])
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(String(decoding: data, as: UTF8.self), forType: .string)
            status = L10n.tr("MCP 配置已复制（包含访问令牌）")
        } catch { status = error.localizedDescription }
    }

    func rotateMCPToken() {
        do { try MCPTokenStore.rotate(); configureMCP(); status = L10n.tr("令牌已更新，原客户端需重新配置") }
        catch { status = error.localizedDescription }
    }
}

/// The MCP bearer token protects a loopback-only service and is not a remote account
/// credential. Keep it in a mode-0600 file so workspace transitions never need to
/// unlock Keychain. Real provider API keys continue to use `SecretStore` below.
enum MCPTokenStore {
    static func loadOrCreate(at url: URL? = nil) throws -> String {
        let target = url ?? defaultURL
        if let data = try? Data(contentsOf: target),
           let token = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
           !token.isEmpty { return token }
        return try rotate(at: target)
    }

    @discardableResult
    static func rotate(at url: URL? = nil) throws -> String {
        let target = url ?? defaultURL
        let directory = target.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])
        let token = UUID().uuidString + UUID().uuidString
        try Data(token.utf8).write(to: target, options: [.atomic])
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: target.path)
        return token
    }

    private static var defaultURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Velora", isDirectory: true)
            .appendingPathComponent("mcp-token")
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
