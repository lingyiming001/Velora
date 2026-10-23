import SwiftUI
import AVKit

/// Explicit row inputs keep unrelated model publications (autosave, another
/// block's text or focus) from rebuilding every native editor and web preview.
struct EditorRowSnapshot: Identifiable, Equatable {
    var id: UUID { block.id }
    let block: Block
    let selected: Bool
    let onlyBlock: Bool
    let first: Bool
    let last: Bool
    let focusRequest: EditorFocusRequest?
    let number: Int
    let headings: [Block]
    let contentRevision: UInt64
    let codeLineCount: Int

    static func make(blocks: [Block], selection: Set<UUID>, focus: EditorFocusRequest?, revisions: [UUID: UInt64] = [:]) -> [Self] {
        let headings = blocks.filter { $0.kind.isHeading }
        var number = 0
        return blocks.enumerated().map { index, block in
            number = block.kind == .numbered ? number + 1 : 0
            return Self(block: block, selected: selection.contains(block.id), onlyBlock: blocks.count == 1,
                        first: index == 0, last: index == blocks.count - 1,
                        focusRequest: focus?.blockID == block.id ? focus : nil,
                        number: block.kind == .numbered ? number : 1,
                        headings: block.kind == .tableOfContents ? headings : [], contentRevision: revisions[block.id] ?? 0,
                        codeLineCount: block.kind == .code && !block.text.isEmpty ? block.text.utf8.reduce(1) { $1 == 10 ? $0 + 1 : $0 } : 0)
        }
    }
}

enum SlashCommandMenu {
    static func matches(_ source: String) -> [BlockKind] {
        let query = String(source.dropFirst()).trimmingCharacters(in: .whitespaces).lowercased()
        let matches = BlockKind.allCases.filter {
            query.isEmpty || $0.label.localizedCaseInsensitiveContains(query) || $0.rawValue.lowercased().contains(query) || $0.category.contains(query) || $0.hint.localizedCaseInsensitiveContains(query) || $0.slashAliases.contains(where: { $0.contains(query) })
        }
        // Exact commands win over related names such as tableOfContents.
        let exact = matches.filter { $0.slashAliases.contains(query) }
        return exact + matches.filter { !$0.slashAliases.contains(query) }
    }
}

private struct TableCellHeightKey: PreferenceKey {
    static let defaultValue: [Int: CGFloat] = [:]
    static func reduce(value: inout [Int: CGFloat], nextValue: () -> [Int: CGFloat]) {
        value.merge(nextValue(), uniquingKeysWith: max)
    }
}

private enum EditorLayout {
    static let controlsWidth: CGFloat = 50
    static let controlsSpacing: CGFloat = 8
    static let contentInset = controlsWidth + controlsSpacing
}

