import Foundation

enum BlockKind: String, CaseIterable, Identifiable, Sendable, Codable {
    case paragraph, heading, heading2, heading3, bullet, numbered, todo, toggle, quote, callout, divider
    case image, video, audio, file, bookmark, pdfDocument
    case code, table, tableOfContents, equation, markdown, warning, success

    var id: String { rawValue }
    static var categories: [String] { [L10n.text("基础块"), L10n.text("媒体与链接"), L10n.text("进阶块")] }
    var category: String {
        switch self {
        case .image, .video, .audio, .file, .bookmark, .pdfDocument: L10n.tr("媒体与链接")
        case .code, .table, .tableOfContents, .equation, .markdown: L10n.tr("进阶块")
        default: L10n.tr("基础块")
        }
    }
    var label: String {
        switch self {
        case .paragraph: L10n.tr("正文")
        case .heading: L10n.tr("标题 1")
        case .heading2: L10n.tr("标题 2")
        case .heading3: L10n.tr("标题 3")
        case .bullet: L10n.tr("项目列表")
        case .numbered: L10n.tr("有序列表")
        case .todo: L10n.tr("待办")
        case .toggle: L10n.tr("折叠块")
        case .quote: L10n.tr("引用")
        case .callout: L10n.tr("提示块")
        case .divider: L10n.tr("分割线")
        case .pdfDocument: L10n.tr("PDF 文档")
        case .image: L10n.tr("图片")
        case .video: L10n.tr("视频")
        case .audio: L10n.tr("音频")
        case .file: L10n.tr("文件链接")
        case .bookmark: L10n.tr("网页书签")
        case .equation: L10n.tr("LaTeX 公式")
        case .markdown: L10n.tr("Markdown 文档")
        case .warning: L10n.tr("警告块")
        case .success: L10n.tr("成功提示")
        case .code: L10n.tr("代码")
        case .table: L10n.tr("简单表格")
        case .tableOfContents: L10n.tr("页面目录")
        }
    }
    var symbol: String {
        switch self {
        case .paragraph: "text.alignleft"
        case .heading, .heading2, .heading3: "textformat.size"
        case .bullet: "list.bullet"
        case .numbered: "list.number"
        case .todo: "checkmark.square"
        case .toggle: "chevron.right"
        case .quote: "text.quote"
        case .callout: "lightbulb"
        case .divider: "minus"
        case .pdfDocument: "doc.richtext"
        case .image: "photo"
        case .video: "video"
        case .audio: "waveform"
        case .file: "doc"
        case .bookmark: "link"
        case .equation: "function"
        case .markdown: "text.document"
        case .warning: "exclamationmark.triangle"
        case .success: "checkmark.circle"
        case .code: "chevron.left.forwardslash.chevron.right"
        case .table: "tablecells"
        case .tableOfContents: "list.bullet.indent"
        }
    }
    var isCallout: Bool { [.callout, .warning, .success].contains(self) }
    var isHeading: Bool { [.heading, .heading2, .heading3].contains(self) }
    var isMedia: Bool { [.image, .video, .audio, .file, .bookmark].contains(self) }
    var hint: String {
        switch self {
        case .heading: "#"
        case .heading2: "##"
        case .heading3: "###"
        case .bullet: "-"
        case .numbered: "1."
        case .todo: "[]"
        case .quote: ">"
        case .divider: "---"
        case .equation: L10n.tr("math latex 公式 数学 $$")
        case .markdown: L10n.tr("md markdown ChatGPT 文档") + " mermaid"
        case .warning: L10n.tr("warning 注意 警告")
        case .success: L10n.tr("success 成功 完成")
        case .code: "```"
        default: rawValue
        }
    }
    var slashAliases: [String] {
        let aliases: [String]
        switch self {
        case .paragraph: aliases = ["text", "p"]
        case .heading: aliases = ["h1", "heading1", "title"]
        case .heading2: aliases = ["h2"]
        case .heading3: aliases = ["h3"]
        case .bullet: aliases = ["list", "ul"]
        case .numbered: aliases = ["number", "ol"]
        case .todo: aliases = ["check", "checkbox", "task"]
        case .toggle: aliases = ["collapse"]
        case .quote: aliases = ["blockquote"]
        case .callout: aliases = ["tip", "note"]
        case .divider: aliases = ["hr", "line"]
        case .image: aliases = ["img", "picture"]
        case .video: aliases = ["movie"]
        case .audio: aliases = ["sound"]
        case .file: aliases = ["attachment"]
        case .bookmark: aliases = ["link", "url"]
        case .pdfDocument: aliases = ["pdf"]
        case .code: aliases = ["pre"]
        case .table: aliases = ["grid"]
        case .tableOfContents: aliases = ["toc", "contents"]
        case .equation: aliases = ["math", "latex", "formula"]
        case .markdown: aliases = ["md"]
        case .warning: aliases = ["alert"]
        case .success: aliases = ["done"]
        }
        return [rawValue.lowercased()] + aliases
    }

