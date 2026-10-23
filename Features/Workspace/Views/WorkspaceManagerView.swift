import AppKit
import SwiftUI

struct WorkspaceManagerView: View {
    @ObservedObject var services: ApplicationServices
    @Environment(\.dismiss) private var dismiss
    @State private var editing: WorkspaceProfile?
    @State private var creating = false
    @State private var deleting: WorkspaceProfile?
    @State private var error = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text(L10n.tr("管理工作空间")).font(.title2.bold())
                Spacer()
                Button(L10n.tr("新增工作空间"), systemImage: "plus") { creating = true }
                Button(L10n.tr("完成")) { dismiss() }.keyboardShortcut(.cancelAction)
            }
            Text(L10n.tr("每个工作空间拥有独立的页面、内容和回收箱。")).foregroundStyle(.secondary)
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
                                    Text(workspace.summary.isEmpty ? L10n.tr("暂无简介") : workspace.summary)
                                        .font(.caption).foregroundStyle(.secondary).lineLimit(2)
                                }
                                Spacer()
                                if workspace.id != services.currentWorkspace?.id {
                                    Button(L10n.tr("切换")) { perform { try await services.switchWorkspace(workspace.id) } }
                                }
                                Button(L10n.tr("编辑")) { editing = workspace }
                                Button(L10n.tr("删除"), role: .destructive) { deleting = workspace }
                                    .disabled(services.workspaces.count <= 1)
                            }
                            Text(workspace.databasePath).font(.system(.caption2, design: .monospaced))
                                .foregroundStyle(.secondary).textSelection(.enabled)
                            HStack {
                                Text(L10n.tr("创建于 ") + workspace.createdAt.formatted(Date.FormatStyle(date: .abbreviated, time: .omitted).locale(L10n.language.locale))).font(.caption).foregroundStyle(.secondary)
                                Spacer()
                                Button(L10n.tr("打开数据文件夹")) {
                                    NSWorkspace.shared.open(URL(fileURLWithPath: workspace.databasePath).deletingLastPathComponent())
                                }.font(.caption)
                            }
                        }.padding(16).background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 12))
                    }
                }
            }
            if !error.isEmpty { Text(error).font(.callout).foregroundStyle(.red).textSelection(.enabled) }
            if services.busy { ProgressView(L10n.tr("正在保存并切换工作空间…")).controlSize(.small) }
            Text(L10n.tr("至少保留一个工作空间。删除后从列表移除，本地数据库文件保留，可通过上方路径找到。")).font(.caption).foregroundStyle(.secondary)
        }
        .padding(24).frame(width: 720, height: 560)
        .disabled(services.busy)
        .interactiveDismissDisabled(services.busy)
        .sheet(isPresented: $creating) { WorkspaceProfileEditor(services: services, profile: nil) }
        .sheet(item: $editing) { WorkspaceProfileEditor(services: services, profile: $0) }
        .alert(L10n.tr("删除工作空间？"), isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } })) {
            Button(L10n.tr("取消"), role: .cancel) { deleting = nil }
            Button(L10n.tr("删除"), role: .destructive) {
                if let workspace = deleting { perform { try await services.deleteWorkspace(workspace.id) } }
                deleting = nil
            }
        } message: {
            Text(L10n.tr("「\(deleting?.name ?? "")」将从工作空间列表移除，本地数据文件保留。删除当前空间时会自动切换到其他空间。"))
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
