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
    let tableCells: [[String]]
    let findMatches: [DocumentFindMatch]
    let currentFindMatch: DocumentFindMatch?

    static func make(blocks: [Block], selection: Set<UUID>, focus: EditorFocusRequest?, revisions: [UUID: UInt64] = [:], findMatches: [DocumentFindMatch] = [], currentFindMatch: DocumentFindMatch? = nil) -> [Self] {
        let headings = blocks.filter { $0.kind.isHeading }
        let findByBlock = Dictionary(grouping: findMatches, by: \.blockID)
        var number = 0
        return blocks.enumerated().map { index, block in
            let displayNumber = ListNumbering.advance(kind: block.kind, start: block.listStart, counter: &number)
            return Self(block: block, selected: selection.contains(block.id), onlyBlock: blocks.count == 1,
                        first: index == 0, last: index == blocks.count - 1,
                        focusRequest: focus?.blockID == block.id ? focus : nil,
                        number: displayNumber,
                        headings: block.kind == .tableOfContents ? headings : [], contentRevision: revisions[block.id] ?? 0,
                        codeLineCount: block.kind == .code && !block.text.isEmpty ? block.text.utf8.reduce(1) { $1 == 10 ? $0 + 1 : $0 } : 0,
                        tableCells: block.kind == .table ? tableCells(for: block) : [],
                        findMatches: findByBlock[block.id] ?? [], currentFindMatch: currentFindMatch?.blockID == block.id ? currentFindMatch : nil)
        }
    }
    private static func tableCells(for block: Block) -> [[String]] {
        if let rows = try? JSONDecoder().decode([[String]].self, from: Data(block.text.utf8)),
           !rows.isEmpty, let columns = rows.first?.count, columns > 0,
           rows.allSatisfy({ $0.count == columns }) {
            return rows.map { $0.map { TableCellContent.visible($0, layout: block.tableLayout) } }
        }
        return [[block.text, ""], ["", ""]]
    }

}

enum SlashCommandMenu {
    static func matches(_ source: String) -> [BlockKind] {
        let query = String(source.dropFirst()).trimmingCharacters(in: .whitespaces).lowercased()
        let matches = BlockKind.allCases.filter { $0 != .imageCard }.filter {
            query.isEmpty || $0.label.localizedCaseInsensitiveContains(query) || $0.rawValue.lowercased().contains(query) || $0.category.contains(query) || $0.hint.localizedCaseInsensitiveContains(query) || $0.slashAliases.contains(where: { $0.contains(query) })
        }
        // Exact commands win over related names such as tableOfContents.
        let exact = matches.filter { $0.slashAliases.contains(query) }
        return exact + matches.filter { !$0.slashAliases.contains(query) }
    }
}

/// Avoid the system _AVKit_SwiftUI VideoPlayer metadata path, which aborts
/// on this macOS runtime. The native player also accepts an explicit size.
struct NativeMediaPlayer: NSViewRepresentable {
    let player: AVPlayer?
    func makeNSView(context: Context) -> AVPlayerView {
        let view = AVPlayerView()
        view.controlsStyle = .inline
        view.player = player
        return view
    }
    func updateNSView(_ view: AVPlayerView, context: Context) {
        if view.player !== player { view.player = player }
    }
    func sizeThatFits(_ proposal: ProposedViewSize, nsView: AVPlayerView, context: Context) -> CGSize? {
        CGSize(width: max(1, proposal.width ?? 320), height: max(1, proposal.height ?? 180))
    }
    static func dismantleNSView(_ view: AVPlayerView, coordinator: ()) {
        view.player?.pause()
        view.player = nil
    }
}

private enum EditorLayout {
    static let controlsWidth: CGFloat = 50
    static let controlsSpacing: CGFloat = 8
    static let contentInset = controlsWidth + controlsSpacing
}

private struct TableCellEditor: View {
    let text: String
    let placeholder: String
    let header: Bool
    let onDeleteRow: (() -> Void)?
    let onDeleteColumn: (() -> Void)?
    let onFind: (DocumentFindAction) -> Void
    let findRanges: [NSRange]
    let currentFindRange: NSRange?
    let contentRevision: UInt64
    let focusRequest: EditorFocusRequest?
    let isFocusRequestCurrent: (UUID) -> Bool
    let onChange: (String) -> Void
    let onExit: () -> Void
    let onFocus: (Bool) -> Void
    let onContentHeightChange: (CGFloat) -> Void
    @State private var height: CGFloat = 28

    var body: some View {
        ZStack(alignment: .topLeading) {
            NativeTextEditor(text: text, font: .systemFont(ofSize: 13, weight: header ? .semibold : .regular),
                             onDeleteTableRow: onDeleteRow, onDeleteTableColumn: onDeleteColumn,
                             onDocumentFind: onFind, findRanges: findRanges, currentFindRange: currentFindRange,
                             focusRequest: focusRequest, isFocusRequestCurrent: isFocusRequestCurrent,
                             contentRevision: contentRevision,
                             onExitBlock: { onExit(); return true },
                             onFocus: onFocus,
                             onHeightChange: {
                                 if abs(height - $0) > 1 { height = $0 }
                                 onContentHeightChange($0)
                             }, onChange: onChange)
                .focusEffectDisabled()
                .frame(height: max(28, height))
            if text.isEmpty {
                Text(placeholder).font(.system(size: 13, weight: header ? .semibold : .regular))
                    .foregroundStyle(.tertiary).padding(.top, 4).allowsHitTesting(false)
            }
        }
    }
}

