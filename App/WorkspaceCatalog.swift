import Foundation
import SwiftUI

struct WorkspaceProfile: Codable, Identifiable, Equatable {
    var id: UUID
    var name: String
    var summary: String
    var symbol: String
    var color: String
    var databasePath: String
    var createdAt: Date
    var replacementArchive: Bool? = nil
    var trashedAt: Date? = nil

    static let symbols = ["square.stack.3d.up.fill", "briefcase.fill", "house.fill", "book.fill", "graduationcap.fill", "lightbulb.fill", "leaf.fill", "star.fill"]
    static let colors = ["indigo", "blue", "green", "orange", "pink", "purple"]
    var tint: Color {
        switch color {
        case "blue": .blue
        case "green": .green
        case "orange": .orange
        case "pink": .pink
        case "purple": .purple
        default: .indigo
        }
    }
}

struct WorkspaceCatalog: Codable {
    var workspaces: [WorkspaceProfile]
    var activeID: UUID
    var storageRoot: String? = nil
    var workspaceDirectory: String? = nil
    // Removing a workspace keeps its metadata and database available for recovery.
    var removedWorkspaces: [WorkspaceProfile] = []

    init(workspaces: [WorkspaceProfile], activeID: UUID, storageRoot: String? = nil, removedWorkspaces: [WorkspaceProfile] = []) {
        self.workspaces = workspaces; self.activeID = activeID
        self.storageRoot = storageRoot; self.removedWorkspaces = removedWorkspaces
    }