    var initialText: String { self == .table ? "[[\"\",\"\"],[\"\",\"\"]]" : "" }
    var acceptsTextInput: Bool { ![.table, .divider, .image, .pdfDocument, .tableOfContents].contains(self) }

    var placeholder: String {
        if isMedia { return L10n.tr("粘贴 https:// 链接") }
        switch self {
        case .equation: return L10n.tr("输入 LaTeX，例如 \\frac{a}{b}，支持 $$ 或 \\[…\\]")
        case .markdown: return L10n.tr("粘贴 Markdown，支持标题、表格、代码、行内与块级公式")
        case .code: return L10n.tr("输入或粘贴代码")
        case .toggle: return L10n.tr("首行作为标题，换行输入可折叠内容")
        case .callout, .warning, .success: return L10n.tr("记录提示或重要信息")
        default: return L10n.tr("输入 / 插入内容，或直接开始书写")
        }
    }

}

struct TableLayout: Codable, Hashable, Sendable {
    var columnWidths: [Double] = []
    var rowHeights: [Double] = []
    var cellsArePlain = false
    static func width(_ value: Double) -> Double { value.isFinite ? min(1200, max(72, value)).rounded() : 160 }
    static func height(_ value: Double) -> Double { value.isFinite ? min(1000, max(36, value)).rounded() : 44 }
    func column(_ index: Int) -> Double { columnWidths.indices.contains(index) ? Self.width(columnWidths[index]) : 160 }
    func row(_ index: Int) -> Double { rowHeights.indices.contains(index) ? Self.height(rowHeights[index]) : 44 }
    func fitted(rows: Int, columns: Int) -> Self {
        Self(columnWidths: (0..<max(0, columns)).map(column), rowHeights: (0..<max(0, rows)).map(row), cellsArePlain: cellsArePlain)
    }
    init(columnWidths: [Double] = [], rowHeights: [Double] = [], cellsArePlain: Bool = false) {
        self.columnWidths = columnWidths.map(Self.width); self.rowHeights = rowHeights.map(Self.height)
        self.cellsArePlain = cellsArePlain
    }
    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        self.init(columnWidths: try values.decodeIfPresent([Double].self, forKey: .columnWidths) ?? [],
                  rowHeights: try values.decodeIfPresent([Double].self, forKey: .rowHeights) ?? [],
                  cellsArePlain: try values.decodeIfPresent(Bool.self, forKey: .cellsArePlain) ?? false)
    }
}

struct Block: Identifiable, Hashable, Sendable {
    let id: UUID
    let pageID: UUID
    var kind: BlockKind
    var text: String
    var order: Int64
    var checked: Bool
    var language: String = "Plain Text"
    var collapsed: Bool = false
    var formatting: [TextStyleRun] = []
    var tableLayout = TableLayout()

    var hasContent: Bool {
        if kind == .divider || kind == .tableOfContents { return true }
        if kind == .table, let data = text.data(using: .utf8),
           let rows = try? JSONDecoder().decode([[String]].self, from: data) {
            return rows.joined().contains { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        }
        return !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}
