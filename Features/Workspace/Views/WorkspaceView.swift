import SwiftUI

struct WorkspaceView: View {
    @ObservedObject var services: ApplicationServices
    @ObservedObject private var model: WorkspaceModel
    @AppStorage("appearance") private var appearance = "system"
    @AppStorage("accentColor") private var accent = "indigo"
    @Environment(\.openSettings) private var openSettings
    @State private var showingAssistant = false
    @State private var showingTransfer = false
    @State private var showingWorkspaces = false
    @State private var rootTargeted = false
    @State private var showingSearch = false
    @State private var showingTrash = false
    @State private var collapsed: Set<UUID> = []
    @State private var movingPage: Page?
    @State private var renamingPage: Page?
    @State private var newTitle = ""
    @State private var deletingPage: Page?
    @State private var confirmingEmpty = false
    @State private var dropTarget: UUID?
    @State private var filter = ""

    init(services: ApplicationServices, model: WorkspaceModel) {
        self.services = services
        self.model = model
    }

    private var colorScheme: ColorScheme? {
        switch appearance {
        case "light": .light
        case "dark": .dark
        default: nil
        }
    }

    private var tree: [(page: Page, depth: Int)] {
        let active = model.pages.filter { !$0.archived }
        var rows: [(Page, Int)] = []
        var visited: Set<UUID> = []
        func append(_ parent: UUID?, depth: Int) {
            for page in active where page.parentID == parent && !visited.contains(page.id) {
                visited.insert(page.id)
                let matches = filter.isEmpty || page.title.localizedCaseInsensitiveContains(filter)
                    || active.contains { $0.title.localizedCaseInsensitiveContains(filter) && model.isDescendant($0.id, of: page.id) }
                guard matches else { continue }
                rows.append((page, depth))
                if !collapsed.contains(page.id) || !filter.isEmpty { append(page.id, depth: depth + 1) }
            }
        }
        append(nil, depth: 0)
        return rows
    }