struct PageEditorView: View {
    @ObservedObject var model: WorkspaceModel
    let page: Page
    @FocusState private var titleFocused: Bool
    @AppStorage("editorWidePage") private var widePage = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        GeometryReader { viewport in
        let documentWidth = max(1, min(widePage ? viewport.size.width : 820, viewport.size.width - 64))
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 6) {
                    Color.clear.frame(height: 1).id("document-top")
                    TextField(L10n.tr("未命名"), text: Binding(get: { model.selectedPage?.title ?? page.title }, set: model.renameSelectedPage), axis: .vertical)
                        .textFieldStyle(.plain)
                        .font(.system(size: 40, weight: .bold, design: .default))
                        .accessibilityLabel(L10n.tr("页面标题"))
                        .focused($titleFocused)
                        .onChange(of: titleFocused) { _, focused in if focused { model.beginTitleEditing() } }
                        .contextMenu {
                            Button(L10n.tr("复制标题")) { ClipboardDocument.copyTitle(model.selectedPage?.title ?? page.title) }
                        }
                        .onSubmit {
                            if let first = model.blocks.first(where: { $0.kind.acceptsTextInput && !$0.collapsed }) {
                                model.requestFocus(first.id, offset: 0)
                            } else { model.addBlock() }
                        }
                        .padding(.leading, EditorLayout.contentInset)
                        .padding(.bottom, 16)
                        .background(model.documentFindMatches.contains(where: { $0.blockID == nil }) ? Color.yellow.opacity(0.2) : .clear)

                    ForEach(EditorRowSnapshot.make(blocks: model.blocks, selection: model.selectedBlockIDs,
                                                   focus: model.editorFocusRequest, revisions: model.editorContentRevisions,
                                                   findMatches: model.documentFindMatches, currentFindMatch: model.currentDocumentFindMatch)) { snapshot in
                        EditorBlockRow(model: model, snapshot: snapshot, availableWidth: documentWidth, scrollTo: { id in
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
                .background {
                    ZStack {
                        DocumentScrollCapture()
                        DocumentRangeSelectionCapture(documentID: page.id, begin: { id in
                            model.clearBlockSelection(); model.activeEditingBlockID = id
                        }, selectRange: { model.selectBlockRange(from: $0, through: $1) }, modifiedClick: { id, modifiers in
                            if modifiers.contains(.command) {
                                model.selectBlock(id, toggle: true); return true
                            }
                            if modifiers.contains(.shift), model.activeEditingBlockID != id || !model.selectedBlockIDs.isEmpty {
                                model.selectBlock(id, extend: true); return true
                            }
                            return false
                        })
                    }
                }
                .overlay(alignment: .bottom) { Color.clear.frame(height: 1).id("document-bottom") }
                .frame(width: documentWidth, alignment: .leading)
                .padding(.horizontal, 32)
                .padding(.top, 48)
                .padding(.bottom, 180)
                .frame(maxWidth: .infinity)
            }
            .scrollIndicators(.visible)
            .background(Color(nsColor: .textBackgroundColor))
            .safeAreaInset(edge: .top, spacing: 0) {
                if model.documentFindPresented { DocumentFindBar(model: model) }
            }
            .navigationTitle(page.title.isEmpty ? L10n.tr("未命名") : page.title)
            .toolbar {
                ToolbarItem(placement: .navigation) {
                    HStack(spacing: 2) {
                    Menu {
                        ForEach(BlockKind.categories, id: \.self) { category in
                            Section(category) {
                                ForEach(BlockKind.allCases.filter { $0 != .imageCard }.filter { $0.category == category }) { kind in
                                    Button { model.addBlock(kind) } label: { Label(kind.label, systemImage: kind.symbol) }
                                        .labelStyle(.titleAndIcon)
                                }
                            }
                        }
                    } label: { Label(L10n.tr("插入块"), systemImage: "plus") }
                    .menuStyle(.borderlessButton).menuIndicator(.hidden)
                    .frame(width: 28, height: 28)
                    .accessibilityLabel(L10n.tr("插入块"))
                    .help(L10n.tr("插入块，也可输入 / 搜索"))
                    Button { widePage.toggle() } label: {
                        Label(widePage ? L10n.tr("阅读宽度") : L10n.tr("全宽页面"), systemImage: widePage ? "rectangle.center.inset.filled" : "rectangle")
                    }.frame(width: 28, height: 28)
                    .accessibilityLabel(widePage ? L10n.tr("阅读宽度") : L10n.tr("全宽页面"))
                    .help(widePage ? L10n.tr("切换为阅读宽度") : L10n.tr("切换为全宽页面"))
                    Menu {
                        Button(L10n.tr("在文档中查找…")) { model.performDocumentFind(.show) }
                        Divider()
                        Button(L10n.tr("跳到文档开头  ⌘↑")) { model.jumpToDocumentBoundary(atStart: true) }
                        Button(L10n.tr("跳到文档末尾  ⌘↓")) { model.jumpToDocumentBoundary(atStart: false) }
                        Divider()
                        Button(L10n.tr("将本页网络图片转为本地")) { model.localizePageImages() }
                            .disabled(model.automationBusy || !model.blocks.contains { $0.kind == .image && ($0.text.hasPrefix("http://") || $0.text.hasPrefix("https://")) })
                        Divider()
                        Button(L10n.tr("全选内容  ⌘A")) { model.selectAllBlocks() }
                    } label: { Label(L10n.tr("文档导航"), systemImage: "arrow.up.arrow.down") }
                    .menuStyle(.borderlessButton).menuIndicator(.hidden)
                    .frame(width: 28, height: 28).accessibilityLabel(L10n.tr("文档导航"))
                    }
                    .labelStyle(.iconOnly).buttonStyle(.plain).controlSize(.small)
                    .font(.system(size: 14, weight: .medium)).foregroundStyle(.secondary).tint(.primary)
                    .padding(.horizontal, 4)
                }
            }
            .background(DocumentKeyboardCapture(selected: !model.selectedBlockIDs.isEmpty,
                selectAll: model.selectAllBlocks, delete: deleteSelection, copy: model.copySelectedBlocks, escape: model.clearBlockSelection,
                insertAfter: model.continueAfterSelectedBlocks,
                boundary: { model.jumpToDocumentBoundary(atStart: $0, extend: $1) }).frame(width: 0, height: 0))
            .safeAreaInset(edge: .bottom) {
                if !model.selectedBlockIDs.isEmpty {
                    HStack {
                        Text(L10n.tr("已选中 \(model.selectedBlockIDs.count) 个块")).fontWeight(.medium)
                        Text(L10n.tr("↩ 下方继续 · Shift 范围选择 · ⌘A 全选 · Esc 取消")).foregroundStyle(.secondary).font(.caption)
                        Spacer()
                        Button(L10n.tr("复制所选内容")) { model.copySelectedBlocks() }
                        Button(L10n.tr("创建所选块副本")) {
                            let ids = model.selectedBlockIDs
                            Task { do { try await model.duplicateBlocks(ids) } catch { model.errorMessage = error.localizedDescription } }
                        }.disabled(model.automationBusy)
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
            .onChange(of: model.currentDocumentFindMatch) { _, match in
                guard let match else { return }
                if let id = match.blockID {
                    if let block = model.blocks.first(where: { $0.id == id }), block.collapsed {
                        model.setBlockOptions(for: block, collapsed: false)
                    }
                    proxy.scrollTo(id, anchor: .center)
                } else { proxy.scrollTo("document-top", anchor: .top) }
            }
            .onDisappear { Task { await model.flushAll() } }
        }
        }
    }
    private func deleteSelection() {
        Task { do { try await model.deleteSelectedBlocks() } catch { model.errorMessage = error.localizedDescription } }
    }
}

private struct DocumentFindBar: View {
    @ObservedObject var model: WorkspaceModel
    @FocusState private var focused: Bool
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
        HStack(spacing: 4) {
            Button { model.documentReplacePresented.toggle() } label: {
                Image(systemName: model.documentReplacePresented ? "chevron.down" : "chevron.right").font(.system(size: 10, weight: .semibold)).frame(width: 20, height: 28)
            }.help(L10n.tr("显示或隐藏替换"))
            HStack(spacing: 8) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
            TextField(L10n.tr("在本文档中查找"), text: $model.documentFindQuery)
                .textFieldStyle(.plain).focusEffectDisabled().focused($focused)
                .accessibilityLabel(L10n.tr("在本文档中查找"))
                .onKeyPress(keys: [.return], phases: .down) { key in
                    model.performDocumentFind(key.modifiers.contains(.shift) ? .previous : .next)
                    return .handled
                }
            Text(model.documentFindQuery.isEmpty ? "" : model.documentFindMatches.isEmpty ? L10n.tr("无匹配项") : "\(model.documentFindIndex + 1) / \(model.documentFindMatches.count)")
                .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                .fixedSize()
                .accessibilityLabel(L10n.tr("查找结果"))
            }
            .padding(.horizontal, 8).frame(height: 30)
            .background(Color.primary.opacity(0.025), in: RoundedRectangle(cornerRadius: 6))
            Button { model.performDocumentFind(.previous) } label: { Image(systemName: "chevron.up").font(.system(size: 11, weight: .medium)).frame(width: 26, height: 28) }
                .help(L10n.tr("上一个匹配项") + " ⇧⌘G").disabled(model.documentFindMatches.isEmpty)
            Button { model.performDocumentFind(.next) } label: { Image(systemName: "chevron.down").font(.system(size: 11, weight: .medium)).frame(width: 26, height: 28) }
                .help(L10n.tr("下一个匹配项") + " ⌘G").disabled(model.documentFindMatches.isEmpty)
            Divider().frame(height: 14).padding(.horizontal, 3)
            Button { model.closeDocumentFind() } label: { Image(systemName: "xmark").font(.system(size: 11, weight: .medium)).frame(width: 26, height: 28) }
                .help(L10n.tr("关闭查找") + " Esc").keyboardShortcut(.cancelAction)
        }
        if model.documentReplacePresented {
            HStack(spacing: 8) {
                Image(systemName: "arrow.turn.down.right").foregroundStyle(.secondary).frame(width: 24)
                TextField(L10n.tr("替换为（留空则删除匹配文本）"), text: $model.documentReplacement)
                    .textFieldStyle(.plain).padding(.horizontal, 8).frame(height: 30)
                    .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 7))
                    .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(Color.primary.opacity(0.08)))
                    .accessibilityLabel(L10n.tr("替换为"))
                    .onSubmit { model.replaceDocumentMatches(all: false) }
            }
            HStack(spacing: 8) {
                if let count = model.documentReplacementCount {
                    Text(String(format: L10n.tr("已替换 %d 处"), count)).font(.caption).foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
                Button(L10n.tr("撤销替换")) { model.undoDocumentReplacement() }
                    .disabled(!model.canUndoDocumentReplacement)
                Button(L10n.tr("替换")) { model.replaceDocumentMatches(all: false) }
                    .disabled(model.documentFindMatches.isEmpty || model.automationBusy)
                Button(L10n.tr("全部替换")) { model.replaceDocumentMatches(all: true) }
                    .disabled(model.documentFindMatches.isEmpty || model.automationBusy)
            }.buttonStyle(.bordered).controlSize(.small).padding(.leading, 32)
        }
        }
        .font(.system(size: 12)).buttonStyle(.plain).foregroundStyle(.secondary)
        .padding(8).frame(maxWidth: 560)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Color.primary.opacity(0.07)))
        .shadow(color: .black.opacity(0.05), radius: 6, y: 2)
        .padding(.horizontal, 20).padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .trailing)
        .background(Color(nsColor: .textBackgroundColor))
        .onAppear { focused = true }
        .onChange(of: model.documentFindFocusID) { _, _ in focused = true }
        .onExitCommand { model.closeDocumentFind() }
    }
}

