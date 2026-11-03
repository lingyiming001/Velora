import SwiftUI
import UniformTypeIdentifiers

struct WorkspaceActions {
    let newPage: () -> Void
    let search: () -> Void
    let findInDocument: ((DocumentFindAction) -> Void)?
    let rename: (() -> Void)?
    let move: (() -> Void)?
    let expandAll: () -> Void
    let collapseAll: () -> Void
}
private struct WorkspaceActionsKey: FocusedValueKey { typealias Value = WorkspaceActions }
extension FocusedValues {
    var workspaceActions: WorkspaceActions? {
        get { self[WorkspaceActionsKey.self] }
        set { self[WorkspaceActionsKey.self] = newValue }
    }
}

struct WorkspaceMenuCommands: Commands {
    @FocusedValue(\.workspaceActions) private var actions
    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button(L10n.tr("新建页面")) { actions?.newPage() }
                .keyboardShortcut("n").disabled(actions == nil)
        }
        CommandGroup(after: .textEditing) {
            Button(L10n.tr("在文档中查找…")) { actions?.findInDocument?(.show) }
                .keyboardShortcut("f").disabled(actions?.findInDocument == nil)
            Button(L10n.tr("查找并替换…")) { actions?.findInDocument?(.replace) }
                .keyboardShortcut("f", modifiers: [.command, .option]).disabled(actions?.findInDocument == nil)
            Button(L10n.tr("下一个匹配项")) { actions?.findInDocument?(.next) }
                .keyboardShortcut("g").disabled(actions?.findInDocument == nil)
            Button(L10n.tr("上一个匹配项")) { actions?.findInDocument?(.previous) }
                .keyboardShortcut("g", modifiers: [.command, .shift]).disabled(actions?.findInDocument == nil)
            Button(L10n.tr("搜索页面…")) { actions?.search() }
                .keyboardShortcut("f", modifiers: [.command, .shift]).disabled(actions == nil)
        }
        CommandMenu(L10n.tr("页面")) {
            Button(L10n.tr("重命名…")) { actions?.rename?() }
                .keyboardShortcut("r", modifiers: [.command, .shift]).disabled(actions?.rename == nil)
            Button(L10n.tr("移动到…")) { actions?.move?() }
                .keyboardShortcut("m", modifiers: [.command, .control]).disabled(actions?.move == nil)
            Divider()
            Button(L10n.tr("全部展开")) { actions?.expandAll() }.disabled(actions == nil)
            Button(L10n.tr("全部折叠")) { actions?.collapseAll() }.disabled(actions == nil)
        }
    }
}

enum PageDropPlacement: Equatable { case before, child, after }

/// Keep native List keyboard selection/accessibility, but draw the document's
/// quiet rounded selection ourselves instead of the system blue row highlight.
struct SidebarSelectionAppearance: NSViewRepresentable {
    func makeNSView(context: Context) -> SidebarSelectionAppearanceView { SidebarSelectionAppearanceView() }
    func updateNSView(_ view: SidebarSelectionAppearanceView, context: Context) { view.applyStyle() }
}
final class SidebarSelectionAppearanceView: NSView {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        applyStyle()
        DispatchQueue.main.async { [weak self] in self?.applyStyle() }
    }
    func applyStyle() {
        var parent = superview
        while let view = parent {
            if let table = view as? NSTableView {
                if table.selectionHighlightStyle != .none { table.selectionHighlightStyle = .none }
                return
            }
            parent = view.superview
        }
    }
}
struct PageDropIndicator: Equatable {
    let pageID: UUID
    let placement: PageDropPlacement
}

@MainActor
final class PageDragState: ObservableObject {
    @Published private(set) var sourceID: UUID?
    @Published private var currentIndicator: PageDropIndicator?
    var indicator: PageDropIndicator? {
        get { currentIndicator }
        set { if newValue != currentIndicator { currentIndicator = newValue } }
    }
    private var session = UUID()
    private var timer: Timer?

    func begin(_ id: UUID, mouseIsDown: @escaping () -> Bool = { NSEvent.pressedMouseButtons & 1 != 0 }) {
        finish()
        session = UUID()
        sourceID = id
        // SwiftUI onDrag has no cancellation callback. Observe release even
        // when the session ends outside every drop destination or with Escape.
        let timer = Timer(timeInterval: 0.08, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                if !mouseIsDown() { self?.finishAfterTracking() }
            }
        }
        self.timer = timer
        RunLoop.main.add(timer, forMode: .common)
    }
    func finishAfterTracking() {
        timer?.invalidate(); timer = nil
        let expected = session
        RunLoop.main.perform(inModes: [.default]) { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.session == expected else { return }
                self.finish()
            }
        }
    }
    func finish() {
        timer?.invalidate(); timer = nil
        indicator = nil
        if sourceID != nil { sourceID = nil }
    }
    deinit { timer?.invalidate() }
}

