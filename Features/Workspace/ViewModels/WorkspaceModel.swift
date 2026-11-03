import Foundation
import SwiftUI

struct DocumentBoundaryRequest {
    let id = UUID()
    let atStart: Bool
}

struct EditorFocusRequest: Equatable {
    let id = UUID()
    let blockID: UUID
    let offset: Int
}

enum DocumentFindAction: Equatable { case show, replace, next, previous }

struct DocumentFindMatch: Equatable {
    let blockID: UUID?
    let row: Int?
    let column: Int?
    let range: NSRange

    static func search(_ query: String, title: String, blocks: [Block]) -> [Self] {
        guard !query.isEmpty else { return [] }
        var results: [Self] = []
        func append(_ text: String, blockID: UUID?, row: Int? = nil, column: Int? = nil) {
            let source = text as NSString
            var offset = 0
            while offset < source.length {
                let range = source.range(of: query, options: [.caseInsensitive, .diacriticInsensitive],
                                         range: NSRange(location: offset, length: source.length - offset))
                guard range.location != NSNotFound, range.length > 0 else { break }
                results.append(Self(blockID: blockID, row: row, column: column, range: range))
                offset = NSMaxRange(range)
            }
        }
        append(title, blockID: nil)
        for block in blocks {
            if block.kind == .table,
               let rows = try? JSONDecoder().decode([[String]].self, from: Data(block.text.utf8)) {
                for (row, cells) in rows.enumerated() {
                    for (column, cell) in cells.enumerated() {
                        append(TableCellContent.visible(cell, layout: block.tableLayout), blockID: block.id, row: row, column: column)
                    }
                }
            } else if !block.kind.isMedia && ![.pdfDocument, .divider, .tableOfContents].contains(block.kind) {
                append(block.text, blockID: block.id)
            }
        }
        return results
    }
}

@MainActor
final class WorkspaceModel: ObservableObject {
    @Published private(set) var pages: [Page] = [] {
        didSet {
            if oldValue != pages {
                sidebarPageIndex = SidebarPageIndex(pages: pages)
                sidebarPageRevision = UUID()
            }
            refreshDocumentFind()
        }
    }
    private(set) var sidebarPageIndex = SidebarPageIndex(pages: [])
    private(set) var sidebarPageRevision = UUID()
    @Published private(set) var blocks: [Block] = [] { didSet { refreshDocumentFind() } }
    @Published private(set) var selectedBlockIDs: Set<UUID> = []
    @Published private(set) var documentBoundaryRequest: DocumentBoundaryRequest?
    private var blockSelectionAnchor: UUID?
    var activeEditingBlockID: UUID?
    @Published var selectedPageID: UUID? { didSet { if oldValue != selectedPageID { closeDocumentFind(); lastDocumentReplacement = nil } } }
    @Published var searchText = ""
    @Published private(set) var documentFindPresented = false
    @Published var documentFindQuery = "" { didSet { documentReplacementCount = nil; refreshDocumentFind() } }
    @Published var documentReplacePresented = false
    @Published var documentReplacement = "" { didSet { documentReplacementCount = nil } }
    @Published private(set) var documentReplacementCount: Int?
    private var replacingDocumentFind = false
    private struct ReplacementSnapshot {
        let pageID: UUID
        let titleBefore: String?
        let titleAfter: String?
        let before: [Block]
        let after: [Block]
    }
    @Published private var lastDocumentReplacement: ReplacementSnapshot?
    var canUndoDocumentReplacement: Bool {
        guard let snapshot = lastDocumentReplacement, snapshot.pageID == selectedPageID,
              snapshot.titleAfter == nil || snapshot.titleAfter == selectedPage?.title else { return false }
        return snapshot.after.allSatisfy { saved in blocks.first { $0.id == saved.id } == saved }
    }
    @Published private(set) var documentFindMatches: [DocumentFindMatch] = []
    @Published private(set) var documentFindIndex = 0
    @Published private(set) var documentFindFocusID = UUID()
    var currentDocumentFindMatch: DocumentFindMatch? {
        documentFindMatches.indices.contains(documentFindIndex) ? documentFindMatches[documentFindIndex] : nil
    }

    func performDocumentFind(_ action: DocumentFindAction) {
        guard selectedPage != nil else { return }
        if action == .replace { documentReplacePresented = true }
        if action == .show || action == .replace || !documentFindPresented {
            documentFindPresented = true
            documentFindFocusID = UUID()
            refreshDocumentFind()
        } else if !documentFindMatches.isEmpty {
            let delta = action == .previous ? -1 : 1
            documentFindIndex = (documentFindIndex + delta + documentFindMatches.count) % documentFindMatches.count
        }
        if let id = currentDocumentFindMatch?.blockID, let block = blocks.first(where: { $0.id == id }), block.collapsed {
            setBlockOptions(for: block, collapsed: false)
        }
    }

    func closeDocumentFind() {
        documentFindPresented = false
        documentFindMatches = []; documentFindIndex = 0
        documentReplacementCount = nil
    }

    private func refreshDocumentFind() {
        guard documentFindPresented, !replacingDocumentFind else { return }
        let previous = currentDocumentFindMatch
        let matches = DocumentFindMatch.search(documentFindQuery, title: selectedPage?.title ?? "", blocks: blocks)
        if matches != documentFindMatches { documentFindMatches = matches }
        documentFindIndex = previous.flatMap { matches.firstIndex(of: $0) } ?? 0
    }

    func replaceDocumentMatches(all: Bool) {
        guard documentFindPresented, !automationBusy, let pageID = selectedPageID else { return }
        refreshDocumentFind()
        let matches = all ? documentFindMatches : currentDocumentFindMatch.map { [$0] } ?? []
        guard !matches.isEmpty else { documentReplacementCount = 0; return }
        let replacement = documentReplacement
        let grouped = Dictionary(grouping: matches, by: \.blockID)
        let before = blocks.filter { grouped[$0.id] != nil }
        let titleBefore = grouped[nil] == nil ? nil : selectedPage?.title
        replacingDocumentFind = true
        if let titleBefore, let titleMatches = grouped[nil] {
            renameSelectedPage(RichInlineContent.replacing(titleBefore, runs: [], ranges: titleMatches.map(\.range), with: replacement).text)
        }
        for block in before {
            guard let hits = grouped[block.id] else { continue }
            if block.kind == .table,
               let raw = try? JSONDecoder().decode([[String]].self, from: Data(block.text.utf8)) {
                var rows = raw.map { $0.map { TableCellContent.visible($0, layout: block.tableLayout) } }
                for row in rows.indices {
                    for column in rows[row].indices {
                        let ranges = hits.filter { $0.row == row && $0.column == column }.map(\.range)
                        rows[row][column] = RichInlineContent.replacing(rows[row][column], runs: [], ranges: ranges, with: replacement).text
                    }
                }
                changeTableCells(rows, in: block)
            } else {
                let changed = RichInlineContent.replacing(block.text, runs: block.formatting, ranges: hits.map(\.range), with: replacement)
                changeRichText(changed.text, formatting: changed.runs, in: block)
            }
            editorContentRevisions[block.id, default: 0] &+= 1
        }
        lastDocumentReplacement = ReplacementSnapshot(pageID: pageID, titleBefore: titleBefore,
            titleAfter: titleBefore == nil ? nil : selectedPage?.title, before: before,
            after: blocks.filter { grouped[$0.id] != nil })
        replacingDocumentFind = false
        refreshDocumentFind()
        if !all, let previous = matches.first {
            func position(_ match: DocumentFindMatch) -> (Int, Int, Int, Int) {
                (match.blockID.flatMap { id in blocks.firstIndex { $0.id == id } }.map { $0 + 1 } ?? 0,
                 match.row ?? -1, match.column ?? -1, match.range.location)
            }
            var next = previous
            next = DocumentFindMatch(blockID: next.blockID, row: next.row, column: next.column,
                                     range: NSRange(location: previous.range.location + replacement.utf16.count, length: 0))
            documentFindIndex = documentFindMatches.firstIndex { position($0) >= position(next) } ?? 0
        } else { documentFindIndex = 0 }
        documentReplacementCount = matches.count
    }

