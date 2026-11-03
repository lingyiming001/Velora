import AppKit
import SwiftUI

struct WorkspaceManagerView: View {
    @ObservedObject var services: ApplicationServices
    @Environment(\.dismiss) private var dismiss
    @State private var editing: WorkspaceProfile?
    @State private var creating = false
    @State private var deleting: WorkspaceProfile?
    @State private var error = ""
    @State private var importPlan: WorkspaceImportPlan?
    @State private var preparingImport = false
    @State private var confirmingDeleteAll = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 10) {
                Text(L10n.tr("管理工作空间")).font(.title2.bold())
                Spacer()
                Button { perform { try await services.refreshWorkspaces() } } label: { Image(systemName: "arrow.clockwise") }
                    .help(L10n.tr("刷新工作空间")).accessibilityLabel(L10n.tr("刷新工作空间"))
                Button(L10n.tr("导入工作空间"), systemImage: "square.and.arrow.down") { chooseImport() }
                Button(L10n.tr("新增工作空间"), systemImage: "plus") { creating = true }
                Menu {
                    Button(L10n.tr("全部删除"), role: .destructive) { confirmingDeleteAll = true }
                } label: { Image(systemName: "ellipsis") }
                    .menuStyle(.borderlessButton).fixedSize().help(L10n.tr("更多操作"))
                Button(L10n.tr("完成")) { dismiss() }.keyboardShortcut(.cancelAction)
            }
            Text(L10n.tr("每个工作空间拥有独立的页面、内容和回收箱。")).font(.callout).foregroundStyle(.secondary)
            ScrollView {
                LazyVStack(spacing: 12) {
                    ForEach(services.workspaces) { workspace in
                        VStack(alignment: .leading, spacing: 10) {
                            HStack(spacing: 12) {
                                Image(systemName: workspace.symbol).font(.title2).foregroundStyle(workspace.tint)
                                    .frame(width: 40, height: 40).background(workspace.tint.opacity(0.1), in: RoundedRectangle(cornerRadius: 10))
                                VStack(alignment: .leading, spacing: 4) {
                                    HStack {
                                        Text(workspace.name).font(.headline).lineLimit(1)
                                        if workspace.id == services.currentWorkspace?.id {
                                            Text(L10n.tr("当前")).font(.caption).foregroundStyle(workspace.tint)
                                        }
                                    }
                                    if !workspace.summary.isEmpty {
                                        Text(workspace.summary).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                                    }
                                }
                                Spacer()
                                if workspace.id != services.currentWorkspace?.id {
                                    Button(L10n.tr("切换")) { perform { try await services.switchWorkspace(workspace.id) } }
                                }
                                Button(L10n.tr("编辑")) { editing = workspace }
                                Button(L10n.tr("删除"), role: .destructive) { deleting = workspace }.disabled(services.workspaces.count <= 1)
                            }
                            Text(workspace.databasePath).font(.system(.caption2, design: .monospaced))
                                .foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle).textSelection(.enabled)
                            if !FileManager.default.fileExists(atPath: workspace.databasePath) {
                                Label(L10n.tr("数据库已移动或不存在，请重新选择存储目录或导入工作空间。"), systemImage: "exclamationmark.triangle")
                                    .font(.caption).foregroundStyle(.red)
                                Button(L10n.tr("选择移动后的存储目录…")) { services.chooseStorage() }
                            }
                            HStack {
                                Text(L10n.tr("创建于 ") + workspace.createdAt.formatted(Date.FormatStyle(date: .abbreviated, time: .omitted).locale(L10n.language.locale))).font(.caption).foregroundStyle(.secondary)
                                Spacer()
                                Button(L10n.tr("打开数据文件夹")) {
                                    NSWorkspace.shared.open(URL(fileURLWithPath: workspace.databasePath).deletingLastPathComponent())
                                }.font(.caption)
                            }
                        }.padding(14).background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 12))
                    }
                }
            }
            if !services.workspaceRefreshStatus.isEmpty { Text(services.workspaceRefreshStatus).font(.caption).foregroundStyle(.secondary) }
            if !error.isEmpty { Text(error).font(.callout).foregroundStyle(.red).textSelection(.enabled) }
            if services.busy { ProgressView(L10n.tr("正在保存并切换工作空间…")).controlSize(.small) }
            Text(L10n.tr("至少保留一个可用工作空间；全部删除时会创建新的空白空间。")).font(.caption).foregroundStyle(.secondary)
        }
        .padding(24).frame(width: 800, height: 580)
        .disabled(services.busy || preparingImport)
        .interactiveDismissDisabled(services.busy || preparingImport)
        .sheet(item: $importPlan) { plan in
            WorkspaceImportOptions(services: services, plan: plan) { message in error = message }
        }
        .sheet(isPresented: $creating) { WorkspaceProfileEditor(services: services, profile: nil) }
        .sheet(item: $editing) { WorkspaceProfileEditor(services: services, profile: $0) }
        .alert(L10n.tr("删除工作空间？"), isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } })) {
            Button(L10n.tr("取消"), role: .cancel) { deleting = nil }
            Button(L10n.tr("删除"), role: .destructive) {
                if let workspace = deleting { perform { try await services.deleteWorkspace(workspace.id) } }
                deleting = nil
            }
        } message: {
            Text(L10n.tr("「\(deleting?.name ?? "")」将移入应用内回收箱，数据保留，可随时恢复。删除当前空间时自动切换到其他空间。"))
        }
        .alert(L10n.tr("全部工作空间移入回收箱？"), isPresented: $confirmingDeleteAll) {
            Button(L10n.tr("取消"), role: .cancel) { }
            Button(L10n.tr("全部删除"), role: .destructive) { perform { try await services.deleteAllWorkspaces() } }
        } message: { Text(L10n.tr("当前所有工作空间移入回收箱，并创建新的空白空间继续使用。原空间可从回收箱恢复。")) }
    }

    private func chooseImport() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true; panel.canChooseFiles = true; panel.allowsMultipleSelection = true
        panel.message = L10n.tr("选择工作空间文件夹、总目录或 SQLite 文件")
        guard panel.runModal() == .OK, !panel.urls.isEmpty else { return }
        let urls = panel.urls
        preparingImport = true
        error = ""
        Task {
            defer { preparingImport = false }
            do { importPlan = try await services.prepareWorkspaceImport(from: urls) }
            catch { self.error = error.localizedDescription }
        }
    }

    private func perform(_ operation: @escaping @MainActor () async throws -> Void) {
        error = ""
        Task { do { try await operation() } catch { self.error = error.localizedDescription } }
    }
}