/// Rebuilt only when page metadata changes, never for editor/autosave publications.
struct SidebarPageIndex {
    let children: [UUID?: [Page]]
    let byID: [UUID: Page]
    init(pages: [Page]) {
        let active = pages.filter { !$0.archived }
        children = Dictionary(grouping: active, by: \.parentID)
        byID = Dictionary(uniqueKeysWithValues: active.map { ($0.id, $0) })
    }
    func rows(filter: String, collapsed: Set<UUID>) -> [(page: Page, depth: Int)] {
        var matching: Set<UUID> = []
        if !filter.isEmpty {
            for page in byID.values where page.title.localizedCaseInsensitiveContains(filter) {
                var current: UUID? = page.id
                while let id = current, matching.insert(id).inserted { current = byID[id]?.parentID }
            }
        }
        var rows: [(page: Page, depth: Int)] = []
        var pending = (children[nil] ?? []).reversed().map { (page: $0, depth: 0) }
        var visited: Set<UUID> = []
        while let item = pending.popLast() {
            guard visited.insert(item.page.id).inserted,
                  filter.isEmpty || matching.contains(item.page.id) else { continue }
            rows.append(item)
            if !collapsed.contains(item.page.id) || !filter.isEmpty {
                for child in (children[item.page.id] ?? []).reversed() {
                    pending.append((child, item.depth + 1))
                }
            }
        }
        return rows
    }
}

@MainActor
final class SidebarExpansionState: ObservableObject {
    private let defaults: UserDefaults
    private let key: String
    @Published var collapsed: Set<UUID> {
        didSet { defaults.set(collapsed.map(\.uuidString).sorted(), forKey: key) }
    }
    init(workspaceID: String, defaults: UserDefaults = .standard) {
        self.defaults = defaults
        key = "sidebar.collapsedPages." + workspaceID
        collapsed = Set((defaults.stringArray(forKey: key) ?? []).compactMap(UUID.init(uuidString:)))
    }
    private var cachedRevision: UUID?
    private var cachedFilter = ""
    private var cachedCollapsed: Set<UUID> = []
    private var cachedRows: [(page: Page, depth: Int)] = []
    private(set) var treeBuildCount = 0
    func visibleRows(index: SidebarPageIndex, revision: UUID, filter: String) -> [(page: Page, depth: Int)] {
        if cachedRevision != revision || cachedFilter != filter || cachedCollapsed != collapsed {
            cachedRows = index.rows(filter: filter, collapsed: collapsed)
            cachedRevision = revision; cachedFilter = filter; cachedCollapsed = collapsed
            treeBuildCount += 1
        }
        return cachedRows
    }
    func expandAll() { collapsed = [] }
    func collapseAll(_ pages: [Page]) {
        let active = pages.filter { !$0.archived }
        let ids = Set(active.map(\.id))
        collapsed = Set(active.compactMap(\.parentID)).intersection(ids)
    }
    func reveal(_ selected: UUID?, in pages: [Page]) {
        guard let selected else { return }
        let parents = Dictionary(uniqueKeysWithValues: pages.map { ($0.id, $0) })
        var current = parents[selected]?.parentID
        var next = collapsed
        var visited: Set<UUID> = []
        while let id = current, visited.insert(id).inserted {
            next.remove(id)
            current = parents[id]?.parentID
        }
        if next != collapsed { collapsed = next }
    }
}

private struct PageRowDropDelegate: DropDelegate {
    let pageID: UUID
    let sourceID: UUID?
    let validTarget: Bool
    @Binding var indicator: PageDropIndicator?
    let perform: (UUID, UUID, PageDropPlacement) -> Bool

    private func placement(_ info: DropInfo) -> PageDropPlacement {
        if info.location.y < 10 { return .before }
        if info.location.y > 24 { return .after }
        return .child
    }
    func validateDrop(info: DropInfo) -> Bool { sourceID != nil && sourceID != pageID && validTarget }
    func dropEntered(info: DropInfo) {
        guard validateDrop(info: info) else { indicator = nil; return }
        indicator = PageDropIndicator(pageID: pageID, placement: placement(info))
    }
    func dropUpdated(info: DropInfo) -> DropProposal? {
        guard validateDrop(info: info) else { indicator = nil; return DropProposal(operation: .forbidden) }
        indicator = PageDropIndicator(pageID: pageID, placement: placement(info))
        return DropProposal(operation: .move)
    }
    func dropExited(info: DropInfo) { if indicator?.pageID == pageID { indicator = nil } }
    func performDrop(info: DropInfo) -> Bool {
        guard validateDrop(info: info), let sourceID else { return false }
        return perform(sourceID, pageID, placement(info))
    }
}