struct PageEditorView: View {
    @ObservedObject var model: WorkspaceModel
    let page: Page
    @AppStorage("editorWidePage") private var widePage = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 6) {
                    Color.clear.frame(height: 1).id("document-top")
                    TextField(L10n.tr("未命名"), text: Binding(get: { model.selectedPage?.title ?? page.title }, set: model.renameSelectedPage))
                        .textFieldStyle(.plain)
                        .font(.system(size: 40, weight: .bold, design: .default))
                        .accessibilityLabel(L10n.tr("页面标题"))
                        .padding(.leading, EditorLayout.contentInset)
                        .padding(.bottom, 16)

                    ForEach(EditorRowSnapshot.make(blocks: model.blocks, selection: model.selectedBlockIDs,
                                                   focus: model.editorFocusRequest, revisions: model.editorContentRevisions)) { snapshot in
                        EditorBlockRow(model: model, snapshot: snapshot, scrollTo: { id in
                            withAnimation(reduceMotion ? nil : .easeOut(duration: 0.18)) { proxy.scrollTo(id, anchor: .top) }
                        }).equatable().id(snapshot.id)
                    }

                    if let last = model.blocks.last, !last.text.isEmpty || last.kind != .paragraph {
                        Button { model.addBlock() } label: {
                            Text(L10n.tr("点击继续书写，输入 / 插入内容"))
                                .font(.system(size: 17)).foregroundStyle(.tertiary)
                                .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .padding(.leading, EditorLayout.contentInset)
                    }
                }
                .background(DocumentScrollCapture())
                .overlay(alignment: .bottom) { Color.clear.frame(height: 1).id("document-bottom") }
                .frame(maxWidth: widePage ? .infinity : 820, alignment: .leading)
                .padding(.horizontal, 32)
                .padding(.top, 48)
                .padding(.bottom, 180)
                .frame(maxWidth: .infinity)
            }
            .scrollIndicators(.visible)
            .background(Color(nsColor: .textBackgroundColor))
            .navigationTitle(page.title.isEmpty ? L10n.tr("未命名") : page.title)
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Menu {
                        ForEach(BlockKind.categories, id: \.self) { category in
                            Section(category) {
                                ForEach(BlockKind.allCases.filter { $0.category == category }) { kind in
                                    Button { model.addBlock(kind) } label: { Label(kind.label, systemImage: kind.symbol) }
                                }
                            }
                        }
                    } label: { Label(L10n.tr("插入块"), systemImage: "plus.square") }
                    .help(L10n.tr("插入块，也可输入 / 搜索"))
                }
                ToolbarItem(placement: .primaryAction) {
                    Button { widePage.toggle() } label: {
                        Label(widePage ? L10n.tr("阅读宽度") : L10n.tr("全宽页面"), systemImage: widePage ? "arrow.right.and.line.vertical.and.arrow.left" : "arrow.left.and.right")
                    }.help(widePage ? L10n.tr("切换为阅读宽度") : L10n.tr("切换为全宽页面"))
                }
                ToolbarItem(placement: .primaryAction) {
                    Menu {
                        Button(L10n.tr("跳到文档开头  ⌘↑")) { model.jumpToDocumentBoundary(atStart: true) }
                        Button(L10n.tr("跳到文档末尾  ⌘↓")) { model.jumpToDocumentBoundary(atStart: false) }
                        Divider()
                        Button(L10n.tr("全选内容  ⌘A")) { model.selectAllBlocks() }
                    } label: { Label(L10n.tr("文档导航"), systemImage: "arrow.up.arrow.down") }
                }
                ToolbarItem(placement: .status) {
                    Text(model.saving ? L10n.tr("正在保存…") : L10n.tr("已保存"))
                        .font(.caption).foregroundStyle(.tertiary)
                }
            }
            .background(DocumentKeyboardCapture(selected: !model.selectedBlockIDs.isEmpty,
                selectAll: model.selectAllBlocks, delete: deleteSelection, copy: model.copySelectedBlocks, escape: model.clearBlockSelection,
                boundary: { model.jumpToDocumentBoundary(atStart: $0, extend: $1) }).frame(width: 0, height: 0))
            .safeAreaInset(edge: .bottom) {
                if !model.selectedBlockIDs.isEmpty {
                    HStack {
                        Text(L10n.tr("已选中 \(model.selectedBlockIDs.count) 个块")).fontWeight(.medium)
                        Text(L10n.tr("Shift 范围选择 · ⌘A 全选 · Esc 取消")).foregroundStyle(.secondary).font(.caption)
                        Spacer()
                        Button(L10n.tr("复制所选内容")) { model.copySelectedBlocks() }
                        Button(L10n.tr("取消选择")) { model.clearBlockSelection() }
                        Button(L10n.tr("删除所选内容"), role: .destructive) { deleteSelection() }
                    }.padding(12).background(.bar)
                }
            }
            .onChange(of: model.editorFocusRequest?.id) { _, _ in
                if let request = model.editorFocusRequest { proxy.scrollTo(request.blockID, anchor: .center) }
            }
            .onChange(of: model.documentBoundaryRequest?.id) { _, _ in
                guard let request = model.documentBoundaryRequest else { return }
                withAnimation(reduceMotion ? nil : .easeOut(duration: 0.18)) { proxy.scrollTo(request.atStart ? "document-top" : "document-bottom", anchor: request.atStart ? .top : .bottom) }
            }
            .onDisappear { Task { await model.flushAll() } }
        }
    }
    private func deleteSelection() {
        Task { do { try await model.deleteSelectedBlocks() } catch { model.errorMessage = error.localizedDescription } }
    }
}