    func undoDocumentReplacement() {
        guard canUndoDocumentReplacement, let snapshot = lastDocumentReplacement else { return }
        replacingDocumentFind = true
        if let title = snapshot.titleBefore { renameSelectedPage(title) }
        for block in snapshot.before {
            changeRichText(block.text, formatting: block.formatting, in: block)
            if block.kind == .table { changeTableLayout(block.tableLayout, in: block) }
            editorContentRevisions[block.id, default: 0] &+= 1
        }
        lastDocumentReplacement = nil; documentReplacementCount = nil
        replacingDocumentFind = false
        refreshDocumentFind()
    }
    @Published var errorMessage: String?
    @Published private(set) var saving = false
    @Published private(set) var automationBusy = false
    var workspaceTransitioning = false

    @Published private(set) var editorFocusRequest: EditorFocusRequest?
    @Published private(set) var editorContentRevisions: [UUID: UInt64] = [:]
    private var pendingConversions: [UUID: Task<Void, Never>] = [:]

    private var pageLoadTask: Task<Void, Never>?
    private var pageLoadGeneration = UUID()
    private var loadedPageID: UUID?
    private var pageCache: [UUID: [Block]] = [:]
    private var cachedPageOrder: [UUID] = []

    private func cacheCurrentPage() {
        guard let id = loadedPageID, id == selectedPageID else { return }
        // Bound retained content, especially embedded PDF/image data URLs.
        let size = blocks.reduce(0) { $0 + $1.text.utf8.count }
        guard size <= 4 * 1024 * 1024 else {
            pageCache[id] = nil
            cachedPageOrder.removeAll { $0 == id }
            return
        }
        pageCache[id] = blocks
        cachedPageOrder.removeAll { $0 == id }
        cachedPageOrder.append(id)
        while cachedPageOrder.count > 4 { pageCache[cachedPageOrder.removeFirst()] = nil }
    }

    private var creatingTrailingInput: Set<UUID> = []
    private let store: SQLiteStore
    private var pendingWrites: [UUID: Task<Void, Never>] = [:]
    private var latestText: [UUID: String] = [:]
    private var latestFormatting: [UUID: [TextStyleRun]] = [:]
    private var latestTableLayouts: [UUID: TableLayout] = [:]

    init(store: SQLiteStore) {
        self.store = store
        Task { await refreshPages() }
    }

    var selectedPage: Page? { pages.first { $0.id == selectedPageID } }

    var visiblePages: [Page] {
        let active = pages.filter { !$0.archived }
        guard !searchText.isEmpty else { return active }
        return active.filter { $0.title.localizedCaseInsensitiveContains(searchText) }
    }

    func refreshPages() async {
        do {
            pages = try await store.pages()
            // Refresh follows imports, automation and structural mutations.
            // Those operations may change pages that are currently cached.
            pageCache.removeAll()
            cachedPageOrder.removeAll()
        }
        catch { report(error) }
    }

    func select(_ pageID: UUID?) {
        // List can repeat its selection binding while SwiftUI reconciles rows.
        // Do not tear down and rebuild the current editor for those writes.
        guard selectedPageID != pageID else { return }
        cacheCurrentPage()
        pageLoadTask?.cancel()
        let generation = UUID()
        pageLoadGeneration = generation
        selectedPageID = pageID
        selectedBlockIDs = []; blockSelectionAnchor = nil; activeEditingBlockID = nil
        editorFocusRequest = nil
        documentBoundaryRequest = nil
        let cached = pageID.flatMap { pageCache[$0] }
        blocks = cached ?? []
        loadedPageID = cached == nil ? nil : pageID
        pageLoadTask = Task { [weak self] in
            guard let self else { return }
            // Pending edits belong to block IDs, so selection need not wait for I/O.
            // Save before reloading a page to avoid showing an older stored version.
            await flushAll()
            guard !Task.isCancelled, pageLoadGeneration == generation, let pageID else { return }
            // Cached content is visible immediately; revalidate in the background
            // to include mutations that completed after the outgoing snapshot.
            let displayed = blocks
            do {
                let loaded = try await store.blocks(in: pageID)
                guard !Task.isCancelled, pageLoadGeneration == generation else { return }
                // Never overwrite edits made while a cached page was being read.
                guard cached == nil || blocks == displayed else { return }
                let refreshed = loaded.map { block in
                    var block = block
                    if let text = latestText[block.id] {
                        block.text = text
                        block.formatting = latestFormatting[block.id] ?? []
                        block.tableLayout = latestTableLayouts[block.id] ?? block.tableLayout
                    }
                    return block
                }
                if blocks != refreshed { blocks = refreshed }
                loadedPageID = pageID
                ensurePageHasInput()
            } catch {
                if !Task.isCancelled, pageLoadGeneration == generation { report(error) }
            }
        }
    }

    func createPage(parentID: UUID? = nil) {
        Task {
            do {
                let (page, firstBlock) = try await store.createPageWithInitialBlock(parentID: parentID)
                pages.append(page)
                pages.sort { $0.order == $1.order ? $0.id.uuidString < $1.id.uuidString : $0.order < $1.order }
                pageCache[page.id] = [firstBlock]
                cachedPageOrder.append(page.id)
                select(page.id)
                requestFocus(firstBlock.id, offset: 0)
            } catch { report(error) }
        }
    }

    func duplicatePage(_ page: Page) async throws {
        guard !workspaceTransitioning, !automationBusy else { throw AppError.message(L10n.tr("正在执行其他操作，请稍后重试")) }
        automationBusy = true; defer { automationBusy = false }
        await flushAll()
        guard !saving else { throw AppError.message(L10n.tr("存在未保存内容，创建副本已停止")) }
        let id = try await store.duplicatePage(page.id)
        await refreshPages()
        select(id)
    }

    func beginTitleEditing() {
        clearBlockSelection()
        activeEditingBlockID = nil
        editorFocusRequest = nil
    }

    func renameSelectedPage(_ title: String) {
        guard let id = selectedPageID else { return }
        if let index = pages.firstIndex(where: { $0.id == id }) { pages[index].title = title }
        Task {
            do { try await store.renamePage(id, title: title) }
            catch { report(error) }
        }
    }

    func archive(_ page: Page) {
        Task {
            do {
                await flushAll()
                try await store.archivePage(page.id, archived: true)
                await refreshPages()
                if selectedPage?.archived == true { select(nil) }
            } catch { report(error) }
        }
    }

    var trashedPages: [Page] {
        pages.filter { page in
            guard page.archived else { return false }
            guard let parentID = page.parentID, let parent = pages.first(where: { $0.id == parentID }), parent.archived else { return true }
            return page.trashBatch == nil || page.trashBatch != parent.trashBatch
        }.sorted { $0.updatedAt > $1.updatedAt }
    }

    func isDescendant(_ candidate: UUID, of pageID: UUID) -> Bool {
        var current: UUID? = candidate
        var visited: Set<UUID> = []
        while let id = current, visited.insert(id).inserted {
            if id == pageID { return true }
            current = sidebarPageIndex.byID[id]?.parentID
        }
        return false
    }

    private var pageMoveQueued = false