struct WorkspaceView: View {
    @ObservedObject var services: ApplicationServices
    @ObservedObject private var model: WorkspaceModel
    @AppStorage("appearance") private var appearance = "system"
    @AppStorage("accentColor") private var accent = "indigo"
    @Environment(\.openSettings) private var openSettings
    @State private var showingAssistant = false
    @State private var showingTransfer = false
    @State private var showingWorkspaces = false
    @State private var creatingWorkspace = false
    @State private var rootTargeted = false
    @State private var showingSearch = false
    @State private var showingTrash = false
    @StateObject private var expansion: SidebarExpansionState
    @State private var movingPage: Page?
    @State private var renamingPage: Page?
    @State private var newTitle = ""
    @State private var deletingPage: Page?
    @State private var confirmingEmpty = false
    @State private var permanentlyDeletingWorkspace: WorkspaceProfile?
    @StateObject private var pageDrag = PageDragState()
    @State private var filter = ""

    init(services: ApplicationServices, model: WorkspaceModel) {
        self.services = services
        self.model = model
        _expansion = StateObject(wrappedValue: SidebarExpansionState(workspaceID: services.currentWorkspace?.id.uuidString ?? "default"))
    }

    private var colorScheme: ColorScheme? {
        switch appearance {
        case "light": .light
        case "dark": .dark
        default: nil
        }
    }

