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
                Label("导入与导出", systemImage: "arrow.up.arrow.down.square").font(.title2.bold())
                Spacer()
                Button("完成") { dismiss() }.keyboardShortcut(.cancelAction).disabled(working)
            }
            Picker("操作", selection: $mode) { Text("导入").tag(0); Text("导出").tag(1) }.pickerStyle(.segmented).disabled(working)
            if mode == 0 { importOptions } else { exportOptions }
            Spacer(minLength: 0)
            if working { ProgressView("正在处理，请稍候…").controlSize(.small) }
            if !status.isEmpty {
                Label(status, systemImage: succeeded ? "checkmark.circle" : "info.circle")
                    .font(.callout).foregroundStyle(succeeded ? Color.green : Color.secondary).textSelection(.enabled)
            }
            if let outputURL {
                Button("在 Finder 中显示导出结果") { NSWorkspace.shared.activateFileViewerSelecting([outputURL]) }
            }
        }.padding(24).frame(width: 640, height: 500)
        .interactiveDismissDisabled(working)
        .onChange(of: mode) { _, _ in status = ""; outputURL = nil }
    }

    private var importOptions: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("支持 Markdown、TXT、HTML、JSON、PDF、Word（DOCX / DOC）和 RTF。")
            HStack {
                Button("选择文件或文件夹…") { chooseSources() }.disabled(working)
                Text(sources.isEmpty ? "尚未选择" : "已选择 \(sources.count) 项").foregroundStyle(.secondary)
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(sources, id: \.self) { Text($0.path).font(.caption).lineLimit(2).textSelection(.enabled) }
                }.frame(maxWidth: .infinity, alignment: .leading)
            }.frame(maxHeight: 110)
            Text("导入到当前工作空间，创建新页面，不覆盖现有页面。文件夹层级会成为子页面；Markdown 的目录内图片会保存到数据库。任一文件失败时，本次导入不写入页面。")
                .font(.caption).foregroundStyle(.secondary)
            Text("PDF 提取可识别文字，不含扫描件 OCR；Word / HTML 尽量保留常见文字样式与本地图片，复杂排版可能简化。单文件或文件夹文档总量不超过 100 MB。")
                .font(.caption).foregroundStyle(.secondary)
            HStack { Spacer(); Button("开始导入") { runImport() }.buttonStyle(.borderedProminent).disabled(working || sources.isEmpty) }
        }
    }
    private var exportOptions: some View {
        VStack(alignment: .leading, spacing: 14) {
            Picker("范围", selection: $wholeWorkspace) {
                Text("当前页面").tag(false)
                Text("整个工作空间").tag(true)
            }.pickerStyle(.segmented).disabled(working)
            Picker("导出格式", selection: $format) { ForEach(TransferFormat.allCases) { Text($0.label).tag($0) } }.disabled(working)
            if !wholeWorkspace { Toggle("包含子页面", isOn: $includeChildren).disabled(working) }
            if wholeWorkspace && format == .json { Toggle("包含回收箱", isOn: $includeArchived).disabled(working) }
            Text(formatDescription).font(.caption).foregroundStyle(.secondary)
            Text("导出前会先保存待写入内容。导出文件不包含 API 密钥或模型配置。").font(.caption).foregroundStyle(.secondary)
            if pageID == nil && !wholeWorkspace { Text("请先选择一个页面，或选择整个工作空间。").foregroundStyle(.secondary) }
            HStack { Spacer(); Button("选择位置并导出…") { runExport() }.buttonStyle(.borderedProminent).disabled(working || (!wholeWorkspace && pageID == nil)) }
        }
    }
    private var formatDescription: String {
        switch format {
        case .markdown: "Markdown 保留标题、列表、待办、代码块、表格和图片。多个页面导出为嵌套目录，本地图片写入配套资源文件夹。"
        case .json: "JSON 完整保留页面层级、块类型、勾选状态、代码语言、折叠状态和本地图片，可重新导入 Velora。"
        case .pdf: "PDF 导出适合阅读和打印的分页文档，保留可见文字与本地图片。远程媒体以链接表示。"
        case .word: "Word 导出可编辑的 DOCX，保留常见标题、文字和本地图片；多个页面合并到一个文档。"
        case .html: "HTML 导出为独立网页，本地图片内嵌；多个页面合并，并标记页面路径。"
        case .text: "TXT 导出可读纯文本；图片和媒体以文字说明或链接表示。"
        }
    }
    private func chooseSources() {
        let panel = NSOpenPanel(); panel.allowedContentTypes = DocumentTransfer.acceptedTypes
        panel.canChooseDirectories = true; panel.canChooseFiles = true; panel.allowsMultipleSelection = true
        panel.message = "选择文档或包含文档的文件夹，导入为新页面"
        if panel.runModal() == .OK { sources = panel.urls; status = ""; outputURL = nil }
    }
    private func runImport() {
        guard let model = services.model, !services.busy, !model.automationBusy else { status = "正在处理其他操作，请稍后重试"; return }
        working = true; status = "正在读取文档…"; succeeded = false
        let inputs = sources
        Task {
            defer { working = false }
            do {
                let document = try DocumentImporter.loadSelection(inputs)
                guard services.model === model else { throw AppError.message("工作空间已切换，请重新导入") }
                let count = try await model.importDocument(document)
                status = "导入成功：新增 \(count) 个页面"; succeeded = true
            } catch { status = "导入失败：" + error.localizedDescription }
        }
    }
    private func runExport() {
        guard let model = services.model, !services.busy, !model.automationBusy else { status = "正在处理其他操作，请稍后重试"; return }
        let folderOutput = format == .markdown && (wholeWorkspace || includeChildren)
        let target: URL
        let name = wholeWorkspace ? services.currentWorkspace?.name ?? "Velora" : model.pages.first(where: { $0.id == pageID })?.title ?? "页面"
        if folderOutput {
            let panel = NSOpenPanel(); panel.canChooseDirectories = true; panel.canChooseFiles = false; panel.canCreateDirectories = true
            panel.message = "选择导出目录，将创建一个包含页面层级和图片资源的新文件夹"
            guard panel.runModal() == .OK, let url = panel.url else { return }; target = url
        } else {
            let panel = NSSavePanel(); panel.allowedContentTypes = [format.type]
            panel.nameFieldStringValue = DocumentExporter.safeName(name) + "." + format.ext
            guard panel.runModal() == .OK, let url = panel.url else { return }; target = url
        }
        working = true; succeeded = false; status = "正在保存并导出…"; outputURL = nil
        let selectedFormat = format; let workspace = wholeWorkspace; let children = includeChildren
        let archived = wholeWorkspace && format == .json && includeArchived
        Task {
            defer { working = false }
            let access = target.startAccessingSecurityScopedResource(); defer { if access { target.stopAccessingSecurityScopedResource() } }
            do {
                let document = try await model.exportDocument(name: name, pageID: workspace ? nil : pageID, includeChildren: children, includeArchived: archived)
                if folderOutput { outputURL = try DocumentExporter.markdownFolder(document, in: target) }
                else { try DocumentExporter.write(document, format: selectedFormat, to: target); outputURL = target }
                status = "导出成功：\(document.pages.count) 个页面 · \(selectedFormat.label)"; succeeded = true
            } catch { status = "导出失败：" + error.localizedDescription }
        }
    }
}
