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
    // Removing a workspace keeps its metadata and database available for recovery.
    var removedWorkspaces: [WorkspaceProfile] = []

    var active: WorkspaceProfile { workspaces.first { $0.id == activeID }! }

    static func load(from url: URL, legacyDatabaseURL: URL) throws -> WorkspaceCatalog {
        guard FileManager.default.fileExists(atPath: url.path) else {
            let profile = WorkspaceProfile(id: UUID(), name: "默认工作空间", summary: "", symbol: WorkspaceProfile.symbols[0],
                                           color: "indigo", databasePath: legacyDatabaseURL.path, createdAt: Date())
            return WorkspaceCatalog(workspaces: [profile], activeID: profile.id)
        }
        let catalog = try JSONDecoder().decode(Self.self, from: Data(contentsOf: url))
        guard !catalog.workspaces.isEmpty, catalog.workspaces.contains(where: { $0.id == catalog.activeID }),
              Set(catalog.workspaces.map(\.id)).count == catalog.workspaces.count else {
            throw AppError.message("工作空间配置无效，请检查 workspaces.json")
        }
        return catalog
    }

    func save(to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(self).write(to: url, options: .atomic)
    }

    func validated(_ profile: WorkspaceProfile) throws -> WorkspaceProfile {
        var result = profile
        result.name = result.name.trimmingCharacters(in: .whitespacesAndNewlines)
        result.summary = result.summary.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !result.name.isEmpty, result.name.count <= 60 else { throw AppError.message("工作空间名称需为 1–60 个字符") }
        guard result.summary.count <= 500 else { throw AppError.message("简介最多 500 个字符") }
        guard !workspaces.contains(where: { $0.id != result.id && $0.name.compare(result.name, options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame }) else {
            throw AppError.message("已存在同名工作空间")
        }
        guard WorkspaceProfile.symbols.contains(result.symbol), WorkspaceProfile.colors.contains(result.color) else {
            throw AppError.message("请选择有效的图标和颜色")
        }
        return result
    }

    mutating func remove(_ id: UUID) throws {
        guard workspaces.count > 1 else { throw AppError.message("至少需要保留一个工作空间") }
        guard let index = workspaces.firstIndex(where: { $0.id == id }) else { throw AppError.message("工作空间不存在") }
        removedWorkspaces.append(workspaces.remove(at: index))
        if activeID == id { activeID = workspaces[0].id }
    }
}