struct WorkspaceProfileEditor: View {
    @ObservedObject var services: ApplicationServices
    let profile: WorkspaceProfile?
    @Environment(\.dismiss) private var dismiss
    @State private var name: String
    @State private var summary: String
    @State private var symbol: String
    @State private var color: String
    @State private var error = ""
    @State private var saving = false

    init(services: ApplicationServices, profile: WorkspaceProfile?) {
        self.services = services
        self.profile = profile
        _name = State(initialValue: profile?.name ?? "")
        _summary = State(initialValue: profile?.summary ?? "")
        _symbol = State(initialValue: profile?.symbol ?? WorkspaceProfile.symbols[0])
        _color = State(initialValue: profile?.color ?? "indigo")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(profile == nil ? L10n.tr("新增工作空间") : L10n.tr("编辑工作空间")).font(.title2.bold())
            Form {
                TextField(L10n.tr("名称"), text: $name, prompt: Text(L10n.tr("例如：个人笔记、项目研发")))
                TextField(L10n.tr("简介"), text: $summary, prompt: Text(L10n.tr("工作空间的用途或说明")), axis: .vertical).lineLimit(3...5)
                Picker(L10n.tr("图标"), selection: $symbol) {
                    ForEach(WorkspaceProfile.symbols, id: \.self) { item in
                        Image(systemName: item).tag(item).accessibilityLabel(symbolLabel(item))
                    }
                }.pickerStyle(.segmented)
                Picker(L10n.tr("颜色"), selection: $color) {
                    Text(L10n.tr("鸢尾紫")).tag("indigo"); Text(L10n.tr("海洋蓝")).tag("blue"); Text(L10n.tr("森林绿")).tag("green")
                    Text(L10n.tr("暖橙")).tag("orange"); Text(L10n.tr("粉色")).tag("pink"); Text(L10n.tr("紫色")).tag("purple")
                }
            }
            if profile == nil {
                Text(L10n.tr("创建后自动切换到新空间。现有空间的内容会保留。")).font(.caption).foregroundStyle(.secondary)
            }
            if !error.isEmpty { Text(error).foregroundStyle(.red).font(.callout) }
            HStack {
                Spacer()
                Button(L10n.tr("取消")) { dismiss() }.keyboardShortcut(.cancelAction)
                Button(saving ? L10n.tr("正在保存…") : (profile == nil ? L10n.tr("创建并切换") : L10n.tr("保存"))) { save() }
                    .buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
                    .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }.padding(24).frame(width: 520)
            .disabled(saving || services.busy).interactiveDismissDisabled(saving)
    }