    func move(_ page: Page, to parentID: UUID?, before beforeID: UUID? = nil) {
        guard !pageMoveQueued, !automationBusy, !workspaceTransitioning else { return }
        pageMoveQueued = true
        // Native menus and drag sessions use nested tracking loops. Reordering
        // their owning List rows inside those callbacks invalidates active hosts.
        // Apply structural mutations only after returning to the default mode.
        RunLoop.main.perform(inModes: [.default]) { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                Task { await self.performPageMove(page.id, to: parentID, before: beforeID) }
            }
        }
    }

    private func performPageMove(_ id: UUID, to parentID: UUID?, before beforeID: UUID?) async {
        defer { pageMoveQueued = false }
        guard !automationBusy, !workspaceTransitioning else { return }
        automationBusy = true
        defer { automationBusy = false }
        do {
            await flushAll()
            guard !saving else { throw AppError.message(L10n.tr("存在未保存内容，操作已停止")) }
            let reordered = try await store.movePage(id, toParent: parentID, before: beforeID)
            // Reordering does not change block contents. Keep the live editor,
            // selection, focus and visited-page cache rather than reloading them.
            if pages != reordered { pages = reordered }
        } catch { report(error) }
    }

    func move(_ page: Page, by offset: Int) {
        let siblings = pages.filter { !$0.archived && $0.parentID == page.parentID }
        guard let index = siblings.firstIndex(where: { $0.id == page.id }), siblings.indices.contains(index + offset) else { return }
        let beforeIndex = offset < 0 ? index - 1 : index + 2
        move(page, to: page.parentID, before: siblings.indices.contains(beforeIndex) ? siblings[beforeIndex].id : nil)
    }

    func rename(_ page: Page, to title: String) {
        Task {
            do { try await store.renamePage(page.id, title: title); await refreshPages() }
            catch { report(error) }
        }
    }

    func restore(_ page: Page) {
        Task {
            do { try await store.restorePage(page.id); await refreshPages() }
            catch { report(error) }
        }
    }

    func permanentlyDelete(_ page: Page) {
        Task {
            do { try await store.permanentlyDeletePage(page.id); await refreshPages() }
            catch { report(error) }
        }
    }

    func archiveAllPages() {
        Task {
            do {
                await flushAll()
                guard !saving else { throw AppError.message("尚有内容未保存，工作空间未切换") }
                try await store.archiveAllPages(); await refreshPages(); select(nil)
            } catch { report(error) }
        }
    }

    func restoreAllPages() {
        Task { do { try await store.restoreAllPages(); await refreshPages() } catch { report(error) } }
    }

    func emptyTrash() {
        Task {
            do { try await store.emptyTrash(); await refreshPages() }
            catch { report(error) }
        }
    }

    func exitBlock(_ block: Block) {
        guard let index = blocks.firstIndex(where: { $0.id == block.id }), selectedPageID == block.pageID else { return }
        clearBlockSelection()
        if blocks.indices.contains(index + 1), blocks[index + 1].kind == .paragraph, blocks[index + 1].text.isEmpty {
            requestFocus(blocks[index + 1].id, offset: 0)
        } else { addBlock(after: blocks[index]) }
    }

    func continueAfterSelectedBlocks() {
        guard let last = blocks.last(where: { selectedBlockIDs.contains($0.id) }) else { return }
        clearBlockSelection()
        exitBlock(last)
    }

    func returnFromSingleLineBlock(_ block: Block, text: String, formatting: [TextStyleRun], selection: NSRange) -> Bool {
        guard let current = blocks.first(where: { $0.id == block.id }), selectedPageID == block.pageID else { return false }
        if current.kind.isMedia { exitBlock(current); return true }
        if current.kind.exitsOnTrailingEmptyLine {
            // Leave a multiline prose block only from its final empty line.
            // Keep source editors and table cells outside this rule.
            guard selection.length == 0, selection.location == text.utf16.count,
                  text.isEmpty || text.hasSuffix("\n") else { return false }
            let body = text.isEmpty ? "" : String(text.dropLast())
            let runs = formatting.compactMap { run -> TextStyleRun? in
                guard let valid = run.validRange(in: text) else { return nil }
                let range = NSIntersectionRange(valid, NSRange(location: 0, length: body.utf16.count))
                return range.length > 0 ? TextStyleRun(location: range.location, length: range.length, style: run.style) : nil
            }
            changeRichText(body, formatting: runs, in: current)
            exitBlock(current)
            return true
        }
        guard current.kind.returnSplitsBlock else { return false }
        guard let index = blocks.firstIndex(where: { $0.id == block.id }), selectedPageID == block.pageID,
              selection.location <= text.utf16.count, selection.length <= text.utf16.count - selection.location else { return false }
        if text.isEmpty, current.kind != .paragraph {
            insertSlashCommand(.paragraph, in: blocks[index], text: ""); return true
        }
        let original = blocks[index]
        // Return at the start of a heading creates room above it. Splitting
        // the heading here would turn all of its content into body text.
        if original.kind.isHeading, selection.location == 0, selection.length == 0 {
            let paragraph = Block(id: UUID(), pageID: original.pageID, kind: .paragraph,
                text: "", order: original.order, checked: false)
            blocks.insert(paragraph, at: index)
            requestFocus(paragraph.id, offset: 0)
            let previous = pendingConversions[original.id]
            let operation = Task { [weak self] in
                if let previous { await previous.value }
                guard let self else { return }
                defer {
                    pendingConversions[paragraph.id] = nil
                    saving = !latestText.isEmpty || !pendingConversions.isEmpty
                }
                do { try await store.splitTextBlock(original, inserting: paragraph, before: true) }
                catch {
                    blocks.removeAll { $0.id == paragraph.id }
                    requestFocus(original.id, offset: 0)
                    report(error)
                }
            }
            pendingConversions[paragraph.id] = operation
            saving = true
            return true
        }
        let source = text as NSString
        let end = NSMaxRange(selection)
        func sliced(_ range: NSRange, body: Bool) -> [TextStyleRun] {
            formatting.compactMap { run in
                guard let valid = run.validRange(in: text) else { return nil }
                let overlap = NSIntersectionRange(valid, range)
                guard overlap.length > 0 else { return nil }
                var style = run.style
                if body { style.fontSize = nil; style.bold = nil }
                return style.isEmpty ? nil : TextStyleRun(location: overlap.location - range.location, length: overlap.length, style: style)
            }
        }
        var first = original
        first.text = source.substring(to: selection.location)
        first.formatting = sliced(NSRange(location: 0, length: selection.location), body: false)
        var second = Block(id: UUID(), pageID: original.pageID, kind: original.kind.isHeading ? .paragraph : original.kind,
            text: source.substring(from: end), order: original.order + 1, checked: false)
        second.formatting = sliced(NSRange(location: end, length: source.length - end), body: original.kind.isHeading)
        let previous = pendingConversions[original.id]
        pendingWrites[original.id]?.cancel(); pendingWrites[original.id] = nil
        latestText[original.id] = nil; latestFormatting[original.id] = nil; latestTableLayouts[original.id] = nil
        let revision = (editorContentRevisions[original.id] ?? 0) &+ 1
        editorContentRevisions[original.id] = revision
        blocks[index] = first; blocks.insert(second, at: index + 1)
        requestFocus(second.id, offset: 0)
        let operation = Task { [weak self] in
            if let previous { await previous.value }
            guard let self else { return }
            defer {
                if editorContentRevisions[first.id] == revision { pendingConversions[first.id] = nil }
                if editorContentRevisions[second.id] == nil { pendingConversions[second.id] = nil }
                saving = !latestText.isEmpty || !pendingConversions.isEmpty
            }
            do { try await store.splitTextBlock(first, inserting: second) }
            catch {
                if let current = blocks.firstIndex(where: { $0.id == first.id }), blocks[current] == first {
                    if editorContentRevisions[first.id] == revision { pendingConversions[first.id] = nil }
                    var restored = original; restored.text = text; restored.formatting = formatting
                    blocks[current] = restored
                    editorContentRevisions[first.id] = revision &+ 1
                    latestText[first.id] = text; latestFormatting[first.id] = formatting; latestTableLayouts[first.id] = restored.tableLayout
                    scheduleWrite(first.id)
                }
                if blocks.first(where: { $0.id == second.id }) == second {
                    blocks.removeAll { $0.id == second.id }; requestFocus(original.id, offset: selection.location)
                }
                report(error)
            }
        }
        pendingConversions[first.id] = operation; pendingConversions[second.id] = operation
        saving = true
        return true
    }

    func addBlock(_ kind: BlockKind = .paragraph, after previous: Block? = nil, text: String = "") {
        guard let id = selectedPageID else { return }
        Task {
            do {
                if let previous, let conversion = pendingConversions[previous.id] { await conversion.value }
                var block = try await store.createBlock(pageID: id, kind: kind, after: previous)
                let initial = text.isEmpty ? kind.initialText : text
                if !initial.isEmpty { try await store.updateBlock(block.id, text: initial); block.text = initial }
                if selectedPageID == id {
                    if let previous, let index = blocks.firstIndex(where: { $0.id == previous.id }) {
                        blocks.insert(block, at: index + 1)
                    } else {
                        blocks.append(block)
                    }
                    requestFocus(block.id, offset: 0)
                }
            } catch { report(error) }
        }
    }

    func moveBlock(_ block: Block, offset: Int) {
        Task {
            do {
                let ordered = try await store.moveBlock(block.id, pageID: block.pageID, offset: offset)
                guard selectedPageID == block.pageID else { return }
                let positions = Dictionary(uniqueKeysWithValues: ordered.map { ($0.id, $0.order) })
                blocks = blocks.map { item in
                    var updated = item; updated.order = positions[item.id] ?? item.order; return updated
                }.sorted { $0.order < $1.order }
            } catch { report(error) }
        }
    }

    func pasteDocument(plain: String?, html: String?, original: String, formatting: [TextStyleRun], selection: NSRange, in block: Block, copiedBlocks: [TransferBlock]? = nil) {
        Task {
            do {
                let source = copiedBlocks == nil ? try await ClipboardDocument.markdown(plain: plain, html: html) : " "
                guard !source.isEmpty else { throw AppError.message(L10n.tr("剪贴板中没有可粘贴的文档内容")) }
                guard selectedPageID == block.pageID, let current = blocks.first(where: { $0.id == block.id }),
                      current.text == original, current.kind == block.kind else {
                    throw AppError.message(L10n.tr("粘贴期间内容已变化，请在目标位置重新粘贴"))
                }
                let combined = ClipboardDocument.replacing(original, formatting: formatting, selection: selection, with: source)
                var imported: [TransferBlock]
                if let copiedBlocks { imported = ClipboardDocument.inserting(copiedBlocks, into: original, formatting: formatting, selection: selection, destination: TransferBlock(current)) }
                else if current.kind != .paragraph {
                    let incoming = try DocumentTransfer.markdown(source, title: "", consumeLeadingTitle: false).pages[0].blocks
                    imported = ClipboardDocument.inserting(incoming, into: original, formatting: formatting, selection: selection, destination: TransferBlock(current))
                }
                else { imported = try DocumentTransfer.markdown(combined, title: "", consumeLeadingTitle: false).pages[0].blocks }
                if imported.isEmpty { imported = [TransferBlock(.paragraph)] }
                imported = try await LocalDocumentImages.blocks(imported)
                guard selectedPageID == current.pageID,
                      let latest = blocks.first(where: { $0.id == current.id }), latest == current else {
                    throw AppError.message("图片下载期间目标内容已变化，请重新粘贴")
                }
                pendingWrites[current.id]?.cancel(); pendingWrites[current.id] = nil
                latestText[current.id] = nil; latestFormatting[current.id] = nil; latestTableLayouts[current.id] = nil
                let inserted = try await store.replaceBlock(current.id, pageID: current.pageID, with: imported)
                guard selectedPageID == current.pageID, let index = blocks.firstIndex(where: { $0.id == current.id }) else { return }
                blocks.replaceSubrange(index...index, with: inserted)
                saving = !latestText.isEmpty || !pendingConversions.isEmpty
                clearBlockSelection()
                if let last = inserted.last { requestFocus(last.id, offset: last.text.utf16.count) }
            } catch { report(error) }
        }
    }

    func mergeImageWithFollowingText(_ image: Block) {
        Task {
            guard !automationBusy, !workspaceTransitioning else { return }
            automationBusy = true; defer { automationBusy = false }
            do {
                await flushAll()
                guard !saving, let index = blocks.firstIndex(where: { $0.id == image.id }), blocks[index].kind == .image else { return }
                let following = Array(blocks.dropFirst(index + 1).prefix(3).prefix { $0.kind.supportsProseConversion && !$0.text.isEmpty })
                guard following.count >= 2 else { throw AppError.message("图片下方至少需要标题和说明两段文字") }
                let sources = [blocks[index]] + following
                let initial = ImageTextCard(image: blocks[index].text, title: following[0].text, body: following[1].text, caption: following.count > 2 ? following[2].text : "")
                let localized = try await LocalDocumentImages.blocks([TransferBlock(.imageCard, initial.encoded)])
                guard sources.allSatisfy({ old in blocks.contains(old) }), let card = ImageTextCard.decode(localized[0].text) else { throw AppError.message("内容已变化，请重试") }
                try await store.mergeImageCard(sources, card: card)
                blocks[index].kind = .imageCard; blocks[index].text = card.encoded; blocks[index].imageWidth = nil
                blocks.removeSubrange((index + 1)...(index + following.count))
            } catch { report(error) }
        }
    }

    func localizePageImages() {
        Task {
            guard !automationBusy, !workspaceTransitioning, let pageID = selectedPageID else { return }
            automationBusy = true; defer { automationBusy = false }
            do {
                await flushAll()
                guard !saving else { throw AppError.message("存在未保存内容，请稍后重试") }
                let originals = blocks.filter { $0.kind == .image && ($0.text.hasPrefix("http://") || $0.text.hasPrefix("https://")) }
                guard !originals.isEmpty else { return }
                let converted = try await LocalDocumentImages.blocks(originals.map(TransferBlock.init))
                guard selectedPageID == pageID, originals.allSatisfy({ old in blocks.contains { $0 == old } }) else {
                    throw AppError.message("图片下载期间页面已变化，请重试")
                }
                let images = Dictionary(uniqueKeysWithValues: zip(originals, converted).map { ($0.0.id, $0.1.text) })
                try await store.embedPageImages(images, expected: Dictionary(uniqueKeysWithValues: originals.map { ($0.id, $0.text) }), pageID: pageID)
                for index in blocks.indices { if let source = images[blocks[index].id] { blocks[index].text = source } }
            } catch { report(error) }
        }
    }

    func localizeImage(_ block: Block) { setImageSource(block.text, in: block) }

    func setImageSource(_ source: String, in block: Block) {
        Task {
            do {
                let converted = try await LocalDocumentImages.blocks([TransferBlock(.image, try ImageSource.validated(source))])
                guard selectedPageID == block.pageID, let current = blocks.first(where: { $0.id == block.id }), current == block else {
                    throw AppError.message("图片已变化，未覆盖当前内容")
                }
                if let image = converted.first { changeText(image.text, in: current); await flushAll() }
            } catch { report(error) }
        }
    }

    func changeText(_ text: String, in block: Block) {
        changeRichText(text, formatting: [], in: block)
    }

    func changeRichText(_ text: String, formatting: [TextStyleRun], in block: Block) {
        guard let index = blocks.firstIndex(where: { $0.id == block.id }) else { return }
        guard blocks[index].text != text || blocks[index].formatting != formatting else { return }
        var updated = blocks[index]
        updated.text = text
        updated.formatting = formatting
        blocks[index] = updated
        latestText[block.id] = text
        latestFormatting[block.id] = formatting
        latestTableLayouts[block.id] = updated.tableLayout
        scheduleWrite(block.id)
    }

    func setListStart(_ start: Int?, in block: Block) async throws {
        guard !workspaceTransitioning, blocks.contains(where: { $0.id == block.id && $0.kind == .numbered }) else { return }
        let value = ListNumbering.start(start)
        try await store.setListStart(value, for: block.id)
        pageCache[block.pageID] = nil
        cachedPageOrder.removeAll { $0 == block.pageID }
        if let index = blocks.firstIndex(where: { $0.id == block.id }), blocks[index].kind == .numbered { blocks[index].listStart = value }
    }

    func continueListNumbering(in block: Block) async throws {
        guard let index = blocks.firstIndex(where: { $0.id == block.id }) else { return }
        var counter = 0
        var previous: Int?
        for item in blocks[..<index] {
            let number = ListNumbering.advance(kind: item.kind, start: item.listStart, counter: &counter)
            if item.kind == .numbered { previous = number }
        }
        try await setListStart(previous.map { min($0 + 1, 1_000_000_000) } ?? 1, in: block)
    }

    func resizeImage(_ width: Double?, in block: Block) async throws {
        guard !workspaceTransitioning, let current = blocks.first(where: { $0.id == block.id }), current.kind == .image else { return }
        let value = ImageSizing.width(width)
        try await store.setImageWidth(value, for: block.id)
        pageCache[block.pageID] = nil
        cachedPageOrder.removeAll { $0 == block.pageID }
        if let index = blocks.firstIndex(where: { $0.id == block.id }), blocks[index].kind == .image {
            blocks[index].imageWidth = value
        }
    }

    func changeTableLayout(_ layout: TableLayout, in block: Block) {
        guard let index = blocks.firstIndex(where: { $0.id == block.id }), blocks[index].kind == .table,
              blocks[index].tableLayout != layout else { return }
        blocks[index].tableLayout = layout
        latestText[block.id] = blocks[index].text
        latestFormatting[block.id] = blocks[index].formatting
        latestTableLayouts[block.id] = layout
        scheduleWrite(block.id)
    }

    func changeTableCells(_ rows: [[String]], in block: Block) {
        guard let current = blocks.first(where: { $0.id == block.id }), current.kind == .table,
              let columns = rows.first?.count, columns > 0, rows.allSatisfy({ $0.count == columns }),
              let data = try? JSONEncoder().encode(rows) else { return }
        changeText(String(decoding: data, as: UTF8.self), in: current)
        var layout = current.tableLayout.fitted(rows: rows.count, columns: columns)
        layout.cellsArePlain = true
        changeTableLayout(layout, in: current)
    }

    func appendTableAxes(row: Bool, column: Bool, in block: Block) {
        guard row || column, let current = blocks.first(where: { $0.id == block.id }), current.kind == .table,
              let raw = try? JSONDecoder().decode([[String]].self, from: Data(current.text.utf8)),
              let columns = raw.first?.count, columns > 0, raw.allSatisfy({ $0.count == columns }) else { return }
        var cells = raw.map { $0.map { TableCellContent.visible($0, layout: current.tableLayout) } }
        if column { cells = cells.map { $0 + [""] } }
        if row { cells.append(Array(repeating: "", count: columns + (column ? 1 : 0))) }
        changeTableCells(cells, in: current)
    }

    func deleteTableRow(_ row: Int, in block: Block) {
        deleteTableAxis(row: row, column: nil, in: block)
    }

    func deleteTableColumn(_ column: Int, in block: Block) {
        deleteTableAxis(row: nil, column: column, in: block)
    }

    private func deleteTableAxis(row: Int?, column: Int?, in block: Block) {
        guard let current = blocks.first(where: { $0.id == block.id }), current.kind == .table,
              var rows = try? JSONDecoder().decode([[String]].self, from: Data(current.text.utf8)),
              let columns = rows.first?.count, columns > 0, rows.allSatisfy({ $0.count == columns }) else { return }
        var layout = current.tableLayout.fitted(rows: rows.count, columns: columns)
        if let row {
            guard rows.count > 1, rows.indices.contains(row) else { return }
            rows.remove(at: row); layout.rowHeights.remove(at: row)
        } else if let column {
            guard columns > 1, (0..<columns).contains(column) else { return }
            rows = rows.map { values in var values = values; values.remove(at: column); return values }
            layout.columnWidths.remove(at: column)
        } else { return }
        // Keep raw cell encoding and its plain/inline flag unchanged. Deleting
        // an axis must not reinterpret code markers or shift another axis's sizes.
        guard let data = try? JSONEncoder().encode(rows) else { return }
        changeText(String(decoding: data, as: UTF8.self), in: current)
        changeTableLayout(layout, in: current)
    }

    func resizeTable(column: Int? = nil, row: Int? = nil, size: Double, in block: Block) {
        guard let current = blocks.first(where: { $0.id == block.id }), current.kind == .table,
              let rows = try? JSONDecoder().decode([[String]].self, from: Data(current.text.utf8)),
              let columns = rows.first?.count, columns > 0 else { return }
        // Merge against live state: a row drag immediately after a column drag
        // must not overwrite that column with an older view snapshot.
        var layout = current.tableLayout.fitted(rows: rows.count, columns: columns)
        if let column, layout.columnWidths.indices.contains(column) { layout.columnWidths[column] = TableLayout.width(size) }
        if let row, layout.rowHeights.indices.contains(row) { layout.rowHeights[row] = TableLayout.height(size) }
        changeTableLayout(layout, in: current)
    }

    private func scheduleWrite(_ id: UUID) {
        pendingWrites[id]?.cancel()
        if !saving { saving = true }
        pendingWrites[id] = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(400))
            guard !Task.isCancelled, let self else { return }
            await self.flush(id)
        }
    }

    func flush(_ id: UUID) async {
        if let conversion = pendingConversions[id] { await conversion.value }
        guard let text = latestText[id] else { return }
        do {
            let formatting = latestFormatting[id] ?? []
            let layout = latestTableLayouts[id] ?? TableLayout()
            try await store.updateBlock(id, text: text, formatting: formatting, tableLayout: layout)
            if latestText[id] == text && latestFormatting[id] == formatting && latestTableLayouts[id] == layout { latestText[id] = nil; latestFormatting[id] = nil; latestTableLayouts[id] = nil }
            saving = !latestText.isEmpty || !pendingConversions.isEmpty
        } catch { report(error) }
    }

    func flushAll() async {
        for conversion in Array(pendingConversions.values) { await conversion.value }
        for id in Array(latestText.keys) { await flush(id) }
    }

    func exportDocument(name: String, pageID: UUID?, includeChildren: Bool, includeArchived: Bool) async throws -> TransferDocument {
        guard !workspaceTransitioning, !automationBusy else { throw AppError.message(L10n.tr("正在执行其他操作，请稍后重试")) }
        automationBusy = true; defer { automationBusy = false }
        await flushAll()
        guard !saving else { throw AppError.message(L10n.tr("存在未保存内容，导出已停止")) }
        return try await store.transferSnapshot(name: name, pageID: pageID, includeChildren: includeChildren, includeArchived: includeArchived)
    }

    func importDocument(_ document: TransferDocument) async throws -> Int {
        guard !workspaceTransitioning, !automationBusy else { throw AppError.message(L10n.tr("正在执行其他操作，请稍后重试")) }
        automationBusy = true; defer { automationBusy = false }
        await flushAll()
        guard !saving else { throw AppError.message(L10n.tr("存在未保存内容，导入已停止")) }
        let localDocument = try await LocalDocumentImages.document(document)
        let ids = try await store.importTransfer(localDocument)
        await refreshPages()
        if let first = ids.first(where: { id in pages.contains { $0.id == id && !$0.archived } }) { select(first) }
        return ids.count
    }

    func insertMedia(_ kind: BlockKind, text: String, pageID: UUID) async throws {
        guard !workspaceTransitioning, !automationBusy, [.image, .audio].contains(kind),
              pages.contains(where: { $0.id == pageID && !$0.archived }) else { throw AppError.message(L10n.tr("目标页面不可用，请重新选择页面")) }
        automationBusy = true
        defer { automationBusy = false }
        await flushAll()
        guard !saving else { throw AppError.message(L10n.tr("尚有内容未保存，请稍后重试")) }
        let content = kind == .image ? try await LocalDocumentImages.blocks([TransferBlock(.image, try ImageSource.validated(text))])[0].text : text
        let block = try await store.createBlock(pageID: pageID, kind: kind)
        try await store.updateBlock(block.id, text: content)
        if selectedPageID == pageID {
            var inserted = block; inserted.text = content; blocks.append(inserted)
        }
    }

    func applyMarkdownHeading(_ text: String, formatting: [TextStyleRun], in block: Block, selection: NSRange? = nil) -> Bool {
        guard let current = blocks.first(where: { $0.id == block.id }), current.kind == .paragraph || current.kind.isHeading,
              let match = DocumentTransfer.firstMatch(#"^(#{1,3})[ \t]+([^\r\n]*)$"#, text) else { return false }
        let title = match[2]
        let prefix = text.utf16.count - title.utf16.count
        let range = NSRange(location: prefix, length: title.utf16.count)
        let runs = formatting.compactMap { run -> TextStyleRun? in
            guard let valid = run.validRange(in: text) else { return nil }
            let overlap = NSIntersectionRange(valid, range)
            guard overlap.length > 0 else { return nil }
            var style = run.style
            style.fontSize = nil
            return style.isEmpty ? nil : TextStyleRun(location: overlap.location - prefix, length: overlap.length, style: style)
        }
        insertSlashCommand(match[1].count == 1 ? .heading : match[1].count == 2 ? .heading2 : .heading3,
                           in: block, text: title, formatting: runs, focusOffset: selection.map { max(0, min(title.utf16.count, $0.location - prefix)) } ?? title.utf16.count)
        return true
    }

    func insertSlashCommand(_ kind: BlockKind, in block: Block, text: String? = nil, formatting: [TextStyleRun] = [], focusOffset: Int = 0) {
        guard let index = blocks.firstIndex(where: { $0.id == block.id }) else { return }
        let original = blocks[index]
        var updated = original
        updated.kind = kind
        updated.text = text ?? kind.initialText
        updated.formatting = formatting; updated.checked = false
        updated.language = "Plain Text"; updated.collapsed = false; updated.tableLayout = TableLayout(); updated.imageWidth = nil; updated.listStart = nil
        pendingWrites[block.id]?.cancel(); pendingWrites[block.id] = nil
        latestText[block.id] = nil; latestFormatting[block.id] = nil; latestTableLayouts[block.id] = nil
        blocks[index] = updated
        let revision = (editorContentRevisions[block.id] ?? 0) &+ 1
        editorContentRevisions[block.id] = revision
        clearBlockSelection()
        if kind.acceptsTextInput || kind == .table { requestFocus(block.id, offset: focusOffset) }
        else { editorFocusRequest = nil }
        let previous = pendingConversions[block.id]
        pendingConversions[block.id] = Task { [weak self] in
            if let previous { await previous.value }
            guard let self else { return }
            defer {
                if editorContentRevisions[block.id] == revision { pendingConversions[block.id] = nil }
                saving = !latestText.isEmpty || !pendingConversions.isEmpty
            }
            do {
                try await store.applyBlockCommand(block.id, kind: kind, text: updated.text, formatting: updated.formatting)
            }
            catch {
                pageCache[original.pageID] = nil
                cachedPageOrder.removeAll { $0 == original.pageID }
                if editorContentRevisions[block.id] == revision {
                    pendingConversions[block.id] = nil
                    if let current = blocks.firstIndex(where: { $0.id == block.id }), blocks[current] == updated {
                        blocks[current] = original
                        editorContentRevisions[block.id] = revision &+ 1
                    }
                }
                report(error)
            }
        }
        saving = true
    }

    @discardableResult
    func convertToHeading(_ level: Int, text: String, formatting: [TextStyleRun], selection: NSRange, in block: Block) -> Bool {
        guard (1...3).contains(level), blocks.contains(where: { $0.id == block.id }) else { return false }
        let runs = formatting.compactMap { run -> TextStyleRun? in
            var run = run
            // Heading size follows its level, rather than a pasted/body size.
            run.style.fontSize = nil
            return run.style.isEmpty ? nil : run
        }
        insertSlashCommand(level == 1 ? .heading : level == 2 ? .heading2 : .heading3,
                           in: block, text: text, formatting: runs, focusOffset: min(selection.location, text.utf16.count))
        return true
    }

    func changeKind(_ kind: BlockKind, of block: Block) {
        guard let current = blocks.first(where: { $0.id == block.id }), current.kind.canConvert(to: kind) else { return }
        if kind.isHeading, let current = blocks.first(where: { $0.id == block.id }) {
            convertToHeading(kind == .heading ? 1 : kind == .heading2 ? 2 : 3, text: current.text,
                             formatting: current.formatting, selection: NSRange(location: current.text.utf16.count, length: 0), in: current)
            return
        }
        guard let index = blocks.firstIndex(where: { $0.id == block.id }), blocks[index].kind != kind else { return }
        let previous = blocks[index].kind
        let previousStart = blocks[index].listStart
        blocks[index].kind = kind
        blocks[index].listStart = nil
        Task {
            do { try await store.setBlockKind(block.id, kind: kind) }
            catch {
                if let index = blocks.firstIndex(where: { $0.id == block.id }), blocks[index].kind == kind {
                    blocks[index].kind = previous
                    blocks[index].listStart = previousStart
                }
                report(error)
            }
        }
    }

    private func ensurePageHasInput() {
        guard let pageID = selectedPageID, !creatingTrailingInput.contains(pageID),
              blocks.isEmpty else { return }
        creatingTrailingInput.insert(pageID)
        Task {
            defer { creatingTrailingInput.remove(pageID) }
            do {
                let block = try await store.createBlock(pageID: pageID, kind: .paragraph)
                if selectedPageID == pageID { blocks.append(block) }
            } catch { report(error) }
        }
    }

    func setBlockOptions(for block: Block, language: String? = nil, collapsed: Bool? = nil) {
        guard let index = blocks.firstIndex(where: { $0.id == block.id }) else { return }
        blocks[index].language = language ?? blocks[index].language
        blocks[index].collapsed = collapsed ?? blocks[index].collapsed
        let updated = blocks[index]
        Task {
            do { try await store.setBlockOptions(updated.id, language: updated.language, collapsed: updated.collapsed) }
            catch { report(error) }
        }
    }

    func toggle(_ block: Block) {
        Task {
            do {
                try await store.setChecked(block.id, checked: !block.checked)
                if let index = blocks.firstIndex(where: { $0.id == block.id }) { blocks[index].checked.toggle() }
            } catch { report(error) }
        }
    }

    func selectBlock(_ id: UUID, extend: Bool = false, toggle: Bool = false) {
        guard let index = blocks.firstIndex(where: { $0.id == id }) else { return }
        if extend, let anchor = blockSelectionAnchor ?? activeEditingBlockID,
           let from = blocks.firstIndex(where: { $0.id == anchor }) {
            selectedBlockIDs = Set(blocks[min(from, index)...max(from, index)].map(\.id))
        } else if toggle {
            if selectedBlockIDs.contains(id) { selectedBlockIDs.remove(id) } else { selectedBlockIDs.insert(id) }
            blockSelectionAnchor = id
        } else { selectedBlockIDs = [id]; blockSelectionAnchor = id }
    }

    func selectAllBlocks() { selectedBlockIDs = Set(blocks.map(\.id)); blockSelectionAnchor = blocks.first?.id }
    func selectBlockRange(from anchor: UUID, through endpoint: UUID) {
        guard let start = blocks.firstIndex(where: { $0.id == anchor }),
              let end = blocks.firstIndex(where: { $0.id == endpoint }) else { return }
        let selected = Set(blocks[min(start, end)...max(start, end)].map(\.id))
        blockSelectionAnchor = anchor
        activeEditingBlockID = anchor
        if selectedBlockIDs != selected { selectedBlockIDs = selected }
    }
    func clearBlockSelection() { selectedBlockIDs = []; blockSelectionAnchor = nil }

    func duplicateBlocks(_ ids: Set<UUID>) async throws {
        guard !workspaceTransitioning, !automationBusy, let pageID = selectedPageID, !ids.isEmpty else { return }
        automationBusy = true; defer { automationBusy = false }
        await flushAll()
        guard !saving else { throw AppError.message(L10n.tr("存在未保存内容，创建副本已停止")) }
        guard selectedPageID == pageID else { return }
        let previousIDs = Set(blocks.map(\.id))
        let ordered = try await store.duplicateBlocks(ids, pageID: pageID)
        guard selectedPageID == pageID else { return }
        // Preserve edits made while the database actor was processing the copy.
        let live = Dictionary(uniqueKeysWithValues: blocks.map { ($0.id, $0) })
        blocks = ordered.map { item in
            var current = live[item.id] ?? item; current.order = item.order; return current
        }
        selectedBlockIDs = Set(ordered.map(\.id)).subtracting(previousIDs)
        blockSelectionAnchor = ordered.first(where: { selectedBlockIDs.contains($0.id) })?.id
    }

    func clipboardBlocks(_ ids: Set<UUID>) -> [TransferBlock] {
        var counter = 0
        var selected: [TransferBlock] = []
        var previousIndex: Int?
        for (index, block) in blocks.enumerated() {
            let number = ListNumbering.advance(kind: block.kind, start: block.listStart, counter: &counter)
            guard ids.contains(block.id) else { continue }
            var copy = TransferBlock(block)
            if block.kind == .numbered, copy.listStart == nil, number != 1,
               previousIndex != index - 1 || selected.last?.kind != .numbered { copy.listStart = number }
            selected.append(copy)
            previousIndex = index
        }
        return selected
    }

    func copySelectedBlocks() {
        let selected = clipboardBlocks(selectedBlockIDs)
        guard !selected.isEmpty else { return }
        ClipboardDocument.copyBlocks(selected)
    }

    func jumpToDocumentBoundary(atStart: Bool, extend: Bool = false) {
        if extend, let anchor = blockSelectionAnchor ?? activeEditingBlockID, let index = blocks.firstIndex(where: { $0.id == anchor }) {
            selectedBlockIDs = Set((atStart ? Array(blocks[...index]) : Array(blocks[index...])).map(\.id))
        } else { clearBlockSelection() }
        documentBoundaryRequest = DocumentBoundaryRequest(atStart: atStart)
        guard !extend else { return }
        let editable = blocks.filter { ![.image, .divider, .table, .tableOfContents].contains($0.kind) }
        if let target = atStart ? editable.first : editable.last {
            if target.collapsed { setBlockOptions(for: target, collapsed: false) }
            requestFocus(target.id, offset: atStart ? 0 : target.text.utf16.count)
        }
    }

    func deleteSelectedBlocks() async throws {
        guard !selectedBlockIDs.isEmpty, !workspaceTransitioning, !automationBusy else { return }
        automationBusy = true; defer { automationBusy = false }
        let ids = selectedBlockIDs.intersection(Set(blocks.map(\.id)))
        for id in ids { pendingWrites[id]?.cancel(); pendingWrites[id] = nil }
        try await store.deleteBlocks(Array(ids))
        for id in ids { latestText[id] = nil; latestFormatting[id] = nil; latestTableLayouts[id] = nil }
        blocks.removeAll { ids.contains($0.id) }
        saving = !latestText.isEmpty || !pendingConversions.isEmpty; clearBlockSelection()
        if blocks.isEmpty, let pageID = selectedPageID {
            let block = try await store.createBlock(pageID: pageID, kind: .paragraph)
            blocks = [block]; requestFocus(block.id, offset: 0)
        }
    }

    func requestFocus(_ blockID: UUID, offset: Int) {
        editorFocusRequest = EditorFocusRequest(blockID: blockID, offset: offset)
    }

    /// Called only for Backspace at the beginning of an editor, outside IME composition.
    func backspaceAtStart(of block: Block) -> Bool {
        guard selectedPageID == block.pageID, let index = blocks.firstIndex(where: { $0.id == block.id }) else { return false }
        let current = blocks[index]
        let prose: (BlockKind) -> Bool = { $0.isHeading || [.paragraph, .bullet, .numbered, .todo, .quote, .callout, .warning, .success, .toggle].contains($0) }
        if current.kind != .paragraph, current.text.isEmpty || prose(current.kind) {
            insertSlashCommand(.paragraph, in: current, text: current.text, formatting: current.formatting)
            return true
        }
        guard current.kind == .paragraph, index > 0 else { return false }
        let previous = blocks[index - 1]
        guard prose(previous.kind), !previous.collapsed else {
            // A text boundary must never concatenate text into a media URL,
            // table payload or code source. Select the preceding block instead.
            selectBlock(previous.id)
            return true
        }
        let offset = previous.text.utf16.count
        var merged = previous
        merged.text += current.text
        merged.formatting += current.formatting.compactMap { run in
            guard let range = run.validRange(in: current.text) else { return nil }
            return TextStyleRun(location: offset + range.location, length: range.length, style: run.style)
        }
        let priorFirst = pendingConversions[previous.id], priorSecond = pendingConversions[current.id]
        for id in [previous.id, current.id] {
            pendingWrites[id]?.cancel(); pendingWrites[id] = nil
            latestText[id] = nil; latestFormatting[id] = nil; latestTableLayouts[id] = nil
        }
        let revision = (editorContentRevisions[previous.id] ?? 0) &+ 1
        let removedRevision = (editorContentRevisions[current.id] ?? 0) &+ 1
        editorContentRevisions[previous.id] = revision
        editorContentRevisions[current.id] = removedRevision
        blocks[index - 1] = merged; blocks.remove(at: index)
        clearBlockSelection()
        requestFocus(previous.id, offset: offset)
        let operation = Task { [weak self] in
            if let priorFirst { await priorFirst.value }
            if let priorSecond { await priorSecond.value }
            guard let self else { return }
            defer {
                if editorContentRevisions[previous.id] == revision { pendingConversions[previous.id] = nil }
                if editorContentRevisions[current.id] == removedRevision { pendingConversions[current.id] = nil }
                saving = !latestText.isEmpty || !pendingConversions.isEmpty
            }
            do { try await store.mergeTextBlocks(merged, removing: current) }
            catch {
                pageCache[current.pageID] = nil
                cachedPageOrder.removeAll { $0 == current.pageID }
                if selectedPageID == current.pageID, let target = blocks.firstIndex(where: { $0.id == previous.id }) {
                    if editorContentRevisions[previous.id] == revision, blocks[target] == merged {
                        blocks[target] = previous
                        editorContentRevisions[previous.id] = revision &+ 1
                        pendingConversions[previous.id] = nil
                        latestText[previous.id] = previous.text; latestFormatting[previous.id] = previous.formatting
                        latestTableLayouts[previous.id] = previous.tableLayout
                        scheduleWrite(previous.id)
                    }
                    if !blocks.contains(where: { $0.id == current.id }) { blocks.insert(current, at: target + 1) }
                    if editorContentRevisions[current.id] == removedRevision {
                        pendingConversions[current.id] = nil
                        latestText[current.id] = current.text; latestFormatting[current.id] = current.formatting
                        latestTableLayouts[current.id] = current.tableLayout
                        scheduleWrite(current.id)
                    }
                    requestFocus(current.id, offset: 0)
                }
                report(error)
            }
        }
        pendingConversions[previous.id] = operation; pendingConversions[current.id] = operation
        saving = true
        return true
    }

    func delete(_ block: Block, focusPrevious: Bool = false) {
        guard let index = blocks.firstIndex(where: { $0.id == block.id }) else { return }
        let pageID = selectedPageID
        let target = index > 0 ? blocks[index - 1] : blocks.dropFirst().first
        pendingWrites[block.id]?.cancel()
        pendingWrites[block.id] = nil
        latestText[block.id] = nil
        latestFormatting[block.id] = nil; latestTableLayouts[block.id] = nil
        selectedBlockIDs.remove(block.id)
        saving = !latestText.isEmpty || !pendingConversions.isEmpty
        blocks.remove(at: index)
        if focusPrevious, let target {
            if target.collapsed { setBlockOptions(for: target, collapsed: false) }
            requestFocus(target.id, offset: target.text.utf16.count)
        }
        Task {
            do {
                try await store.deleteBlock(block.id)
                if selectedPageID == pageID { ensurePageHasInput() }
            } catch {
                report(error)
                // Restore the row on a failed write rather than silently hiding stored data.
                if selectedPageID == pageID, !blocks.contains(where: { $0.id == block.id }) {
                    blocks.insert(block, at: min(index, blocks.count))
                }
            }
        }
    }

    func performSearch(_ query: String) async -> [Page] {
        do { return try await store.search(query) }
        catch { report(error); return [] }
    }

    private func report(_ error: Error) { errorMessage = error.localizedDescription }
}

