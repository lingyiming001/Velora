import SwiftUI
import AVKit

struct PageEditorView: View {
    @ObservedObject var model: WorkspaceModel
    let page: Page

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 6) {
                    Color.clear.frame(height: 1).id("document-top")
                    TextField("未命名", text: Binding(get: { model.selectedPage?.title ?? page.title }, set: model.renameSelectedPage))
                        .textFieldStyle(.plain)
                        .font(.system(size: 48, weight: .bold))
                        .accessibilityLabel("页面标题")
                        .padding(.bottom, 28)

                    ForEach(model.blocks) { block in
                        EditorBlockRow(model: model, block: block, scrollTo: { id in
                            withAnimation { proxy.scrollTo(id, anchor: .top) }
                        }).id(block.id)
                    }

                    if let last = model.blocks.last, !last.text.isEmpty || last.kind != .paragraph {
                        Button { model.addBlock() } label: {
                            Text("点击继续书写，输入 / 插入内容")
                                .font(.system(size: 17)).foregroundStyle(.tertiary)
                                .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
                .overlay(alignment: .bottom) { Color.clear.frame(height: 1).id("document-bottom") }
                .frame(maxWidth: 820, alignment: .leading)
                .padding(.horizontal, 48)
                .padding(.top, 72)
                .padding(.bottom, 180)
                .frame(maxWidth: .infinity)
            }
            .background(Color(nsColor: .textBackgroundColor))
            .navigationTitle(page.title.isEmpty ? "未命名" : page.title)
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Menu {
                        Button("跳到文档开头  ⌘↑") { model.jumpToDocumentBoundary(atStart: true) }
                        Button("跳到文档末尾  ⌘↓") { model.jumpToDocumentBoundary(atStart: false) }
                        Divider()
                        Button("全选内容  ⌘A") { model.selectAllBlocks() }
                    } label: { Label("文档导航", systemImage: "arrow.up.arrow.down") }
                }
                ToolbarItem(placement: .status) {
                    Text(model.saving ? "正在保存…" : "已保存")
                        .font(.caption).foregroundStyle(.tertiary)
                }
            }
            .background(DocumentKeyboardCapture(selected: !model.selectedBlockIDs.isEmpty,
                selectAll: model.selectAllBlocks, delete: deleteSelection, escape: model.clearBlockSelection,
                boundary: { model.jumpToDocumentBoundary(atStart: $0, extend: $1) }).frame(width: 0, height: 0))
            .safeAreaInset(edge: .bottom) {
                if !model.selectedBlockIDs.isEmpty {
                    HStack {
                        Text("已选中 \(model.selectedBlockIDs.count) 个块").fontWeight(.medium)
                        Text("Shift 范围选择 · ⌘A 全选 · Esc 取消").foregroundStyle(.secondary).font(.caption)
                        Spacer()
                        Button("取消选择") { model.clearBlockSelection() }
                        Button("删除所选内容", role: .destructive) { deleteSelection() }
                    }.padding(12).background(.bar)
                }
            }
            .onChange(of: model.documentBoundaryRequest?.id) { _, _ in
                guard let request = model.documentBoundaryRequest else { return }
                withAnimation { proxy.scrollTo(request.atStart ? "document-top" : "document-bottom", anchor: request.atStart ? .top : .bottom) }
            }
            .onDisappear { Task { await model.flushAll() } }
        }
    }
    private func deleteSelection() {
        Task { do { try await model.deleteSelectedBlocks() } catch { model.errorMessage = error.localizedDescription } }
    }
}

private struct EditorBlockRow: View {
    @ObservedObject var model: WorkspaceModel
    let block: Block
    var scrollTo: (UUID) -> Void
    @AppStorage("editorFontSize") private var editorFontSize = 17.0
    @AppStorage("codeFontSize") private var codeFontSize = 13.0
    @AppStorage("codeLineNumbers") private var codeLineNumbers = true
    @Environment(\.colorScheme) private var colorScheme
    @State private var copied = false
    @State private var selectingImage = false
    @State private var customLanguage = ""
    @State private var showingLanguageEditor = false
    @State private var player: AVPlayer?
    @State private var hovered = false
    @State private var focused = false
    @State private var height: CGFloat = 30
    @State private var dismissed = false
    @State private var selectedIndex = 0