    var body: some View {
        NavigationSplitView {
            sidebar.navigationSplitViewColumnWidth(min: 220, ideal: 270, max: 360)
                .disabled(model.automationBusy)
        } detail: {
            if showingTrash {
                trash
            } else if let page = model.selectedPage, !page.archived {
                PageEditorView(model: model, page: page).id(page.id).disabled(model.automationBusy)
            } else {
                ContentUnavailableView {
                    Label("开始整理你的想法", systemImage: "square.and.pencil")
                } description: { Text("新建页面，或从侧边栏选择已有页面。") }
                actions: { Button("新建页面") { model.createPage() }.buttonStyle(.borderedProminent) }
            }
        }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button { showingTransfer = true } label: { Label("导入与导出", systemImage: "arrow.up.arrow.down.square") }
                    .disabled(model.automationBusy)
            }
            ToolbarItem(placement: .primaryAction) {
                Button { showingAssistant = true } label: { Label("助手与语音", systemImage: "sparkles") }
                    .keyboardShortcut("j", modifiers: .command)
            }
            ToolbarItem(placement: .primaryAction) {
                Button { showingSearch = true } label: { Label("搜索", systemImage: "magnifyingglass") }
                    .keyboardShortcut("p", modifiers: .command)
            }
            ToolbarItem(placement: .primaryAction) {
                Button { showingTrash = false; model.createPage() } label: { Label("新建页面", systemImage: "plus") }
                    .keyboardShortcut("n", modifiers: .command)
            }
        }
        .sheet(isPresented: $showingTransfer) { TransferPanel(services: services, pageID: model.selectedPageID) }
        .sheet(isPresented: $showingWorkspaces) { WorkspaceManagerView(services: services) }
        .sheet(isPresented: $showingAssistant) { AssistantPanel(services: services) }
        .sheet(isPresented: $showingSearch) { SearchPanel(model: model, isPresented: $showingSearch) }
        .sheet(item: $movingPage) { page in MovePagePanel(model: model, page: page) }
        .alert("重命名页面", isPresented: Binding(get: { renamingPage != nil }, set: { if !$0 { renamingPage = nil } })) {
            TextField("页面名称", text: $newTitle)
            Button("取消", role: .cancel) { renamingPage = nil }
            Button("保存") {
                if let page = renamingPage { model.rename(page, to: newTitle) }
                renamingPage = nil
            }
        }
        .alert("永久删除页面？", isPresented: Binding(get: { deletingPage != nil }, set: { if !$0 { deletingPage = nil } })) {
            Button("取消", role: .cancel) { deletingPage = nil }
            Button("永久删除", role: .destructive) {
                if let page = deletingPage { model.permanentlyDelete(page) }
                deletingPage = nil
            }
        } message: { Text("此页面及其所有子页面和内容将被永久删除，无法恢复。") }
        .alert("清空回收箱？", isPresented: $confirmingEmpty) {
            Button("取消", role: .cancel) { }
            Button("清空回收箱", role: .destructive) { model.emptyTrash() }
        } message: { Text("回收箱内的所有页面和内容将被永久删除，无法恢复。") }
        .alert("操作失败", isPresented: Binding(get: { model.errorMessage != nil }, set: { if !$0 { model.errorMessage = nil } })) {
            Button("知道了") { model.errorMessage = nil }
        } message: { Text(model.errorMessage ?? "未知错误") }
        .onChange(of: model.selectedPageID) { _, id in
            if id != nil { showingTrash = false }
            revealSelection()
        }
        .onChange(of: model.pages) { _, _ in revealSelection() }
        .tint(accent == "blue" ? .blue : accent == "green" ? .green : accent == "orange" ? .orange : .indigo)
        .preferredColorScheme(colorScheme)
        .frame(minWidth: 760, minHeight: 520)
    }

    private func revealSelection() {
        guard let selected = model.selectedPageID else { return }
        var current = model.pages.first(where: { $0.id == selected })?.parentID
        var visited: Set<UUID> = []
        while let id = current, visited.insert(id).inserted {
            collapsed.remove(id)
            current = model.pages.first(where: { $0.id == id })?.parentID
        }
    }

    private var sidebar: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Menu {
                    ForEach(services.workspaces) { workspace in
                        Button {
                            Task {
                                do { try await services.switchWorkspace(workspace.id) }
                                catch { model.errorMessage = error.localizedDescription }
                            }
                        } label: {
                            Label(workspace.name, systemImage: workspace.id == services.currentWorkspace?.id ? "checkmark" : workspace.symbol)
                        }
                    }
                    Divider()
                    Button("管理工作空间…", systemImage: "square.stack.3d.up") { showingWorkspaces = true }
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: services.currentWorkspace?.symbol ?? "square.stack.3d.up.fill")
                            .foregroundStyle(services.currentWorkspace?.tint ?? .indigo)
                        Text(services.currentWorkspace?.name ?? "Velora").font(.headline).lineLimit(1)
                    }
                }.menuStyle(.borderlessButton).help("切换或管理工作空间")
                Spacer()
                Button { showingTrash = false; model.createPage() } label: { Image(systemName: "square.and.pencil") }
                    .buttonStyle(.plain).help("新建页面 ⌘N")
            }.padding(16)
            TextField("筛选页面", text: $filter).textFieldStyle(.roundedBorder).padding(.horizontal, 12).padding(.bottom, 10)
            List(selection: Binding<UUID?>(get: { showingTrash ? nil : model.selectedPageID }, set: { id in
                showingTrash = false
                Task { await model.flushAll(); model.select(id) }
            })) {
                Section("页面") {
                    ForEach(tree, id: \.page.id) { item in
                        pageRow(item.page, depth: item.depth).tag(item.page.id)
                    }
                }
                if tree.isEmpty { Text(filter.isEmpty ? "暂无页面" : "没有匹配页面").foregroundStyle(.tertiary) }
            }.listStyle(.sidebar)
            Label(rootTargeted ? "松开以移到顶层" : "拖到这里移出到顶层", systemImage: "arrow.up.to.line")
                .font(.caption).foregroundStyle(rootTargeted ? Color.accentColor : .secondary)
                .frame(maxWidth: .infinity, minHeight: 34)
                .background(rootTargeted ? Color.accentColor.opacity(0.1) : .clear, in: RoundedRectangle(cornerRadius: 6))
                .contentShape(Rectangle())
                .dropDestination(for: String.self) { items, _ in
                    guard let raw = items.first, raw.hasPrefix("velora-page:"),
                          let id = UUID(uuidString: String(raw.dropFirst(12))),
                          let page = model.pages.first(where: { $0.id == id && !$0.archived }) else { return false }
                    model.move(page, to: nil)
                    return true
                } isTargeted: { rootTargeted = $0 }
                .padding(.horizontal, 10)
            Divider()
            Button {
                Task { await model.flushAll(); showingTrash = true }
            } label: {
                HStack {
                    Label("回收箱", systemImage: showingTrash ? "trash.fill" : "trash")
                    Spacer()
                    if !model.trashedPages.isEmpty {
                        Text("\(model.trashedPages.count)").font(.caption).monospacedDigit().foregroundStyle(.secondary)
                    }
                }
                .padding(10).contentShape(Rectangle())
                .background(showingTrash ? Color.primary.opacity(0.06) : .clear, in: RoundedRectangle(cornerRadius: 8))
            }.buttonStyle(.plain).padding(.horizontal, 8).padding(.top, 8)
            Button { openSettings() } label: {
                Label("设置", systemImage: "gearshape").frame(maxWidth: .infinity, alignment: .leading)
                    .padding(10).contentShape(Rectangle())
            }.buttonStyle(.plain).padding(.horizontal, 8).padding(.bottom, 8)
        }
    }

    private func pageRow(_ page: Page, depth: Int) -> some View {
        let hasChildren = model.pages.contains { !$0.archived && $0.parentID == page.id }
        return HStack(spacing: 6) {
            Button {
                if collapsed.contains(page.id) { collapsed.remove(page.id) } else { collapsed.insert(page.id) }
            } label: {
                Image(systemName: collapsed.contains(page.id) ? "chevron.right" : "chevron.down")
                    .font(.system(size: 9, weight: .semibold)).frame(width: 14, height: 22)
            }.buttonStyle(.plain).opacity(hasChildren ? 1 : 0).disabled(!hasChildren)
                .accessibilityLabel(collapsed.contains(page.id) ? "展开子页面" : "收起子页面")
            Image(systemName: "doc.text").foregroundStyle(.secondary)
            Text(page.title.isEmpty ? "未命名" : page.title).lineLimit(1)
            Spacer(minLength: 0)
            if page.parentID != nil {
                Button {
                    let parent = model.pages.first(where: { $0.id == page.parentID })
                    model.move(page, to: parent?.parentID)
                } label: { Image(systemName: "arrow.turn.up.left").font(.system(size: 10)) }
                .buttonStyle(.plain).help("移出一级")
            }
            Menu { pageActions(page) } label: { Image(systemName: "ellipsis") }
                .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize().help("页面操作")
        }
        .padding(.leading, CGFloat(min(depth, 12)) * 14)
        .padding(.vertical, 3).contentShape(Rectangle())
        .background(dropTarget == page.id ? Color.accentColor.opacity(0.14) : .clear, in: RoundedRectangle(cornerRadius: 6))
        .overlay {
            if dropTarget == page.id {
                RoundedRectangle(cornerRadius: 6).strokeBorder(Color.accentColor, lineWidth: 1)
                    .allowsHitTesting(false)
            }
        }
        .help("拖到此页面上，成为它的子页面；排序请使用页面菜单的上移/下移")
        .contextMenu { pageActions(page) }
        .draggable("velora-page:\(page.id.uuidString)")
        .dropDestination(for: String.self) { items, _ in
            guard let raw = items.first, raw.hasPrefix("velora-page:"),
                  let id = UUID(uuidString: String(raw.dropFirst(12))), id != page.id,
                  let source = model.pages.first(where: { $0.id == id && !$0.archived }),
                  !model.isDescendant(page.id, of: id) else { return false }
            collapsed.remove(page.id)
            model.move(source, to: page.id)
            return true
        } isTargeted: { dropTarget = $0 ? page.id : nil }
    }

    @ViewBuilder private func pageActions(_ page: Page) -> some View {
        Button("重命名…") { newTitle = page.title; renamingPage = page }
        Button("新建子页面") { collapsed.remove(page.id); model.createPage(parentID: page.id) }
        Divider()
        Button("上移") { model.move(page, by: -1) }
            .disabled(model.pages.first(where: { !$0.archived && $0.parentID == page.parentID })?.id == page.id)
        Button("下移") { model.move(page, by: 1) }
            .disabled(model.pages.last(where: { !$0.archived && $0.parentID == page.parentID })?.id == page.id)
        Button("移动到…") { movingPage = page }
        if page.parentID != nil {
            Button("移出一级") {
                let parent = model.pages.first(where: { $0.id == page.parentID })
                model.move(page, to: parent?.parentID)
            }
            Button("移到顶层") { model.move(page, to: nil) }
        }
        Divider()
        Button("移到回收箱", role: .destructive) { model.archive(page) }
    }

    private var trash: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack {
                VStack(alignment: .leading, spacing: 6) {
                    Text("回收箱").font(.largeTitle.bold())
                    Text("页面保留在此，直到你恢复或永久删除。").foregroundStyle(.secondary)
                }
                Spacer()
                Button("清空回收箱", role: .destructive) { confirmingEmpty = true }.disabled(model.trashedPages.isEmpty)
            }.padding(.horizontal, 28).padding(.top, 28)
            if model.trashedPages.isEmpty {
                ContentUnavailableView("回收箱为空", systemImage: "trash", description: Text("删除的页面会出现在这里。"))
            } else {
                List(model.trashedPages) { page in
                    HStack(spacing: 12) {
                        Image(systemName: "doc.text").foregroundStyle(.secondary)
                        VStack(alignment: .leading, spacing: 5) {
                            Text(page.title.isEmpty ? "未命名" : page.title).fontWeight(.medium)
                            Text(page.updatedAt, style: .date).font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button("恢复") { model.restore(page) }.buttonStyle(.bordered)
                        Button { deletingPage = page } label: { Image(systemName: "trash") }
                            .buttonStyle(.borderless).help("永久删除").accessibilityLabel("永久删除页面")
                    }.padding(.vertical, 8)
                }.listStyle(.inset)
            }
        }.navigationTitle("回收箱")
    }
}

private struct MovePagePanel: View {
    @ObservedObject var model: WorkspaceModel
    let page: Page
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("移动“\(page.title.isEmpty ? "未命名" : page.title)”").font(.title3.bold())
            Text("选择目标页面，当前页面及其子页面会一起移动。").font(.caption).foregroundStyle(.secondary)
            TextField("搜索目标页面", text: $query).textFieldStyle(.roundedBorder)
            List {
                Button { model.move(page, to: nil); dismiss() } label: { Label("工作区顶层", systemImage: "square.stack") }
                    .buttonStyle(.plain).padding(.vertical, 6)
                ForEach(model.pages.filter { !$0.archived && !model.isDescendant($0.id, of: page.id) && (query.isEmpty || $0.title.localizedCaseInsensitiveContains(query)) }) { target in
                    Button { model.move(page, to: target.id); dismiss() } label: {
                        Label(target.title.isEmpty ? "未命名" : target.title, systemImage: "doc.text")
                            .frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
                    }.buttonStyle(.plain).padding(.vertical, 6)
                }
            }.listStyle(.inset)
            HStack { Spacer(); Button("取消", role: .cancel) { dismiss() }.keyboardShortcut(.cancelAction) }
        }.padding(24).frame(width: 460, height: 430)
    }
}