    private func symbolLabel(_ value: String) -> String {
        let labels = [L10n.tr("工作空间"), L10n.tr("工作"), L10n.tr("家庭"), L10n.tr("书籍"), L10n.tr("学习"), L10n.tr("创意"), L10n.tr("生活"), L10n.tr("收藏")]
        return labels[WorkspaceProfile.symbols.firstIndex(of: value) ?? 0]
    }

    private func save() {
        saving = true; error = ""
        Task {
            defer { saving = false }
            do {
                if var updated = profile {
                    updated.name = name; updated.summary = summary; updated.symbol = symbol; updated.color = color
                    try services.updateWorkspace(updated)
                } else {
                    try await services.createWorkspace(name: name, summary: summary, symbol: symbol, color: color)
                }
                dismiss()
            } catch { self.error = error.localizedDescription }
        }
    }
}

private struct WorkspaceImportOptions: View {
    @ObservedObject var services: ApplicationServices
    let plan: WorkspaceImportPlan
    let reportError: (String) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var policy: WorkspaceImportPolicy = .keep
    @State private var error = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(L10n.tr("导入工作空间")).font(.title2.bold())
            Text(L10n.format("已读取 %d 个工作空间", plan.contents.workspaces.count))
            if !plan.conflicts.isEmpty {
                Text(L10n.tr("发现相同 ID、名称或文件路径的工作空间。请选择重复处理策略："))
                ScrollView { Text(Array(Set(plan.conflicts)).sorted().joined(separator: "、")).textSelection(.enabled) }.frame(maxHeight: 100)
                Picker(L10n.tr("重复处理策略"), selection: $policy) {
                    ForEach(WorkspaceImportPolicy.allCases) { Text($0.label).tag($0) }
                }.pickerStyle(.segmented)
                Text(L10n.tr("保留：创建独立副本；跳过：不导入重复项；替换：更新已有空间，原数据库保留以便恢复。"))
                    .font(.caption).foregroundStyle(.secondary)
            } else {
                Text(L10n.tr("未发现重复空间，将保留名称并导入到当前存储目录。"))
            }
            if !error.isEmpty { Text(error).foregroundStyle(.red).textSelection(.enabled) }
            HStack {
                Spacer()
                Button(L10n.tr("取消")) { dismiss() }.keyboardShortcut(.cancelAction)
                Button(L10n.tr("导入")) {
                    Task {
                        do {
                            try await services.applyWorkspaceImport(plan, policy: policy)
                            reportError(""); dismiss()
                        } catch { self.error = error.localizedDescription }
                    }
                }.buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
            }
        }.padding(24).frame(width: 530)
        .disabled(services.busy).interactiveDismissDisabled(services.busy)
    }
}