private struct EditorBlockRow: View, Equatable {
    let model: WorkspaceModel
    let snapshot: EditorRowSnapshot
    let availableWidth: CGFloat
    private var block: Block { snapshot.block }

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.model === rhs.model && lhs.snapshot == rhs.snapshot && lhs.availableWidth == rhs.availableWidth
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
    @State private var showingImagePreview = false
    @State private var imageDragWidth: Double?
    @State private var displayedImageWidth: CGFloat = 0
    @State private var selectingMedia = false
    @State private var savingResource = false
    @State private var savedResourceURL: URL?
    @State private var resourceSaveTask: Task<Void, Never>?
    @State private var mediaError: String?
    @State private var playerObservation: NSKeyValueObservation?
    @State private var playbackSource: URL?
    @State private var customLanguage = ""
    @State private var showingLanguageEditor = false
    @State private var selectedTableRow: Int?
    @State private var selectedTableColumn: Int?
    @State private var focusedTableCell: String?
    @State private var player: AVPlayer?
    @State private var hovered = false
    @State private var focused = false
    @State private var height: CGFloat = 30
    @State private var dismissed = false
    @State private var selectedIndex = 0
    @State private var columnDrag: (index: Int, value: Double)?
    @State private var rowDrag: (index: Int, value: Double)?
    @State private var tableCellContentHeights: [Int: [Int: CGFloat]] = [:]

