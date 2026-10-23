import AppKit
import Foundation
import CryptoKit

@MainActor
enum DOCXTransfer {
    nonisolated static func xml(_ text: String) -> String {
        HTMLTransfer.escape(String(String.UnicodeScalarView(text.unicodeScalars.filter { ($0.value >= 32 || [9, 10, 13].contains($0.value)) && $0.value != 0xFFFE && $0.value != 0xFFFF })))
    }
    nonisolated static func contentDigest(_ package: [String: Data]) -> String {
        var hash = SHA256()
        for key in package.keys.filter({ $0.hasPrefix("word/") }).sorted() {
            hash.update(data: Data((key + "\0").utf8)); hash.update(data: package[key]!)
        }
        return hash.finalize().map { String(format: "%02x", $0) }.joined()
    }
    static func encode(_ document: TransferDocument, math: [String: String] = [:], original: TransferDocument? = nil) throws -> Data {
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
                var hyperlinkID: String?
                if let link = format.link.flatMap(HTMLTransfer.safeLink) {
                    let id = "rLink" + String(relationships.count)
                    hyperlinkID = id
                    properties += "<w:color w:val=\"5651CC\"/><w:u w:val=\"single\"/>"
                    relationships += "<Relationship Id=\"" + id + "\" Type=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships/hyperlink\" Target=\"" + xml(link) + "\" TargetMode=\"External\"/>"
                }
                func textRun(_ text: String) -> String {
                    let content = text.components(separatedBy: "\n").map { "<w:t xml:space=\"preserve\">" + xml($0) + "</w:t>" }.joined(separator: "<w:br/>")
                    let run = "<w:r><w:rPr>" + properties + "</w:rPr>" + content + "</w:r>"
                    if let hyperlinkID { return "<w:hyperlink r:id=\"" + hyperlinkID + "\">" + run + "</w:hyperlink>" }
                    return run
                }
                let pattern = try! NSRegularExpression(pattern: "VELORAMATH[0-9]{8}")
                let ns = segment.text as NSString
                var result = "", start = 0
                for match in pattern.matches(in: segment.text, range: NSRange(location: 0, length: ns.length)) {
                    result += textRun(ns.substring(with: NSRange(location: start, length: match.range.location - start)))
                    let key = ns.substring(with: match.range)
                    result += math[key] ?? textRun(key)
                    start = NSMaxRange(match.range)
                }
                return result + textRun(ns.substring(from: start))
            }.joined()
            return "<w:p><w:pPr><w:pStyle w:val=\"\(style)\"/></w:pPr>\(runs)</w:p>"
        }
        for page in try document.orderedPages() {
            if page.parentID != nil { body += paragraph(document.path(for: page), style: "Caption") }
            if !page.title.isEmpty { body += paragraph(page.title, style: "Title") }
            for block in page.blocks {
                switch block.kind {
                case .heading: body += paragraph(block.text, style: "Heading1", formatting: block.formatting)
                case .heading2: body += paragraph(block.text, style: "Heading2", formatting: block.formatting)
                case .heading3: body += paragraph(block.text, style: "Heading3", formatting: block.formatting)
                case .equation: body += paragraph(block.text, style: "Equation")
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
                        let cells = row.map { cell in
                            let parsed = block.tableLayout.cellsArePlain ? (text: cell, runs: [TextStyleRun]()) : RichInlineContent.parseMarkdown(cell)
                            var header = InlineTextStyle(); header.bold = true
                            let formatting = (index == 0 ? [TextStyleRun(location: 0, length: parsed.text.utf16.count, style: header)] : []) + parsed.runs
                            return "<w:tc><w:tcPr>" + (index == 0 ? "<w:shd w:fill=\"F3F4F6\"/>" : "") + "</w:tcPr>" + paragraph(parsed.text, formatting: formatting) + "</w:tc>"
                        }.joined()
                        body += "<w:tr>" + cells + "</w:tr>"
                    }
                    body += "</w:tbl><w:p/>"
                case .tableOfContents: body += paragraph("页面目录", style: "Caption")
                default: body += paragraph(block.text, formatting: block.formatting)
                }
            }
        }
        let styles = """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?><w:styles xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main"><w:docDefaults><w:rPrDefault><w:rPr><w:rFonts w:ascii="Arial" w:hAnsi="Arial" w:eastAsia="Heiti SC"/><w:sz w:val="24"/><w:color w:val="000000"/></w:rPr></w:rPrDefault><w:pPrDefault><w:pPr><w:spacing w:after="160" w:line="300" w:lineRule="auto"/></w:pPr></w:pPrDefault></w:docDefaults><w:style w:type="paragraph" w:default="1" w:styleId="Normal"><w:name w:val="Normal"/></w:style>
        <w:style w:type="paragraph" w:styleId="Title"><w:name w:val="Title"/><w:basedOn w:val="Normal"/><w:rPr><w:b/><w:sz w:val="52"/></w:rPr></w:style>
        <w:style w:type="paragraph" w:styleId="Heading1"><w:name w:val="heading 1"/><w:basedOn w:val="Normal"/><w:pPr><w:keepNext/><w:outlineLvl w:val="0"/></w:pPr><w:rPr><w:b/><w:sz w:val="44"/></w:rPr></w:style>
        <w:style w:type="paragraph" w:styleId="Heading2"><w:name w:val="heading 2"/><w:basedOn w:val="Normal"/><w:pPr><w:keepNext/><w:outlineLvl w:val="1"/></w:pPr><w:rPr><w:b/><w:sz w:val="36"/></w:rPr></w:style>
        <w:style w:type="paragraph" w:styleId="Heading3"><w:name w:val="heading 3"/><w:basedOn w:val="Normal"/><w:pPr><w:keepNext/><w:outlineLvl w:val="2"/></w:pPr><w:rPr><w:b/><w:sz w:val="32"/></w:rPr></w:style>
        <w:style w:type="paragraph" w:styleId="Code"><w:name w:val="Code"/><w:basedOn w:val="Normal"/><w:pPr><w:shd w:fill="F5F5F7"/></w:pPr><w:rPr><w:rFonts w:ascii="Courier New" w:hAnsi="Courier New"/><w:sz w:val="20"/></w:rPr></w:style>
        <w:style w:type="paragraph" w:styleId="Equation"><w:name w:val="Equation"/><w:basedOn w:val="Normal"/><w:pPr><w:jc w:val="center"/></w:pPr></w:style>
        <w:style w:type="paragraph" w:styleId="Caption"><w:name w:val="Caption"/><w:basedOn w:val="Normal"/><w:rPr><w:sz w:val="20"/><w:color w:val="666666"/></w:rPr></w:style>
        <w:style w:type="paragraph" w:styleId="Quote"><w:name w:val="Quote"/><w:basedOn w:val="Normal"/><w:pPr><w:ind w:left="300"/></w:pPr><w:rPr><w:color w:val="555555"/></w:rPr></w:style></w:styles>
        """
        let xmlDocument = """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?><w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main" xmlns:m="http://schemas.openxmlformats.org/officeDocument/2006/math" xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships" xmlns:wp="http://schemas.openxmlformats.org/drawingml/2006/wordprocessingDrawing" xmlns:a="http://schemas.openxmlformats.org/drawingml/2006/main" xmlns:pic="http://schemas.openxmlformats.org/drawingml/2006/picture"><w:body>\(body)<w:sectPr><w:pgSz w:w="11906" w:h="16838"/><w:pgMar w:top="960" w:right="960" w:bottom="960" w:left="960"/></w:sectPr></w:body></w:document>
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
        var metadata: [(String, Data)] = []
        if let original {
            let digest = contentDigest(Dictionary(uniqueKeysWithValues: [("word/document.xml", Data(xmlDocument.utf8)), ("word/styles.xml", Data(styles.utf8)), ("word/_rels/document.xml.rels", Data(documentRelationships.utf8))] + media))
            let payload = try JSONEncoder().encode(original).base64EncodedString()
            metadata = [("customXml/velora.xml", Data(("<velora hash=\"" + digest + "\">" + payload + "</velora>").utf8))]
        }
        return try ZIPPackage.encode([("[Content_Types].xml", Data(types.utf8)), ("_rels/.rels", Data(rootRelationships.utf8)), ("word/document.xml", Data(xmlDocument.utf8)), ("word/styles.xml", Data(styles.utf8)), ("word/_rels/document.xml.rels", Data(documentRelationships.utf8))] + media + metadata)
    }

    static func decode(_ data: Data, title: String) throws -> TransferDocument {
        let package = try ZIPPackage.decode(data)
        if let data = package["customXml/velora.xml"], let metadata = String(data: data, encoding: .utf8),
           let match = DocumentTransfer.firstMatch(#"<velora hash="([a-f0-9]+)">([A-Za-z0-9+/=]+)</velora>"#, metadata),
           contentDigest(package) == match[1],
           let source = Data(base64Encoded: match[2]), let original = try? JSONDecoder().decode(TransferDocument.self, from: source) {
            _ = try original.orderedPages(); return original
        }

        guard let body = package["word/document.xml"] else { throw AppError.message("Word 缺少正文文档") }
        let relationships = WordRelationships()
        if let xml = package["word/_rels/document.xml.rels"] {
            let parser = XMLParser(data: xml); parser.shouldResolveExternalEntities = false; parser.delegate = relationships
            guard parser.parse() else { throw AppError.message("Word 图片关系无法读取") }
        }
        let numbering = WordNumbering()
        if let xml = package["word/numbering.xml"] {
            let parser = XMLParser(data: xml); parser.shouldResolveExternalEntities = false; parser.delegate = numbering
            guard parser.parse() else { throw AppError.message("Word 列表定义无法读取") }
        }
        let reader = WordBodyReader(package: package, relationships: relationships.images, links: relationships.links, numbering: numbering)
        let parser = XMLParser(data: body); parser.shouldResolveExternalEntities = false; parser.delegate = reader
        guard parser.parse() else { throw AppError.message("Word 正文 XML 无法读取") }
        let name = reader.title ?? title
        return TransferDocument(name: name, pages: [TransferPage(title: name, blocks: reader.resolvedBlocks())])
    }
}

private final class WordRelationships: NSObject, XMLParserDelegate {
    var images: [String: String] = [:]
    var links: [String: String] = [:]
    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName qName: String?, attributes: [String: String]) {
        guard elementName == "Relationship", let id = attributes["Id"], let target = attributes["Target"] else { return }
        if attributes["Type"]?.hasSuffix("/hyperlink") == true {
            links[id] = HTMLTransfer.safeLink(target); return
        }
        guard attributes["TargetMode"] != "External", attributes["Type"]?.hasSuffix("/image") == true else { return }
        let path = target.hasPrefix("/") ? String(target.dropFirst()) : "word/" + target
        let normalized = URL(fileURLWithPath: "/" + path).standardizedFileURL.path
        if normalized.hasPrefix("/word/") { images[id] = String(normalized.dropFirst()) }
    }
}

private final class WordNumbering: NSObject, XMLParserDelegate {
    var definitions: [String: String] = [:]
    var bullets: [String: Bool] = [:]
    var starts: [String: Int] = [:]
    private var abstract: String?, number: String?, level = "0"
    func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?, qualifiedName qName: String?, attributes: [String: String]) {
        switch name {
        case "w:abstractNum": abstract = attributes["w:abstractNumId"]
        case "w:lvl": level = attributes["w:ilvl"] ?? "0"
        case "w:numFmt": if let abstract { bullets[abstract + ":" + level] = attributes["w:val"] == "bullet" }
        case "w:start": if let abstract { starts[abstract + ":" + level] = attributes["w:val"].flatMap(Int.init) }
        case "w:num": number = attributes["w:numId"]
        case "w:abstractNumId": if let number { definitions[number] = attributes["w:val"] }
        default: break
        }
    }
    func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName qName: String?) {
        if name == "w:abstractNum" { abstract = nil }; if name == "w:num" { number = nil }
    }
}

private final class WordBodyReader: NSObject, XMLParserDelegate {
    let package: [String: Data]
    let relationships: [String: String]
    let links: [String: String]
    let numbering: WordNumbering
    private var activeLink: String?
    private var listID: String?
    private var listLevel = 0
    private var counters: [String: Int] = [:]
    var blocks: [TransferBlock] = []
    var title: String?
    private var text = ""
    private var style = ""
    private var runs: [TextStyleRun] = []
    private var runStyle = InlineTextStyle()
    private var runStart = 0
    private var inText = false
    private var mathDepth = 0
    private var mathXML = ""
    private var mathSources: [String: String] = [:]
    private var tableDepth = 0
    private var rows: [[String]] = []
    private var row: [String] = []
    private var cell = ""
    init(package: [String: Data], relationships: [String: String], links: [String: String], numbering: WordNumbering) {
        self.package = package; self.relationships = relationships; self.links = links; self.numbering = numbering
    }
    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName qName: String?, attributes: [String: String]) {
        if elementName == "m:oMath" || mathDepth > 0 {
            if mathDepth == 0 { mathXML = "" }
            mathDepth += 1
            mathXML += "<" + elementName + (elementName == "m:oMath" ? " xmlns:m=\"http://schemas.openxmlformats.org/officeDocument/2006/math\"" : "")
            for (key, value) in attributes { mathXML += " " + key + "=\"" + HTMLTransfer.escape(value) + "\"" }
            mathXML += ">"; return
        }
        switch elementName {
        case "w:p": text = ""; style = ""; runs = []; listID = nil; listLevel = 0; activeLink = nil
        case "w:hyperlink": activeLink = attributes["r:id"].flatMap { links[$0] }
        case "w:numId": listID = attributes["w:val"]
        case "w:ilvl": listLevel = min(20, max(0, attributes["w:val"].flatMap(Int.init) ?? 0))
        case "w:r": runStyle = InlineTextStyle(); runStyle.link = activeLink; runStart = text.utf16.count
        case "w:b": runStyle.bold = attributes["w:val"] != "0" && attributes["w:val"] != "false"
        case "w:i": runStyle.italic = attributes["w:val"] != "0" && attributes["w:val"] != "false"
        case "w:u": runStyle.underline = attributes["w:val"] != "none"
        case "w:strike": runStyle.strikethrough = attributes["w:val"] != "0"
        case "w:color": runStyle.color = attributes["w:val"]
        case "w:sz": runStyle.fontSize = attributes["w:val"].flatMap(Double.init).map { $0 / 2 }
        case "w:rFonts": runStyle.fontFamily = attributes["w:ascii"] ?? attributes["w:eastAsia"]
        case "w:pStyle": style = attributes["w:val"]?.lowercased() ?? ""
        case "w:t", "m:t": inText = true
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
    func parser(_ parser: XMLParser, foundCharacters string: String) {
        if mathDepth > 0 { mathXML += HTMLTransfer.escape(string) }
        else if inText { text += string }
    }
    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {
        if mathDepth > 0 {
            mathXML += "</" + elementName + ">"; mathDepth -= 1
            if mathDepth == 0 {
                let key = "VELORAOMML" + String(format: "%08d", mathSources.count)
                mathSources[key] = mathXML; text += key
            }
            return
        }
        switch elementName {
        case "w:hyperlink": activeLink = nil
        case "w:r":
            let length = text.utf16.count - runStart
            if length > 0, !runStyle.isEmpty { runs.append(TextStyleRun(location: runStart, length: length, style: runStyle)) }
        case "w:t", "m:t": inText = false
        case "w:p":
            if tableDepth > 0 { cell += (cell.isEmpty ? "" : "\n") + text }
            else { emitText() }
        case "w:tc": if tableDepth == 1 { row.append(cell) }
        case "w:tr": if tableDepth == 1 && !row.isEmpty { rows.append(row) }
        case "w:tbl":
            tableDepth -= 1
            if tableDepth == 0, let data = try? JSONEncoder().encode(rows), !rows.isEmpty {
                blocks.append(TransferBlock(.table, String(decoding: data, as: UTF8.self), tableLayout: TableLayout(cellsArePlain: true)))
            }
        default: break
        }
    }
    // XMLParser is not reentrant: resolve equations only after the outer document parse ends.
    func resolvedBlocks() -> [TransferBlock] {
        let formulas = mathSources.mapValues { "\\(" + MathMLToOfficeMath.latex(fromOfficeMath: $0) + "\\)" }
        func resolve(_ source: String) -> String {
            formulas.reduce(source) { $0.replacingOccurrences(of: $1.key, with: $1.value) }
        }
        let resolved = blocks.map { block in
            var result = block
            if block.kind == .table, let data = block.text.data(using: .utf8),
               let rows = try? JSONDecoder().decode([[String]].self, from: data), block.text.contains("VELORAOMML"), let first = rows.first {
                func row(_ cells: [String]) -> String { "| " + cells.map { resolve($0).replacingOccurrences(of: "|", with: "\\|") }.joined(separator: " | ") + " |" }
                result.kind = .markdown
                result.text = ([row(first), row(Array(repeating: "---", count: first.count))] + rows.dropFirst().map(row)).joined(separator: "\n")
            } else { result.text = resolve(block.text) }
            return result
        }
        var grouped: [TransferBlock] = []
        for block in resolved {
            if block.kind == .markdown, let last = grouped.last, last.kind == .markdown,
               DocumentTransfer.firstMatch(#"^\s*(?:[-*+] |[0-9]+\. )"#, block.text) != nil,
               DocumentTransfer.firstMatch(#"^\s*(?:[-*+] |[0-9]+\. )"#, last.text) != nil {
                grouped[grouped.count - 1].text += "\n" + block.text
            } else { grouped.append(block) }
        }
        return grouped
    }

    private func emitText() {
        let codeStyle = ["code", "sourcecode", "source code", "codeblock", "preformatted", "htmlpreformatted"].contains(style)
        // Word code paragraphs encode indentation in xml:space-preserved text
        // and w:tab. Keep both, including deliberately empty code paragraphs.
        let value = codeStyle ? text : text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard codeStyle || !value.isEmpty else { return }
        if style == "title", title == nil { title = value; return }
        let kind: BlockKind
        switch style {
        case "heading1": kind = .heading
        case "heading2": kind = .heading2
        case "heading3", "heading4", "heading5", "heading6": kind = .heading3
        case "code", "sourcecode", "source code", "codeblock", "preformatted", "htmlpreformatted": kind = .code
        case "quote", "intensequote", "blockquote": kind = .quote
        default: kind = .paragraph
        }
        let offset = (text as NSString).range(of: value).location
        let formatting = runs.compactMap { run -> TextStyleRun? in
            let intersection = NSIntersectionRange(NSRange(location: run.location, length: run.length), NSRange(location: offset, length: value.utf16.count))
            guard intersection.length > 0 else { return nil }
            return TextStyleRun(location: intersection.location - offset, length: intersection.length, style: run.style)
        }
        let inline = RichInlineContent.markdown(value, runs: formatting)
        if codeStyle {
            blocks.append(TransferBlock(.code, value, formatting: formatting))
        } else if let listID, let abstract = numbering.definitions[listID] {
            let key = abstract + ":" + String(listLevel)
            let counterKey = listID + ":" + String(listLevel)
            let next = counters[counterKey].map { $0 + 1 } ?? numbering.starts[key] ?? 1
            counters[counterKey] = next
            let prefix = numbering.bullets[key] == true ? "- " : "\(next). "
            blocks.append(TransferBlock(.markdown, String(repeating: "    ", count: listLevel) + prefix + inline))
        } else if value.hasPrefix("• ") || DocumentTransfer.firstMatch(#"^[0-9]+\. "#, value) != nil {
            let spaces = text.prefix { $0 == " " }.count
            blocks.append(TransferBlock(.markdown, String(repeating: " ", count: spaces) + (value.hasPrefix("• ") ? "- " + String(inline.dropFirst(2)) : inline)))
        } else if value.contains("VELORAOMML") {
            blocks.append(TransferBlock(.markdown, RichInlineContent.markdown(value, runs: formatting)))
        } else { blocks.append(TransferBlock(kind, value, formatting: formatting)) }
    }
}
