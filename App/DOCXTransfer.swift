import AppKit
import Foundation

@MainActor
enum DOCXTransfer {
    static func xml(_ text: String) -> String {
        HTMLTransfer.escape(String(String.UnicodeScalarView(text.unicodeScalars.filter { ($0.value >= 32 || [9, 10, 13].contains($0.value)) && $0.value != 0xFFFE && $0.value != 0xFFFF })))
    }
    static func encode(_ document: TransferDocument) throws -> Data {
        var media: [(String, Data)] = []; var relationships = ""; var body = ""; var imageIndex = 0
        func paragraph(_ text: String, style: String = "Normal", formatting: [TextStyleRun] = []) -> String {
            let runs = RichInlineContent.segments(text, runs: formatting).map { segment -> String in
                let format = segment.style; var properties = ""
                if let bold = format.bold { properties += "<w:b w:val=\"\(bold ? 1 : 0)\"/>" }
                if let italic = format.italic { properties += "<w:i w:val=\"\(italic ? 1 : 0)\"/>" }
                if format.underline { properties += "<w:u w:val=\"single\"/>" }
                if format.strikethrough { properties += "<w:strike/>" }
                if let color = format.color, UInt32(color, radix: 16) != nil { properties += "<w:color w:val=\"\(xml(color))\"/>" }
                if let color = format.highlight, UInt32(color, radix: 16) != nil { properties += "<w:shd w:fill=\"\(xml(color))\"/>" }
                if let size = format.fontSize { properties += "<w:sz w:val=\"\(Int(min(96, max(8, size)) * 2))\"/>" }
                if let family = format.fontFamily { properties += "<w:rFonts w:ascii=\"\(xml(family))\" w:hAnsi=\"\(xml(family))\" w:eastAsia=\"\(xml(family))\"/>" }
                let content = segment.text.components(separatedBy: "\n").map { "<w:t xml:space=\"preserve\">" + xml($0) + "</w:t>" }.joined(separator: "<w:br/>")
                return "<w:r><w:rPr>" + properties + "</w:rPr>" + content + "</w:r>"
            }.joined()
            return "<w:p><w:pPr><w:pStyle w:val=\"\(style)\"/></w:pPr>\(runs)</w:p>"
        }
        for page in try document.orderedPages() {
            if page.parentID != nil { body += paragraph(document.path(for: page), style: "Caption") }
            body += paragraph(page.title, style: "Title")
            for block in page.blocks {
                switch block.kind {
                case .heading: body += paragraph(block.text, style: "Heading1", formatting: block.formatting)
                case .heading2: body += paragraph(block.text, style: "Heading2", formatting: block.formatting)
                case .heading3: body += paragraph(block.text, style: "Heading3", formatting: block.formatting)
                case .code: body += paragraph(block.text, style: "Code", formatting: block.formatting)
                case .todo: body += paragraph((block.checked ? "☑ " : "☐ ") + block.text)
                case .bullet: body += paragraph("• " + block.text)
                case .numbered: body += paragraph("1. " + block.text)
                case .quote, .callout: body += paragraph(block.text, style: "Quote")
                case .divider: body += paragraph("────────────────────")
                case .image:
                    guard block.text.hasPrefix("data:"), let image = ImageSource.thumbnail(block.text), image.size.width > 0,
                          let tiff = image.tiffRepresentation, let bitmap = NSBitmapImageRep(data: tiff),
                          let png = bitmap.representation(using: .png, properties: [:]) else {
                        body += paragraph(block.text.isEmpty ? "[未选择图片]" : "[图片链接] " + block.text, style: "Caption"); continue
                    }
                    imageIndex += 1; let name = "image\(imageIndex).png"; let id = "rImage\(imageIndex)"
                    media.append(("word/media/" + name, png))
                    relationships += "<Relationship Id=\"\(id)\" Type=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships/image\" Target=\"media/\(name)\"/>"
                    let ratio = min(1, 490 / image.size.width, 400 / image.size.height)
                    let cx = Int(image.size.width * ratio * 12700); let cy = Int(image.size.height * ratio * 12700)
                    body += """
                    <w:p><w:r><w:drawing><wp:inline><wp:extent cx="\(cx)" cy="\(cy)"/><wp:docPr id="\(imageIndex)" name="图片 \(imageIndex)"/><a:graphic><a:graphicData uri="http://schemas.openxmlformats.org/drawingml/2006/picture"><pic:pic><pic:nvPicPr><pic:cNvPr id="\(imageIndex)" name="\(name)"/><pic:cNvPicPr/></pic:nvPicPr><pic:blipFill><a:blip r:embed="\(id)"/><a:stretch><a:fillRect/></a:stretch></pic:blipFill><pic:spPr><a:xfrm><a:off x="0" y="0"/><a:ext cx="\(cx)" cy="\(cy)"/></a:xfrm><a:prstGeom prst="rect"><a:avLst/></a:prstGeom></pic:spPr></pic:pic></a:graphicData></a:graphic></wp:inline></w:drawing></w:r></w:p>
                    """
                case .table:
                    guard let data = block.text.data(using: .utf8), let rows = try? JSONDecoder().decode([[String]].self, from: data) else { body += paragraph(block.text); continue }
                    let borders = ["top", "left", "bottom", "right", "insideH", "insideV"].map { "<w:\($0) w:val=\"single\" w:sz=\"4\" w:color=\"D5D5D5\"/>" }.joined()
                    body += "<w:tbl><w:tblPr><w:tblW w:w=\"0\" w:type=\"auto\"/><w:tblBorders>\(borders)</w:tblBorders></w:tblPr>"
                    for (index, row) in rows.enumerated() {
                        body += "<w:tr>" + row.map { "<w:tc><w:tcPr>" + (index == 0 ? "<w:shd w:fill=\"F3F4F6\"/>" : "") + "</w:tcPr>" + paragraph($0) + "</w:tc>" }.joined() + "</w:tr>"
                    }
                    body += "</w:tbl><w:p/>"
                case .tableOfContents: body += paragraph("页面目录", style: "Caption")
                default: body += paragraph(block.text, formatting: block.formatting)
                }
            }
        }
        let styles = """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?><w:styles xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main"><w:docDefaults><w:rPrDefault><w:rPr><w:rFonts w:ascii="Arial" w:hAnsi="Arial" w:eastAsia="Songti SC"/><w:sz w:val="24"/><w:color w:val="000000"/></w:rPr></w:rPrDefault><w:pPrDefault><w:pPr><w:spacing w:after="160" w:line="300" w:lineRule="auto"/></w:pPr></w:pPrDefault></w:docDefaults><w:style w:type="paragraph" w:default="1" w:styleId="Normal"><w:name w:val="Normal"/></w:style>
        <w:style w:type="paragraph" w:styleId="Title"><w:name w:val="Title"/><w:basedOn w:val="Normal"/><w:rPr><w:b/><w:sz w:val="52"/></w:rPr></w:style>
        <w:style w:type="paragraph" w:styleId="Heading1"><w:name w:val="heading 1"/><w:basedOn w:val="Normal"/><w:pPr><w:keepNext/><w:outlineLvl w:val="0"/></w:pPr><w:rPr><w:b/><w:sz w:val="44"/></w:rPr></w:style>
        <w:style w:type="paragraph" w:styleId="Heading2"><w:name w:val="heading 2"/><w:basedOn w:val="Normal"/><w:pPr><w:keepNext/><w:outlineLvl w:val="1"/></w:pPr><w:rPr><w:b/><w:sz w:val="36"/></w:rPr></w:style>
        <w:style w:type="paragraph" w:styleId="Heading3"><w:name w:val="heading 3"/><w:basedOn w:val="Normal"/><w:pPr><w:keepNext/><w:outlineLvl w:val="2"/></w:pPr><w:rPr><w:b/><w:sz w:val="32"/></w:rPr></w:style>
        <w:style w:type="paragraph" w:styleId="Code"><w:name w:val="Code"/><w:basedOn w:val="Normal"/><w:pPr><w:shd w:fill="F5F5F7"/></w:pPr><w:rPr><w:rFonts w:ascii="Courier New" w:hAnsi="Courier New"/><w:sz w:val="20"/></w:rPr></w:style>
        <w:style w:type="paragraph" w:styleId="Caption"><w:name w:val="Caption"/><w:basedOn w:val="Normal"/><w:rPr><w:sz w:val="20"/><w:color w:val="666666"/></w:rPr></w:style>
        <w:style w:type="paragraph" w:styleId="Quote"><w:name w:val="Quote"/><w:basedOn w:val="Normal"/><w:pPr><w:ind w:left="300"/></w:pPr><w:rPr><w:color w:val="555555"/></w:rPr></w:style></w:styles>
        """
        let xmlDocument = """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?><w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main" xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships" xmlns:wp="http://schemas.openxmlformats.org/drawingml/2006/wordprocessingDrawing" xmlns:a="http://schemas.openxmlformats.org/drawingml/2006/main" xmlns:pic="http://schemas.openxmlformats.org/drawingml/2006/picture"><w:body>\(body)<w:sectPr><w:pgSz w:w="11906" w:h="16838"/><w:pgMar w:top="960" w:right="960" w:bottom="960" w:left="960"/></w:sectPr></w:body></w:document>
        """
        let types = """
        <?xml version="1.0" encoding="UTF-8"?><Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types"><Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/><Default Extension="xml" ContentType="application/xml"/><Default Extension="png" ContentType="image/png"/><Override PartName="/word/document.xml" ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.document.main+xml"/><Override PartName="/word/styles.xml" ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.styles+xml"/></Types>
        """
        let rootRelationships = """
        <?xml version="1.0" encoding="UTF-8"?><Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships"><Relationship Id="rDocument" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="word/document.xml"/></Relationships>
        """
        let documentRelationships = """
        <?xml version="1.0" encoding="UTF-8"?><Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships"><Relationship Id="rStyles" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/styles" Target="styles.xml"/>\(relationships)</Relationships>
        """
        return try ZIPPackage.encode([("[Content_Types].xml", Data(types.utf8)), ("_rels/.rels", Data(rootRelationships.utf8)), ("word/document.xml", Data(xmlDocument.utf8)), ("word/styles.xml", Data(styles.utf8)), ("word/_rels/document.xml.rels", Data(documentRelationships.utf8))] + media)
    }