    private enum CodingKeys: String, CodingKey { case workspaces, activeID, storageRoot, workspaceDirectory, removedWorkspaces }
    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        workspaces = try values.decode([WorkspaceProfile].self, forKey: .workspaces)
        activeID = try values.decode(UUID.self, forKey: .activeID)
        storageRoot = try values.decodeIfPresent(String.self, forKey: .storageRoot)
        workspaceDirectory = try values.decodeIfPresent(String.self, forKey: .workspaceDirectory)
        removedWorkspaces = try values.decodeIfPresent([WorkspaceProfile].self, forKey: .removedWorkspaces) ?? []
    }

    static func databaseURL(root: URL, id: UUID) -> URL {
        root.appendingPathComponent("Workspaces", isDirectory: true)
            .appendingPathComponent(id.uuidString, isDirectory: true).appendingPathComponent("velora.sqlite")
    }

    func directoryURL(fallbackRoot: URL) -> URL {
        workspaceDirectory.map { URL(fileURLWithPath: $0, isDirectory: true) }
            ?? URL(fileURLWithPath: storageRoot ?? fallbackRoot.path, isDirectory: true).appendingPathComponent("Workspaces", isDirectory: true)
    }

    static func selectedWorkspaceDirectory(_ selected: URL) throws -> URL {
        let selected = selected.standardizedFileURL.resolvingSymlinksInPath()
        if selected.lastPathComponent == "Workspaces" { return selected }
        if FileManager.default.fileExists(atPath: selected.path) {
            let children = try FileManager.default.contentsOfDirectory(at: selected, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])
            if children.contains(where: { FileManager.default.fileExists(atPath: $0.appendingPathComponent("velora.sqlite").path) }) { return selected }
        }
        return selected.appendingPathComponent("Workspaces", isDirectory: true)
    }

    mutating func reconnectMovedWorkspaces(in directory: URL) throws {
        guard FileManager.default.fileExists(atPath: directory.path) else { return }
        let regularFolders = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])
        let trashFolders = (try? FileManager.default.contentsOfDirectory(at: directory.appendingPathComponent(".Trash"), includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])) ?? []
        func resolved(_ profile: WorkspaceProfile) throws -> WorkspaceProfile {
            guard !FileManager.default.fileExists(atPath: profile.databasePath) else { return profile }
            let originalFolder = URL(fileURLWithPath: profile.databasePath).deletingLastPathComponent().lastPathComponent
            let folders = profile.trashedAt == nil ? regularFolders : trashFolders
            let matches = folders.filter { folder in
                guard FileManager.default.fileExists(atPath: folder.appendingPathComponent("velora.sqlite").path) else { return false }
                if let data = try? Data(contentsOf: folder.appendingPathComponent("workspace.json")),
                   let metadata = try? JSONDecoder().decode(WorkspaceProfile.self, from: data) { return metadata.id == profile.id }
                return folder.lastPathComponent == originalFolder
            }
            let exact = matches.first { $0.lastPathComponent == originalFolder }
            guard let folder = exact ?? (matches.count == 1 ? matches.first : nil) else { return profile }
            let database = folder.appendingPathComponent("velora.sqlite")
            try WorkspaceBackup.validateDatabase(at: database)
            var result = profile; result.databasePath = database.path
            return result
        }
        workspaces = try workspaces.map(resolved)
        removedWorkspaces = try removedWorkspaces.map(resolved)
    }

    static func importedProfile(for database: URL, knownProfiles: [WorkspaceProfile]) -> WorkspaceProfile {
        let folder = database.deletingLastPathComponent()
        let metadata = (try? Data(contentsOf: folder.appendingPathComponent("workspace.json")))
            .flatMap { try? JSONDecoder().decode(WorkspaceProfile.self, from: $0) }
        var candidates = knownProfiles
        for root in [folder.deletingLastPathComponent(), folder.deletingLastPathComponent().deletingLastPathComponent()] {
            if let data = try? Data(contentsOf: root.appendingPathComponent("workspaces.json")),
               let catalog = try? JSONDecoder().decode(Self.self, from: data) {
                candidates += catalog.workspaces + catalog.removedWorkspaces
            }
        }
        let folderID = UUID(uuidString: String(folder.lastPathComponent.prefix(36)))
        let known = candidates.first {
            ($0.id == folderID || URL(fileURLWithPath: $0.databasePath).standardizedFileURL == database.standardizedFileURL)
                && UUID(uuidString: String($0.name.prefix(36))) == nil
        }
        var profile = metadata ?? known ?? WorkspaceProfile(id: UUID(), name: "", summary: "",
            symbol: WorkspaceProfile.symbols[0], color: "indigo", databasePath: "", createdAt: Date())
        // A UUID folder is an implementation detail, never a fallback display name.
        if profile.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || UUID(uuidString: String(profile.name.prefix(36))) != nil {
            let stem = database.deletingPathExtension().lastPathComponent
            let fallback = ["velora", "workspace", "store", "database"].contains(stem.lowercased()) ? folder.lastPathComponent : stem
            profile.name = known?.name ?? (UUID(uuidString: String(fallback.prefix(36))) == nil ? String(fallback.prefix(60)) : L10n.text("导入的工作空间"))
        }
        return profile
    }

    /// Register existing immediate workspace folders when selecting a storage location.
    /// Existing IDs (including removed records) win so old migration copies never replace live data.
    @discardableResult
    mutating func discoverWorkspaces(in directory: URL, includingRemoved: Bool = false) throws -> Int {
        let fm = FileManager.default
        guard fm.fileExists(atPath: directory.path) else { return 0 }
        let children = try fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles])
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        var count = 0
        for folder in children {
            guard try folder.resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true else { continue }
            let database = folder.appendingPathComponent("velora.sqlite")
            guard fm.fileExists(atPath: database.path) else { continue }
            let known = workspaces + removedWorkspaces.filter {
                !includingRemoved || $0.trashedAt != nil || $0.replacementArchive == true
            }
            if known.contains(where: { URL(fileURLWithPath: $0.databasePath).standardizedFileURL == database.standardizedFileURL }) { continue }
            var profile = Self.importedProfile(for: database, knownProfiles: workspaces + removedWorkspaces)
            if profile.replacementArchive == true || profile.trashedAt != nil { continue }
            if let folderID = UUID(uuidString: folder.lastPathComponent),
               !fm.fileExists(atPath: folder.appendingPathComponent("workspace.json").path) { profile.id = folderID }
            if known.contains(where: { $0.id == profile.id }) { continue }
            try WorkspaceBackup.validateDatabase(at: database)
            profile.databasePath = database.path
            let base = profile.name
            var name = base; var index = 2
            while workspaces.contains(where: { $0.name.caseInsensitiveCompare(name) == .orderedSame }) {
                let suffix = " \(index)"
                name = String(base.prefix(60 - suffix.count)) + suffix; index += 1
            }
            profile.name = name
            let validated = try validated(profile)
            if includingRemoved { removedWorkspaces.removeAll { $0.id == validated.id } }
            workspaces.append(validated)
            count += 1
        }
        return count
    }

    var active: WorkspaceProfile { workspaces.first { $0.id == activeID }! }

    static func load(from url: URL, legacyDatabaseURL: URL) throws -> WorkspaceCatalog {
        guard FileManager.default.fileExists(atPath: url.path) else {
            let profile = WorkspaceProfile(id: UUID(), name: L10n.tr("默认工作空间"), summary: "", symbol: WorkspaceProfile.symbols[0],
                                           color: "indigo", databasePath: legacyDatabaseURL.path, createdAt: Date())
            return WorkspaceCatalog(workspaces: [profile], activeID: profile.id)
        }
        let catalog = try JSONDecoder().decode(Self.self, from: Data(contentsOf: url))
        guard !catalog.workspaces.isEmpty, catalog.workspaces.contains(where: { $0.id == catalog.activeID }),
              Set(catalog.workspaces.map(\.id)).count == catalog.workspaces.count else {
            throw AppError.message(L10n.tr("工作空间配置无效，请检查 workspaces.json"))
        }
        return catalog
    }

    func save(to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        var previous: [(URL, Data?)] = []
        do {
            // Metadata and the central catalog must roll back together on a failed commit.
            for profile in workspaces + removedWorkspaces where FileManager.default.fileExists(atPath: profile.databasePath) {
                let metadata = URL(fileURLWithPath: profile.databasePath).deletingLastPathComponent().appendingPathComponent("workspace.json")
                let old = FileManager.default.fileExists(atPath: metadata.path) ? try Data(contentsOf: metadata) : nil
                previous.append((metadata, old))
                try JSONEncoder().encode(profile).write(to: metadata, options: .atomic)
            }
            try JSONEncoder().encode(self).write(to: url, options: .atomic)
        } catch {
            for (metadata, old) in previous.reversed() {
                if let old { try? old.write(to: metadata, options: .atomic) }
                else { try? FileManager.default.removeItem(at: metadata) }
            }
            throw error
        }
    }

    func validated(_ profile: WorkspaceProfile) throws -> WorkspaceProfile {
        var result = profile
        result.name = result.name.trimmingCharacters(in: .whitespacesAndNewlines)
        result.summary = result.summary.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !result.name.isEmpty, result.name.count <= 60 else { throw AppError.message(L10n.tr("工作空间名称需为 1–60 个字符")) }
        guard result.summary.count <= 500 else { throw AppError.message(L10n.tr("简介最多 500 个字符")) }
        guard !workspaces.contains(where: { $0.id != result.id && $0.name.compare(result.name, options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame }) else {
            throw AppError.message(L10n.tr("已存在同名工作空间"))
        }
        guard WorkspaceProfile.symbols.contains(result.symbol), WorkspaceProfile.colors.contains(result.color) else {
            throw AppError.message(L10n.tr("请选择有效的图标和颜色"))
        }
        return result
    }

    mutating func remove(_ id: UUID) throws {
        guard workspaces.count > 1 else { throw AppError.message(L10n.tr("至少需要保留一个工作空间")) }
        guard let index = workspaces.firstIndex(where: { $0.id == id }) else { throw AppError.message(L10n.tr("工作空间不存在")) }
        removedWorkspaces.append(workspaces.remove(at: index))
        if activeID == id { activeID = workspaces[0].id }
    }
}