extension WorkspaceModel {
    static var automationTools: [[String: Any]] {
        let definitions: [(String, String, [String], [String])] = [
            ("list_pages", "List active pages with IDs, titles, and parent IDs.", ["query"], []),
            ("read_page", "Read a page and its blocks.", ["page_id"], ["page_id"]),
            ("create_page", "Create a page; parent_id is optional (root when empty).", ["title", "parent_id"], ["title"]),
            ("rename_page", "Rename an active page.", ["page_id", "title"], ["page_id", "title"]),
            ("move_page", "Move a page and descendants; omit parent_id or use empty string for root.", ["page_id", "parent_id"], ["page_id"]),
            ("trash_page", "Move a page and its active descendants to trash, recoverably.", ["page_id"], ["page_id"]),
            ("restore_page", "Restore a trashed page and its deletion batch.", ["page_id"], ["page_id"]),
            ("append_text", "Append a plain text block to an active page.", ["page_id", "text"], ["page_id", "text"]),
            ("append_document", "Parse Markdown, HTML or text and append editable blocks to an existing page, preserving existing content. format: markdown/html/text. Read the page first; do not retry writes blindly.", ["page_id", "content", "format"], ["page_id", "content", "format"]),
            ("import_document", "Create a new page from Markdown, HTML or text. format: markdown/html/text. Does not overwrite existing pages.", ["title", "content", "format"], ["title", "content", "format"]),
            ("import_file", "Import one existing local file (Markdown/TXT/HTML/JSON/PDF/DOCX/DOC/RTF). Absolute path is on the Velora computer. With page_id, append into that page; otherwise create new pages. Never retry blindly.", ["path", "page_id"], ["path"]),
            ("open_page", "Open an active page in Velora.", ["page_id"], ["page_id"])
        ]
        return definitions.map { name, description, properties, required in
            ["name": name, "description": description,
             "inputSchema": ["type": "object", "properties": Dictionary(uniqueKeysWithValues: properties.map { ($0, ["type": "string"]) }),
                             "required": required, "additionalProperties": false],
             "annotations": ["readOnlyHint": ["list_pages", "read_page"].contains(name), "destructiveHint": name == "trash_page"]] as [String: Any]
        }
    }