private struct EditorBlockRow: View, Equatable {
    let model: WorkspaceModel
    let snapshot: EditorRowSnapshot
    private var block: Block { snapshot.block }

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.model === rhs.model && lhs.snapshot == rhs.snapshot
    }
    var scrollTo: (UUID) -> Void
    @AppStorage("editorFontSize") private var editorFontSize = 17.0
    @AppStorage("codeFontSize") private var codeFontSize = 13.0
    @AppStorage("codeLineNumbers") private var codeLineNumbers = true
    @AppStorage("codeLineCount") private var codeLineCount = true
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var editingRichSource = false
    @State private var richPreviewHeight: CGFloat = 100
    @State private var richPreviewError: String?
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
    @FocusState private var focusedTableCell: String?
    @State private var columnDrag: (index: Int, value: Double)?
    @State private var rowDrag: (index: Int, value: Double)?
    @State private var tableRowContentHeights: [Int: CGFloat] = [:]

    private var commands: [BlockKind] { SlashCommandMenu.matches(block.text) }
    private var showingCommands: Bool {
        block.kind != .code && focused && !dismissed && block.text.hasPrefix("/") && !block.text.contains("\n")
    }
    private var showsBlockControls: Bool {
        let richPreview = block.kind == .equation || block.kind == .markdown || isMermaidCode
        let editingText = focused && block.kind.acceptsTextInput && !block.collapsed
            && (!richPreview || editingRichSource || !block.hasContent)
        let editingTable = block.kind == .table && focusedTableCell != nil
        return hovered || editingText || editingTable || snapshot.selected || showingCommands
            || selectingImage || showingLanguageEditor || columnDrag != nil || rowDrag != nil
    }

    var body: some View {
        HStack(alignment: .top, spacing: EditorLayout.controlsSpacing) {
            HStack(spacing: 2) {
                Button { model.addBlock(after: block) } label: {
                    Image(systemName: "plus")
                        .font(.system(size: 16, weight: .regular))
                        .frame(width: 24, height: 28)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(L10n.tr("在下方添加块"))
                .accessibilityLabel(L10n.tr("在下方添加块"))
                blockMenu
            }
            .foregroundStyle(Color(red: 0.45, green: 0.47, blue: 0.56))
            .frame(width: EditorLayout.controlsWidth)
            .padding(.top, block.kind == .code ? 12 : 1)
            .opacity(showsBlockControls ? 1 : 0)
            .allowsHitTesting(showsBlockControls)
            .accessibilityHidden(!showsBlockControls)
            .animation(reduceMotion ? nil : .easeOut(duration: 0.12), value: showsBlockControls)
            VStack(alignment: .leading, spacing: 8) {
            if block.kind == .pdfDocument {
                PDFDocumentBlock(source: Binding(get: { block.text }, set: { model.changeText($0, in: block) }), extract: { text in
                    model.addBlock(.markdown, after: block, text: text)
                })
            } else if block.kind == .image {
                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        Label(L10n.tr("图片"), systemImage: "photo").font(.caption).foregroundStyle(.secondary)
                        Spacer()
                        Button(block.text.isEmpty ? L10n.tr("选择图片…") : L10n.tr("更换图片…")) { selectingImage = true }

                    }
                    if !block.text.isEmpty { MediaImageView(source: block.text) }
                    else {
                        Button { selectingImage = true } label: {
                            Label(L10n.tr("从 URL 或本地文件选择图片"), systemImage: "photo.badge.plus")
                                .frame(maxWidth: .infinity, minHeight: 110)
                        }.buttonStyle(.plain).foregroundStyle(.secondary)
                    }
                }.padding(12).background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 10))
            } else if block.kind == .equation || block.kind == .markdown || isMermaidCode {
                richContent
            } else if block.kind == .code {
                codeCard
            } else if block.kind == .toggle && block.collapsed {
                HStack {
                    collapseButton
                    Text(block.text.components(separatedBy: "\n").first.flatMap { $0.isEmpty ? nil : $0 } ?? L10n.tr("折叠块"))
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
                        if block.text.isEmpty && (focused || snapshot.onlyBlock) {
                            Text(block.kind.placeholder)
                                .font(.system(size: 17)).foregroundStyle(.tertiary)
                                .padding(.top, 2).allowsHitTesting(false)
                        }
                        NativeTextEditor(text: block.text, font: font, formatting: block.formatting,
                                         onRichChange: { text, runs in
                                             dismissed = false; selectedIndex = 0
                                             model.changeRichText(text, formatting: runs, in: block)
                                         },
                                         onMarkdownHeading: { model.applyMarkdownHeading($0, formatting: $1, in: block, selection: $2) },
                                         onHeadingShortcut: { model.convertToHeading($0, text: $1, formatting: $2, selection: $3, in: block) },
                                         onSelectAllBlocks: { model.selectAllBlocks(); return true },
                                         onDeleteBlocks: deleteBlocks,
                                         onDocumentBoundary: { model.jumpToDocumentBoundary(atStart: $0, extend: $1); return true },
                                         onBlockMouseDown: handleBlockClick,
                                         onPasteDocument: pasteDocument,
                                         focusRequest: snapshot.focusRequest, isFocusRequestCurrent: { model.editorFocusRequest?.id == $0 }, contentRevision: snapshot.contentRevision,
                                         onExitBlock: { model.exitBlock(block); return true },
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
                    .background {
                        if showingCommands {
                            EditorCommandPopup {
                                commandMenu
                                    .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 14))
                                    .overlay(RoundedRectangle(cornerRadius: 14).stroke(Color.primary.opacity(0.09)))
                            }
                        }
                    }

                }
            }
            if block.kind.isMedia && block.kind != .image { mediaPreview }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(snapshot.selected ? Color.accentColor.opacity(0.10) : .clear, in: RoundedRectangle(cornerRadius: 7))
        .overlay(RoundedRectangle(cornerRadius: 7).stroke(snapshot.selected ? Color.accentColor.opacity(0.4) : .clear))
        .padding(.top, block.kind.isHeading && !snapshot.first ? 16 : 0)
        .padding(.vertical, block.kind == .code ? 0 : block.kind.isCallout ? 10 : 3)
        .padding(.horizontal, block.kind.isCallout ? 12 : 0)
        .background(block.kind.isCallout ? calloutColor.opacity(0.09) : .clear, in: RoundedRectangle(cornerRadius: 8))
        .sheet(isPresented: $selectingImage) { ImageSourcePicker(initialValue: block.text) { model.changeText($0, in: block) } }
        .contentShape(Rectangle())
        .onHover { hovered = $0 }
        .zIndex(showingCommands ? 1 : 0)
    }

    private func pasteDocument(_ plain: String?, _ html: String?, _ original: String, _ runs: [TextStyleRun], _ range: NSRange) -> Bool {
        let copiedBlocks = ClipboardDocument.blocks(from: .general)
        guard block.kind == .paragraph, copiedBlocks != nil || ClipboardDocument.isStructured(plain, html: html) else { return false }
        model.pasteDocument(plain: plain, html: html, original: original, formatting: runs, selection: range, in: block, copiedBlocks: copiedBlocks)
        return true
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
            Button(L10n.tr("复制块内容"), systemImage: "doc.on.doc", action: copyCode)
            Button(L10n.tr("上移"), systemImage: "arrow.up") { model.moveBlock(block, offset: -1) }
                .disabled(snapshot.first)
            Button(L10n.tr("下移"), systemImage: "arrow.down") { model.moveBlock(block, offset: 1) }
                .disabled(snapshot.last)
            Divider()
            Button(L10n.tr("删除块"), role: .destructive) { model.delete(block) }
            Button(L10n.tr("选择此块")) { model.selectBlock(block.id) }
            Button(L10n.tr("全选文档内容  ⌘A")) { model.selectAllBlocks() }
        } label: {
            Image(systemName: "ellipsis")
                .font(.system(size: 15, weight: .semibold))
            .frame(width: 24, height: 28)
            .contentShape(Rectangle())
        }
        .menuStyle(.borderlessButton).menuIndicator(.hidden).frame(width: 24, height: 28)
        .help(L10n.tr("块操作：更改类型、选择或删除"))
        .accessibilityLabel(L10n.tr("块操作"))
    }

    private var collapseButton: some View {
        Button { model.setBlockOptions(for: block, collapsed: !block.collapsed) } label: {
            Image(systemName: block.collapsed ? "chevron.right" : "chevron.down")
                .frame(width: 18, height: 24)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(block.collapsed ? L10n.tr("展开内容") : L10n.tr("折叠内容"))
    }

    private var numberedIndex: Int {
        snapshot.number
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
                Text(L10n.tr("页面目录")).font(.caption).foregroundStyle(.secondary)
                let headings = snapshot.headings
                if headings.isEmpty {
                    Text(L10n.tr("添加标题后会自动生成目录")).foregroundStyle(.tertiary)
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
                    Link(L10n.tr("在浏览器打开"), destination: url).font(.caption)
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
                            Text(block.kind == .file ? url.lastPathComponent : url.host ?? L10n.tr("网页链接")).lineLimit(1)
                            Text(url.absoluteString).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        }
                        Spacer()
                        Image(systemName: "arrow.up.right")
                    }.padding(14).background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 8))
                }
            }
        } else if !block.text.isEmpty && !showingCommands {
            Text(L10n.tr("请输入有效的 http 或 https 链接")).font(.caption).foregroundStyle(.secondary)
        }
    }

    private var cells: [[String]] {
        if let data = block.text.data(using: .utf8),
           let rows = try? JSONDecoder().decode([[String]].self, from: data),
           !rows.isEmpty, let columns = rows.first?.count, columns > 0,
           rows.allSatisfy({ $0.count == columns }) { return rows.map { $0.map { TableCellContent.visible($0, layout: block.tableLayout) } } }
        return [[block.text, ""], ["", ""]]
    }

    private func saveCells(_ rows: [[String]]) { model.changeTableCells(rows, in: block) }

    private func columnWidth(_ index: Int) -> CGFloat {
        if let columnDrag, columnDrag.index == index { return CGFloat(columnDrag.value) }
        return CGFloat(block.tableLayout.column(index))
    }
    private func contentRowHeight(_ row: Int) -> CGFloat {
        (tableRowContentHeights[row] ?? 20) + 16
    }
    private func rowHeight(_ index: Int) -> CGFloat {
        let requested: CGFloat
        if let rowDrag, rowDrag.index == index { requested = CGFloat(rowDrag.value) }
        else { requested = CGFloat(block.tableLayout.row(index)) }
        return max(requested, contentRowHeight(index))
    }
    private func saveColumn(_ index: Int, width: Double) { model.resizeTable(column: index, size: width, in: block) }
    private func saveRow(_ index: Int, height: Double) { model.resizeTable(row: index, size: height, in: block) }
    private func columnHandle(_ index: Int) -> some View {
        TableResizeGrip(horizontal: true, index: index) { delta, ended in
            let value = TableLayout.width(block.tableLayout.column(index) + delta)
            if ended { saveColumn(index, width: value); columnDrag = nil }
            else { columnDrag = (index, value) }
        }
            .frame(width: 8)
            .overlay(Rectangle().fill(Color.accentColor.opacity(columnDrag?.index == index ? 0.8 : 0.08)).frame(width: 2).allowsHitTesting(false))
            .help(L10n.tr("拖动调整列宽"))
            .accessibilityLabel(L10n.tr("列宽"))
            .accessibilityValue(String(Int(columnWidth(index))))
            .accessibilityAdjustableAction { direction in
                saveColumn(index, width: Double(columnWidth(index)) + (direction == .increment ? 16 : -16))
            }
    }
    private func rowHandle(_ index: Int) -> some View {
        let startingHeight = max(CGFloat(block.tableLayout.row(index)), contentRowHeight(index))
        return TableResizeGrip(horizontal: false, index: index) { delta, ended in
            let value = TableLayout.height(Double(startingHeight) + delta)
            if ended { saveRow(index, height: value); rowDrag = nil }
            else { rowDrag = (index, value) }
        }
            .frame(height: 8)
            .overlay(Rectangle().fill(Color.accentColor.opacity(rowDrag?.index == index ? 0.8 : 0.08)).frame(height: 2).allowsHitTesting(false))
            .help(L10n.tr("拖动调整行高"))
            .accessibilityLabel(L10n.tr("行高"))
            .accessibilityValue(String(Int(rowHeight(index))))
            .accessibilityAdjustableAction { direction in
                saveRow(index, height: Double(rowHeight(index)) + (direction == .increment ? 8 : -8))
            }
    }

    private var tableContent: some View {
        VStack(alignment: .leading, spacing: 8) {
            ScrollView(.horizontal) {
                Grid(horizontalSpacing: 1, verticalSpacing: 1) {
                    ForEach(cells.indices, id: \.self) { row in
                        GridRow {
                            ForEach(cells[row].indices, id: \.self) { column in
                                TextField(row == 0 ? L10n.tr("列名") : L10n.tr("内容"), text: Binding(get: {
                                    cells[row][column]
                                }, set: { value in
                                    var updated = cells
                                    updated[row][column] = value
                                    saveCells(updated)
                                }), axis: .vertical)
                                .focused($focusedTableCell, equals: "\(row):\(column)")
                                .textFieldStyle(.plain).fontWeight(row == 0 ? .semibold : .regular)
                                .lineLimit(nil)
                                .frame(width: max(1, columnWidth(column) - 16), alignment: .leading)
                                .fixedSize(horizontal: false, vertical: true)
                                .background {
                                    GeometryReader { geometry in
                                        Color.clear.preference(key: TableCellHeightKey.self,
                                            value: [row: ceil(geometry.size.height)])
                                    }
                                }
                                .padding(8).frame(width: columnWidth(column), height: rowHeight(row), alignment: .topLeading)
                                .background(row == 0 ? Color.primary.opacity(0.06) : Color(nsColor: .textBackgroundColor))
                                .overlay(alignment: .trailing) { columnHandle(column) }
                                .overlay(alignment: .bottom) { rowHandle(row) }
                                .accessibilityLabel(L10n.tr("第 \(row + 1) 行，第 \(column + 1) 列"))
                            }
                        }
                    }
                }.padding(1).background(Color.primary.opacity(0.12))
            }
            .onPreferenceChange(TableCellHeightKey.self) { heights in
                if tableRowContentHeights != heights { tableRowContentHeights = heights }
            }
            HStack {
                Button(L10n.tr("添加行")) { saveCells(cells + [Array(repeating: "", count: cells[0].count)]) }
                Button(L10n.tr("添加列")) { saveCells(cells.map { $0 + [""] }) }
                Menu(L10n.tr("删除")) {
                    Button(L10n.tr("删除末行")) { saveCells(Array(cells.dropLast())) }.disabled(cells.count <= 1)
                    Button(L10n.tr("删除末列")) { saveCells(cells.map { Array($0.dropLast()) }) }.disabled(cells[0].count <= 1)
                }.fixedSize()
                Button(L10n.tr("重置表格尺寸")) {
                    var layout = block.tableLayout
                    layout.columnWidths = []; layout.rowHeights = []
                    model.changeTableLayout(layout, in: block)
                }
            }.font(.caption).buttonStyle(.borderless)
            Text(L10n.tr("拖动单元格右边缘调整列宽，下边缘调整行高"))
                .font(.caption2).foregroundStyle(.tertiary)
        }.frame(maxWidth: .infinity, alignment: .leading)
        .task(id: snapshot.focusRequest?.id) {
            if snapshot.focusRequest?.blockID == block.id { focusedTableCell = "0:0" }
        }
    }

    private var calloutColor: Color {
        block.kind == .success ? .green : block.kind == .warning ? .orange : .indigo
    }

    private var isMermaidCode: Bool { block.kind == .code && block.language.lowercased() == "mermaid" }

    private var richContent: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label(block.kind.label, systemImage: block.kind.symbol).font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button(action: copyCode) { Label(copied ? L10n.tr("已复制") : L10n.tr("复制源码"), systemImage: copied ? "checkmark" : "doc.on.doc") }
                Button { editingRichSource.toggle() } label: {
                    Label(editingRichSource ? L10n.tr("完成") : L10n.tr("编辑源码"), systemImage: editingRichSource ? "checkmark" : "pencil")
                }
            }.buttonStyle(.borderless).font(.caption)
            if editingRichSource || !block.hasContent {
                NativeTextEditor(text: block.text, font: .monospacedSystemFont(ofSize: codeFontSize, weight: .regular),
                                 onSelectAllBlocks: { model.selectAllBlocks(); return true }, onDeleteBlocks: deleteBlocks,
                                 onBlockMouseDown: handleBlockClick,
                                 codeLanguage: "Plain Text", sanitizePastedLaTeX: block.kind == .equation,
                                 showCodeLineNumbers: false, darkCode: colorScheme == .dark,
                                 focusRequest: snapshot.focusRequest, isFocusRequestCurrent: { model.editorFocusRequest?.id == $0 }, contentRevision: snapshot.contentRevision,
                                 onExitBlock: { model.exitBlock(block); return true },
                                 onFocus: { focused = $0 }, onHeightChange: { if abs(height - $0) > 1 { height = $0 } }) {
                    model.changeText($0, in: block)
                }
                .frame(height: max(80, height))
                .overlay(alignment: .topLeading) {
                    if block.text.isEmpty {
                        Text(block.kind.placeholder).font(.caption).foregroundStyle(.tertiary)
                            .padding(.leading, 18).padding(.top, 6).allowsHitTesting(false)
                    }
                }
                Text(block.kind == .equation ? L10n.tr("LaTeX 数学公式 · 支持分式、矩阵、积分与多行公式") : L10n.tr("Markdown · 支持表格、代码及 $…$、$$…$$、\\(…\\)、\\[…\\] 公式"))
                    .font(.caption2).foregroundStyle(.secondary)
            }
            if block.hasContent {
                RichBlockPreview(source: isMermaidCode ? ClipboardDocument.fencedMermaid(block.text) : block.text, equation: block.kind == .equation, dark: colorScheme == .dark,
                                 fontSize: editorFontSize, height: $richPreviewHeight, error: $richPreviewError)
                    .frame(height: richPreviewHeight)
                    .accessibilityLabel(block.kind == .equation ? L10n.tr("公式预览") : L10n.tr("Markdown 预览"))
            }
        }
        .padding(16)
        .background(block.kind == .equation ? Color.primary.opacity(0.025) : Color.clear,
                    in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Color.primary.opacity(editingRichSource || !block.hasContent ? 0.09 : 0)))
        .padding(.vertical, 6)
        .onChange(of: block.id) { _, _ in editingRichSource = false }
        .task(id: copied) {
            if copied {
                try? await Task.sleep(for: .seconds(2))
                if !Task.isCancelled { copied = false }
            }
        }
        .overlay(alignment: .bottomLeading) {
            if let richPreviewError { Text(richPreviewError).font(.caption).foregroundStyle(.red).padding(8) }
        }
    }

    private var codeSurface: Color {
        colorScheme == .dark ? Color(red: 0.085, green: 0.095, blue: 0.12) : Color(nsColor: .quaternarySystemFill)
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
                                 focusRequest: snapshot.focusRequest, isFocusRequestCurrent: { model.editorFocusRequest?.id == $0 }, contentRevision: snapshot.contentRevision,
                                 onExitBlock: { model.exitBlock(block); return true },
                                 onBackspaceAtStart: { model.backspaceAtStart(of: block) },
                                 onFocus: { focused = $0 },
                                 onHeightChange: { if abs(height - $0) > 1 { height = $0 } }) {
                    model.changeText($0, in: block)
                }
                .frame(height: max(24, height))
                .padding(.vertical, 8).padding(.trailing, 18)
                .accessibilityLabel(L10n.tr("代码编辑器"))
            }
        }
        .contextMenu {
            Button(L10n.tr("复制代码"), systemImage: "doc.on.doc", action: copyCode)
            Divider()
            Button(L10n.tr("转为正文")) { model.changeKind(.paragraph, of: block) }
            Button(L10n.tr("删除代码块"), role: .destructive) { model.delete(block) }
        }
        .background(codeSurface, in: RoundedRectangle(cornerRadius: 12))
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12)
            .strokeBorder(focused ? Color.accentColor.opacity(0.35) : Color.primary.opacity(0.08), lineWidth: 1))
        .padding(.vertical, 6)
    }

    private func copyCode() {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        if block.kind == .pdfDocument, let data = EmbeddedPDF.data(block.text) {
            copied = pasteboard.setData(data, forType: .pdf)
            if let text = EmbeddedPDF.document(block.text)?.string { pasteboard.setString(text, forType: .string) }
        } else if block.kind == .code { copied = ClipboardDocument.copyBlocks([TransferBlock(block)]) }
        else { copied = pasteboard.setString(block.text, forType: .string) }
    }

    private var codeHeader: some View {
        HStack(spacing: 10) {
            Image(systemName: "chevron.left.forwardslash.chevron.right")
                .font(.system(size: 12, weight: .medium)).foregroundStyle(.secondary)
            Menu {
                ForEach(["Plain Text", "Swift", "Python", "JavaScript", "TypeScript", "HTML", "CSS",
                         "JSON", "SQL", "Bash", "C", "C++", "C#", "Java", "Kotlin", "Go", "Rust",
                         "Ruby", "PHP", "YAML", "Markdown", "Mermaid"], id: \.self) { language in
                    Button {
                        model.setBlockOptions(for: block, language: language)
                    } label: {
                        if block.language == language { Label(language, systemImage: "checkmark") }
                        else { Text(language) }
                    }
                }
                Divider()
                Button(L10n.tr("自定义语言…")) {
                    customLanguage = block.language
                    showingLanguageEditor = true
                }
            } label: { Text(block.language.isEmpty ? "Plain Text" : block.language).fontWeight(.medium) }
            .menuStyle(.borderlessButton).fixedSize()
            .help(L10n.tr("选择语言"))
            Spacer(minLength: 8)
            if codeLineCount {
                Text(L10n.tr("\(snapshot.codeLineCount) 行"))
                    .monospacedDigit().foregroundStyle(.tertiary)
            }
            Menu {
                Toggle(L10n.tr("显示代码行号"), isOn: $codeLineNumbers)
                Toggle(L10n.tr("显示代码行数"), isOn: $codeLineCount)
            } label: { Image(systemName: "slider.horizontal.3").frame(width: 24, height: 24) }
                .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                .help(L10n.tr("代码显示设置"))
                .accessibilityLabel(L10n.tr("代码显示设置"))
            Button(action: copyCode) {
                Label(copied ? L10n.tr("已复制") : L10n.tr("复制"), systemImage: copied ? "checkmark" : "doc.on.doc")
                    .padding(.horizontal, 8)
                    .frame(height: 24)
                    .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 5))
                    .contentShape(Rectangle())
            }
            .help(copied ? L10n.tr("已复制到剪贴板") : L10n.tr("复制代码到剪贴板"))
            .accessibilityLabel(copied ? L10n.tr("已复制到剪贴板") : L10n.tr("复制代码到剪贴板"))
            .task(id: copied) {
                if copied {
                    try? await Task.sleep(for: .seconds(2))
                    if !Task.isCancelled { copied = false }
                }
            }
            Button { model.setBlockOptions(for: block, collapsed: !block.collapsed) } label: {
                Image(systemName: block.collapsed ? "chevron.right" : "chevron.down").frame(width: 24, height: 24)
            }
            .help(block.collapsed ? L10n.tr("展开代码") : L10n.tr("折叠代码"))
            .accessibilityLabel(block.collapsed ? L10n.tr("展开代码") : L10n.tr("折叠代码"))
        }
        .buttonStyle(.plain)
        .font(.system(size: 11))
        .foregroundStyle(.secondary)
        .padding(.horizontal, 16).padding(.vertical, 9)
        .alert(L10n.tr("自定义代码语言"), isPresented: $showingLanguageEditor) {
            TextField(L10n.tr("语言名称"), text: $customLanguage)
            Button(L10n.tr("取消"), role: .cancel) { }
            Button(L10n.tr("保存")) {
                let value = customLanguage.trimmingCharacters(in: .whitespacesAndNewlines)
                model.setBlockOptions(for: block, language: value.isEmpty ? "Plain Text" : value)
            }
        }
    }

    @ViewBuilder private var marker: some View {
        if block.kind == .toggle {
            collapseButton
        } else if block.kind.isCallout {
            Image(systemName: block.kind.symbol).foregroundStyle(calloutColor).padding(.top, 4)
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
                            Text(L10n.tr("没有匹配的块类型")).foregroundStyle(.secondary).padding(12)
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
            Text(L10n.tr("↑ ↓ 选择   ↩ 插入   esc 关闭"))
                .font(.system(size: 11)).foregroundStyle(.tertiary).padding(8)
        }
        .padding(8).frame(width: 330)
    }

    private func choose(_ kind: BlockKind) {
        dismissed = true
        model.insertSlashCommand(kind, in: block)
        if kind == .image { selectingImage = true }
    }

    private func handleCommand(_ selector: Selector, _ source: String) -> Bool {
        guard block.kind != .code, !dismissed, source.hasPrefix("/"), !source.contains("\n") else { return false }
        let commands = SlashCommandMenu.matches(source)
        switch NSStringFromSelector(selector) {
        case "cancelOperation:": dismissed = true
        case "moveDown:": selectedIndex = min(selectedIndex + 1, max(0, commands.count - 1))
        case "moveUp:": selectedIndex = max(0, selectedIndex - 1)
        case "insertNewline:", "insertTab:":
            guard !commands.isEmpty else { return false }
            choose(commands[commands.indices.contains(selectedIndex) ? selectedIndex : 0])
        default: return false
        }
        return true
    }

}