    static func decode(_ data: Data, title: String) throws -> TransferDocument {
        let package = try ZIPPackage.decode(data)
        guard let body = package["word/document.xml"] else { throw AppError.message("Word 缺少正文文档") }
        let relationships = WordRelationships()
        if let xml = package["word/_rels/document.xml.rels"] {
            let parser = XMLParser(data: xml); parser.shouldResolveExternalEntities = false; parser.delegate = relationships
            guard parser.parse() else { throw AppError.message("Word 图片关系无法读取") }
        }
        let reader = WordBodyReader(package: package, relationships: relationships.images)
        let parser = XMLParser(data: body); parser.shouldResolveExternalEntities = false; parser.delegate = reader
        guard parser.parse() else { throw AppError.message("Word 正文 XML 无法读取") }
        let name = reader.title ?? title
        return TransferDocument(name: name, pages: [TransferPage(title: name, blocks: reader.blocks)])
    }
}

private final class WordRelationships: NSObject, XMLParserDelegate {
    var images: [String: String] = [:]
    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName qName: String?, attributes: [String: String]) {
        guard elementName == "Relationship", attributes["TargetMode"] != "External", attributes["Type"]?.hasSuffix("/image") == true,
              let id = attributes["Id"], let target = attributes["Target"] else { return }
        let path = target.hasPrefix("/") ? String(target.dropFirst()) : "word/" + target
        let normalized = URL(fileURLWithPath: "/" + path).standardizedFileURL.path
        if normalized.hasPrefix("/word/") { images[id] = String(normalized.dropFirst()) }
    }
}

