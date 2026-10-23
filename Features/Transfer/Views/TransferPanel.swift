import AppKit
import SwiftUI

struct TransferPanel: View {
    @ObservedObject var services: ApplicationServices
    @Environment(\.dismiss) private var dismiss
    @State private var mode = 0
    @State private var format: TransferFormat = .markdown
    @State private var wholeWorkspace = false
    @State private var includeChildren = true
    @State private var includeArchived = false
    @State private var sources: [URL] = []
    @State private var working = false
    @State private var status = ""
    @State private var succeeded = false
    @State private var outputURL: URL?
    let pageID: UUID?

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                Label(L10n.tr("导入与导出"), systemImage: "arrow.up.arrow.down.square").font(.title2.bold())
                Spacer()
                Button(L10n.tr("完成")) { dismiss() }.keyboardShortcut(.cancelAction).disabled(working)
            }
            Picker(L10n.tr("操作"), selection: $mode) { Text(L10n.tr("导入")).tag(0); Text(L10n.tr("导出")).tag(1) }.pickerStyle(.segmented).disabled(working)
            if mode == 0 { importOptions } else { exportOptions }
            Spacer(minLength: 0)
            if working { ProgressView(L10n.tr("正在处理，请稍候…")).controlSize(.small) }
            if !status.isEmpty {
                Label(status, systemImage: succeeded ? "checkmark.circle" : "info.circle")
                    .font(.callout).foregroundStyle(succeeded ? Color.green : Color.secondary).textSelection(.enabled)
            }
            if let outputURL {
                Button(L10n.tr("在 Finder 中显示导出结果")) { NSWorkspace.shared.activateFileViewerSelecting([outputURL]) }
            }
        }.padding(24).frame(width: 640, height: 500)
        .interactiveDismissDisabled(working)
        .onChange(of: mode) { _, _ in status = ""; outputURL = nil }
    }

    private var importOptions: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(L10n.tr("支持 Markdown、TXT、HTML、JSON、PDF、Word（DOCX / DOC）和 RTF。"))
            HStack {
                Button(L10n.tr("选择文件或文件夹…")) { chooseSources() }.disabled(working)
                Text(sources.isEmpty ? L10n.tr("尚未选择") : L10n.tr("已选择 \(sources.count) 项")).foregroundStyle(.secondary)
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(sources, id: \.self) { Text($0.path).font(.caption).lineLimit(2).textSelection(.enabled) }
                }.frame(maxWidth: .infinity, alignment: .leading)
            }.frame(maxHeight: 110)
            Text(L10n.tr("导入到当前工作空间，创建新页面，不覆盖现有页面。文件夹层级会成为子页面；Markdown 的目录内图片会保存到数据库。任一文件失败时，本次导入不写入页面。"))
                .font(.caption).foregroundStyle(.secondary)
            Text(L10n.tr("文件内容自动拆分为可编辑块。PDF 根据文字和版式识别标题、正文、列表、代码与引用；扫描页保留图片并尝试本地文字识别。复杂格式可能需要整理。文档及内嵌资源总量不超过 100 MB。"))
                .font(.caption).foregroundStyle(.secondary)
            HStack { Spacer(); Button(L10n.tr("开始导入")) { runImport() }.buttonStyle(.borderedProminent).disabled(working || sources.isEmpty) }
        }
    }
    private var exportOptions: some View {
        VStack(alignment: .leading, spacing: 14) {
            Picker(L10n.tr("范围"), selection: $wholeWorkspace) {
                Text(L10n.tr("当前页面")).tag(false)
                Text(L10n.tr("整个工作空间")).tag(true)
            }.pickerStyle(.segmented).disabled(working)
            Picker(L10n.tr("导出格式"), selection: $format) { ForEach(TransferFormat.allCases) { Text($0.label).tag($0) } }.disabled(working)
            if !wholeWorkspace { Toggle(L10n.tr("包含子页面"), isOn: $includeChildren).disabled(working) }
            if wholeWorkspace && format == .json { Toggle(L10n.tr("包含回收箱"), isOn: $includeArchived).disabled(working) }
            Text(formatDescription).font(.caption).foregroundStyle(.secondary)
            Text(L10n.tr("导出前会先保存待写入内容。导出文件不包含 API 密钥或模型配置。")).font(.caption).foregroundStyle(.secondary)
            if pageID == nil && !wholeWorkspace { Text(L10n.tr("请先选择一个页面，或选择整个工作空间。")).foregroundStyle(.secondary) }
            HStack { Spacer(); Button(L10n.tr("选择位置并导出…")) { runExport() }.buttonStyle(.borderedProminent).disabled(working || (!wholeWorkspace && pageID == nil)) }
        }
    }
    private var formatDescription: String {
        switch format {
        case .markdown: L10n.tr("Markdown 保留标题、嵌套列表、待办、代码、公式、表格和图片。多个页面导出为嵌套目录，本地图片写入配套资源文件夹。")
        case .json: L10n.tr("JSON 完整保留页面层级、块类型、勾选状态、代码语言、折叠状态和本地图片，可重新导入 Velora。")
        case .pdf: L10n.tr("PDF 使用与页面相同的渲染，保留公式排版、表格、代码和图片，并自动分页。")
        case .word: L10n.tr("Word 导出可编辑的标题、嵌套列表、表格和文字；数学公式使用 Word 原生方程，不再显示 LaTeX 源码。")
        case .html: L10n.tr("HTML 导出已排版的独立网页，内嵌字体与公式，不需要联网脚本；重新导入时保留原始块结构。")
        case .text: L10n.tr("TXT 导出可读纯文本；图片和媒体以文字说明或链接表示。")
        }
    }
    private func chooseSources() {
        let panel = NSOpenPanel(); panel.allowedContentTypes = DocumentTransfer.acceptedTypes
        panel.canChooseDirectories = true; panel.canChooseFiles = true; panel.allowsMultipleSelection = true
        panel.message = L10n.tr("选择文档或包含文档的文件夹，导入为新页面")
        if panel.runModal() == .OK { sources = panel.urls; status = ""; outputURL = nil }
    }
    private func runImport() {
        guard let model = services.model, !services.busy, !model.automationBusy else { status = L10n.tr("正在处理其他操作，请稍后重试"); return }
        working = true; status = L10n.tr("正在读取文档…"); succeeded = false
        let inputs = sources
        Task {
            defer { working = false }
            do {
                let document = try await DocumentImporter.loadSelection(inputs)
                guard services.model === model else { throw AppError.message(L10n.tr("工作空间已切换，请重新导入")) }
                let count = try await model.importDocument(document)
                status = L10n.tr("导入成功：新增 \(count) 个页面"); succeeded = true
            } catch { status = L10n.tr("导入失败：") + error.localizedDescription }
        }
    }
    private func runExport() {
        guard let model = services.model, !services.busy, !model.automationBusy else { status = L10n.tr("正在处理其他操作，请稍后重试"); return }
        let folderOutput = format == .markdown && (wholeWorkspace || includeChildren)
        let target: URL
        let name = wholeWorkspace ? services.currentWorkspace?.name ?? "Velora" : model.pages.first(where: { $0.id == pageID })?.title ?? L10n.tr("页面")
        if folderOutput {
            let panel = NSOpenPanel(); panel.canChooseDirectories = true; panel.canChooseFiles = false; panel.canCreateDirectories = true
            panel.message = L10n.tr("选择导出目录，将创建一个包含页面层级和图片资源的新文件夹")
            guard panel.runModal() == .OK, let url = panel.url else { return }; target = url
        } else {
            let panel = NSSavePanel(); panel.allowedContentTypes = [format.type]
            panel.nameFieldStringValue = DocumentExporter.safeName(name) + "." + format.ext
            guard panel.runModal() == .OK, let url = panel.url else { return }; target = url
        }
        working = true; succeeded = false; status = L10n.tr("正在保存并导出…"); outputURL = nil
        let selectedFormat = format; let workspace = wholeWorkspace; let children = includeChildren
        let archived = wholeWorkspace && format == .json && includeArchived
        Task {
            defer { working = false }
            let access = target.startAccessingSecurityScopedResource(); defer { if access { target.stopAccessingSecurityScopedResource() } }
            do {
                let document = try await model.exportDocument(name: name, pageID: workspace ? nil : pageID, includeChildren: children, includeArchived: archived)
                if folderOutput { outputURL = try await DocumentExporter.markdownFolder(document, in: target) }
                else { try await DocumentExporter.write(document, format: selectedFormat, to: target); outputURL = target }
                status = L10n.tr("导出成功：\(document.pages.count) 个页面 · \(selectedFormat.label)"); succeeded = true
            } catch { status = L10n.tr("导出失败：") + error.localizedDescription }
        }
    }
}
