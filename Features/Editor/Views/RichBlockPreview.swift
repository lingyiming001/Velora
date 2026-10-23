import SwiftUI
import WebKit
import PDFKit
import UniformTypeIdentifiers

/// A single local document reused across edits; no network scripts or reload per keystroke.
struct RichBlockPreview: NSViewRepresentable {
    let source: String
    let equation: Bool
    let dark: Bool
    let fontSize: Double
    @Binding var height: CGFloat
    @Binding var error: String?

    static var documentURL: URL? { Bundle.main.url(forResource: "preview", withExtension: "html", subdirectory: "RenderAssets") }

    func makeNSView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.userContentController.add(context.coordinator, name: "layout")
        configuration.userContentController.add(context.coordinator, name: "copy")
        let view = WKWebView(frame: .zero, configuration: configuration)
        view.navigationDelegate = context.coordinator
        view.underPageBackgroundColor = .clear
        context.coordinator.webView = view
        if let url = Self.documentURL { view.loadFileURL(url, allowingReadAccessTo: url.deletingLastPathComponent()) }
        else { DispatchQueue.main.async { error = L10n.tr("预览资源缺失，请重新构建应用。") } }
        return view
    }

    func updateNSView(_ view: WKWebView, context: Context) {
        context.coordinator.parent = self
        context.coordinator.scheduleRender()
    }

    static func dismantleNSView(_ view: WKWebView, coordinator: Coordinator) {
        coordinator.isActive = false
        coordinator.pending?.cancel()
        coordinator.pending = nil
        view.configuration.userContentController.removeScriptMessageHandler(forName: "layout")
        view.configuration.userContentController.removeScriptMessageHandler(forName: "copy")
        view.navigationDelegate = nil
        view.stopLoading()
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    final class Coordinator: NSObject, WKNavigationDelegate, WKScriptMessageHandler {
        var parent: RichBlockPreview
        weak var webView: WKWebView?
        var pending: Task<Void, Never>?
        var isActive = true
        private var scheduled: Input?
        private var ready = false
        private var rendered: Input?
        private struct Input: Equatable { var source: String; var equation: Bool; var dark: Bool; var size: Double; var language: String }
        init(_ parent: RichBlockPreview) { self.parent = parent }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            guard isActive else { return }
            ready = true; rendered = nil; scheduled = nil; scheduleRender()
        }

        func scheduleRender() {
            guard isActive, ready else { return }
            let input = Input(source: parent.source, equation: parent.equation, dark: parent.dark, size: parent.fontSize, language: L10n.language.resolved)
            guard input != scheduled else { return }
            // Height updates can arrive before JavaScript completes. Keep the same
            // in-flight render instead of repeatedly cancelling and enqueueing it.
            scheduled = input
            pending?.cancel()
            pending = Task { @MainActor [weak self] in
                // First display should not pay the typing debounce delay.
                if self?.rendered != nil {
                    do { try await Task.sleep(for: .milliseconds(160)) } catch { return }
                }
                guard let self, self.isActive, !Task.isCancelled, let view = self.webView else { return }
                do {
                    _ = try await view.callAsyncJavaScript("return window.renderContent(source, equation, dark, fontSize, language)",
                        arguments: ["source": input.source, "equation": input.equation, "dark": input.dark, "fontSize": input.size, "language": input.language],
                        in: nil, contentWorld: .page)
                    guard self.isActive, !Task.isCancelled else { return }
                    self.rendered = input; self.parent.error = nil
                } catch {
                    if self.isActive, !Task.isCancelled {
                        self.scheduled = nil
                        self.parent.error = L10n.tr("预览加载失败，可继续编辑并复制源码。")
                    }
                }
            }
        }

        func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
            guard isActive, message.frameInfo.isMainFrame else { return }
            if message.name == "layout", let value = message.body as? Double, value.isFinite, value > 0 {
                let height = CGFloat(min(value, 200000))
                if abs(parent.height - height) > 1 { parent.height = height }
            } else if message.name == "copy", let payload = message.body as? [String: Any], let text = payload["text"] as? String {
                if payload["selection"] as? Bool == true {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(text, forType: .string)
                    NSPasteboard.general.setString("1", forType: ClipboardDocument.textSelectionType)
                } else {
                    ClipboardDocument.copyBlocks([TransferBlock(.code, text, language: payload["language"] as? String ?? "Plain Text")])
                }
            } else if message.name == "copy", let text = message.body as? String {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(text, forType: .string)
            }
        }

        func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction,
                     decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
            if action.navigationType == .linkActivated {
                if let url = action.request.url, ["https", "http", "mailto"].contains(url.scheme?.lowercased() ?? "") {
                    NSWorkspace.shared.open(url)
                }
                decisionHandler(.cancel)
            } else { decisionHandler(action.request.url?.isFileURL == true ? .allow : .cancel) }
        }
        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
            parent.error = L10n.tr("预览加载失败，可继续编辑并复制源码。")
        }
        func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
            ready = false; rendered = nil; parent.error = L10n.tr("预览进程已停止。重新打开页面以重试，源码已保留。")
        }
    }
}


struct PDFDocumentBlock: View {
    @Binding var source: String
    var extract: (String) -> Void
    @State private var document: PDFDocument?
    @State private var error: String?
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label(L10n.tr("PDF 原件"), systemImage: "doc.richtext")
                if let document { Text(L10n.tr("\(document.pageCount) 页")).foregroundStyle(.secondary) }
                Spacer()
                if let text = document?.string, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    Button(L10n.tr("提取文字为新块")) { extract(text) }
                }
                Button(document == nil ? L10n.tr("选择 PDF…") : L10n.tr("更换 PDF…")) { choose() }
            }.font(.caption).buttonStyle(.borderless)
            if let document { NativePDFPreview(document: document).frame(height: 640) }
            else { Text(L10n.tr("导入或选择 PDF，保留原始页面、图表和公式排版。")).foregroundStyle(.secondary).frame(maxWidth: .infinity, minHeight: 100) }
            if let error { Text(error).font(.caption).foregroundStyle(.red) }
        }.padding(12).background(Color.primary.opacity(0.025), in: RoundedRectangle(cornerRadius: 10))
            .task(id: source) {
                document = EmbeddedPDF.document(source)
                if !source.isEmpty && document == nil { error = L10n.tr("PDF 原件无法读取") }
            }
    }
    private func choose() {
        let panel = NSOpenPanel(); panel.allowedContentTypes = [.pdf]; panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task {
            let access = url.startAccessingSecurityScopedResource(); defer { if access { url.stopAccessingSecurityScopedResource() } }
            do {
                let data = try await Task.detached { () throws -> Data in
                    guard (try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0) <= 70 * 1024 * 1024 else { throw AppError.message(L10n.tr("PDF 不能超过 70 MB")) }
                    return try Data(contentsOf: url)
                }.value
                guard let pdf = PDFDocument(data: data), !pdf.isLocked else { throw AppError.message(L10n.tr("PDF 无法读取或需要密码")) }
                error = nil; source = EmbeddedPDF.source(data)
            } catch { self.error = error.localizedDescription }
        }
    }
}

private struct NativePDFPreview: NSViewRepresentable {
    let document: PDFDocument
    func makeNSView(context: Context) -> PDFView {
        let view = PDFView(); view.autoScales = true; view.displayMode = .singlePageContinuous
        view.displayDirection = .vertical; view.displaysPageBreaks = true
        view.document = document; return view
    }
    func updateNSView(_ view: PDFView, context: Context) {
        if view.document !== document { view.document = document }
    }
}