    private var tree: [(page: Page, depth: Int)] {
        expansion.visibleRows(index: model.sidebarPageIndex, revision: model.sidebarPageRevision, filter: filter)
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
                    Label(L10n.tr("开始整理你的想法"), systemImage: "square.and.pencil")
                } description: { Text(L10n.tr("新建页面，或从侧边栏选择已有页面。")) }
                actions: { Button(L10n.tr("新建页面")) { model.createPage() }.buttonStyle(.borderedProminent) }
            }
        }
        .disabled(services.busy)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                HStack(spacing: 4) {
                    Button { showingAssistant = true } label: { Label("AI", systemImage: "sparkles") }
                        .frame(width: 28, height: 28).accessibilityLabel("AI").help("AI · ⌘J")
                        .keyboardShortcut("j", modifiers: .command)
                    Button { showingTransfer = true } label: { Label(L10n.tr("导出"), systemImage: "square.and.arrow.up") }
                        .frame(width: 28, height: 28).accessibilityLabel(L10n.tr("导出")).help(L10n.tr("导出"))
                        .disabled(model.automationBusy)
                }
                .labelStyle(.iconOnly).buttonStyle(.plain).controlSize(.small)
                .font(.system(size: 14, weight: .medium)).foregroundStyle(.secondary).tint(.primary)
                .padding(.horizontal, 4)
            }
        }
        .focusedSceneValue(\.workspaceActions, menuActions)
        .sheet(isPresented: $showingTransfer) { TransferPanel(services: services, pageID: model.selectedPageID) }
        .sheet(isPresented: $showingWorkspaces) { WorkspaceManagerView(services: services) }
        .sheet(isPresented: $creatingWorkspace) { WorkspaceProfileEditor(services: services, profile: nil) }
        .sheet(isPresented: $showingAssistant) { AssistantPanel(services: services) }
        .sheet(isPresented: $showingSearch) { SearchPanel(model: model, isPresented: $showingSearch) }
        .sheet(item: $movingPage) { page in
            MovePagePanel(model: model, services: services, page: page, onMove: { target in
                if let target {
                    expansion.collapsed.remove(target)
                    expansion.reveal(target, in: model.pages)
                }
            })
        }
        .alert(L10n.tr("重命名页面"), isPresented: Binding(get: { renamingPage != nil }, set: { if !$0 { renamingPage = nil } })) {
            TextField(L10n.tr("页面名称"), text: $newTitle)
            Button(L10n.tr("取消"), role: .cancel) { renamingPage = nil }
            Button(L10n.tr("保存")) {
                if let page = renamingPage { model.rename(page, to: newTitle) }
                renamingPage = nil
            }
        }
        .alert(L10n.tr("永久删除页面？"), isPresented: Binding(get: { deletingPage != nil }, set: { if !$0 { deletingPage = nil } })) {
            Button(L10n.tr("取消"), role: .cancel) { deletingPage = nil }
            Button(L10n.tr("永久删除"), role: .destructive) {
                if let page = deletingPage { model.permanentlyDelete(page) }
                deletingPage = nil
            }
        } message: { Text(L10n.tr("此页面及其所有子页面和内容将被永久删除，无法恢复。")) }
        .alert(L10n.tr("清空回收箱？"), isPresented: $confirmingEmpty) {
            Button(L10n.tr("取消"), role: .cancel) { }
            Button(L10n.tr("全部删除"), role: .destructive) {
                performTrashOperation { try await services.emptyWorkspaceTrash(); model.emptyTrash() }
            }
        } message: { Text(L10n.tr("回收箱中的工作空间文件夹及当前空间的已删除文档将被永久删除，无法恢复。")) }
        .alert(L10n.tr("永久删除工作空间？"), isPresented: Binding(get: { permanentlyDeletingWorkspace != nil }, set: { if !$0 { permanentlyDeletingWorkspace = nil } })) {
            Button(L10n.tr("取消"), role: .cancel) { permanentlyDeletingWorkspace = nil }
            Button(L10n.tr("永久删除"), role: .destructive) {
                if let target = permanentlyDeletingWorkspace { performTrashOperation { try await services.permanentlyDeleteWorkspace(target.id) } }
                permanentlyDeletingWorkspace = nil
            }
        } message: { Text(L10n.tr("整个工作空间文件夹将被永久删除，无法恢复。")) }
        .alert(L10n.tr("操作失败"), isPresented: Binding(get: { model.errorMessage != nil }, set: { if !$0 { model.errorMessage = nil } })) {
            Button(L10n.tr("知道了")) { model.errorMessage = nil }
        } message: { Text(model.errorMessage ?? L10n.tr("未知错误")) }
        .onChange(of: model.selectedPageID) { _, id in
            if id != nil { showingTrash = false }
            revealSelection()
        }
        .onDisappear { pageDrag.finish() }
        .onChange(of: pageDrag.sourceID) { _, id in if id == nil { rootTargeted = false } }
        .tint(accent == "blue" ? .blue : accent == "green" ? .green : accent == "orange" ? .orange : .indigo)
        .preferredColorScheme(colorScheme)
        .frame(minWidth: 760, minHeight: 520)
    }

    private var menuActions: WorkspaceActions? {
        guard !model.automationBusy && !services.busy,
              !showingTransfer, !showingAssistant, !showingSearch, !showingWorkspaces, !creatingWorkspace,
              movingPage == nil, renamingPage == nil, deletingPage == nil, !confirmingEmpty else { return nil }
        let selected = showingTrash ? nil : model.pages.first { $0.id == model.selectedPageID && !$0.archived }
        let findAction: ((DocumentFindAction) -> Void)? = selected == nil ? nil : { action in model.performDocumentFind(action) }
        return WorkspaceActions(newPage: { showingTrash = false; model.createPage() },
            search: { showingSearch = true },
            findInDocument: findAction,
            rename: selected.map { page in { newTitle = page.title; renamingPage = page } },
            move: selected.map { page in { movingPage = page } },
            expandAll: expansion.expandAll, collapseAll: { expansion.collapseAll(model.pages) })
    }

    private func revealSelection() {
        expansion.reveal(model.selectedPageID, in: model.pages)
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
                    Button(L10n.tr("刷新工作空间"), systemImage: "arrow.clockwise") {
                        Task {
                            do { try await services.refreshWorkspaces() }
                            catch { model.errorMessage = error.localizedDescription }
                        }
                    }.disabled(services.busy)
                    Button(L10n.tr("管理工作空间…"), systemImage: "square.stack.3d.up") { showingWorkspaces = true }
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: services.currentWorkspace?.symbol ?? "square.stack.3d.up.fill")
                            .foregroundStyle(services.currentWorkspace?.tint ?? .indigo)
                        Text(services.currentWorkspace?.name ?? "Velora").font(.headline).lineLimit(1)
                    }
                }.menuStyle(.borderlessButton).help(L10n.tr("切换或管理工作空间"))
                Spacer()
                Button { showingTrash = false; model.createPage() } label: { Image(systemName: "square.and.pencil") }
                    .buttonStyle(.plain).help(L10n.tr("新建页面 ⌘N"))
            }.padding(16)
            TextField(L10n.tr("筛选页面"), text: $filter).textFieldStyle(.roundedBorder).padding(.horizontal, 12).padding(.bottom, 10)
            List(selection: Binding<UUID?>(get: { showingTrash ? nil : model.selectedPageID }, set: { id in
                // AppKit may transiently clear List selection when a row control
                // or drag gesture takes focus. That is not a request to close a page.
                guard let id else { return }
                openPage(id)
            })) {
                Section {
                    ForEach(tree, id: \.page.id) { item in
                        pageRow(item.page, depth: item.depth).tag(item.page.id)
                            .listRowInsets(EdgeInsets(top: 2, leading: -14, bottom: 2, trailing: -6))
                    }
                } header: {
                    HStack {
                        Text(L10n.tr("页面"))
                        Spacer()
                        Menu {
                            Button(L10n.tr("全部展开"), systemImage: "chevron.down.2") { expansion.expandAll() }
                            Button(L10n.tr("全部折叠"), systemImage: "chevron.up.2") { expansion.collapseAll(model.pages) }
                        } label: { Image(systemName: "ellipsis").frame(width: 28, height: 28).contentShape(Rectangle()) }
                        .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                        .help(L10n.tr("页面树操作"))
                        .accessibilityLabel(L10n.tr("页面树操作"))
                    }.padding(.trailing, 14)
                }
                if tree.isEmpty { Text(filter.isEmpty ? L10n.tr("暂无页面") : L10n.tr("没有匹配页面")).foregroundStyle(.tertiary) }
            }.listStyle(.sidebar)
            .transaction { $0.animation = nil }
            if pageDrag.sourceID != nil {
            Label(rootTargeted ? L10n.tr("松开以移到顶层") : L10n.tr("拖到这里移出到顶层"), systemImage: "arrow.up.to.line")
                .font(.caption).foregroundStyle(rootTargeted ? Color.accentColor : .secondary)
                .frame(maxWidth: .infinity, minHeight: 34)
                .background(rootTargeted ? Color.accentColor.opacity(0.1) : .clear, in: RoundedRectangle(cornerRadius: 6))
                .contentShape(Rectangle())
                .dropDestination(for: String.self) { items, _ in
                    guard let raw = items.first, raw.hasPrefix("velora-page:"),
                          let id = UUID(uuidString: String(raw.dropFirst(12))),
                          let page = model.pages.first(where: { $0.id == id && !$0.archived }) else { return false }
                    guard pageDrag.sourceID == id else { return false }
                    pageDrag.finishAfterTracking()
                    model.move(page, to: nil)
                    return true
                } isTargeted: { rootTargeted = $0 }
                .padding(.horizontal, 10)
            }
            Button { creatingWorkspace = true } label: {
                Label(L10n.tr("新建工作空间"), systemImage: "plus")
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(10).contentShape(Rectangle())
            }
            .buttonStyle(.plain).padding(.horizontal, 8).padding(.vertical, 4)
            Divider()
            Button {
                Task { await model.flushAll(); showingTrash = true }
            } label: {
                HStack {
                    Label(L10n.tr("回收箱"), systemImage: showingTrash ? "trash.fill" : "trash")
                    Spacer()
                    if !model.trashedPages.isEmpty || !services.trashedWorkspaces.isEmpty {
                        Text("\(model.trashedPages.count + services.trashedWorkspaces.count)").font(.caption).monospacedDigit().foregroundStyle(.secondary)
                    }
                }
                .padding(10).contentShape(Rectangle())
                .background(showingTrash ? Color.primary.opacity(0.06) : .clear, in: RoundedRectangle(cornerRadius: 8))
            }.buttonStyle(.plain).padding(.horizontal, 8).padding(.top, 8)
            Button { openSettings() } label: {
                Label(L10n.tr("设置"), systemImage: "gearshape").frame(maxWidth: .infinity, alignment: .leading)
                    .padding(10).contentShape(Rectangle())
            }.buttonStyle(.plain).padding(.horizontal, 8).padding(.bottom, 8)
        }
    }

    private func openPage(_ id: UUID) {
        pageDrag.finish()
        rootTargeted = false
        showingTrash = false
        model.select(id)
    }

    private func pageRow(_ page: Page, depth: Int) -> some View {
        let hasChildren = model.sidebarPageIndex.children[page.id]?.isEmpty == false
        let active = model.selectedPageID == page.id && !showingTrash
        return HStack(spacing: 6) {
            Button {
                if expansion.collapsed.contains(page.id) { expansion.collapsed.remove(page.id) } else { expansion.collapsed.insert(page.id) }
            } label: {
                Image(systemName: expansion.collapsed.contains(page.id) ? "chevron.right" : "chevron.down")
                    .font(.system(size: 10, weight: .semibold)).frame(width: 24, height: 28)
                    .contentShape(Rectangle())
            }.buttonStyle(.plain).opacity(hasChildren ? 1 : 0).disabled(!hasChildren)
                .accessibilityLabel(expansion.collapsed.contains(page.id) ? L10n.tr("展开子页面") : L10n.tr("收起子页面"))
            Button { openPage(page.id) } label: {
                HStack(spacing: 6) {
                    Image(systemName: "doc.text").foregroundStyle(.secondary)
                    Text(page.title.isEmpty ? L10n.tr("未命名") : page.title).lineLimit(1)
                    Spacer(minLength: 0)
                }
                .frame(maxWidth: .infinity, minHeight: 32, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(page.title.isEmpty ? L10n.tr("未命名") : page.title)
            .accessibilityAddTraits(model.selectedPageID == page.id && !showingTrash ? .isSelected : [])
            if page.parentID != nil && active {
                Button {
                    let parent = model.pages.first(where: { $0.id == page.parentID })
                    model.move(page, to: parent?.parentID)
                } label: { Image(systemName: "arrow.turn.up.left").font(.system(size: 10)) }
                .buttonStyle(.plain).help(L10n.tr("移出一级"))
            }
            if active {
            Menu { pageActions(page) } label: { Image(systemName: "ellipsis").frame(width: 28, height: 28).contentShape(Rectangle()) }
                .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize().help(L10n.tr("页面操作"))
                .accessibilityLabel(L10n.tr("页面操作"))
            } else { Color.clear.frame(width: 28, height: 28).accessibilityHidden(true) }
        }
        .padding(.leading, 14 + CGFloat(min(depth, 12)) * 14)
        .padding(.trailing, 6)
        .padding(.vertical, 1).contentShape(Rectangle())
        .frame(minHeight: 32)
        .background {
            if active {
                RoundedRectangle(cornerRadius: 10).fill(Color.primary.opacity(0.055))
                    .shadow(color: .black.opacity(0.025), radius: 3, y: 1)
            }
        }
        .background(SidebarSelectionAppearance().frame(width: 0, height: 0))
        .background(pageDrag.indicator?.pageID == page.id && pageDrag.indicator?.placement == .child ? Color.accentColor.opacity(0.14) : .clear, in: RoundedRectangle(cornerRadius: 6))
        .overlay {
            if pageDrag.indicator?.pageID == page.id && pageDrag.indicator?.placement == .child {
                RoundedRectangle(cornerRadius: 6).strokeBorder(Color.accentColor, lineWidth: 1)
                    .allowsHitTesting(false)
            } else if pageDrag.indicator?.pageID == page.id {
                VStack {
                    if pageDrag.indicator?.placement == .after { Spacer() }
                    Rectangle().fill(Color.accentColor).frame(height: 2)
                    if pageDrag.indicator?.placement == .before { Spacer() }
                }.allowsHitTesting(false)
            }
        }
        .help(L10n.tr("拖到上方或下方调整顺序；拖到中间成为子页面"))
        .contextMenu { pageActions(page) }
        .onDrag {
            pageDrag.begin(page.id)
            return NSItemProvider(object: "velora-page:\(page.id.uuidString)" as NSString)
        }
        .onDrop(of: [UTType.plainText], delegate: PageRowDropDelegate(pageID: page.id, sourceID: pageDrag.sourceID,
            validTarget: pageDrag.sourceID.map { !model.isDescendant(page.id, of: $0) } ?? false,
            indicator: $pageDrag.indicator, perform: performPageDrop))
    }

    private func performPageDrop(_ sourceID: UUID, _ targetID: UUID, _ placement: PageDropPlacement) -> Bool {
        defer { pageDrag.finishAfterTracking() }
        guard sourceID != targetID,
              let source = model.pages.first(where: { $0.id == sourceID && !$0.archived }),
              let target = model.pages.first(where: { $0.id == targetID && !$0.archived }),
              !model.isDescendant(target.id, of: source.id) else { return false }
        switch placement {
        case .child:
            RunLoop.main.perform(inModes: [.default]) {
                MainActor.assumeIsolated { _ = expansion.collapsed.remove(target.id) }
            }
            model.move(source, to: target.id)
        case .before:
            model.move(source, to: target.parentID, before: target.id)
        case .after:
            let siblings = model.pages.filter { !$0.archived && $0.parentID == target.parentID && $0.id != source.id }
            guard let index = siblings.firstIndex(where: { $0.id == target.id }) else { return false }
            let before = siblings.indices.contains(index + 1) ? siblings[index + 1].id : nil
            model.move(source, to: target.parentID, before: before)
        }
        return true
    }

    @ViewBuilder private func pageActions(_ page: Page) -> some View {
        Button(L10n.tr("重命名…")) { newTitle = page.title; renamingPage = page }
        Button(L10n.tr("新建子页面")) { expansion.collapsed.remove(page.id); model.createPage(parentID: page.id) }
        Button(L10n.tr("复制页面")) {
            Task { do { try await model.duplicatePage(page) } catch { model.errorMessage = error.localizedDescription } }
        }
        .disabled(model.automationBusy)
        Divider()
        Button(L10n.tr("上移")) { model.move(page, by: -1) }
            .disabled(model.pages.first(where: { !$0.archived && $0.parentID == page.parentID })?.id == page.id)
        Button(L10n.tr("下移")) { model.move(page, by: 1) }
            .disabled(model.pages.last(where: { !$0.archived && $0.parentID == page.parentID })?.id == page.id)
        Button(L10n.tr("移动到…")) { movingPage = page }
        if page.parentID != nil {
            Button(L10n.tr("移出一级")) {
                let parent = model.pages.first(where: { $0.id == page.parentID })
                model.move(page, to: parent?.parentID)
            }
            Button(L10n.tr("移到顶层")) { model.move(page, to: nil) }
        }
        Divider()
        Button(L10n.tr("移到回收箱"), role: .destructive) { model.archive(page) }
    }

    private func performTrashOperation(_ operation: @escaping @MainActor () async throws -> Void) {
        Task { do { try await operation() } catch { model.errorMessage = error.localizedDescription } }
    }

    private var trash: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                VStack(alignment: .leading, spacing: 6) {
                    Text(L10n.tr("回收箱")).font(.title2.bold())
                    Text(L10n.tr("删除的工作空间和当前空间的文档保留在此，直到恢复或永久删除。"))
                        .font(.callout).foregroundStyle(.secondary)
                }
                Spacer()
                HStack(spacing: 10) {
                    Button(L10n.tr("全部恢复")) {
                        performTrashOperation { try await services.restoreAllWorkspaces(); model.restoreAllPages() }
                    }
                    Button(L10n.tr("全部删除"), role: .destructive) { confirmingEmpty = true }
                }.fixedSize().disabled(model.trashedPages.isEmpty && services.trashedWorkspaces.isEmpty)

            }.padding(.horizontal, 28).padding(.top, 28)
            if model.trashedPages.isEmpty && services.trashedWorkspaces.isEmpty {
                ContentUnavailableView(L10n.tr("回收箱为空"), systemImage: "trash", description: Text(L10n.tr("删除的工作空间和文档会出现在这里。")))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List {
                    if !services.trashedWorkspaces.isEmpty {
                        Section(L10n.tr("工作空间")) {
                            ForEach(services.trashedWorkspaces) { workspace in
                                HStack {
                                    Image(systemName: workspace.symbol).foregroundStyle(workspace.tint)
                                    VStack(alignment: .leading) {
                                        Text(workspace.name).fontWeight(.medium)
                                        if let date = workspace.trashedAt { Text(date, style: .date).font(.caption).foregroundStyle(.secondary) }
                                    }
                                    Spacer()
                                    Button(L10n.tr("恢复")) { performTrashOperation { try await services.restoreWorkspace(workspace.id) } }
                                    Button(L10n.tr("删除"), role: .destructive) { permanentlyDeletingWorkspace = workspace }
                                }.padding(.vertical, 6)
                            }
                        }
                    }
                    Section(L10n.tr("当前工作空间的文档")) {
                        ForEach(model.trashedPages) { page in
                            HStack(spacing: 12) {
                                Image(systemName: "doc.text").foregroundStyle(.secondary)
                                VStack(alignment: .leading, spacing: 5) {
                                    Text(page.title.isEmpty ? L10n.tr("未命名") : page.title).fontWeight(.medium)
                                    Text(page.updatedAt, style: .date).font(.caption).foregroundStyle(.secondary)
                                }
                                Spacer()
                                Button(L10n.tr("恢复")) { model.restore(page) }.buttonStyle(.bordered)
                                Button(L10n.tr("删除"), role: .destructive) { deletingPage = page }
                                    .help(L10n.tr("永久删除")).accessibilityLabel(L10n.tr("永久删除页面"))
                            }.padding(.vertical, 8)
                        }
                    }
                }.listStyle(.inset)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .navigationTitle(L10n.tr("回收箱"))
    }

}