    private var commands: [BlockKind] { SlashCommandMenu.matches(block.text) }
    private var showingCommands: Bool {
        block.kind == .paragraph && focused && !dismissed && block.text.hasPrefix("/") && !block.text.contains("\n")
    }
    private var showsBlockControls: Bool {
        let richPreview = block.kind == .equation || block.kind == .markdown || isMermaidCode
        let editingText = focused && block.kind.acceptsTextInput && !block.collapsed
            && (!richPreview || editingRichSource || !block.hasContent)
        return hovered || editingText || snapshot.selected || showingCommands
            || !block.kind.acceptsTextInput || block.collapsed
            || selectingImage || selectingMedia || showingLanguageEditor || columnDrag != nil || rowDrag != nil
    }

    var body: some View {
        HStack(alignment: .top, spacing: EditorLayout.controlsSpacing) {
            HStack(spacing: 2) {
                Menu {
                    ForEach(BlockKind.categories, id: \.self) { category in
                        Section(category) {
                            ForEach(BlockKind.allCases.filter { $0 != .imageCard }.filter { $0.category == category }) { kind in
                                Button { model.addBlock(kind, after: block) } label: {
                                    Label(kind.label, systemImage: kind.symbol)
                                }
                            }
                        }
                    }
                } label: {
                    Image(systemName: "plus").font(.system(size: 16))
                        .frame(width: 24, height: 28).contentShape(Rectangle())
                }
                .menuStyle(.borderlessButton).menuIndicator(.hidden).frame(width: 24, height: 28)
                .help(L10n.tr("在下方插入…"))
                .accessibilityLabel(L10n.tr("在下方插入…"))
                blockMenu
            }
            .foregroundStyle(Color(red: 0.45, green: 0.47, blue: 0.56))
            .frame(width: EditorLayout.controlsWidth)
            .padding(.top, block.kind == .code ? 12 : block.kind.isCallout ? 11 : 1)
            .opacity(showsBlockControls ? 1 : 0)
            .allowsHitTesting(showsBlockControls)
            .accessibilityHidden(!showsBlockControls)
            .animation(reduceMotion ? nil : .easeOut(duration: 0.12), value: showsBlockControls)
            VStack(alignment: .leading, spacing: 8) {
            if block.kind == .pdfDocument {
                PDFDocumentBlock(source: Binding(get: { block.text }, set: { model.changeText($0, in: block) }), extract: { text in
                    model.addBlock(.markdown, after: block, text: text)
                })
            } else if block.kind == .imageCard {
                if let card = ImageTextCard.decode(block.text) {
                    ImageTextCardEditor(card: card) { model.changeText($0.encoded, in: block) }
                } else { Text(L10n.tr("图文卡片无法读取")) }
            } else if block.kind == .image {
                imageContent
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
                        NativeTextEditor(text: block.text, font: font, lineSpacing: block.kind.isHeading ? 0 : 4, formatting: block.formatting,
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
                                         onDocumentFind: model.performDocumentFind,
                                         findRanges: snapshot.findMatches.map(\.range), currentFindRange: snapshot.currentFindMatch?.range,
                                         focusRequest: snapshot.focusRequest, isFocusRequestCurrent: { model.editorFocusRequest?.id == $0 }, contentRevision: snapshot.contentRevision,
                                         onReturnBlock: { model.returnFromSingleLineBlock(block, text: $0, formatting: $1, selection: $2) },
                                         onExitBlock: { model.exitBlock(block); return true },
                                         shiftReturnInsertsNewline: block.kind.returnSplitsBlock || block.kind.exitsOnTrailingEmptyLine,
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
            if savingResource || savedResourceURL != nil { resourceSaveFeedback }
            }
            .padding(.horizontal, block.kind.isCallout ? 12 : 0)
            .padding(.vertical, block.kind.isCallout ? 10 : 0)
            .frame(width: max(1, availableWidth - EditorLayout.contentInset), alignment: .leading)
            .background(block.kind.isCallout ? calloutColor.opacity(0.09) : .clear, in: RoundedRectangle(cornerRadius: 8))
            .clipped()
        }
        .frame(width: availableWidth, alignment: .leading)
        .background(snapshot.selected ? Color.accentColor.opacity(0.10) : .clear, in: RoundedRectangle(cornerRadius: 7))
        .overlay(RoundedRectangle(cornerRadius: 7).stroke(snapshot.selected ? Color.accentColor.opacity(0.4) : .clear))
        .padding(.top, block.kind.isHeading && !snapshot.first ? 16 : 0)
        .padding(.vertical, block.kind == .code ? 0 : 3)
        .background(DocumentBlockSelectionAnchor(blockID: block.id))
        .sheet(isPresented: $selectingMedia) {
            MediaSourcePicker(kind: block.kind, source: block.text) { model.changeText($0, in: block) }
        }
        .sheet(isPresented: $showingImagePreview) { ImageZoomPreview(source: block.text) }
        .sheet(isPresented: $selectingImage) { ImageSourcePicker(initialValue: block.text) { model.setImageSource($0, in: block) } }
        .contentShape(Rectangle())
        .onHover { hovered = $0 }
        .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(snapshot.currentFindMatch == nil ? Color.clear : Color.accentColor.opacity(0.5), lineWidth: 1).allowsHitTesting(false))
        .zIndex(showingCommands ? 1 : 0)
    }

    private func pasteDocument(_ plain: String?, _ html: String?, _ original: String, _ runs: [TextStyleRun], _ range: NSRange) -> Bool {
        let copiedBlocks = ClipboardDocument.blocks(from: .general)
        let proseKinds: Set<BlockKind> = [.paragraph, .heading, .heading2, .heading3, .bullet, .numbered, .todo, .toggle, .quote, .callout, .warning, .success]
        guard proseKinds.contains(block.kind), copiedBlocks != nil || ClipboardDocument.isStructured(plain, html: html) else { return false }
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

    @ViewBuilder private var imageContent: some View {
        if block.text.isEmpty {
            Button { selectingImage = true } label: {
                Label(L10n.tr("从 URL 或本地文件选择图片"), systemImage: "photo.badge.plus")
                    .frame(maxWidth: .infinity, minHeight: 96)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain).foregroundStyle(.secondary)
            .background(Color.primary.opacity(0.025), in: RoundedRectangle(cornerRadius: 6))
            .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Color.secondary.opacity(0.2), style: StrokeStyle(lineWidth: 1, dash: [5, 4])).allowsHitTesting(false))
        } else {
            MediaImageView(source: block.text, preferredWidth: imageDragWidth ?? block.imageWidth)
                .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { displayedImageWidth = $0 }
                .onTapGesture(count: 2) { showingImagePreview = true }
                .clipShape(RoundedRectangle(cornerRadius: 4))
                .overlay(alignment: .topTrailing) {
                    HStack(spacing: 6) {
                        Button(action: saveResource) { Image(systemName: "arrow.down.to.line") }
                            .disabled(savingResource).help(L10n.tr("保存到本地…")).accessibilityLabel(L10n.tr("保存到本地…"))
                        Button { showingImagePreview = true } label: { Image(systemName: "arrow.up.left.and.arrow.down.right") }
                            .help(L10n.tr("放大查看")).accessibilityLabel(L10n.tr("放大查看"))
                        Button { selectingImage = true } label: { Image(systemName: "arrow.triangle.2.circlepath") }
                            .help(L10n.tr("更换图片…")).accessibilityLabel(L10n.tr("更换图片…"))
                    }
                        .buttonStyle(.bordered)
                        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 6))
                        .padding(8)
                        .opacity(hovered || snapshot.selected ? 1 : 0)
                        .allowsHitTesting(hovered || snapshot.selected)
                        .accessibilityHidden(!hovered && !snapshot.selected)
                }
                .overlay(alignment: .trailing) {
                    let startingWidth = Double(displayedImageWidth)
                    TableResizeGrip(horizontal: true, index: 0, identifierPrefix: "image") { delta, ended in
                        let value = min(max(80, Double(availableWidth - EditorLayout.contentInset)), max(80, startingWidth + delta))
                        imageDragWidth = value
                        if ended { commitImageWidth(value) }
                    }
                    .frame(width: 14)
                    .overlay(Capsule().fill(Color.secondary.opacity(0.6)).frame(width: 4, height: 32).allowsHitTesting(false))
                    .opacity(hovered || snapshot.selected || imageDragWidth != nil ? 1 : 0)
                    .allowsHitTesting(hovered || snapshot.selected || imageDragWidth != nil)
                    .help(L10n.tr("拖动调整图片大小"))
                    .accessibilityLabel(L10n.tr("图片宽度"))
                    .accessibilityAdjustableAction { direction in commitImageWidth(startingWidth + (direction == .increment ? 32 : -32)) }
                }
                .contextMenu {
                    Button(L10n.tr("保存到本地…"), action: saveResource).disabled(savingResource)
                    Button(L10n.tr("与下方文字合并为图文卡片")) { model.mergeImageWithFollowingText(block) }
                    if block.text.hasPrefix("http://") || block.text.hasPrefix("https://") {
                        Button(L10n.tr("转为文档内本地图片")) { model.localizeImage(block) }
                    }
                    Divider()
                    Button(L10n.tr("放大查看")) { showingImagePreview = true }
                    Button(L10n.tr("恢复默认大小")) { commitImageWidth(nil) }
                    Button(L10n.tr("更换图片…")) { selectingImage = true }
                }
        }
    }

    @ViewBuilder private var resourceSaveFeedback: some View {
        HStack(spacing: 8) {
            if savingResource {
                ProgressView().controlSize(.small)
                Text(L10n.tr("正在准备媒体文件…"))
                Button(L10n.tr("取消")) { resourceSaveTask?.cancel() }
            } else if let url = savedResourceURL {
                Image(systemName: "checkmark.circle").foregroundStyle(.green)
                Text(L10n.tr("已保存到本地"))
                Button(L10n.tr("在 Finder 中显示")) { NSWorkspace.shared.activateFileViewerSelecting([url]) }
            }
        }.font(.caption).foregroundStyle(.secondary).buttonStyle(.borderless)
    }

    private func saveResource() {
        guard !savingResource else { return }
        let source = block.text, kind = block.kind
        let parentWindow = NSApp.keyWindow
        savingResource = true; savedResourceURL = nil
        resourceSaveTask = Task { @MainActor in
            defer { savingResource = false; resourceSaveTask = nil }
            do {
                let resource = try await MediaResourceExporter.prepare(source: source, kind: kind)
                defer { resource.discard() }
                try Task.checkCancellation()
                let panel = NSSavePanel()
                panel.title = L10n.tr("保存到本地")
                panel.prompt = L10n.tr("保存")
                panel.nameFieldStringValue = resource.filename
                panel.canCreateDirectories = true
                panel.isExtensionHidden = false
                let result: NSApplication.ModalResponse = await withCheckedContinuation { continuation in
                    if let parentWindow, parentWindow.isVisible, parentWindow.attachedSheet == nil {
                        panel.beginSheetModal(for: parentWindow) { continuation.resume(returning: $0) }
                    } else { panel.begin { continuation.resume(returning: $0) } }
                }
                guard result == .OK, let destination = panel.url else { return }
                try await resource.write(to: destination)
                if model.blocks.first(where: { $0.id == block.id })?.text == source { savedResourceURL = destination }
            } catch is CancellationError { }
            catch let error as URLError where error.code == .cancelled { }
            catch { model.errorMessage = L10n.tr("保存媒体失败：") + error.localizedDescription }
        }
    }

    private func commitImageWidth(_ width: Double?) {
        Task {
            do { try await model.resizeImage(width, in: block) }
            catch { model.errorMessage = error.localizedDescription }
            imageDragWidth = nil
        }
    }

    private var blockMenu: some View {
        Menu {
            if MediaResourceExporter.supports(block.kind), !block.text.isEmpty {
                Button(L10n.tr("保存到本地…"), systemImage: "arrow.down.to.line", action: saveResource).disabled(savingResource)
                Divider()
            }
            if block.kind == .image {
                if !block.text.isEmpty {
                    Button(L10n.tr("放大查看")) { showingImagePreview = true }
                    Button(L10n.tr("恢复默认大小")) { commitImageWidth(nil) }
                }
                Button(block.text.isEmpty ? L10n.tr("选择图片…") : L10n.tr("更换图片…")) { selectingImage = true }
                Divider()
            }
            if block.kind == .numbered {
                Button(L10n.tr("接续前一编号")) {
                    Task { do { try await model.continueListNumbering(in: block) } catch { model.errorMessage = error.localizedDescription } }
                }
                Button(L10n.tr("从 1 重新编号")) {
                    Task { do { try await model.setListStart(1, in: block) } catch { model.errorMessage = error.localizedDescription } }
                }
                Divider()
            }
            let conversions = BlockKind.allCases.filter { $0 != .imageCard }.filter { $0 != block.kind && block.kind.canConvert(to: $0) }
            if !conversions.isEmpty {
                Menu(L10n.tr("转换为")) {
                    ForEach(conversions) { kind in
                        Button { model.changeKind(kind, of: block) } label: {
                            Label(kind.label, systemImage: kind.symbol)
                        }
                    }
                }
            }
            Divider()
            Button(L10n.tr("创建块副本"), systemImage: "plus.square.on.square") {
                Task { do { try await model.duplicateBlocks([block.id]) } catch { model.errorMessage = error.localizedDescription } }
            }.disabled(model.automationBusy)
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

    private var mediaURL: URL? { MediaSource.url(block.text) }

    @ViewBuilder private var mediaPreview: some View {
        HStack {
            Button(block.text.isEmpty ? L10n.tr("选择媒体或文件…") : L10n.tr("更换来源…")) { selectingMedia = true }
            Spacer()
            if MediaResourceExporter.supports(block.kind), !block.text.isEmpty {
                Button(L10n.tr("保存到本地…"), action: saveResource).disabled(savingResource)
            }
        }.font(.caption).buttonStyle(.borderless)
        if let url = mediaURL {
            if url.isFileURL && !FileManager.default.isReadableFile(atPath: url.path) {
                Label(L10n.tr("文件不存在或无法读取，请重新选择。"), systemImage: "exclamationmark.triangle")
                    .font(.callout).foregroundStyle(.secondary)
            } else if block.kind == .video || block.kind == .audio {
                VStack(alignment: .leading, spacing: 8) {
                    NativeMediaPlayer(player: player).frame(maxWidth: .infinity).frame(height: block.kind == .audio ? 80 : 280)
                    if let mediaError { Text(mediaError).font(.caption).foregroundStyle(.secondary) }
                    Button(url.isFileURL ? L10n.tr("打开文件") : L10n.tr("在浏览器打开")) { NSWorkspace.shared.open(url) }
                        .font(.caption).buttonStyle(.borderless)
                }
                .task(id: url) {
                    playerObservation?.invalidate(); player?.pause(); mediaError = nil; playbackSource = url
                    let item = AVPlayerItem(url: url)
                    playerObservation = item.observe(\.status, options: [.new, .initial]) { item, _ in
                        if item.status == .failed {
                            Task { @MainActor in
                                if playbackSource == url { mediaError = L10n.tr("此来源无法直接播放，可在外部打开或更换为音视频文件链接。") }
                            }
                        }
                    }
                    player = AVPlayer(playerItem: item)
                }
                .onDisappear { playerObservation?.invalidate(); playerObservation = nil; playbackSource = nil; player?.pause() }
            } else {
                Button { NSWorkspace.shared.open(url) } label: {
                    HStack(spacing: 12) {
                        Image(systemName: block.kind.symbol).font(.title2)
                        VStack(alignment: .leading, spacing: 4) {
                            Text(url.isFileURL || block.kind == .file ? url.lastPathComponent : url.host ?? L10n.tr("网页链接"))
                                .lineLimit(1).truncationMode(.middle)
                            Text(url.isFileURL ? url.path : url.absoluteString).font(.caption).foregroundStyle(.secondary)
                                .lineLimit(1).truncationMode(.middle)
                        }.frame(maxWidth: .infinity, alignment: .leading)
                        Image(systemName: "arrow.up.right")
                    }.padding(14).frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 8))
                }.buttonStyle(.plain)
            }
        } else if !block.text.isEmpty && !showingCommands {
            Text(L10n.tr("请输入有效链接或选择本地文件。")).font(.caption).foregroundStyle(.secondary)
        }
    }

    private var cells: [[String]] { snapshot.tableCells }

    private func saveCells(_ rows: [[String]]) { model.changeTableCells(rows, in: block) }

    private func columnWidth(_ index: Int) -> CGFloat {
        if let columnDrag, columnDrag.index == index { return CGFloat(columnDrag.value) }
        return CGFloat(block.tableLayout.column(index))
    }
    private func contentRowHeight(_ row: Int) -> CGFloat {
        max(28, tableCellContentHeights[row]?.values.max() ?? 28) + 16
    }
    private func rowHeight(_ index: Int) -> CGFloat {
        let requested: CGFloat
        if let rowDrag, rowDrag.index == index { requested = CGFloat(rowDrag.value) }
        else { requested = CGFloat(block.tableLayout.row(index)) }
        return requested
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

    private var tableGridWidth: CGFloat {
        cells[0].indices.reduce(CGFloat(2 + max(0, cells[0].count - 1))) { $0 + columnWidth($1) }
    }

    private var tableControlsVisible: Bool {
        focusedTableCell != nil || snapshot.selected || columnDrag != nil || rowDrag != nil
    }

    private func tableAxisMenu(_ index: Int, row: Bool, axisCount: Int) -> some View {
        let title = String(format: L10n.tr(row ? "第 %d 行操作" : "第 %d 列操作"), index + 1)
        return Menu {
            Button(String(format: L10n.tr(row ? "删除第 %d 行" : "删除第 %d 列"), index + 1), role: .destructive) {
                if row { deleteTableRow(index) } else { deleteTableColumn(index) }
            }
            .disabled(axisCount <= 1)
        } label: {
            Text(" ")
        }
        .menuStyle(.borderlessButton).menuIndicator(.hidden)
        .frame(width: 18, height: 18)
        .background(Color(nsColor: .textBackgroundColor), in: Circle())
        .overlay(Circle().strokeBorder(Color.secondary.opacity(0.3), lineWidth: 1.5).allowsHitTesting(false))
        .overlay {
            Image(systemName: "equal")
                .font(.system(size: 10, weight: .medium))
                .rotationEffect(.degrees(row ? 0 : 90))
                .foregroundStyle(.primary)
                .allowsHitTesting(false)
                .accessibilityHidden(true)
        }
        .contentShape(Circle())
        .help(title).accessibilityLabel(title)
        .opacity(tableControlsVisible ? 1 : 0)
        .allowsHitTesting(tableControlsVisible)
        .accessibilityHidden(!tableControlsVisible)
    }

    private var tableContent: some View {
        VStack(alignment: .leading, spacing: 8) {
            ScrollView(.horizontal) {
                VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 5) {
                VStack(alignment: .leading, spacing: 1) {
                    ForEach(cells.indices, id: \.self) { row in
                        HStack(alignment: .top, spacing: 1) {
                            ForEach(cells[row].indices, id: \.self) { column in
                                TableCellEditor(text: cells[row][column], placeholder: row == 0 ? L10n.tr("列名") : L10n.tr("内容"),
                                                header: row == 0,
                                                onDeleteRow: cells.count > 1 ? { deleteTableRow(row) } : nil,
                                                onDeleteColumn: cells[0].count > 1 ? { deleteTableColumn(column) } : nil,
                                                onFind: model.performDocumentFind,
                                                findRanges: snapshot.findMatches.filter { $0.row == row && $0.column == column }.map(\.range),
                                                currentFindRange: snapshot.currentFindMatch.flatMap { $0.row == row && $0.column == column ? $0.range : nil },
                                                contentRevision: snapshot.contentRevision,
                                                focusRequest: row == 0 && column == 0 ? snapshot.focusRequest : nil,
                                                isFocusRequestCurrent: { model.editorFocusRequest?.id == $0 },
                                                onChange: { value in
                                    var updated = cells
                                    updated[row][column] = value
                                    saveCells(updated)
                                }, onExit: { model.exitBlock(block) }, onFocus: { active in
                                    let cellID = "\(row):\(column)"
                                    if active { focusedTableCell = cellID }
                                    else if focusedTableCell == cellID { focusedTableCell = nil }
                                    if active { selectedTableRow = row; selectedTableColumn = column }
                                }, onContentHeightChange: { measured in
                                    guard measured.isFinite, measured > 0 else { return }
                                    let value = ceil(measured)
                                    if tableCellContentHeights[row]?[column] != value {
                                        tableCellContentHeights[row, default: [:]][column] = value
                                    }
                                })
                                .frame(width: max(1, columnWidth(column) - 16), alignment: .leading)
                                .fixedSize(horizontal: false, vertical: true)
                                .padding(8)
                                .frame(width: columnWidth(column), alignment: .leading)
                                // Explicit intrinsic row heights avoid Grid's
                                // unbounded-height negotiation inside a lazy page.
                                .frame(height: max(rowHeight(row), contentRowHeight(row)), alignment: .topLeading)
                                .background {
                                    Color(nsColor: .textBackgroundColor)
                                        .overlay(row == 0 ? Color.primary.opacity(0.025) : .clear)
                                }
                                .clipped()
                                .overlay(Rectangle().strokeBorder(Color.primary.opacity(0.12), lineWidth: 0.5).allowsHitTesting(false))
                                .overlay(alignment: .trailing) { columnHandle(column) }
                                .overlay(alignment: .bottom) { rowHandle(row) }
                                .overlay {
                                    if tableControlsVisible && selectedTableRow == row && selectedTableColumn == column {
                                        Rectangle().strokeBorder(Color.cyan, lineWidth: 2).allowsHitTesting(false)
                                    }
                                }
                                .contextMenu {
                                    Button(L10n.tr("删除所在行"), role: .destructive) { deleteTableRow(row) }
                                        .disabled(cells.count <= 1)
                                    Button(L10n.tr("删除所在列"), role: .destructive) { deleteTableColumn(column) }
                                        .disabled(cells[0].count <= 1)
                                }
                                .accessibilityLabel(L10n.tr("第 \(row + 1) 行，第 \(column + 1) 列"))
                                .overlay(alignment: .leading) {
                                    if column == 0 { tableAxisMenu(row, row: true, axisCount: cells.count).offset(x: -9) }
                                }
                                .overlay(alignment: .top) {
                                    if row == 0 { tableAxisMenu(column, row: false, axisCount: cells[0].count).offset(y: -9) }
                                }
                            }
                        }
                    }
                }.padding(1)
                Button { model.appendTableAxes(row: false, column: true, in: block) } label: {
                    Label(L10n.tr("添加列"), systemImage: "plus").labelStyle(.iconOnly)
                        .frame(width: 28).frame(maxHeight: .infinity)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain).background(Color.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: 7))
                .help(L10n.tr("添加列"))
                .opacity(tableControlsVisible ? 1 : 0).allowsHitTesting(tableControlsVisible)
                .accessibilityHidden(!tableControlsVisible)
                }.fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 5) {
                    Button { model.appendTableAxes(row: true, column: false, in: block) } label: {
                        Label(L10n.tr("添加行"), systemImage: "plus").labelStyle(.iconOnly)
                            .frame(width: tableGridWidth, height: 28).contentShape(Rectangle())
                    }
                    .buttonStyle(.plain).background(Color.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: 7))
                    .help(L10n.tr("添加行"))
                    Button { model.appendTableAxes(row: true, column: true, in: block) } label: {
                        Label(L10n.tr("添加行和列"), systemImage: "plus").labelStyle(.iconOnly)
                            .frame(width: 28, height: 28).contentShape(Circle())
                    }
                    .buttonStyle(.plain).background(Color.primary.opacity(0.045), in: Circle())
                    .help(L10n.tr("添加行和列"))
                }
                .opacity(tableControlsVisible ? 1 : 0).allowsHitTesting(tableControlsVisible)
                .accessibilityHidden(!tableControlsVisible)
                }
                // Reserve only the circular handles' overhang, not a separate grid column.
                .padding(.top, 10).padding(.leading, 10)
            }
        }.frame(maxWidth: .infinity, alignment: .leading)
    }

    private func deleteTableRow(_ row: Int) {
        NSApp.keyWindow?.makeFirstResponder(nil)
        tableCellContentHeights = Dictionary(uniqueKeysWithValues: tableCellContentHeights.compactMap { index, heights in
            index == row ? nil : (index > row ? index - 1 : index, heights)
        })
        rowDrag = nil; columnDrag = nil
        selectedTableRow = nil; selectedTableColumn = nil
        model.deleteTableRow(row, in: block)
    }

    private func deleteTableColumn(_ column: Int) {
        NSApp.keyWindow?.makeFirstResponder(nil)
        tableCellContentHeights = tableCellContentHeights.mapValues { heights in
            Dictionary(uniqueKeysWithValues: heights.compactMap { index, height in
                index == column ? nil : (index > column ? index - 1 : index, height)
            })
        }
        rowDrag = nil; columnDrag = nil
        selectedTableRow = nil; selectedTableColumn = nil
        model.deleteTableColumn(column, in: block)
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
                                 onDeleteBlocks: deleteBlocks,
                                 onBlockMouseDown: handleBlockClick,
                                 onDocumentFind: model.performDocumentFind,
                                 findRanges: snapshot.findMatches.map(\.range), currentFindRange: snapshot.currentFindMatch?.range,
                                 codeLanguage: "Plain Text", sanitizePastedLaTeX: block.kind == .equation,
                                 showCodeLineNumbers: false, darkCode: colorScheme == .dark,
                                 focusRequest: snapshot.focusRequest, isFocusRequestCurrent: { model.editorFocusRequest?.id == $0 }, contentRevision: snapshot.contentRevision,
                                 onExitBlock: { model.exitBlock(block); return true },
                                 onFocus: {
                                     focused = $0
                                     if $0 { editingRichSource = true }
                                 }, onHeightChange: { if abs(height - $0) > 1 { height = $0 } }) {
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
                                 onHeadingShortcut: { model.convertToHeading($0, text: $1, formatting: $2, selection: $3, in: block) },
                                 onDeleteBlocks: deleteBlocks,
                                 onDocumentBoundary: { model.jumpToDocumentBoundary(atStart: $0, extend: $1); return true },
                                 onBlockMouseDown: handleBlockClick,
                                 onDocumentFind: model.performDocumentFind,
                                 findRanges: snapshot.findMatches.map(\.range), currentFindRange: snapshot.currentFindMatch?.range,
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
        } else { copied = ClipboardDocument.copyBlocks(model.clipboardBlocks([block.id])) }
    }

    private var codeHeader: some View {
        HStack(spacing: 10) {
            Image(systemName: "chevron.left.forwardslash.chevron.right")
                .font(.system(size: 12, weight: .medium)).foregroundStyle(.secondary)
            Menu {
                ForEach(CodeLanguage.groups) { group in
                    Menu(L10n.text(group.title)) {
                    ForEach(group.languages, id: \.self) { language in
                    Button {
                        model.setBlockOptions(for: block, language: language)
                    } label: {
                        if CodeLanguage.canonical(block.language) == language { Label(language, systemImage: "checkmark") }
                        else { Text(language) }
                    }
                    }
                    }
                }
                Divider()
                Button(L10n.tr("自定义语言…")) {
                    customLanguage = block.language
                    showingLanguageEditor = true
                }
            } label: { Text(CodeLanguage.canonical(block.language)).fontWeight(.medium) }
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
        else if kind.isMedia { selectingMedia = true }
    }

    private func handleCommand(_ selector: Selector, _ source: String) -> Bool {
        guard block.kind == .paragraph, !dismissed, source.hasPrefix("/"), !source.contains("\n") else { return false }
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


private struct ImageTextCardEditor: View {
    let card: ImageTextCard
    let onChange: (ImageTextCard) -> Void
    @State private var image: NSImage?
    private func binding(_ key: WritableKeyPath<ImageTextCard, String>) -> Binding<String> {
        Binding(get: { card[keyPath: key] }, set: { value in var copy = card; copy[keyPath: key] = value; onChange(copy) })
    }
    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            Group {
                if let image { Image(nsImage: image).resizable().scaledToFit().frame(width: min(68, image.size.width), height: min(68, image.size.height)) }
                else if let url = URL(string: card.image), url.scheme == "https" || url.scheme == "http" {
                    AsyncImage(url: url) { picture in picture.resizable().scaledToFit().padding(4) } placeholder: { ProgressView() }
                } else { Image(systemName: "photo").foregroundStyle(.secondary) }
            }
            .frame(width: 76, height: 76)
            .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 14))
            .overlay(RoundedRectangle(cornerRadius: 14).stroke(Color.secondary.opacity(0.14), lineWidth: 1))
            .accessibilityLabel(L10n.tr("图片"))
            VStack(alignment: .leading, spacing: 7) {
                TextField(L10n.tr("标题"), text: binding(\.title), axis: .vertical)
                    .font(.system(size: 17, weight: .semibold)).accessibilityLabel(L10n.tr("卡片标题"))
                TextField(L10n.tr("说明"), text: binding(\.body), axis: .vertical)
                    .font(.system(size: 16)).accessibilityLabel(L10n.tr("卡片说明"))
                TextField(L10n.tr("关键词"), text: binding(\.caption), axis: .vertical)
                    .font(.system(size: 14)).foregroundStyle(.secondary).accessibilityLabel(L10n.tr("卡片关键词"))
            }.textFieldStyle(.plain).frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.vertical, 12)
        .overlay(alignment: .bottom) { Divider().opacity(0.6) }
        .task(id: card.image) { image = card.image.hasPrefix("data:") ? ImageSource.thumbnail(card.image) : nil }
    }
}