private final class WordBodyReader: NSObject, XMLParserDelegate {
    let package: [String: Data]
    let relationships: [String: String]
    var blocks: [TransferBlock] = []
    var title: String?
    private var text = ""
    private var style = ""
    private var inText = false
    private var tableDepth = 0
    private var rows: [[String]] = []
    private var row: [String] = []
    private var cell = ""
    init(package: [String: Data], relationships: [String: String]) { self.package = package; self.relationships = relationships }
    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName qName: String?, attributes: [String: String]) {
        switch elementName {
        case "w:p": text = ""; style = ""
        case "w:pStyle": style = attributes["w:val"]?.lowercased() ?? ""
        case "w:t": inText = true
        case "w:tab": text += "\t"
        case "w:br": text += "\n"
        case "a:blip":
            if let id = attributes["r:embed"], let path = relationships[id], let bytes = package[path], let image = try? ImageSource.embedded(bytes) {
                if !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { emitText() }
                blocks.append(TransferBlock(.image, image)); text = ""
            }
        case "w:tbl": tableDepth += 1; if tableDepth == 1 { rows = [] }
        case "w:tr": if tableDepth == 1 { row = [] }
        case "w:tc": if tableDepth == 1 { cell = "" }
        default: break
        }
    }
    func parser(_ parser: XMLParser, foundCharacters string: String) { if inText { text += string } }
    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {
        switch elementName {
        case "w:t": inText = false
        case "w:p":
            if tableDepth > 0 { cell += (cell.isEmpty ? "" : "\n") + text }
            else { emitText() }
        case "w:tc": if tableDepth == 1 { row.append(cell) }
        case "w:tr": if tableDepth == 1 && !row.isEmpty { rows.append(row) }
        case "w:tbl":
            tableDepth -= 1
            if tableDepth == 0, let data = try? JSONEncoder().encode(rows), !rows.isEmpty { blocks.append(TransferBlock(.table, String(decoding: data, as: UTF8.self))) }
        default: break
        }
    }
    private func emitText() {
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return }
        if style == "title", title == nil { title = value; return }
        let kind: BlockKind
        switch style {
        case "heading1": kind = .heading
        case "heading2": kind = .heading2
        case "heading3", "heading4", "heading5", "heading6": kind = .heading3
        case "code": kind = .code
        case "quote": kind = .quote
        default: kind = .paragraph
        }
        blocks.append(TransferBlock(kind, value))
    }
}
