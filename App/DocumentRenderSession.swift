import AppKit
import WebKit
import PDFKit
import CryptoKit

/// The same local renderer powers block previews, rich import and all visual exports.
@MainActor
final class DocumentRenderSession: NSObject, WKNavigationDelegate, WKScriptMessageHandler {
    let view: WKWebView
    private var continuation: CheckedContinuation<Void, Error>?
    private var timeout: Task<Void, Never>?
    private var loaded = false

    override init() {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .nonPersistent()
        view = WKWebView(frame: NSRect(x: 0, y: 0, width: 740, height: 1000), configuration: config)
        super.init()
        view.navigationDelegate = self
        config.userContentController.add(self, name: "layout")
        config.userContentController.add(self, name: "copy")
    }
    func close() {
        timeout?.cancel(); view.stopLoading(); view.navigationDelegate = nil
        view.configuration.userContentController.removeAllScriptMessageHandlers()
        finish(AppError.message("文档处理已取消"))
    }
    func open() async throws {
        guard !loaded else { return }
        guard let url = RichBlockPreview.documentURL else { throw AppError.message("文档渲染资源缺失，请重新构建应用") }
        try await withCheckedThrowingContinuation { continuation in
            self.continuation = continuation
            timeout = Task { [weak self] in
                do { try await Task.sleep(for: .seconds(25)) } catch { return }
                self?.finish(AppError.message("文档渲染超时，请缩小导出范围后重试"))
            }
            view.loadFileURL(url, allowingReadAccessTo: url.deletingLastPathComponent())
        }
    }
    private func finish(_ error: Error? = nil) {
        timeout?.cancel(); timeout = nil
        let waiting = continuation; continuation = nil
        if let error { waiting?.resume(throwing: error) } else { loaded = true; waiting?.resume() }
    }
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { finish() }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) { finish(error) }
    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) { finish(error) }
    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) { finish(AppError.message("文档渲染进程退出，请重试")) }
    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) { }
    func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        decisionHandler(action.request.url?.isFileURL == true ? .allow : .cancel)
    }
    func run(_ script: String, arguments: [String: Any] = [:]) async throws -> Any? {
        try await open()
        try Task.checkCancellation()
        return try await view.callAsyncJavaScript("return await Promise.race([(async()=>{" + script + "})(),new Promise((_,reject)=>setTimeout(()=>reject(new Error('文档处理超时')),30000))])", arguments: arguments, in: nil, contentWorld: .page)
    }
    static func markdown(fromHTML html: String) async throws -> String {
        let session = DocumentRenderSession(); defer { session.close() }
        return try await session.run("return htmlToMarkdown(html)", arguments: ["html": html]) as? String ?? ""
    }
    func render(_ document: TransferDocument) async throws {
        let expanded = try EmbeddedPDF.expanded(document)
        let source = try expanded.orderedPages().map {
            try DocumentExporter.markdown($0, assetDirectory: nil)
        }.joined(separator: "\n\n---\n\n")
        _ = try await run("await renderContent(source, false, false, 16); await prepareExport(); if(document.querySelector('.math-error,.mermaid-error'))throw new Error('存在无效公式或图表，请在页面中修正后导出'); return true", arguments: ["source": source])
    }
    nonisolated static func digest(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }

    func html(_ original: TransferDocument) async throws -> String {
        let body = try await run("const clone=document.querySelector('#content').cloneNode(true); clone.querySelectorAll('button,.mermaid-source').forEach(n=>n.remove()); clone.querySelectorAll('[data-export-png]').forEach(n=>n.removeAttribute('data-export-png')); return clone.innerHTML") as? String ?? ""
        guard let assets = RichBlockPreview.documentURL?.deletingLastPathComponent() else { throw AppError.message("渲染资源缺失") }
        var css = try ["katex.min.css", "highlight-light.css", "preview.css"].map { try String(contentsOf: assets.appendingPathComponent($0), encoding: .utf8) }.joined(separator: "\n")
        let regex = try NSRegularExpression(pattern: #"url\((?:\"|')?(fonts/[^\)\"']+)(?:\"|')?\)"#)
        for match in regex.matches(in: css, range: NSRange(css.startIndex..., in: css)).reversed() {
            guard let path = Range(match.range(at: 1), in: css), let range = Range(match.range, in: css) else { continue }
            let data = try Data(contentsOf: assets.appendingPathComponent(String(css[path])))
            css.replaceSubrange(range, with: "url(data:font/woff2;base64," + data.base64EncodedString() + ")")
        }
        css += "\nhtml,body{overflow:visible;background:white;color:#24252a}body{max-width:850px;margin:40px auto;padding:0 28px}pre code{white-space:pre-wrap;overflow-wrap:anywhere}img{max-width:100%;height:auto}.code-header button{display:none}@media print{body{margin:0;max-width:none}h1,h2,h3{break-after:avoid}tr,.katex-display,img{break-inside:avoid}}"
        let payload = try JSONEncoder().encode(original).base64EncodedString()
        return "<!doctype html><html lang=\"zh-CN\"><head><meta charset=\"utf-8\"><meta name=\"viewport\" content=\"width=device-width,initial-scale=1\"><title>" + HTMLTransfer.escape(original.name) + "</title><meta name=\"velora-body-sha256\" content=\"" + Self.digest(Data((body + css).utf8)) + "\"><meta http-equiv=\"Content-Security-Policy\" content=\"default-src 'none'; style-src 'unsafe-inline'; img-src data: https: http:; font-src data:\"><style>" + css + "</style><script type=\"application/json\" id=\"velora-source\">" + payload + "</script></head><body>" + body + "</body></html>"
    }
    func pdf() async throws -> Data {
        let width: CGFloat = 740, contentWidth: CGFloat = 499, contentHeight: CGFloat = 746
        let value = try await run("return exportCuts(height)", arguments: ["height": contentHeight * width / contentWidth])
        let cuts = value as? [Double] ?? []
        guard cuts.count > 1, cuts.count <= 2001 else { throw AppError.message("文档为空或超过 2,000 页导出限制") }
        let data = NSMutableData(); var media = CGRect(x: 0, y: 0, width: 595, height: 842)
        guard let consumer = CGDataConsumer(data: data as CFMutableData), let context = CGContext(consumer: consumer, mediaBox: &media, nil) else { throw AppError.message("无法创建 PDF") }
        for index in 0..<(cuts.count - 1) {
            try Task.checkCancellation()
            let height = CGFloat(cuts[index + 1] - cuts[index])
            let config = WKPDFConfiguration(); config.rect = CGRect(x: 0, y: cuts[index], width: width, height: height)
            let pageData = try await view.pdf(configuration: config)
            guard let provider = CGDataProvider(data: pageData as CFData), let pdf = CGPDFDocument(provider), let page = pdf.page(at: 1) else { throw AppError.message("PDF 分页失败") }
            context.beginPDFPage(nil); context.saveGState()
            context.setFillColor(NSColor.white.cgColor); context.fill(media)
            context.translateBy(x: 48, y: 842 - 48 - height * contentWidth / width)
            context.scaleBy(x: contentWidth / width, y: contentWidth / width)
            context.drawPDFPage(page)
            context.restoreGState(); context.endPDFPage()
        }
        context.closePDF(); return data as Data
    }
    func word(_ original: TransferDocument) async throws -> Data {
        let value = try await run("return wordContent()") as? [String: Any] ?? [:]
        let blocks = try JSONDecoder().decode([TransferBlock].self, from: JSONSerialization.data(withJSONObject: value["blocks"] ?? []))
        let math = (value["math"] as? [String: String] ?? [:]).mapValues { MathMLToOfficeMath.convert($0) }
        let rendered = TransferDocument(name: original.name, pages: [TransferPage(title: "", blocks: blocks)])
        return try DOCXTransfer.encode(rendered, math: math, original: original)
    }
}