    private var query: String { String(block.text.dropFirst()).lowercased() }
    private var commands: [BlockKind] {
        BlockKind.allCases.filter {
            query.isEmpty || $0.label.localizedCaseInsensitiveContains(query) || $0.rawValue.lowercased().contains(query) || $0.category.contains(query) || $0.hint.contains(query)
        }
    }
    private var showingCommands: Bool {
        block.kind != .code && focused && !dismissed && block.text.hasPrefix("/") && !block.text.contains("\n")
    }

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Group {
            if block.hasContent {
            HStack(spacing: 2) {
                Button { model.addBlock(after: block) } label: {
                    Image(systemName: "plus")
                        .font(.system(size: 16, weight: .regular))
                        .frame(width: 24, height: 28)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("在下方添加块")
                .accessibilityLabel("在下方添加块")
                blockMenu
            }
            .foregroundStyle(Color(red: 0.45, green: 0.47, blue: 0.56))
            } else {
                Color.clear.frame(width: 50, height: 28).allowsHitTesting(false)
            }
            }
            .frame(width: 50)
            .padding(.top, block.kind == .code ? 12 : 1)
            .opacity(hovered || focused || model.selectedBlockIDs.contains(block.id) ? 1 : 0.55)
            VStack(alignment: .leading, spacing: 8) {
            if block.kind == .image {
                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        Label("图片", systemImage: "photo").font(.caption).foregroundStyle(.secondary)
                        Spacer()
                        Button(block.text.isEmpty ? "选择图片…" : "更换图片…") { selectingImage = true }

                    }
                    if !block.text.isEmpty { MediaImageView(source: block.text) }
                    else {
                        Button { selectingImage = true } label: {
                            Label("从 URL 或本地文件选择图片", systemImage: "photo.badge.plus")
                                .frame(maxWidth: .infinity, minHeight: 110)
                        }.buttonStyle(.plain).foregroundStyle(.secondary)
                    }
                }.padding(12).background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 10))
            } else if block.kind == .code {
                codeCard
            } else if block.kind == .toggle && block.collapsed {
                HStack {
                    collapseButton
                    Text(block.text.components(separatedBy: "\n").first.flatMap { $0.isEmpty ? nil : $0 } ?? "折叠块")
                    Spacer()

                }
            } else if block.kind == .divider || block.kind == .table || block.kind == .tableOfContents {
                HStack(alignment: .top) {
                    specialContent

                }
            } else {
                HStack(alignment: .top, spacing: 10) {
                    marker
                    ZStack(alignment: .topLeading) {
                        if block.text.isEmpty && (focused || model.blocks.count == 1) {
                            Text(block.kind.placeholder)
                                .font(.system(size: 17)).foregroundStyle(.tertiary)
                                .padding(.top, 2).allowsHitTesting(false)
                        }
                        NativeTextEditor(text: block.text, font: font, formatting: block.formatting,
                                         onRichChange: { model.changeRichText($0, formatting: $1, in: block) },
                                         onSelectAllBlocks: { model.selectAllBlocks(); return true },
                                         onDeleteBlocks: deleteBlocks,
                                         onDocumentBoundary: { model.jumpToDocumentBoundary(atStart: $0, extend: $1); return true },
                                         onBlockMouseDown: handleBlockClick,
                                         focusRequest: model.editorFocusRequest?.blockID == block.id ? model.editorFocusRequest : nil,
                                         onBackspaceAtStart: { model.backspaceAtStart(of: block) },
                                         onCommand: handleCommand,
                                         onFocus: { focused = $0 },
                                         onHeightChange: { if abs(height - $0) > 1 { height = $0 } }) {
                            dismissed = false
                            selectedIndex = 0
                            model.changeText($0, in: block)
                        }
                        .frame(height: max(block.kind.isHeading ? 42 : 30, height))
                        .accessibilityLabel(block.kind.label)
                    }
                    .overlay(alignment: .topLeading) {
                        if showingCommands {
                            commandMenu
                                .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 14))
                                .overlay(RoundedRectangle(cornerRadius: 14).stroke(Color.primary.opacity(0.09)))
                                .shadow(color: .black.opacity(0.12), radius: 18, y: 6)
                                .offset(y: max(block.kind.isHeading ? 42 : 30, height) + 8)
                        }
                    }

                }
            }
            if block.kind.isMedia && block.kind != .image { mediaPreview }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(model.selectedBlockIDs.contains(block.id) ? Color.accentColor.opacity(0.10) : .clear, in: RoundedRectangle(cornerRadius: 7))
        .overlay(RoundedRectangle(cornerRadius: 7).stroke(model.selectedBlockIDs.contains(block.id) ? Color.accentColor.opacity(0.4) : .clear))
        .padding(.vertical, block.kind == .code ? 0 : block.kind == .callout ? 12 : 3)
        .padding(.horizontal, block.kind == .callout ? 12 : 0)
        .background(block.kind == .callout ? Color.orange.opacity(0.1) : .clear, in: RoundedRectangle(cornerRadius: 8))
        .sheet(isPresented: $selectingImage) { ImageSourcePicker(initialValue: block.text) { model.changeText($0, in: block) } }
        .contentShape(Rectangle())
        .onHover { hovered = $0 }
        .zIndex(showingCommands ? 1 : 0)
    }

    private func handleBlockClick(_ modifiers: NSEvent.ModifierFlags) -> Bool {
        if modifiers.contains(.shift), model.activeEditingBlockID != nil, model.activeEditingBlockID != block.id {
            model.selectBlock(block.id, extend: true); return true
        }
        model.clearBlockSelection(); model.activeEditingBlockID = block.id; return false
    }
    private func deleteBlocks() -> Bool {
        guard !model.selectedBlockIDs.isEmpty else { return false }
        Task { do { try await model.deleteSelectedBlocks() } catch { model.errorMessage = error.localizedDescription } }
        return true
    }

    private var blockMenu: some View {
        Menu {
            ForEach(BlockKind.categories, id: \.self) { category in
                Menu(category) {
                    ForEach(BlockKind.allCases.filter { $0.category == category }) { kind in
                        Button(kind.label) { model.changeKind(kind, of: block) }
                    }
                }
            }
            Divider()
            Button("删除块", role: .destructive) { model.delete(block) }
            Button("选择此块") { model.selectBlock(block.id) }
            Button("全选文档内容  ⌘A") { model.selectAllBlocks() }
        } label: {
            HStack(spacing: 4) {
                ForEach(0..<2) { _ in
                    Image(systemName: "ellipsis")
                        .font(.system(size: 15, weight: .bold))
                        .rotationEffect(.degrees(90))
                        .frame(width: 4, height: 18)
                }
            }
            .frame(width: 24, height: 28)
            .contentShape(Rectangle())
        }
        .menuStyle(.borderlessButton).menuIndicator(.hidden).frame(width: 24, height: 28)
        .help("块操作：更改类型、选择或删除")
        .accessibilityLabel("块操作")
    }

    private var collapseButton: some View {
        Button { model.setBlockOptions(for: block, collapsed: !block.collapsed) } label: {
            Image(systemName: block.collapsed ? "chevron.right" : "chevron.down")
                .frame(width: 18, height: 24)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(block.collapsed ? "展开内容" : "折叠内容")
    }

    private var numberedIndex: Int {
        guard let index = model.blocks.firstIndex(where: { $0.id == block.id }) else { return 1 }
        return model.blocks[..<index].reversed().prefix(while: { $0.kind == .numbered }).count + 1
    }

    @ViewBuilder private var specialContent: some View {
        switch block.kind {
        case .divider:
            VStack(alignment: .leading) {
                Divider().padding(.vertical, 14)
                if !block.text.isEmpty { Text(block.text).foregroundStyle(.secondary) }
            }
        case .table:
            tableContent
        case .tableOfContents:
            VStack(alignment: .leading, spacing: 10) {
                Text("页面目录").font(.caption).foregroundStyle(.secondary)
                let headings = model.blocks.filter { $0.kind.isHeading }
                if headings.isEmpty {
                    Text("添加标题后会自动生成目录").foregroundStyle(.tertiary)
                }
                ForEach(headings) { heading in
                    Button { scrollTo(heading.id) } label: {
                        Text(heading.text.isEmpty ? heading.kind.label : heading.text)
                            .lineLimit(1)
                            .padding(.leading, heading.kind == .heading2 ? 16 : heading.kind == .heading3 ? 32 : 0)
                    }.buttonStyle(.plain)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 8)
        default: EmptyView()
        }
    }

    private var mediaURL: URL? {
        guard let url = URL(string: block.text.trimmingCharacters(in: .whitespacesAndNewlines)),
              let scheme = url.scheme?.lowercased(), ["https", "http"].contains(scheme),
              url.host != nil else { return nil }
        return url
    }

    @ViewBuilder private var mediaPreview: some View {
        if let url = mediaURL {
            switch block.kind {
            case .video, .audio:
                VStack(alignment: .leading, spacing: 8) {
                    VideoPlayer(player: player).frame(height: block.kind == .audio ? 80 : 280)
                    Link("在浏览器打开", destination: url).font(.caption)
                }
                .task(id: url) {
                    player?.pause()
                    player = AVPlayer(url: url)
                }
                .onDisappear { player?.pause() }
            default:
                Link(destination: url) {
                    HStack(spacing: 12) {
                        Image(systemName: block.kind.symbol).font(.title2)
                        VStack(alignment: .leading, spacing: 4) {
                            Text(block.kind == .file ? url.lastPathComponent : url.host ?? "网页链接").lineLimit(1)
                            Text(url.absoluteString).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        }
                        Spacer()
                        Image(systemName: "arrow.up.right")
                    }.padding(14).background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 8))
                }
            }
        } else if !block.text.isEmpty && !showingCommands {
            Text("请输入有效的 http 或 https 链接").font(.caption).foregroundStyle(.secondary)
        }
    }

    private var cells: [[String]] {
        if let data = block.text.data(using: .utf8),
           let rows = try? JSONDecoder().decode([[String]].self, from: data),
           !rows.isEmpty, let columns = rows.first?.count, columns > 0,
           rows.allSatisfy({ $0.count == columns }) { return rows }
        return [[block.text, ""], ["", ""]]
    }

    private func saveCells(_ rows: [[String]]) {
        guard let data = try? JSONEncoder().encode(rows), let text = String(data: data, encoding: .utf8) else { return }
        model.changeText(text, in: block)
    }

    private var tableContent: some View {
        VStack(alignment: .leading, spacing: 8) {
            ScrollView(.horizontal) {
                Grid(horizontalSpacing: 1, verticalSpacing: 1) {
                    ForEach(cells.indices, id: \.self) { row in
                        GridRow {
                            ForEach(cells[row].indices, id: \.self) { column in
                                TextField(row == 0 ? "列名" : "内容", text: Binding(get: {
                                    cells[row][column]
                                }, set: { value in
                                    var updated = cells
                                    updated[row][column] = value
                                    saveCells(updated)
                                }))
                                .textFieldStyle(.plain).fontWeight(row == 0 ? .semibold : .regular)
                                .padding(10).frame(width: 160, alignment: .leading)
                                .background(row == 0 ? Color.primary.opacity(0.06) : Color(nsColor: .textBackgroundColor))
                                .accessibilityLabel("第 \(row + 1) 行，第 \(column + 1) 列")
                            }
                        }
                    }
                }.padding(1).background(Color.primary.opacity(0.12))
            }
            HStack {
                Button("添加行") { saveCells(cells + [Array(repeating: "", count: cells[0].count)]) }
                Button("添加列") { saveCells(cells.map { $0 + [""] }) }
                Menu("删除") {
                    Button("删除末行") { saveCells(Array(cells.dropLast())) }.disabled(cells.count <= 1)
                    Button("删除末列") { saveCells(cells.map { Array($0.dropLast()) }) }.disabled(cells[0].count <= 1)
                }.fixedSize()
            }.font(.caption).buttonStyle(.borderless)
        }.frame(maxWidth: .infinity, alignment: .leading)
    }

    private var codeSurface: Color {
        colorScheme == .dark ? Color(red: 0.085, green: 0.095, blue: 0.12) : Color(red: 0.975, green: 0.978, blue: 0.987)
    }

    private var codeCard: some View {
        VStack(spacing: 0) {
            codeHeader
            if !block.collapsed {
                Rectangle().fill(Color.primary.opacity(0.07)).frame(height: 1)
                NativeTextEditor(text: block.text, font: .monospacedSystemFont(ofSize: codeFontSize, weight: .regular), formatting: block.formatting,
                                 onRichChange: { model.changeRichText($0, formatting: $1, in: block) },
                                 onSelectAllBlocks: { model.selectAllBlocks(); return true }, onDeleteBlocks: deleteBlocks,
                                 onDocumentBoundary: { model.jumpToDocumentBoundary(atStart: $0, extend: $1); return true },
                                 onBlockMouseDown: handleBlockClick,
                                 codeLanguage: block.language, showCodeLineNumbers: codeLineNumbers, darkCode: colorScheme == .dark,
                                 focusRequest: model.editorFocusRequest?.blockID == block.id ? model.editorFocusRequest : nil,
                                 onBackspaceAtStart: { model.backspaceAtStart(of: block) },
                                 onFocus: { focused = $0 },
                                 onHeightChange: { if abs(height - $0) > 1 { height = $0 } }) {
                    model.changeText($0, in: block)
                }
                .frame(height: max(72, height))
                .padding(.vertical, 14).padding(.trailing, 18)
                .accessibilityLabel("代码编辑器")
            }
        }
        .contextMenu {
            Button("复制代码", systemImage: "doc.on.doc", action: copyCode)
            Divider()
            Button("转为正文") { model.changeKind(.paragraph, of: block) }
            Button("删除代码块", role: .destructive) { model.delete(block) }
        }
        .background(codeSurface, in: RoundedRectangle(cornerRadius: 12))
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12)
            .strokeBorder(focused ? Color.indigo.opacity(0.35) : Color.primary.opacity(0.08), lineWidth: 1))
        .shadow(color: .black.opacity(colorScheme == .dark ? 0.12 : 0.025), radius: 8, y: 3)
        .padding(.vertical, 6)
    }

    private func copyCode() {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        copied = pasteboard.setString(block.text, forType: .string)
    }

    private var codeHeader: some View {
        HStack(spacing: 10) {
            Image(systemName: "chevron.left.forwardslash.chevron.right")
                .font(.system(size: 12, weight: .semibold)).foregroundStyle(.indigo)
            Menu {
                ForEach(["Plain Text", "Swift", "Python", "JavaScript", "TypeScript", "HTML", "CSS",
                         "JSON", "SQL", "Bash", "C", "C++", "C#", "Java", "Kotlin", "Go", "Rust",
                         "Ruby", "PHP", "YAML", "Markdown"], id: \.self) { language in
                    Button {
                        model.setBlockOptions(for: block, language: language)
                    } label: {
                        if block.language == language { Label(language, systemImage: "checkmark") }
                        else { Text(language) }
                    }
                }
                Divider()
                Button("自定义语言…") {
                    customLanguage = block.language
                    showingLanguageEditor = true
                }
            } label: { Text(block.language.isEmpty ? "Plain Text" : block.language).fontWeight(.medium) }
            .menuStyle(.borderlessButton).fixedSize()
            .help("选择语言")
            Spacer(minLength: 8)
            Text("\(block.text.isEmpty ? 0 : block.text.components(separatedBy: "\n").count) 行")
                .monospacedDigit().foregroundStyle(.tertiary)
            Button(action: copyCode) {
                Label(copied ? "已复制" : "复制", systemImage: copied ? "checkmark" : "doc.on.doc")
                    .padding(.horizontal, 8)
                    .frame(height: 24)
                    .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 5))
                    .contentShape(Rectangle())
            }
            .help(copied ? "已复制到剪贴板" : "复制代码到剪贴板")
            .accessibilityLabel(copied ? "已复制到剪贴板" : "复制代码到剪贴板")
            .task(id: copied) {
                if copied {
                    try? await Task.sleep(for: .seconds(2))
                    if !Task.isCancelled { copied = false }
                }
            }
            Button { model.setBlockOptions(for: block, collapsed: !block.collapsed) } label: {
                Image(systemName: block.collapsed ? "chevron.right" : "chevron.down").frame(width: 24, height: 24)
            }
            .help(block.collapsed ? "展开代码" : "折叠代码")
            .accessibilityLabel(block.collapsed ? "展开代码" : "折叠代码")
        }
        .buttonStyle(.plain)
        .font(.system(size: 11))
        .foregroundStyle(.secondary)
        .padding(.horizontal, 16).padding(.vertical, 9)
        .alert("自定义代码语言", isPresented: $showingLanguageEditor) {
            TextField("语言名称", text: $customLanguage)
            Button("取消", role: .cancel) { }
            Button("保存") {
                let value = customLanguage.trimmingCharacters(in: .whitespacesAndNewlines)
                model.setBlockOptions(for: block, language: value.isEmpty ? "Plain Text" : value)
            }
        }
    }

    @ViewBuilder private var marker: some View {
        if block.kind == .toggle {
            collapseButton
        } else if block.kind == .callout {
            Image(systemName: "lightbulb").foregroundStyle(.orange).padding(.top, 4)
        } else if block.kind == .numbered {
            Text("\(numberedIndex).")
                .font(.system(size: 17)).foregroundStyle(.secondary).padding(.top, 2)
        } else if block.kind == .todo {
            Button { model.toggle(block) } label: {
                Image(systemName: block.checked ? "checkmark.square.fill" : "square")
                    .foregroundStyle(block.checked ? Color.accentColor : .secondary)
            }.buttonStyle(.plain).padding(.top, 5)
        } else if block.kind == .bullet {
            Circle().fill(.secondary).frame(width: 5, height: 5).padding(.top, 12)
        } else if block.kind == .quote {
            RoundedRectangle(cornerRadius: 2).fill(.secondary.opacity(0.4)).frame(width: 3, height: max(30, height))
        }
    }

    private var font: NSFont {
        switch block.kind {
        case .heading: .systemFont(ofSize: 28, weight: .semibold)
        case .heading2: .systemFont(ofSize: 23, weight: .semibold)
        case .heading3: .systemFont(ofSize: 19, weight: .semibold)
        case .code: .monospacedSystemFont(ofSize: 15, weight: .regular)
        default: .systemFont(ofSize: editorFontSize)
        }
    }

    private var commandMenu: some View {
        VStack(alignment: .leading, spacing: 4) {
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 4) {
                        if commands.isEmpty {
                            Text("没有匹配的块类型").foregroundStyle(.secondary).padding(12)
                        }
                        ForEach(Array(commands.enumerated()), id: \.element.id) { index, kind in
                            if index == 0 || commands[index - 1].category != kind.category {
                                Text(kind.category).font(.system(size: 12, weight: .semibold))
                                    .foregroundStyle(.secondary).padding(10)
                            }
                            Button { choose(kind) } label: {
                                HStack(spacing: 12) {
                                    Image(systemName: kind.symbol).font(.system(size: 19)).frame(width: 28)
                                    Text(kind.label).font(.system(size: 15))
                                    Spacer()
                                    Text(kind.hint).font(.system(size: 11)).foregroundStyle(.tertiary)
                                }
                                .padding(10).contentShape(Rectangle())
                                .background(selectedIndex == index ? Color.primary.opacity(0.06) : .clear,
                                            in: RoundedRectangle(cornerRadius: 8))
                            }
                            .buttonStyle(.plain).id(index)
                            .onHover { if $0 { selectedIndex = index } }
                        }
                    }
                }
                .frame(height: 320)
                .onChange(of: selectedIndex) { _, index in proxy.scrollTo(index) }
            }
            Divider()
            Text("↑ ↓ 选择   ↩ 插入   esc 关闭")
                .font(.system(size: 11)).foregroundStyle(.tertiary).padding(8)
        }
        .padding(8).frame(width: 330)
    }

    private func choose(_ kind: BlockKind) {
        dismissed = true
        model.changeText("", in: block)
        model.changeKind(kind, of: block)
    }

    private func handleCommand(_ selector: Selector) -> Bool {
        guard showingCommands else { return false }
        switch NSStringFromSelector(selector) {
        case "cancelOperation:": dismissed = true
        case "moveDown:": selectedIndex = min(selectedIndex + 1, max(0, commands.count - 1))
        case "moveUp:": selectedIndex = max(0, selectedIndex - 1)
        case "insertNewline:":
            if commands.indices.contains(selectedIndex) { choose(commands[selectedIndex]) }
            else { return false }
        default: return false
        }
        return true
    }

}