    func executeTool(_ name: String, arguments: [String: String]) async throws -> Any {
        guard !automationBusy, !workspaceTransitioning else { throw AppError.message(L10n.tr("已有操作正在执行，请稍后重试")) }
        automationBusy = true
        defer { automationBusy = false }
        await flushAll()
        guard !saving else { throw AppError.message(L10n.tr("存在未保存内容，操作已停止")) }
        await refreshPages()
        func id(_ key: String) throws -> UUID {
            guard let value = arguments[key], let id = UUID(uuidString: value) else { throw AppError.message(L10n.tr("缺少有效的 \(key)")) }
            return id
        }
        func active(_ id: UUID) throws {
            guard pages.contains(where: { $0.id == id && !$0.archived }) else { throw StoreError.missingPage }
        }
        func parent() throws -> UUID? {
            guard let value = arguments["parent_id"], !value.isEmpty else { return nil }
            guard let id = UUID(uuidString: value) else { throw StoreError.invalidMove }
            try active(id)
            return id
        }
        func record(_ page: Page) -> [String: Any] {
            ["id": page.id.uuidString, "title": page.title, "parent_id": page.parentID?.uuidString ?? "", "trashed": page.archived]
        }
        var result: Any = ["success": true]
        switch name {
        case "list_pages":
            let query = arguments["query"] ?? ""
            return pages.filter { !$0.archived && (query.isEmpty || $0.title.localizedCaseInsensitiveContains(query)) }.map(record)
        case "read_page":
            let pageID = try id("page_id"); try active(pageID)
            guard let page = pages.first(where: { $0.id == pageID }) else { throw StoreError.missingPage }
            let content = try await store.blocks(in: pageID)
            return ["page": record(page), "blocks": content.map {
                ["id": $0.id.uuidString, "type": $0.kind.rawValue, "text": $0.text, "language": $0.language]
            }] as [String: Any]
        case "create_page":
            let page = try await store.createPage(parentID: parent())
            try await store.renamePage(page.id, title: arguments["title"] ?? L10n.tr("未命名"))
            result = ["page_id": page.id.uuidString]
        case "rename_page":
            let pageID = try id("page_id"); try active(pageID)
            guard let title = arguments["title"] else { throw AppError.message(L10n.tr("缺少标题")) }
            try await store.renamePage(pageID, title: title)
        case "move_page":
            let pageID = try id("page_id"); try active(pageID)
            try await store.movePage(pageID, toParent: parent())
        case "trash_page":
            let pageID = try id("page_id"); try active(pageID)
            try await store.archivePage(pageID, archived: true)
        case "restore_page": try await store.restorePage(id("page_id"))
        case "append_text":
            let pageID = try id("page_id"); try active(pageID)
            guard let text = arguments["text"], !text.isEmpty else { throw AppError.message(L10n.tr("正文不能为空")) }
            let block = try await store.createBlock(pageID: pageID, kind: .paragraph)
            try await store.updateBlock(block.id, text: text)
        case "append_document", "import_document", "import_file":
            let target = arguments["page_id"].flatMap(UUID.init(uuidString:))
            if name == "append_document" || arguments["page_id"] != nil {
                guard let target else { throw AppError.message("缺少有效的 page_id") }
                try active(target)
            }
            let document: TransferDocument
            if name == "import_file" {
                guard let path = arguments["path"], path.hasPrefix("/"),
                      (try? URL(fileURLWithPath: path).resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true else {
                    throw AppError.message("请选择 Velora 所在电脑上的绝对文件路径")
                }
                document = try await DocumentTransfer.load(URL(fileURLWithPath: path))
            } else {
                guard let content = arguments["content"], !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                      content.utf8.count <= 900000 else { throw AppError.message("内容为空或超过 900 KB；大文件请使用 import_file") }
                let title = arguments["title"] ?? "导入内容"
                switch arguments["format"] {
                case "markdown": document = try DocumentTransfer.markdown(content, title: title, consumeLeadingTitle: false)
                case "html":
                    let markdown = try await DocumentRenderSession.markdown(fromHTML: content)
                    document = try DocumentTransfer.markdown(markdown, title: title, consumeLeadingTitle: false)
                case "text": document = TransferDocument(name: title, pages: [TransferPage(title: title, blocks: [TransferBlock(.paragraph, content)])])
                default: throw AppError.message("format 必须是 markdown、html 或 text")
                }
            }
            let localDocument = try await LocalDocumentImages.document(document)
            if let target {
                let ordered = try localDocument.orderedPages()
                let items = ordered.flatMap { page in
                    (ordered.count > 1 ? [TransferBlock(.heading2, page.title)] : []) + page.blocks
                }
                let ids = try await store.appendTransferBlocks(items, to: target)
                result = ["page_id": target.uuidString, "block_ids": ids.map(\.uuidString), "appended_blocks": ids.count] as [String: Any]
            } else {
                let ids = try await store.importTransfer(localDocument)
                result = ["page_ids": ids.map(\.uuidString), "created_pages": ids.count] as [String: Any]
            }
        case "open_page":
            let pageID = try id("page_id"); try active(pageID)
            selectedPageID = pageID
        default: throw AppError.message(L10n.tr("不支持的操作：\(name)"))
        }
        await refreshPages()
        if let selectedPageID {
            if selectedPage?.archived == true { select(nil) }
            else {
                let loaded = try await store.blocks(in: selectedPageID)
                if self.selectedPageID == selectedPageID {
                    blocks = loaded.map { block in
                        var block = block
                        if let pending = latestText[block.id] { block.text = pending }
                        return block
                    }
                }
            }
        }
        return result
    }
}