struct MovePagePanel: View {
    @ObservedObject var model: WorkspaceModel
    @ObservedObject var services: ApplicationServices
    let page: Page
    var onMove: (UUID?) -> Void = { _ in }
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    @State private var destination: UUID?
    @State private var targetWorkspace: UUID?
    @State private var moving = false
    @State private var moveError: String?
    @FocusState private var searchFocused: Bool
    // A stable local selection token represents the workspace root.
    private static let rootID = UUID(uuidString: "00000000-0000-0000-0000-000000000000")!

    private var targets: [Page] {
        model.pages.filter { !$0.archived && $0.id != page.id && !model.isDescendant($0.id, of: page.id)
            && (query.isEmpty || $0.title.localizedCaseInsensitiveContains(query)) }
    }
    private var canMove: Bool {
        if let targetWorkspace, targetWorkspace != services.currentWorkspace?.id {
            return services.workspaces.contains { $0.id == targetWorkspace } && !moving
        }
        guard let destination else { return false }
        if destination == Self.rootID { return page.parentID != nil }
        return destination != page.parentID && targets.contains { $0.id == destination }
    }
    private func path(for target: Page) -> String {
        let pages = Dictionary(uniqueKeysWithValues: model.pages.map { ($0.id, $0) })
        var parts: [String] = [], visited: Set<UUID> = [target.id]
        var parent = target.parentID
        while let id = parent, visited.insert(id).inserted, let page = pages[id] {
            parts.append(page.title.isEmpty ? L10n.tr("未命名") : page.title)
            parent = page.parentID
        }
        return parts.isEmpty ? L10n.tr("工作区顶层") : parts.reversed().joined(separator: " › ")
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Label(L10n.tr("移动“\(page.title.isEmpty ? "未命名" : page.title)”"), systemImage: "folder")
                .font(.title3.weight(.semibold)).lineLimit(2)
            Text(L10n.tr("选择目标页面，当前页面及其子页面会一起移动。"))
                .font(.callout).foregroundStyle(.secondary)
            Picker(L10n.tr("目标工作空间"), selection: $targetWorkspace) {
                ForEach(services.workspaces) { workspace in
                    Text(workspace.name).tag(Optional(workspace.id))
                }
            }.disabled(moving)
            if targetWorkspace == services.currentWorkspace?.id {
            TextField(L10n.tr("搜索目标页面"), text: $query).textFieldStyle(.roundedBorder).focused($searchFocused)
            List(selection: $destination) {
                Label(L10n.tr("工作区顶层"), systemImage: "square.stack")
                    .padding(.vertical, 6).tag(Self.rootID)
                ForEach(targets) { target in
                    HStack(spacing: 10) {
                        Image(systemName: "doc.text").foregroundStyle(.secondary)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(target.title.isEmpty ? L10n.tr("未命名") : target.title).lineLimit(1)
                            Text(path(for: target)).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        }
                    }.padding(.vertical, 5).tag(target.id)
                }
            }.listStyle(.inset).clipShape(RoundedRectangle(cornerRadius: 10))
            } else {
                VStack(alignment: .leading, spacing: 12) {
                    Label(L10n.tr("移到目标工作空间顶层"), systemImage: "square.stack.3d.up")
                    Text(L10n.tr("子页面、内容和格式将一起保留。目标保存成功后，源文档移入当前工作空间的回收箱，可恢复。移动后仍停留在当前工作空间。"))
                        .font(.callout).foregroundStyle(.secondary)
                }.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading).padding(.top, 8)
            }
            if let moveError { Text(moveError).font(.callout).foregroundStyle(.red).textSelection(.enabled) }
            HStack {
                if moving { ProgressView().controlSize(.small); Text(L10n.tr("正在移动…")).font(.caption) }
                Spacer()
                Button(L10n.tr("取消"), role: .cancel) { dismiss() }.keyboardShortcut(.cancelAction).disabled(moving)
                Button(L10n.tr("移动")) {
                    if let targetWorkspace, targetWorkspace != services.currentWorkspace?.id {
                        moving = true; moveError = nil
                        Task {
                            do { try await services.movePage(page.id, toWorkspace: targetWorkspace); dismiss() }
                            catch { moveError = error.localizedDescription; moving = false }
                        }
                        return
                    }
                    guard canMove, let destination else { return }
                    let parent = destination == Self.rootID ? nil : destination
                    onMove(parent)
                    model.move(page, to: parent)
                    dismiss()
                }.buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction).disabled(!canMove)
            }
        }.padding(24).frame(width: 500, height: 550)
        .interactiveDismissDisabled(moving)
        .background(Color(nsColor: .windowBackgroundColor))
        .onAppear { targetWorkspace = services.currentWorkspace?.id; destination = page.parentID ?? Self.rootID; searchFocused = true }
        .onChange(of: query) { _, _ in destination = nil }
    }
}