@MainActor
enum EmbeddedPDF {
    static func source(_ data: Data) -> String { "data:application/pdf;base64," + data.base64EncodedString() }
    static func data(_ source: String) -> Data? {
        guard source.hasPrefix("data:application/pdf;base64,") else { return nil }
        return Data(base64Encoded: String(source.dropFirst("data:application/pdf;base64,".count)))
    }
    static func document(_ source: String) -> PDFDocument? { data(source).flatMap(PDFDocument.init(data:)) }
    static func images(_ source: String) throws -> [String] {
        guard let pdf = document(source), !pdf.isLocked else { throw AppError.message("PDF 无法读取或需要密码") }
        guard pdf.pageCount <= 100 else { throw AppError.message("超过 100 页的 PDF 请直接导出为 PDF，以保留完整原件") }
        return try (0..<pdf.pageCount).map { index in
            guard let page = pdf.page(at: index) else { throw AppError.message("PDF 页面无法读取") }
            let image = page.thumbnail(of: NSSize(width: 1600, height: 2200), for: .mediaBox)
            guard let tiff = image.tiffRepresentation, let bitmap = NSBitmapImageRep(data: tiff), let png = bitmap.representation(using: .png, properties: [:]) else { throw AppError.message("PDF 页面渲染失败") }
            return try ImageSource.embedded(png)
        }
    }
    static func expanded(_ original: TransferDocument) throws -> TransferDocument {
        var document = original
        for page in document.pages.indices {
            document.pages[page].blocks = try document.pages[page].blocks.flatMap { block in
                if block.kind == .pdfDocument { return try images(block.text).map { TransferBlock(.image, $0) } }
                return [block]
            }
        }
        return document
    }
    static func exportPDF(_ document: TransferDocument) async throws -> Data {
        let pages = try document.orderedPages()
        if pages.count == 1, pages[0].blocks.count == 1, pages[0].blocks[0].kind == .pdfDocument,
           let data = data(pages[0].blocks[0].text), (PDFDocument(data: data)?.pageCount ?? 0) > 0 { return data }
        let output = PDFDocument()
        func append(_ data: Data) throws {
            guard let pdf = PDFDocument(data: data) else { throw AppError.message("PDF 无法读取") }
            for index in 0..<pdf.pageCount { if let page = pdf.page(at: index) { output.insert(page, at: output.pageCount) } }
        }
        for page in pages {
            var pending: [TransferBlock] = page.blocks.isEmpty ? [TransferBlock(.paragraph)] : [], title = page.title
            func flush() async throws {
                guard !pending.isEmpty else { return }
                let session = DocumentRenderSession(); defer { session.close() }
                try await session.render(TransferDocument(name: document.name, pages: [TransferPage(title: title, blocks: pending)]))
                let data = try await session.pdf(); try append(data); pending = []; title = ""
            }
            for block in page.blocks {
                if block.kind == .pdfDocument {
                    try await flush()
                    guard let bytes = data(block.text) else { throw AppError.message("PDF 原件损坏") }
                    try append(bytes)
                } else { pending.append(block) }
            }
            try await flush()
        }
        guard let data = output.dataRepresentation() else { throw AppError.message("PDF 合并失败") }
        return data
    }
}
