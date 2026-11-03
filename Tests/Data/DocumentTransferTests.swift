import AppKit
import PDFKit
import CoreText
import SQLite3
import XCTest
@testable import Velora

@MainActor
final class DocumentTransferTests: XCTestCase {
    func testRawPythonCodeCopyCreatesPythonBlockWithExactWhitespace() async throws {
        let source = "from dotenv import load_dotenv\nfrom langchain_openai import ChatOpenAI\n\n# 加载环境变量\nload_dotenv()\n\nmodel = ChatOpenAI(\n    model=\"gpt-4o-mini\",\n    temperature=0\n)\nresponse = model.invoke(\"解释 LangChain\")\nprint(response.content)"
        XCTAssertTrue(ClipboardDocument.isStructured(source, html: nil))
        let markdown = try await ClipboardDocument.markdown(plain: source, html: nil)
        let blocks = try DocumentTransfer.markdown(markdown, title: "", consumeLeadingTitle: false).pages[0].blocks
        XCTAssertEqual(blocks.count, 1)
        XCTAssertEqual(blocks[0].kind, .code)
        XCTAssertEqual(blocks[0].language.lowercased(), "python")
        XCTAssertEqual(blocks[0].text, source)
        XCTAssertNil(ClipboardDocument.pythonCode("下面是代码：\nfrom dotenv import load_dotenv\nmodel = 1\n这是一段说明"))
        XCTAssertNil(ClipboardDocument.pythonCode("from package import value\n说明文字"))
    }

    func testRawPythonWithInlineHTMLRetainsCodeWhitespace() async throws {
        let source = "import os\n\nif True:\n    print(os.getcwd())"
        let markdown = try await ClipboardDocument.markdown(plain: source, html: "<span>import os if True: print(os.getcwd())</span>")
        let blocks = try DocumentTransfer.markdown(markdown, title: "", consumeLeadingTitle: false).pages[0].blocks
        XCTAssertEqual(blocks.count, 1)
        XCTAssertEqual(blocks.first?.kind, .code)
        XCTAssertEqual(blocks.first?.text, source)
    }

    func testHTMLCodeParagraphLinesAndNestedRowsRetainWhitespace() async throws {
        for body in [
            "<p>import os</p><p></p><p>if True:</p><p>    print(1)</p>",
            "<div><div>import os</div><div></div><div>if True:</div><div>    print(1)</div></div>"
        ] {
            let markdown = try await DocumentRenderSession.markdown(fromHTML: "<pre data-language='python'>" + body + "</pre>")
            let blocks = try DocumentTransfer.markdown(markdown, title: "", consumeLeadingTitle: false).pages[0].blocks
            XCTAssertEqual(blocks.first?.text, "import os\n\nif True:\n    print(1)")
        }
    }

    private func captureChatGPTBrowserCopy(_ fixture: String, selectionScript: String = "range.selectNodeContents(fixture);") async throws -> [String: String] {
        let scriptURL = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("deploy/chrome-copy-helper/copy.js")
        let helper = try String(contentsOf: scriptURL, encoding: .utf8)
        let session = DocumentRenderSession(); defer { session.close() }
        _ = try await session.run(helper + "\nreturn true;")
        let result = try await session.run("""
        const fixture=document.createElement('div');fixture.innerHTML=html;document.body.append(fixture);
        const range=document.createRange();
        """ + selectionScript + """
        const selection=window.getSelection();selection.removeAllRanges();selection.addRange(range);
        const copied={};const event=new Event('copy',{bubbles:true,cancelable:true});
        Object.defineProperty(event,'clipboardData',{value:{setData(type,value){copied[type]=value;}}});
        fixture.dispatchEvent(event);return copied;
        """, arguments: ["html": fixture])
        return try XCTUnwrap(result as? [String: String])
    }

    func testBrowserCopyHelperPreservesPythonAndPlainTextBlocksThroughPaste() async throws {
        let python = "import sys\n\nfor path in sys.path:\n    print(path)"
        let plain = "Windows:\n.venv/Lib/site-packages/\n\nmacOS / Linux:\n.venv/lib/pythonX.Y/site-packages/"
        let fixture = "<p>之前</p><div>Python</div><div class='cm-editor'><div class='cm-content'>" + python.components(separatedBy: "\n").map { "<div class='cm-line'><span>" + HTMLTransfer.escape($0) + "</span></div>" }.joined() + "</div></div><p>中间</p><pre><code>" + HTMLTransfer.escape(plain) + "</code></pre><p>之后</p>"
        let copy = try await captureChatGPTBrowserCopy(fixture)
        XCTAssertTrue(try XCTUnwrap(copy["text/plain"]).contains(python))
        XCTAssertTrue(try XCTUnwrap(copy["text/plain"]).contains(plain))
        let markdown = try await ClipboardDocument.markdown(plain: copy["text/plain"], html: copy["text/html"])
        let blocks = try DocumentTransfer.markdown(markdown, title: "", consumeLeadingTitle: false).pages[0].blocks
        XCTAssertEqual(blocks.filter { $0.kind == .code }.map(\.text), [python, plain])
        XCTAssertTrue(blocks.contains { $0.text == "之前" })
        XCTAssertTrue(blocks.contains { $0.text == "之后" })
    }

    func testBrowserCopyHelperPreservesPartialEditorSelectionAndRepeatedBlankLines() async throws {
        let fixture = "<div class='cm-content'><div class='cm-line'><span>prefix abc</span></div><div class='cm-line'></div><div class='cm-line'></div><div class='cm-line'>    abc suffix</div></div>"
        let copy = try await captureChatGPTBrowserCopy(fixture, selectionScript: "const lines=fixture.querySelectorAll('.cm-line');range.setStart(lines[0].firstChild.firstChild,7);range.setEnd(lines[3].firstChild,7);")
        XCTAssertEqual(copy["text/plain"], "abc\n\n\n    abc")
        let markdown = try await ClipboardDocument.markdown(plain: copy["text/plain"], html: copy["text/html"])
        XCTAssertEqual(try DocumentTransfer.markdown(markdown, title: "", consumeLeadingTitle: false).pages[0].blocks.first?.text, "abc\n\n\n    abc")
    }

    func testBrowserCopyHelperLeavesProseAloneAndPreservesLineBasedPlainText() async throws {
        let prose = try await captureChatGPTBrowserCopy("<p>普通正文</p>")
        XCTAssertTrue(prose.isEmpty)
        let virtualized = try await captureChatGPTBrowserCopy("<div class='cm-content'><div class='cm-line'>first</div><div class='cm-gap'></div><div class='cm-line'>last</div></div>")
        XCTAssertTrue(virtualized.isEmpty)
        let copy = try await captureChatGPTBrowserCopy("<pre><code><span class='line'>line 1</span><span class='line'></span><span class='line'>    line 2</span></code></pre>")
        XCTAssertEqual(copy["text/plain"], "line 1\n\n    line 2\n")
    }

    func testLocalCodeLineRepairRestoresScreenshotWithoutChangingCharacters() throws {
        let source = "import osapi_key = os.getenv(\"OPENAI_API_KEY\")"
        let expected = "import os\n\napi_key = os.getenv(\"OPENAI_API_KEY\")"
        let suggestion = try XCTUnwrap(CodeLineRepair.localSuggestion(source))
        XCTAssertEqual(suggestion, expected)
        XCTAssertEqual(try CodeLineRepair.validated(suggestion, original: source), expected)
        XCTAssertNil(CodeLineRepair.localSuggestion(expected))
        XCTAssertNil(CodeLineRepair.localSuggestion("import os"))
        XCTAssertNil(CodeLineRepair.localSuggestion("import osapi_key = other.getenv('KEY')"))
        XCTAssertNil(CodeLineRepair.localSuggestion("import os1key = os.getenv('KEY')"))
    }

    func testLocalCodeLineRepairRestoresJoinedImportAndSimpleLoop() throws {
        let source = "import sysfor path in sys.path:    print(path)"
        let expected = "import sys\n\nfor path in sys.path:\n    print(path)"
        XCTAssertEqual(CodeLineRepair.localSuggestion(source), expected)
        XCTAssertEqual(try CodeLineRepair.validated(expected, original: source), expected)
        XCTAssertNil(CodeLineRepair.localSuggestion("import sysfor path in other.path:    print(path)"))
        XCTAssertNil(CodeLineRepair.localSuggestion("import sysfor path in sys.path:    print(other)"))
    }

    func testCodeLineRepairRejectsChangedCodeAndStringContents() throws {
        let source = "import osapi_key = os.getenv(\"OPENAI_API_KEY\")"
        let expected = "import os\n\napi_key = os.getenv(\"OPENAI_API_KEY\")"
        XCTAssertThrowsError(try CodeLineRepair.validated(source, original: source))
        XCTAssertThrowsError(try CodeLineRepair.validated(expected.replacingOccurrences(of: "getenv", with: "system"), original: source))
        XCTAssertThrowsError(try CodeLineRepair.validated(expected.replacingOccurrences(of: "OPENAI_API_KEY", with: "OPENAI API KEY"), original: source))
        XCTAssertEqual(try CodeLineRepair.validated("```python\n" + expected + "\n```", original: source), expected)
        for literal in [#""hello world""#, #"'a \' b'"#, #""""中文  空格""""#, #""a\" b""#] {
            let code = "a=" + literal + ";b=1"
            XCTAssertNoThrow(try CodeLineRepair.validated("a = " + literal + ";\nb = 1", original: code))
            XCTAssertThrowsError(try CodeLineRepair.validated("a = " + literal.replacingOccurrences(of: " ", with: "") + ";\nb = 1", original: code))
        }
    }

    func testChatGPTScreenshotCollapsedImportWarnsAndIntactCodeCopyWorks() async throws {
        let damaged = "import osapi_key = os.getenv(\"OPENAI_API_KEY\")"
        let html = "<p>更合理的做法是：</p><div><div><pre dir='ltr'><code>" + damaged + "</code></pre></div><div></div></div><p>这样，代码与密钥分离。</p>"
        let markdown = try await ClipboardDocument.markdown(plain: "更合理的做法是：\n" + damaged + "\n这样，代码与密钥分离。", html: html)
        let blocks = try DocumentTransfer.markdown(markdown, title: "", consumeLeadingTitle: false).pages[0].blocks
        let code = try XCTUnwrap(blocks.first { $0.kind == .code })
        XCTAssertEqual(code.text, damaged)
        XCTAssertEqual(code.language.lowercased(), "python")
        XCTAssertTrue(blocks.contains { $0.kind == .warning && $0.text.contains("复制代码") })

        let intact = "import os\n\napi_key = os.getenv(\"OPENAI_API_KEY\")"
        let copied = try await ClipboardDocument.markdown(plain: intact, html: nil)
        let restored = try DocumentTransfer.markdown(copied, title: "", consumeLeadingTitle: false).pages[0].blocks
        XCTAssertEqual(restored.first?.text, intact)
        XCTAssertEqual(restored.first?.language.lowercased(), "python")

        let valid = try await ClipboardDocument.markdown(plain: nil, html: "<pre><code>import os; api_key = os.getenv(\"OPENAI_API_KEY\")</code></pre>")
        XCTAssertFalse(valid.contains("[!WARNING]"))
    }

    func testClipboardAlreadyCollapsedPythonWarnsWithoutInventingNewlines() async throws {
        let damaged = "from dotenv import load_dotenvfrom langchain_openai import ChatOpenAI# 1. 加载环境变量load_dotenv()# 2. 创建模型model = ChatOpenAI(    model=\"gpt-4o-mini\",    temperature=0)"
        let html = "<p>创建文件 <code>example_01.py</code>：</p><div><div><pre dir='ltr'><code>" + HTMLTransfer.escape(damaged) + "</code></pre></div><div></div></div>"
        let markdown = try await ClipboardDocument.markdown(plain: "创建文件 example_01.py：\n" + damaged, html: html)
        let blocks = try DocumentTransfer.markdown(markdown, title: "", consumeLeadingTitle: false).pages[0].blocks
        let code = try XCTUnwrap(blocks.first { $0.kind == .code })
        XCTAssertEqual(code.language.lowercased(), "python")
        XCTAssertEqual(code.text, damaged)
        XCTAssertTrue(blocks.contains { $0.kind == .warning && $0.text.contains("复制代码") })
        let valid = try await DocumentRenderSession.markdown(fromHTML: "<p>创建文件 <code>example_01.py</code>：</p><div><pre><code>import os\n\nprint(os.getcwd())</code></pre></div>")
        let good = try DocumentTransfer.markdown(valid, title: "").pages[0].blocks
        XCTAssertEqual(good.first { $0.kind == .code }?.text, "import os\n\nprint(os.getcwd())")
        XCTAssertFalse(good.contains { $0.kind == .warning })
    }

    func testImageTextCardLocalizationCopyExportsAndExistingBlocksMerge() async throws {
        let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 12, pixelsHigh: 8, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        let bytes = bitmap.representation(using: .png, properties: [:])!
        let card = ImageTextCard(image: "https://example.com/logo.png", title: "LangChain", body: "构建 LLM 应用与 Agent", caption: "关键词：模型集成")
        let converted = try await LocalDocumentImages.blocks([TransferBlock(.imageCard, card.encoded)]) { _ in bytes }
        let localized = try XCTUnwrap(ImageTextCard.decode(converted[0].text))
        XCTAssertTrue(localized.image.hasPrefix("data:image/png;base64,"))
        XCTAssertEqual(localized.title, card.title)
        let page = TransferPage(title: "资料", blocks: converted)
        let markdown = try DocumentExporter.markdown(page, assetDirectory: nil)
        XCTAssertTrue(markdown.contains("![图片]")); XCTAssertTrue(markdown.contains("LangChain"))
        XCTAssertFalse(markdown.contains("\"caption\""))
        let html = HTMLTransfer.page(page)
        XCTAssertTrue(html.contains("velora-image-card"))
        let renderer = DocumentRenderSession(); defer { renderer.close() }
        try await renderer.render(TransferDocument(name: "卡片", pages: [page]))
        let visualHTML = try await renderer.html(TransferDocument(name: "卡片", pages: [page]))
        XCTAssertTrue(visualHTML.contains("velora-image-card"))
        let roundTrip = try await DocumentRenderSession.markdown(fromHTML: html)
        let imported = try DocumentTransfer.markdown(roundTrip, title: "", consumeLeadingTitle: false)
        XCTAssertEqual(ImageTextCard.decode(imported.pages[0].blocks.first(where: { $0.kind == .imageCard })!.text), localized)
        let directory = try mediaSaveDirectory(); defer { try? FileManager.default.removeItem(at: directory) }
        let store = try SQLiteStore(databaseURL: directory.appendingPathComponent("cards.sqlite"))
        let ids = try await store.importTransfer(TransferDocument(name: "资料", pages: [TransferPage(title: "旧布局", blocks: localized.expanded)]))
        let original = try await store.blocks(in: ids[0])
        try await store.mergeImageCard(original, card: localized)
        let merged = try await store.blocks(in: ids[0])
        XCTAssertEqual(merged.count, 1); XCTAssertEqual(merged[0].id, original[0].id)
        XCTAssertEqual(merged[0].kind, .imageCard)
        XCTAssertEqual(ImageTextCard.decode(merged[0].text), localized)
        let copy = NSPasteboard.withUniqueName(); defer { copy.releaseGlobally() }
        XCTAssertTrue(ClipboardDocument.copyBlocks([TransferBlock(merged[0])], to: copy))
        XCTAssertEqual(ClipboardDocument.blocks(from: copy), converted)
        let docx = try DOCXTransfer.encode(TransferDocument(name: "卡片", pages: [page]))
        XCTAssertTrue(try ZIPPackage.decode(docx).keys.contains { $0.hasPrefix("word/media/") })
    }

    func testRemoteImagesEmbedOriginalBytesDeduplicateAndSurviveReopening() async throws {
        let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 8, pixelsHigh: 6, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        let bytes = bitmap.representation(using: .png, properties: [:])!
        let remote = "https://example.com/expiring-image.png"
        var requests = 0
        let input = [TransferBlock(.paragraph, "原文"), TransferBlock(.image, remote, imageWidth: 180), TransferBlock(.image, remote), TransferBlock(.bookmark, "https://example.com")]
        let embedded = try await LocalDocumentImages.blocks(input) { source in
            requests += 1; XCTAssertEqual(source, remote); return bytes
        }
        XCTAssertEqual(requests, 1)
        XCTAssertTrue(embedded[1].text.hasPrefix("data:image/png;base64,"))
        XCTAssertEqual(Data(base64Encoded: embedded[1].text.components(separatedBy: ";base64,")[1]), bytes)
        XCTAssertEqual(embedded[1].text, embedded[2].text)
        XCTAssertEqual(embedded[1].imageWidth, 180)
        XCTAssertEqual(embedded[3], input[3])
        let directory = try mediaSaveDirectory(); defer { try? FileManager.default.removeItem(at: directory) }
        let path = directory.appendingPathComponent("offline.sqlite")
        let store = try SQLiteStore(databaseURL: path)
        let ids = try await store.importTransfer(TransferDocument(name: "离线图片", pages: [TransferPage(title: "图片", blocks: embedded)]))
        let reopened = try SQLiteStore(databaseURL: path)
        let loaded = try await reopened.blocks(in: ids[0])
        XCTAssertEqual(loaded[1].text, embedded[1].text)
        XCTAssertNotNil(ImageSource.thumbnail(loaded[1].text))
        let noNetwork = try await LocalDocumentImages.blocks(embedded) { _ in XCTFail("Local image must not fetch"); return Data() }
        XCTAssertEqual(noNetwork, embedded)
        let remoteIDs = try await store.importTransfer(TransferDocument(name: "旧页", pages: [TransferPage(title: "旧页", blocks: input)]))
        let before = try await store.blocks(in: remoteIDs[0])
        let replacements = [before[1].id: embedded[1].text, before[2].id: embedded[2].text]
        try await store.embedPageImages(replacements, expected: [before[1].id: remote, before[2].id: remote], pageID: remoteIDs[0])
        let after = try await store.blocks(in: remoteIDs[0])
        XCTAssertEqual(after.map(\.id), before.map(\.id))
        XCTAssertEqual(after[1].text, embedded[1].text)
        do {
            try await store.embedPageImages(replacements, expected: [before[1].id: remote, before[2].id: remote], pageID: remoteIDs[0])
            XCTFail("Stale sources must not overwrite current data")
        } catch { }
    }

    func testImageLocalizationFailureDoesNotReturnPartialContent() async throws {
        let input = [TransferBlock(.paragraph, "原文"), TransferBlock(.image, "https://example.com/missing.png")]
        do {
            _ = try await LocalDocumentImages.blocks(input) { _ in Data("not an image".utf8) }
            XCTFail("Invalid download must fail")
        } catch { }
        XCTAssertEqual(input[1].text, "https://example.com/missing.png")
    }

    func testChatGPTImageCardsBecomeImagesInsteadOfSourceTitleLinks() async throws {
        let names = ["LangChain", "LangGraph", "LangSmith"]
        let sourceTitles = ["LangChain - Partner Ecosystem | MongoDB", "Improve your AI infrastructure - AI memory engine", "AI Quality Assurance & Governance – Humancloud Technologies"]
        var html = "<p>这是初学者经常混淆的三个概念。</p>"
        for index in names.indices {
            html += "<div><a href='https://images.openai.com/static-rsc-4/resource-\(index)?purpose=inline'>" + sourceTitles[index] + "</a><p><strong>" + names[index] + "</strong></p><p>用途说明</p><p>关键词：应用开发、模型集成</p></div>"
        }
        let markdown = try await ClipboardDocument.markdown(plain: sourceTitles.map { "[" + $0 + "](https://example.com)" }.joined(separator: "\n"), html: html)
        let blocks = try DocumentTransfer.markdown(markdown, title: "", consumeLeadingTitle: false).pages[0].blocks
        XCTAssertEqual(blocks.filter { $0.kind == .imageCard }.count, 3)
        let flattened = TransferDocument(name: "", pages: [TransferPage(title: "", blocks: blocks)]).expandingImageCards().pages[0].blocks
        let images = flattened.filter { $0.kind == .image }
        XCTAssertEqual(images.count, 3, markdown)
        for index in names.indices {
            XCTAssertEqual(images[index].text, "https://images.openai.com/static-rsc-4/resource-\(index)?purpose=inline")
            XCTAssertTrue(flattened.contains { $0.text == names[index] })
            XCTAssertFalse(blocks.contains { $0.text.contains(sourceTitles[index]) })
        }
        XCTAssertTrue(ClipboardDocument.isStructured(nil, html: html))
        let reopened = try JSONDecoder().decode([TransferBlock].self, from: JSONEncoder().encode(blocks))
        XCTAssertEqual(reopened, blocks)
    }

    func testLinkedImagesDoNotNestMarkdownLinksAndNormalLinksRemainText() async throws {
        let html = "<a href='https://example.com/article'><img src='https://example.com/logo.png' alt='Logo'/></a><a href='https://example.com/manual'>文档链接</a><a href='https://images.openai.com.evil.example/static-rsc-4/x'>普通链接</a><a href='javascript:alert(1)'>无效链接</a>"
        let markdown = try await ClipboardDocument.markdown(plain: "**标题**", html: html)
        let blocks = try DocumentTransfer.markdown(markdown, title: "", consumeLeadingTitle: false).pages[0].blocks
        XCTAssertEqual(blocks.filter { $0.kind == .image }.map(\.text), ["https://example.com/logo.png"])
        XCTAssertFalse(markdown.contains("[\n\n!["))
        XCTAssertTrue(markdown.contains("[文档链接](<https://example.com/manual>)"))
        XCTAssertTrue(markdown.contains("[普通链接](<https://images.openai.com.evil.example/static-rsc-4/x>)"))
        XCTAssertFalse(markdown.contains("javascript:"))
    }

    func testChatGPTCodePasteRestoresExactPlainTextLineBreaksAndIndentation() async throws {
        let code = "from langchain_core.prompts import ChatPromptTemplate\n\nprompt = ChatPromptTemplate.from_messages([\n    (\"system\", \"你是一位专业的 Python 讲师\"),\n    (\"human\", \"请解释：{question}\")\n])"
        let collapsed = code.replacingOccurrences(of: "\n", with: "")
        let html = "<p>示例</p><div data-language='python'><pre><code>" + HTMLTransfer.escape(collapsed) + "</code></pre></div><p>结束</p>"
        let markdown = try await ClipboardDocument.markdown(plain: "示例\nPython\n" + code + "\n结束", html: html)
        let blocks = try DocumentTransfer.markdown(markdown, title: "", consumeLeadingTitle: false).pages[0].blocks
        let block = try XCTUnwrap(blocks.first { $0.kind == .code })
        XCTAssertEqual(block.text, code)
        XCTAssertEqual(block.language.lowercased(), "python")
        let copied = NSPasteboard.withUniqueName(); defer { copied.releaseGlobally() }
        XCTAssertTrue(ClipboardDocument.copyBlocks([block], to: copied))
        XCTAssertEqual(copied.string(forType: .string), code)
        XCTAssertEqual(ClipboardDocument.blocks(from: copied)?.first?.text, code)
    }

    func testHTMLCodeBlockStyledSpanLinesAndBlankLinesWithoutPlainClipboard() async throws {
        let html = "<pre><code class='language-python'><span style='display:block'>import example</span><span style='display:block'></span><span style='display:block'>if True:</span><span style='display:block'>    print(1)</span></code></pre>"
        let markdown = try await DocumentRenderSession.markdown(fromHTML: html)
        let blocks = try DocumentTransfer.markdown(markdown, title: "").pages[0].blocks
        XCTAssertEqual(blocks.first?.text, "import example\n\nif True:\n    print(1)")
        XCTAssertEqual(blocks.first?.language.lowercased(), "python")
        let header = try await DocumentRenderSession.markdown(fromHTML: "<div><div><span>Python</span><button>Copy</button><button>Run</button></div><div><pre><code>print(1)</code></pre></div></div>")
        XCTAssertEqual(try DocumentTransfer.markdown(header, title: "").pages[0].blocks.first(where: { $0.kind == .code })?.language.lowercased(), "python")
        let unrelated = try await DocumentRenderSession.markdown(fromHTML: "<pre><code>a = 1\nb = 2</code></pre>", plainText: "另一段\n无关内容")
        XCTAssertEqual(try DocumentTransfer.markdown(unrelated, title: "").pages[0].blocks.first?.text, "a = 1\nb = 2")
    }

    func testChatGPTSVGIconsSurviveClipboardAsCompactOfflineImages() async throws {
        let icons = [
            "<path d='M12 22v-5'/><path d='M8 2v5M16 2v5'/><rect x='5' y='7' width='14' height='10' rx='3'/>",
            "<path d='M21 11a8 8 0 0 1-8 8H5l-3 3V11a9 9 0 0 1 19 0Z'/>",
            "<rect x='4' y='3' width='16' height='18' rx='3'/><path d='M8 8h8M8 12h5'/>",
            "<ellipse cx='12' cy='5' rx='8' ry='3'/><path d='M4 5v14c0 4 16 4 16 0V5M4 12c0 4 16 4 16 0'/>",
            "<path d='m4 20 7-7a6 6 0 0 0 7-7l-4 4-3-3 4-4a6 6 0 0 0-7 7l-7 7Z'/>",
            "<circle cx='12' cy='12' r='9'/><path d='M12 6v6l4 2'/>",
            "<path d='M12 2 21 6v7c0 5-9 9-9 9s-9-4-9-9V6Z'/><path d='M12 7v6M12 16h.01'/>"
        ]
        let titles = ["连接模型", "管理 Prompt", "处理文档", "检索知识", "调用工具", "管理状态", "处理异常"]
        let rows = zip(icons,titles).map { icon,title in
            "<div style='display:flex'><span aria-hidden='true'><svg aria-hidden='true' viewBox='0 0 24 24' width='24' height='24' fill='none' stroke='currentColor' stroke-width='2'>" + icon + "</svg></span><div><p><strong>" + title + "</strong></p><p>能力说明</p></div></div>"
        }.joined()
        let markdown = try await ClipboardDocument.markdown(plain: titles.joined(separator: "\n"), html: rows)
        let blocks = try DocumentTransfer.markdown(markdown, title: "", consumeLeadingTitle: false).expandingImageCards().pages[0].blocks
        let images = blocks.filter { $0.kind == .image }
        XCTAssertEqual(images.count, 7, markdown)
        for image in images {
            let valid = try ImageSource.validated(image.text)
            let picture = try XCTUnwrap(ImageSource.thumbnail(valid))
            XCTAssertLessThanOrEqual(picture.size.width, 24)
            XCTAssertGreaterThan(picture.size.height, 0)
            let data = try XCTUnwrap(Data(base64Encoded: valid.components(separatedBy: ";base64,").last!))
            let bitmap = try XCTUnwrap(NSBitmapImageRep(data: data))
            var visiblePixels = 0
            for y in 0..<bitmap.pixelsHigh { for x in 0..<bitmap.pixelsWide {
                if (bitmap.colorAt(x: x, y: y)?.alphaComponent ?? 0) > 0.1 { visiblePixels += 1 }
            } }
            XCTAssertGreaterThan(visiblePixels, 8, "Icon must contain visible drawing, not a transparent image")
        }
        for title in titles { XCTAssertTrue(blocks.contains { $0.text.contains(title) }) }
        XCTAssertFalse(markdown.contains("<svg"))
        let json = try JSONEncoder().encode(blocks)
        XCTAssertEqual(try JSONDecoder().decode([TransferBlock].self, from: json), blocks)
        let copied = NSPasteboard.withUniqueName(); defer { copied.releaseGlobally() }
        XCTAssertTrue(ClipboardDocument.copyBlocks(blocks, to: copied))
        XCTAssertEqual(ClipboardDocument.blocks(from: copied), blocks)
    }

    func testSVGClipboardStripsActiveContentAndKeepsVisibleText() async throws {
        let svg = "<svg viewBox='0 0 24 24' width='24' height='24' fill='none' stroke='currentColor' onload='alert(1)'><script>window.pwned=true</script><foreignObject><p>恶意内容</p></foreignObject><image href='https://invalid.example/track'/><circle cx='12' cy='12' r='8'/><path d='M4 4h16' style='stroke:url(https://invalid.example/x)'/></svg>"
        let markdown = try await DocumentRenderSession.markdown(fromHTML: "<p>之前</p>" + svg + "<p>之后</p><button>" + svg + "复制</button>")
        let blocks = try DocumentTransfer.markdown(markdown, title: "", consumeLeadingTitle: false).pages[0].blocks
        XCTAssertEqual(blocks.filter { $0.kind == .image }.count, 1)
        XCTAssertTrue(blocks.contains { $0.text == "之前" })
        XCTAssertTrue(blocks.contains { $0.text == "之后" })
        XCTAssertFalse(markdown.contains("恶意内容"))
        XCTAssertFalse(markdown.contains("invalid.example"))
        XCTAssertFalse(markdown.contains("复制"))
    }

    func testEPUBBookPackageHierarchyReadingOrderAndOfflineImages() async throws {
        let parent = UUID(), child = UUID(), grandchild = UUID(), second = UUID()
        let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 4, pixelsHigh: 3, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        let source = "data:image/png;base64," + bitmap.representation(using: .png, properties: [:])!.base64EncodedString()
        let document = TransferDocument(name: "技术书 & <学习>", pages: [
            TransferPage(id: parent, title: "第一章", blocks: [TransferBlock(.heading, "概念 & 基础"), TransferBlock(.numbered, "Token", listStart: 1), TransferBlock(.paragraph, "正文"), TransferBlock(.numbered, "Prompt", listStart: 2), TransferBlock(.image, source), TransferBlock(.image, source), TransferBlock(.code, "if a < b {\n  print(\"&\")\n}"), TransferBlock(.table, "[[\"名称\",\"说明\"],[\"A\",\"B\"]]")]),
            TransferPage(id: second, title: "第二章", blocks: [TransferBlock(.paragraph, "结束")]),
            TransferPage(id: child, parentID: parent, title: "子章节", blocks: [TransferBlock(.markdown, "## Markdown 标题\n\n**粗体**")]),
            TransferPage(id: grandchild, parentID: child, title: "孙章节", blocks: [TransferBlock(.equation, "x^2")])
        ])
        let data = try await EPUBTransfer.encode(document)
        // EPUB OCF requires the first local entry to be stored, with no extra field.
        XCTAssertEqual(Array(data[8..<10]), [0, 0])
        XCTAssertEqual(Array(data[28..<30]), [0, 0])
        XCTAssertEqual(String(data: data[30..<38], encoding: .utf8), "mimetype")
        XCTAssertEqual(String(data: data[38..<58], encoding: .utf8), "application/epub+zip")
        let package = try ZIPPackage.decode(data)
        for (path, bytes) in package where path.hasSuffix(".xhtml") || path.hasSuffix(".xml") || path.hasSuffix(".opf") {
            XCTAssertNoThrow(try XMLDocument(data: bytes, options: []), path)
        }
        let opf = try XMLDocument(data: XCTUnwrap(package["EPUB/package.opf"]))
        XCTAssertEqual(try opf.nodes(forXPath: "//*[local-name()='itemref']").count, 4)
        let chapter = String(decoding: try XCTUnwrap(package["EPUB/chapter-1.xhtml"]), as: UTF8.self)
        XCTAssertTrue(chapter.contains("<ol start=\"2\">"))
        XCTAssertTrue(chapter.contains("<table>"))
        XCTAssertFalse(chapter.contains("data:image"))
        XCTAssertEqual(package.keys.filter { $0.hasPrefix("EPUB/images/") }.count, 1)
        let nav = String(decoding: try XCTUnwrap(package["EPUB/nav.xhtml"]), as: UTF8.self)
        XCTAssertTrue(nav.contains("epub:type=\"toc\""))
        XCTAssertTrue(nav.contains("chapter-1.xhtml#heading-0"))
        XCTAssertTrue(String(decoding: package["EPUB/chapter-2.xhtml"]!, as: UTF8.self).contains("子章节"))
        XCTAssertTrue(String(decoding: package["EPUB/chapter-3.xhtml"]!, as: UTF8.self).contains("孙章节"))
        XCTAssertTrue(String(decoding: package["EPUB/chapter-4.xhtml"]!, as: UTF8.self).contains("第二章"))
        let output = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent(".agents/test/epub-fixture.epub")
        try await DocumentExporter.write(document, format: .epub, to: output)
        XCTAssertEqual(TransferFormat.epub.ext, "epub")
        XCTAssertNil(TransferFormat.detect(output), "EPUB export does not imply EPUB import")
    }

    func testEPUBFailureProtectsExistingExportAndDoesNotLeakLocalPaths() async throws {
        let directory = try mediaSaveDirectory(); defer { try? FileManager.default.removeItem(at: directory) }
        let output = directory.appendingPathComponent("book.epub")
        let original = Data("existing".utf8); try original.write(to: output)
        let invalid = TransferDocument(name: "图片错误", pages: [TransferPage(title: "A", blocks: [TransferBlock(.image, "data:image/png;base64,YmFk")])])
        do { try await DocumentExporter.write(invalid, format: .epub, to: output); XCTFail("Invalid image must fail") } catch { }
        XCTAssertEqual(try Data(contentsOf: output), original)
        let document = TransferDocument(name: "附件", pages: [TransferPage(title: "A", blocks: [TransferBlock(.file, "file:///private/example.pdf"), TransferBlock(.video, "https://example.com/watch?v=1&x=2"), TransferBlock(.paragraph, "control\u{0001}text")])])
        let package = try ZIPPackage.decode(try await EPUBTransfer.encode(document))
        let bytes = try XCTUnwrap(package["EPUB/chapter-1.xhtml"])
        let html = String(decoding: bytes, as: UTF8.self)
        XCTAssertFalse(html.contains("/private/"))
        XCTAssertTrue(html.contains("watch?v=1&amp;x=2"))
        XCTAssertNoThrow(try XMLDocument(data: bytes))
    }

    func testChatGPTInlineBadgeAndImportanceRemainOneLineWithCodeAndBoldStyles() async throws {
        let title = "23. MySQL 索引为什么会失效？什么是最左前缀原则？"
        let variants = [
            "<p><code>难度 ★★★★☆</code> <strong>重要程度：★★★★★</strong></p>",
            "<div style='display:flex;gap:16px'><div><p><code>难度 ★★★★☆</code></p></div><blockquote><p><strong>重要程度：★★★★★</strong></p></blockquote></div>",
            "<p><code>难度 ★★★★☆</code></p><blockquote><strong>重要程度：★★★★★</strong></blockquote>",
            "<p><span>\n    <code>难度 ★★★★☆</code>\n    </span><strong>重要程度：★★★★★</strong></p>"
        ]
        for row in variants {
            let html = "<h3>" + title + "</h3>" + row + "<h3>一、标准答案</h3>"
            let plain = title + "\n难度 ★★★★☆ 重要程度：★★★★★\n一、标准答案"
            let markdown = try await ClipboardDocument.markdown(plain: plain, html: html)
            let blocks = try DocumentTransfer.markdown(markdown, title: "", consumeLeadingTitle: false).pages[0].blocks
            XCTAssertEqual(blocks.map(\.kind), [.heading3, .paragraph, .heading3], markdown)
            guard blocks.count == 3 else { continue }
            XCTAssertTrue(blocks[1].text.contains("难度 ★★★★☆"))
            XCTAssertTrue(blocks[1].text.contains("重要程度：★★★★★"))
            XCTAssertFalse(blocks[1].text.contains("\n"))
            XCTAssertTrue(blocks[1].formatting.contains { $0.style.code })
            XCTAssertTrue(blocks[1].formatting.contains { $0.style.bold == true })
            XCTAssertTrue(RichInlineContent.html(blocks[1].text, runs: blocks[1].formatting).contains("<code>"))
        }
    }

    func testClipboardLayoutDoesNotMergeIndependentParagraphsOrQuotesAndKeepsCodeIndent() async throws {
        let html = "<p><code>难度 ★★★★☆</code></p><blockquote><strong>重要程度：★★★★★</strong></blockquote><pre><code>if ok:\n    call()\n\n    done()</code></pre>"
        let markdown = try await ClipboardDocument.markdown(plain: "难度 ★★★★☆\n重要程度：★★★★★", html: html)
        let blocks = try DocumentTransfer.markdown(markdown, title: "", consumeLeadingTitle: false).pages[0].blocks
        XCTAssertEqual(blocks.map(\.kind), [.paragraph, .quote, .code])
        XCTAssertEqual(blocks.last?.text, "if ok:\n    call()\n\n    done()")
        let column = "<div style='display:flex;flex-direction:column'><p>A</p><p>B</p></div>"
        let columnMarkdown = try await ClipboardDocument.markdown(plain: nil, html: column)
        let columnBlocks = try DocumentTransfer.markdown(columnMarkdown, title: "", consumeLeadingTitle: false).pages[0].blocks
        XCTAssertEqual(columnBlocks.map(\.text), ["A", "B"])
    }

    func testInlineCodeHasNeutralBackgroundAndRoundTripsWithoutInventedHighlight() {
        let parsed = RichInlineContent.parseMarkdown("`难度 ★★★★☆` **重要程度：★★★★★**")
        let base = NSFont.systemFont(ofSize: 17)
        let rendered = RichTextFormatting.attributed(parsed.text, runs: parsed.runs, base: base)
        let attributes = rendered.attributes(at: 0, effectiveRange: nil)
        XCTAssertNotNil(attributes[.backgroundColor])
        XCTAssertTrue(RichTextFormatting.hasDefaultCodeBackground(attributes))
        let roundTrip = RichTextFormatting.runs(rendered, base: base)
        XCTAssertTrue(roundTrip.contains { $0.style.code && $0.style.highlight == nil && $0.style.fontFamily == parsed.runs.first?.style.fontFamily })
        var defaultStyle = InlineTextStyle(); defaultStyle.code = true
        let defaultCode = RichTextFormatting.attributed("x", runs: [TextStyleRun(location: 0, length: 1, style: defaultStyle)], base: base)
        XCTAssertNil(RichTextFormatting.runs(defaultCode, base: base).first?.style.fontFamily)
        var explicit = InlineTextStyle(); explicit.code = true; explicit.highlight = "FFFF00"
        let highlighted = RichTextFormatting.attributed("x", runs: [TextStyleRun(location: 0, length: 1, style: explicit)], base: base)
        XCTAssertEqual(RichTextFormatting.runs(highlighted, base: base).first?.style.highlight, "FFFF00")
    }

    private func mediaSaveDirectory() throws -> URL {
        let directory = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent(".agents/test/MediaSave-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    func testEmbeddedMediaSavesExactOriginalBytesAndCleansTemporaryData() async throws {
        let directory = try mediaSaveDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let original = Data([0, 1, 2, 3, 250, 255])
        for (kind, mime, ext) in [(BlockKind.image, "image/png", "png"), (.pdfDocument, "application/pdf", "pdf"), (.audio, "audio/mpeg", "mp3")] {
            let source = "data:" + mime + ";base64," + original.base64EncodedString()
            let resource = try await MediaResourceExporter.prepare(source: source, kind: kind, temporaryDirectory: directory)
            XCTAssertEqual((resource.filename as NSString).pathExtension, ext)
            let output = directory.appendingPathComponent(resource.filename)
            try await resource.write(to: output)
            XCTAssertEqual(try Data(contentsOf: output), original, "Saving must not export a resized display thumbnail")
            let preparedURL = resource.fileURL
            resource.discard()
            XCTAssertFalse(FileManager.default.fileExists(atPath: preparedURL.path))
            XCTAssertTrue(FileManager.default.fileExists(atPath: output.path))
        }
        do { _ = try await MediaResourceExporter.prepare(source: "data:image/png;base64,!bad!", kind: .image, temporaryDirectory: directory); XCTFail("Invalid data must fail") } catch { }
    }

    func testLocalMediaSaveCopiesBytesReplacesDestinationAndNeverDeletesSource() async throws {
        let directory = try mediaSaveDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = directory.appendingPathComponent("原视频.mp4")
        let original = Data("source video bytes".utf8)
        try original.write(to: source)
        let link = directory.appendingPathComponent("video-link.mp4")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: source)
        let resource = try await MediaResourceExporter.prepare(source: link.absoluteString, kind: .video, temporaryDirectory: directory)
        let output = directory.appendingPathComponent("copy.mp4")
        try Data("existing file".utf8).write(to: output)
        try await resource.write(to: output)
        XCTAssertEqual(try Data(contentsOf: output), original)
        XCTAssertFalse(try output.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink ?? true)
        try await resource.write(to: source) // choosing the original filename is a no-op
        resource.discard()
        XCTAssertEqual(try Data(contentsOf: source), original)
        do { _ = try await MediaResourceExporter.prepare(source: directory.path, kind: .file, temporaryDirectory: directory); XCTFail("Directories are not media files") } catch { }
        do { _ = try await MediaResourceExporter.prepare(source: directory.appendingPathComponent("missing.mp3").path, kind: .audio, temporaryDirectory: directory); XCTFail("Missing file must fail") } catch { }
        XCTAssertFalse(try FileManager.default.contentsOfDirectory(atPath: directory.path).contains { $0.hasPrefix(".velora-save-") })
    }

    func testRemoteMediaPreparationUsesResponseFilenameAndCleansDownloadOnFailure() async throws {
        let directory = try mediaSaveDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = try XCTUnwrap(URL(string: "https://example.test/download?token=private"))
        let downloaded = directory.appendingPathComponent("download.tmp")
        let original = Data("remote original bytes".utf8)
        try original.write(to: downloaded)
        let response = try XCTUnwrap(HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil,
            headerFields: ["Content-Type": "image/png", "Content-Disposition": "attachment; filename=\"diagram.png\""]))
        let resource = try await MediaResourceExporter.prepare(source: url.absoluteString, kind: .image, temporaryDirectory: directory,
            download: { _ in (downloaded, response) })
        XCTAssertEqual(resource.filename, "diagram.png")
        XCTAssertFalse(FileManager.default.fileExists(atPath: downloaded.path))
        let destination = directory.appendingPathComponent("saved.png")
        try await resource.write(to: destination)
        XCTAssertEqual(try Data(contentsOf: destination), original)
        resource.discard()
        try original.write(to: downloaded)
        let denied = try XCTUnwrap(HTTPURLResponse(url: url, statusCode: 403, httpVersion: nil, headerFields: [:]))
        do {
            _ = try await MediaResourceExporter.prepare(source: url.absoluteString, kind: .image, temporaryDirectory: directory,
                download: { _ in (downloaded, denied) })
            XCTFail("HTTP errors must not be saved as media")
        } catch { }
        XCTAssertFalse(FileManager.default.fileExists(atPath: downloaded.path))
        XCTAssertEqual(try Data(contentsOf: destination), original)
    }

    func testMediaSaveRejectsWebPagesAndPlaylistsAndHandlesCancellationAtomically() async throws {
        let directory = try mediaSaveDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = try XCTUnwrap(URL(string: "https://example.test/video"))
        for mime in ["text/html", "application/vnd.apple.mpegurl", "application/dash+xml"] {
            let response = try XCTUnwrap(HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: ["Content-Type": mime]))
            XCTAssertThrowsError(try MediaResourceExporter.validate(response, kind: .video))
        }
        let source = directory.appendingPathComponent("source.bin")
        let destination = directory.appendingPathComponent("saved.bin")
        try Data("new data".utf8).write(to: source)
        let original = Data("keep existing data".utf8)
        try original.write(to: destination)
        let resource = try await MediaResourceExporter.prepare(source: source.path, kind: .file, temporaryDirectory: directory)
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            try await resource.write(to: destination)
        }
        do { try await task.value; XCTFail("Cancelled write must fail") } catch is CancellationError { } catch { XCTFail("Unexpected error: \(error)") }
        XCTAssertEqual(try Data(contentsOf: destination), original)
        XCTAssertFalse(try FileManager.default.contentsOfDirectory(atPath: directory.path).contains { $0.hasPrefix(".velora-save-") })
        let safe = MediaResourceExporter.filename("../../图像", mime: "image/png", kind: .image)
        XCTAssertEqual(safe, "图像.png")
        XCTAssertEqual(MediaResourceExporter.filename("download.php", mime: "image/png", kind: .image), "download.png")
        XCTAssertEqual(MediaResourceExporter.filename("clip.mp4", mime: "application/octet-stream", kind: .video), "clip.mp4")
        XCTAssertFalse(MediaResourceExporter.supports(.bookmark))
    }

    func testPastedNumberedSectionsKeepStartsAcrossProseCodeAndBullets() async throws {
        let html = """
        <ol><li><strong>Token</strong></li></ol>
        <p>Token 是模型处理文本时的基本单位。</p><p>例如：</p>
        <pre><code>Java 是一种编程语言</code></pre>
        <p>Token 很重要：</p><ul><li>上下文长度</li><li>API 费用</li></ul>
        <ol start="2"><li><strong>Prompt</strong></li></ol>
        """
        let markdown = try await ClipboardDocument.markdown(plain: "1. Token\n2. Prompt", html: html)
        let document = try DocumentTransfer.markdown(markdown, title: "", consumeLeadingTitle: false)
        let page = try XCTUnwrap(document.pages.first)
        let numbered = zip(page.blocks, ListNumbering.numbers(page.blocks)).filter { $0.0.kind == .numbered }
        XCTAssertEqual(numbered.map { $0.0.text }, ["Token", "Prompt"])
        XCTAssertEqual(numbered.map { $0.1 }, [1, 2])
        XCTAssertTrue(numbered.allSatisfy { $0.0.formatting.contains { $0.style.bold == true } })
        let exported = try DocumentExporter.markdown(page, assetDirectory: nil)
        XCTAssertTrue(exported.contains("2. **Prompt**"))
        XCTAssertTrue(DocumentExporter.plain(page).contains("2. Prompt"))
        XCTAssertTrue(DocumentExporter.richText(document).string.contains("2. Prompt"))
        let package = try ZIPPackage.decode(DOCXTransfer.encode(document))
        let xml = try XCTUnwrap(package["word/document.xml"].flatMap { String(data: $0, encoding: .utf8) })
        XCTAssertTrue(xml.contains("2. Prompt"))
        let roundTrip = try await ClipboardDocument.markdown(plain: nil, html: HTMLTransfer.page(page))
        let roundBlocks = try DocumentTransfer.markdown(roundTrip, title: "", consumeLeadingTitle: false).pages[0].blocks
        XCTAssertEqual(zip(roundBlocks, ListNumbering.numbers(roundBlocks)).filter { $0.0.kind == .numbered }.map { $0.1 }, [1, 2])
        let values = try await ClipboardDocument.markdown(plain: nil, html: "<ol start='4'><li>A</li><li value='9'>B</li></ol>")
        let valueBlocks = try DocumentTransfer.markdown(values, title: "", consumeLeadingTitle: false).pages[0].blocks
        XCTAssertEqual(ListNumbering.numbers(valueBlocks), [4, 9])
    }

    func testMarkdownRepeatedOneMarkersContinueButSeparateStartsStayExplicit() throws {
        let blocks = try DocumentTransfer.markdown("1. A\n1. B\n1. C\n\n正文\n\n2. D\n3. E", title: "").pages[0].blocks
        XCTAssertEqual(zip(blocks, ListNumbering.numbers(blocks)).filter { $0.0.kind == .numbered }.map { $0.1 }, [1, 2, 3, 2, 3])
        XCTAssertNil(blocks[1].listStart)
        XCTAssertEqual(blocks[4].listStart, 2)
    }

    func testBrowserClipboardPrefersSemanticHTMLOverPartialMarkdownPlainText() async throws {
        let html = """
        <article><h2>核心结论</h2><blockquote><p>第一段 <strong>重点</strong></p><p>第二段引用</p></blockquote>
        <h3>具体步骤</h3><ol><li><p>检查输入</p></li><li><p>完成处理</p></li></ol><p>普通正文</p></article>
        """
        let plain = "核心结论\n第一段 **重点**\n第二段引用\n具体步骤\n1. 检查输入\n2. 完成处理\n普通正文"
        let markdown = try await ClipboardDocument.markdown(plain: plain, html: html)
        let blocks = try DocumentTransfer.markdown(markdown, title: "", consumeLeadingTitle: false).pages[0].blocks
        XCTAssertEqual(blocks.map(\.kind), [.heading2, .quote, .heading3, .numbered, .numbered, .paragraph])
        XCTAssertEqual(blocks[0].text, "核心结论")
        XCTAssertTrue(blocks[1].text.contains("第二段引用"))
        XCTAssertTrue(blocks[1].formatting.contains { $0.style.bold == true })
        XCTAssertEqual(blocks.last?.text, "普通正文")
    }

    func testMarkdownTableInlineCodeHasNoVisibleDelimiterCharacters() throws {
        let source = #"""
        | 方法 | 作用 |
        | --- | --- |
        | ` add() ` | **添加消息** |
        | ` messages() ` | 获取当前消息 |
        | ` clear() ` | 清空 |
        | ` id() ` | 返回会话 |
        | `a\|b` | 管道字符 |
        | ``value `quoted` `` | 内容中的反引号 |
        """#
        let table = try XCTUnwrap(DocumentTransfer.markdown(source, title: "Fixture", consumeLeadingTitle: false).pages[0].blocks.first)
        let rows = try JSONDecoder().decode([[String]].self, from: Data(table.text.utf8))
        XCTAssertEqual(table.kind, .table)
        XCTAssertTrue(table.tableLayout.cellsArePlain)
        XCTAssertEqual(rows.map { $0[0] }, ["方法", "add()", "messages()", "clear()", "id()", "a|b", "value `quoted` "])
        XCTAssertEqual(rows[1][1], "添加消息")
        XCTAssertEqual(TableCellContent.visible("` add() `", layout: TableLayout()), "add()")
        XCTAssertEqual(TableCellContent.visible("`literal`", layout: TableLayout(cellsArePlain: true)), "`literal`")
        XCTAssertEqual(TableCellContent.visible("a ` b", layout: TableLayout()), "a ` b")
    }

    func testExternalWordTablePreservesActualBackticks() throws {
        let rows = [["内容"], ["`literal`"]]
        let block = TransferBlock(.table, String(decoding: try JSONEncoder().encode(rows), as: UTF8.self), tableLayout: TableLayout(cellsArePlain: true))
        let document = TransferDocument(name: "table", pages: [TransferPage(title: "", blocks: [block])])
        var package = try ZIPPackage.decode(DOCXTransfer.encode(document))
        package["customXml/velora.xml"] = nil
        let external = try ZIPPackage.encode(package.map { ($0.key, $0.value) })
        let table = try XCTUnwrap(DOCXTransfer.decode(external, title: "external").pages[0].blocks.first { $0.kind == .table })
        let result = try JSONDecoder().decode([[String]].self, from: Data(table.text.utf8))
        XCTAssertEqual(result, rows)
        XCTAssertTrue(table.tableLayout.cellsArePlain)
        XCTAssertEqual(TableCellContent.visible(result[1][0], layout: table.tableLayout), "`literal`")
    }

    func testPlainTableMarkdownRoundTripPreservesLiteralSyntax() throws {
        let rows = [["方法", "内容"], ["`literal`", "*stars* &lt; <tag> [link]"], ["a|b", #"C:\Temp"#]]
        let table = TransferBlock(.table, String(decoding: try JSONEncoder().encode(rows), as: UTF8.self), tableLayout: TableLayout(cellsArePlain: true))
        let markdown = try DocumentExporter.markdown(TransferPage(title: "", blocks: [table]), assetDirectory: nil)
        let restored = try DocumentTransfer.markdown(markdown, title: "", consumeLeadingTitle: false)
        let result = try XCTUnwrap(restored.pages[0].blocks.first { $0.kind == .table })
        XCTAssertEqual(try JSONDecoder().decode([[String]].self, from: Data(result.text.utf8)), rows)
        let html = HTMLTransfer.page(TransferPage(title: "", blocks: [table]))
        XCTAssertTrue(html.contains("`literal`"))
        XCTAssertTrue(html.contains("&amp;lt;"))
    }

    func testHTMLClipboardTableCodeConvertsToPlainNativeCells() async throws {
        let html = "<table><tr><th>方法</th><th>作用</th></tr><tr><td><code>messages()</code></td><td>获取消息</td></tr></table>"
        let markdown = try await ClipboardDocument.markdown(plain: "方法\t作用\nmessages()\t获取消息", html: html)
        let table = try XCTUnwrap(DocumentTransfer.markdown(markdown, title: "", consumeLeadingTitle: false).pages[0].blocks.first { $0.kind == .table })
        let rows = try JSONDecoder().decode([[String]].self, from: Data(table.text.utf8))
        XCTAssertEqual(rows[1], ["messages()", "获取消息"])
        XCTAssertTrue(table.tableLayout.cellsArePlain)
    }

    private var root: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent(".agents/test/transfer", isDirectory: true)
    }
    private func directory() throws -> URL {
        let url = root.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true); return url
    }
    private func png() throws -> Data {
        let image = try XCTUnwrap(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 240, pixelsHigh: 120,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        let bytes = try XCTUnwrap(image.bitmapData)
        for y in 0..<120 { for x in 0..<240 {
            let p = y * image.bytesPerRow + x * 4
            bytes[p] = 48; bytes[p + 1] = 110; bytes[p + 2] = 220; bytes[p + 3] = 255
        } }
        return try XCTUnwrap(image.representation(using: .png, properties: [:]))
    }
    private func fixture() throws -> TransferDocument {
        let image = try ImageSource.embedded(png())
        let rows = String(decoding: try JSONEncoder().encode([["字段", "说明"], ["版本", "导入导出验证"]]), as: UTF8.self)
        let page = TransferPage(title: "导入导出验证", blocks: [
            TransferBlock(.heading, "功能概览"), TransferBlock(.paragraph, "中文内容与 English。导出后应保留标题、列表、代码、表格和本地图片。"),
            TransferBlock(.bullet, "支持常用格式"), TransferBlock(.todo, "图片与备份验证", checked: true),
            TransferBlock(.code, "let message = \"你好\"\nprint(message)\n// ``` inside code", language: "Swift"),
            TransferBlock(.table, rows), TransferBlock(.image, image),
            TransferBlock(.quote, "保留内容，便于迁移。"), TransferBlock(.toggle, "折叠内容", collapsed: true)
        ])
        let child = TransferPage(parentID: page.id, title: "子页面", blocks: [TransferBlock(.paragraph, "Child page content")])
        return TransferDocument(name: "格式验证", pages: [page, child])
    }

    func testPartialStyleAndLinkSurviveMarkdownAndNativeAttributes() throws {
        let style = try JSONDecoder().decode(InlineTextStyle.self, from: Data(#"{"bold":true,"link":"https://example.com/test"}"#.utf8))
        XCTAssertTrue(style.bold == true); XCTAssertFalse(style.underline)
        let runs = [TextStyleRun(location: 0, length: 2, style: style)]
        let markdown = RichInlineContent.markdown("链接", runs: runs)
        let parsed = RichInlineContent.parseMarkdown(markdown)
        XCTAssertEqual(parsed.text, "链接")
        XCTAssertEqual(parsed.runs.first?.style.link, style.link)
        let attributed = RichTextFormatting.attributed("链接", runs: runs, base: .systemFont(ofSize: 17))
        XCTAssertEqual(RichTextFormatting.runs(attributed, base: .systemFont(ofSize: 17)).first?.style.link, style.link)
    }

    func testChatGPTClipboardAndVisualExportsKeepStructureAndMath() async throws {
        let markdown = #"""
        ## MIXED_HEADING

        **重要结论**：行内公式 \(x_i^2 + \frac{a}{b}\)，以及 [参考链接](https://example.com/reference)。

        3. 第三项
           - 嵌套条目
           - **嵌套粗体**
        4. 第四项

        | 参数 | 结果 |
        | --- | --- |
        | A | $\frac{1}{2}$ |

        ```python
        print("literal $x$ and <script>")
        ```

        $$
        \begin{pmatrix}a&b\\c&d\end{pmatrix}
        $$

        MARKER_AFTER_EQUATION
        """#
        let document = TransferDocument(name: "复制与导出一致性", pages: [TransferPage(title: "复制与导出一致性", blocks: [TransferBlock(.markdown, markdown)])])
        let session = DocumentRenderSession(); defer { session.close() }
        try await session.render(document)
        let fontState = try await session.run("return Array.from(document.fonts).some(f=>f.family==='KaTeX_Size3'&&f.status==='loaded')")
        XCTAssertEqual(fontState as? Bool, true)
        let renderedHTML = try await session.run("return document.querySelector('#content').innerHTML")
        let html = try XCTUnwrap(renderedHTML as? String)
        let converted = try await ClipboardDocument.markdown(plain: "网页格式的粘贴", html: html)
        XCTAssertTrue(converted.contains(#"\frac{a}{b}"#))
        XCTAssertTrue(converted.contains("x_i"))
        XCTAssertTrue(converted.contains("  - **嵌套粗体**"))
        XCTAssertTrue(converted.contains("3. "))
        XCTAssertTrue(converted.contains("```python"))
        XCTAssertTrue(converted.contains("https://example.com/reference"))
        XCTAssertFalse(converted.contains("复制代码"))
        let corruptedPlain = "## 方差\n\n$\\operatorname{Var}(X)=\\sigma^2 \\\u{0332}$"
        let recovered = try await ClipboardDocument.markdown(plain: corruptedPlain, html: html)
        XCTAssertTrue(recovered.contains(#"\frac{a}{b}"#))
        XCTAssertFalse(recovered.contains("\u{0332}"))
        let annotationHTML = #"<span class="katex"><span class="katex-mathml"><math><semantics><annotation encoding="application/x-tex">\operatorname{Var}(X)=\sigma^2</annotation></semantics></math></span></span>"#
        let corruptedEquation = #"\operatorname{Var}(X)=\sigma^2 \"# + "\u{0332}"
        XCTAssertEqual(ClipboardDocument.equationPaste(plain: corruptedEquation, html: annotationHTML), #"\operatorname{Var}(X)=\sigma^2"#)
        XCTAssertEqual(ClipboardDocument.equationPaste(plain: #"\begin{aligned}a&=b\\c&=d\end{aligned}"#, html: nil), #"\begin{aligned}a&=b\\c&=d\end{aligned}"#)
        XCTAssertTrue(ClipboardDocument.isStructured(markdown, html: nil))
        XCTAssertFalse(ClipboardDocument.isStructured("普通文本", html: nil))
        let combined = ClipboardDocument.replacing("前😀选中后", formatting: [], selection: NSRange(location: 3, length: 2), with: converted)
        XCTAssertTrue(combined.hasPrefix("前😀\n\n")); XCTAssertTrue(combined.hasSuffix("\n\n后"))
        let folder = root.appendingPathComponent("Fidelity-QA")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        for format in [TransferFormat.html, .pdf, .word, .markdown] {
            let file = folder.appendingPathComponent("mixed." + format.ext)
            try await DocumentExporter.write(document, format: format, to: file)
        }
        try assertFidelityFiles(document, in: folder)
    }

    func testChatGPTMermaidPasteRenderAndVisualExports() async throws {
        let flow = "flowchart LR\n    A[\"数据输入\"] --> B{\"质量检查\"}\n    B -->|通过| C[\"模型训练\"]\n    B -->|失败| D[\"修正数据\"]"
        XCTAssertTrue(ClipboardDocument.isStructured(flow, html: nil))
        let wrapped = try await ClipboardDocument.markdown(plain: flow, html: nil)
        XCTAssertTrue(wrapped.hasPrefix("```mermaid\n"))
        XCTAssertTrue(wrapped.contains(flow))
        let clipboard = "<h2>图表</h2><pre data-language=\"mermaid\"><code>" + HTMLTransfer.escape(flow).replacingOccurrences(of: "\n", with: "<br>") + "</code></pre>"
        let fromHTML = try await ClipboardDocument.markdown(plain: "## 图表\n数据输入 → 质量检查", html: clipboard)
        XCTAssertTrue(fromHTML.contains("```mermaid\n"))
        XCTAssertTrue(fromHTML.contains(flow))
        let sequence = "sequenceDiagram\n    participant U as 用户\n    participant S as 服务\n    U->>S: 提交请求\n    S-->>U: 返回结果"
        let mindmap = "mindmap\n  root((学习计划))\n    数学\n      线性代数\n    编程"
        let source = "## 图表测试\n\n" + wrapped + "\n\n" + ClipboardDocument.fencedMermaid(sequence) + "\n\n" + ClipboardDocument.fencedMermaid(mindmap)
        let session = DocumentRenderSession(); defer { session.close() }
        _ = try await session.run("return await renderContent(source,false,false,17,'zh-Hans')", arguments: ["source": source])
        let values = try await session.run("return {diagrams:root.querySelectorAll('.mermaid-canvas svg').length,errors:root.querySelectorAll('.mermaid-error').length,nodes:root.querySelectorAll('.node').length,foreign:root.querySelectorAll('foreignObject,script').length,wide:[...root.querySelectorAll('.mermaid-canvas svg')].every(n=>n.viewBox.baseVal.width>0&&n.viewBox.baseVal.height>0),texts:root.textContent}")
        let result = try XCTUnwrap(values as? [String: Any])
        XCTAssertEqual(result["diagrams"] as? Int, 3, result["texts"] as? String ?? "")
        XCTAssertEqual(result["errors"] as? Int, 0)
        XCTAssertEqual(result["foreign"] as? Int, 0)
        XCTAssertEqual(result["wide"] as? Bool, true)
        let rendered = try await session.run("return root.innerHTML") as? String ?? ""
        let roundtrip = try await ClipboardDocument.markdown(plain: "图表", html: rendered)
        XCTAssertTrue(roundtrip.contains(flow)); XCTAssertTrue(roundtrip.contains(sequence)); XCTAssertTrue(roundtrip.contains(mindmap))
        _ = try await session.run("return await renderContent(source,false,true,17,'en')", arguments: ["source": wrapped])
        let dark = try await session.run("return document.documentElement.classList.contains('dark')&&root.querySelectorAll('.mermaid-canvas svg').length===1")
        XCTAssertEqual(dark as? Bool, true)
        _ = try await session.run("return await renderContent(source,false,false,17,'en')", arguments: ["source": ClipboardDocument.fencedMermaid("flowchart TD\n A --> [broken")])
        let failed = try await session.run("return root.querySelector('.mermaid-error')!==null&&root.querySelector('details').open&&root.textContent.includes('[broken')")
        XCTAssertEqual(failed as? Bool, true)
        let document = TransferDocument(name: "Mermaid QA", pages: [TransferPage(title: "Mermaid 图表", blocks: [TransferBlock(.markdown, source)])])
        let folder = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent(".agents/test/mermaid-QA")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        for format in [TransferFormat.html, .pdf, .word, .markdown] {
            try await DocumentExporter.write(document, format: format, to: folder.appendingPathComponent("diagrams." + format.ext))
        }
        let html = try String(contentsOf: folder.appendingPathComponent("diagrams.html"), encoding: .utf8)
        XCTAssertTrue(html.contains("<svg")); XCTAssertFalse(html.contains("<script src="))
        let word = try ZIPPackage.decode(Data(contentsOf: folder.appendingPathComponent("diagrams.docx")))
        XCTAssertEqual(word.keys.filter { $0.hasPrefix("word/media/") }.count, 3)
        let restored = try await DocumentTransfer.load(folder.appendingPathComponent("diagrams.docx"))
        XCTAssertEqual(restored.pages.first?.blocks.first?.text, source)
    }

    private func assertFidelityFiles(_ document: TransferDocument, in folder: URL) throws {
        let exportedHTML = try String(contentsOf: folder.appendingPathComponent("mixed.html"), encoding: .utf8)
        XCTAssertTrue(exportedHTML.contains("katex-mathml"))
        XCTAssertTrue(exportedHTML.contains("data:font/woff2;base64,"))
        XCTAssertFalse(exportedHTML.contains("<script src="))
        XCTAssertEqual(HTMLTransfer.embeddedDocument(exportedHTML)?.pages.first?.blocks, document.pages[0].blocks)
        let pdf = try XCTUnwrap(PDFDocument(url: folder.appendingPathComponent("mixed.pdf")))
        for word in ["MARKER", "AFTER", "EQUATION"] { XCTAssertTrue(pdf.string?.contains(word) == true) }
        XCTAssertFalse(pdf.string?.contains(#"\begin{pmatrix}"#) == true)
        let word = try Data(contentsOf: folder.appendingPathComponent("mixed.docx"))
        var package = try ZIPPackage.decode(word)
        let xml = try XCTUnwrap(package["word/document.xml"].flatMap { String(data: $0, encoding: .utf8) })
        XCTAssertTrue(xml.contains("<m:f>")); XCTAssertTrue(xml.contains("<m:m>"))
        XCTAssertTrue(xml.contains("<w:tbl>")); XCTAssertTrue(xml.contains("<w:hyperlink"))
        XCTAssertFalse(xml.contains("VELORAMATH"))
        XCTAssertEqual(try DOCXTransfer.decode(word, title: "fallback").pages[0].blocks, document.pages[0].blocks)
        // An external edit must invalidate source metadata rather than silently restoring old text.
        package["word/document.xml"] = Data(xml.replacingOccurrences(of: "MARKER_AFTER_EQUATION", with: "EDITED_IN_WORD").utf8)
        let changed = try ZIPPackage.encode(package.map { ($0.key, $0.value) })
        let restored = try DOCXTransfer.decode(changed, title: "Edited")
        XCTAssertTrue(restored.pages[0].blocks.contains { $0.text.contains("EDITED_IN_WORD") })
        XCTAssertTrue(restored.pages[0].blocks.contains { $0.kind == .markdown && $0.text.contains(#"\frac{"#) })
    }

    func testMarkdownBlocksAndLocalAssetsRoundTrip() async throws {
        let folder = try directory(); let document = try fixture()
        let exported = try await DocumentExporter.markdownFolder(document, in: folder)
        let restored = try await DocumentImporter.directory(exported)
        let page = try XCTUnwrap(restored.pages.first { $0.title == "导入导出验证" })
        XCTAssertGreaterThan(page.blocks.count, 5)
        XCTAssertTrue(page.blocks.contains { $0.kind == .todo && $0.checked })
        XCTAssertTrue(page.blocks.contains { $0.kind == .code && $0.text.contains("``` inside code") })
        XCTAssertTrue(page.blocks.contains { $0.kind == .table && $0.text.contains("字段") })
        XCTAssertTrue(page.blocks.contains { $0.kind == .image && $0.text.hasPrefix("data:image/") })
        let child = try XCTUnwrap(restored.pages.first { $0.title == "子页面" })
        XCTAssertEqual(child.parentID, page.id)
        let files = FileManager.default.enumerator(at: exported, includingPropertiesForKeys: nil)!.allObjects.compactMap { $0 as? URL }
        XCTAssertTrue(files.contains { $0.pathExtension == "png" })
        let single = folder.appendingPathComponent("one.md")
        try await DocumentExporter.write(TransferDocument(name: page.title, pages: [TransferPage(title: page.title, blocks: page.blocks)]), format: .markdown, to: single)
        let importedSingle = try await DocumentTransfer.load(single)
        XCTAssertEqual(importedSingle.pages.first?.title, page.title)
    }

    func testJSONPreservesStructureAndImportRemapsIDs() async throws {
        let folder = try directory(); let document = try fixture(); let file = folder.appendingPathComponent("export.json")
        try await DocumentExporter.write(document, format: .json, to: file)
        let decoded = try await DocumentTransfer.load(file)
        XCTAssertEqual(decoded.pages[0].blocks, document.pages[0].blocks)
        XCTAssertEqual(decoded.pages[1].parentID, document.pages[0].id)
        let store = try SQLiteStore(databaseURL: folder.appendingPathComponent("store.sqlite"))
        let original = try await store.createPage()
        _ = try await store.importTransfer(decoded); _ = try await store.importTransfer(decoded)
        let pages = try await store.pages()
        XCTAssertEqual(pages.count, 5)
        XCTAssertTrue(pages.contains { $0.id == original.id })
        XCTAssertEqual(Set(pages.map(\.id)).count, 5)
        for child in pages where child.title == "子页面" { XCTAssertEqual(pages.first { $0.id == child.parentID }?.title, "导入导出验证") }
    }

    func testInvalidImportAndMidTransactionFailureLeaveExistingPagesIntact() async throws {
        let folder = try directory(); let database = folder.appendingPathComponent("store.sqlite")
        let store = try SQLiteStore(databaseURL: database); let original = try await store.createPage()
        var invalid = try fixture(); invalid.pages[0].parentID = invalid.pages[1].id
        do { _ = try await store.importTransfer(invalid); XCTFail("Cycle should be rejected") } catch { }
        var raw: OpaquePointer?; XCTAssertEqual(sqlite3_open(database.path, &raw), SQLITE_OK)
        defer { sqlite3_close(raw) }
        XCTAssertEqual(sqlite3_exec(raw, "CREATE TRIGGER reject_test BEFORE INSERT ON pages WHEN NEW.title='拒绝导入' BEGIN SELECT RAISE(ABORT,'test failure'); END;", nil, nil, nil), SQLITE_OK)
        let document = TransferDocument(name: "事务", pages: [TransferPage(title: "先写入", blocks: []), TransferPage(title: "拒绝导入", blocks: [])])
        do { _ = try await store.importTransfer(document); XCTFail("Trigger should abort entire import") } catch { }
        let pages = try await store.pages(); XCTAssertEqual(pages.map(\.id), [original.id])
    }

    func testHTMLRoundTripAndInactiveContentRemoval() async throws {
        let folder = try directory(); let fixture = try fixture(); let file = folder.appendingPathComponent("export.html")
        let document = TransferDocument(name: fixture.name, pages: [fixture.pages[0]])
        try await DocumentExporter.write(document, format: .html, to: file)
        let imported = try await DocumentTransfer.load(file)
        let blocks = try XCTUnwrap(imported.pages.first?.blocks)
        XCTAssertTrue(blocks.contains { $0.kind == .table })
        XCTAssertTrue(blocks.contains { $0.kind == .image })
        XCTAssertTrue(blocks.contains { $0.kind == .code && $0.text.contains("let message") })
        let unsafe = "<html><head><title>HTML 测试</title><link href='https://example.com/external.css'/></head><body><script>alert('do-not-import')</script><p>visible text</p><iframe src='https://example.com'></iframe></body></html>"
        let safe = try HTMLTransfer.importDocument(unsafe, title: "test")
        let text = safe.pages.flatMap(\.blocks).map(\.text).joined()
        XCTAssertTrue(text.contains("visible text")); XCTAssertFalse(text.contains("do-not-import")); XCTAssertFalse(text.contains("external.css"))
    }

    func testRelativeImagesCannotEscapeDocumentFolder() throws {
        let folder = try directory(); let inside = folder.appendingPathComponent("docs")
        try FileManager.default.createDirectory(at: inside, withIntermediateDirectories: true)
        try png().write(to: folder.appendingPathComponent("outside.png"))
        XCTAssertThrowsError(try DocumentTransfer.markdown("![图片](../outside.png)", title: "test", directory: inside))
        XCTAssertThrowsError(try DocumentTransfer.markdown("![图片](file:///etc/passwd)", title: "test", directory: inside))
        XCTAssertThrowsError(try DocumentTransfer.decodeText(Data([0xFF, 0x00, 0xFF])))
    }

    func testSnapshotSelectionIncludesChildrenAndOptionalTrash() async throws {
        let folder = try directory(); let store = try SQLiteStore(databaseURL: folder.appendingPathComponent("store.sqlite"))
        let root = try await store.createPage(); let child = try await store.createPage(parentID: root.id)
        let other = try await store.createPage(); try await store.archivePage(other.id, archived: true)
        let one = try await store.transferSnapshot(name: "page", pageID: child.id, includeChildren: false)
        XCTAssertEqual(one.pages.count, 1); XCTAssertNil(one.pages[0].parentID)
        let tree = try await store.transferSnapshot(name: "tree", pageID: root.id)
        XCTAssertEqual(tree.pages.count, 2)
        let withoutTrash = try await store.transferSnapshot(name: "workspace")
        let withTrash = try await store.transferSnapshot(name: "workspace", includeArchived: true)
        XCTAssertEqual(withoutTrash.pages.count, 2); XCTAssertEqual(withTrash.pages.count, 3)
    }

    func testPDFRecognizesCodeRestoresGeometricIndentAndGroupsQuotes() async throws {
        let folder = try directory()
        let file = folder.appendingPathComponent("code-and-quote.pdf")
        let consumer = try XCTUnwrap(CGDataConsumer(url: file as CFURL))
        var box = CGRect(x: 0, y: 0, width: 600, height: 800)
        let context = try XCTUnwrap(CGContext(consumer: consumer, mediaBox: &box, nil))
        context.beginPDFPage(nil)
        func draw(_ text: String, font: NSFont, x: CGFloat, y: CGFloat) {
            context.textPosition = CGPoint(x: x, y: y)
            let line = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: [.font: font]))
            CTLineDraw(line, context)
        }
        let body = NSFont.systemFont(ofSize: 12)
        let code = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
        let space = (" " as NSString).size(withAttributes: [.font: code]).width
        draw("Ordinary body text; a paragraph before the code sample.", font: body, x: 50, y: 750)
        draw("if ready:", font: code, x: 50, y: 700)
        draw("print(value)", font: code, x: 50 + space * 4, y: 682)
        draw("return value", font: code, x: 50 + space * 8, y: 664)
        draw("# keep *literal* and 1. items", font: code, x: 50, y: 628)
        draw("Quoted first line", font: body, x: 80, y: 570)
        draw("Quoted second line", font: body, x: 80, y: 552)
        draw("Ordinary body text after the quote; keep it as prose.", font: body, x: 50, y: 500)
        context.endPDFPage(); context.closePDF()
        let imported = try await DocumentTransfer.load(file)
        let blocks = imported.pages[0].blocks
        let source = try XCTUnwrap(blocks.first { $0.kind == .code })
        XCTAssertEqual(source.text, "if ready:\n    print(value)\n        return value\n\n# keep *literal* and 1. items")
        let quote = try XCTUnwrap(blocks.first { $0.kind == .quote })
        XCTAssertEqual(quote.text, "Quoted first line\nQuoted second line")
        XCTAssertTrue(blocks.contains { $0.kind == .paragraph && $0.text.contains("after the quote") })
    }

    func testMarkdownPreservesIndentedCodeAndQuoteSubtrees() throws {
        let input = "Before\n\n    if ready:\n        print(value)\n\n        return value\n\n> First quote line\n> Second quote line\n\n> ```python\n> if ready:\n>     print(value)\n> ```\n\n- parent\n    - child\n\nAfter"
        let blocks = try DocumentTransfer.markdownDocument(input, title: "structure").pages[0].blocks
        XCTAssertEqual(blocks.map(\.kind), [.paragraph, .code, .quote, .markdown, .markdown, .paragraph])
        XCTAssertEqual(blocks[1].text, "if ready:\n    print(value)\n\n    return value")
        XCTAssertEqual(blocks[2].text, "First quote line\nSecond quote line")
        XCTAssertTrue(blocks[3].text.contains(">     print(value)"))
        XCTAssertTrue(blocks[4].text.contains("    - child"))
    }

    func testHTMLCodeRetainsIndentationAndMultipleBlankLines() async throws {
        let source = "if ready:\n    print(value)\n\n\n    return value"
        let html = "<p>Before</p><pre><code class=\"language-python\">" + HTMLTransfer.escape(source) + "</code></pre><blockquote><p>First quote</p><p>Second quote</p></blockquote>"
        let markdown = try await DocumentRenderSession.markdown(fromHTML: html)
        let blocks = try DocumentTransfer.markdownDocument(markdown, title: "html").pages[0].blocks
        let code = try XCTUnwrap(blocks.first { $0.kind == .code })
        XCTAssertEqual(code.text, source)
        XCTAssertEqual(code.language, "python")
        let quote = try XCTUnwrap(blocks.first { $0.kind == .quote })
        XCTAssertTrue(quote.text.contains("First quote\n\nSecond quote"))
    }

    func testRTFCodeRetainsWhitespaceAndQuotationIndent() async throws {
        let folder = try directory()
        let source = "if ready:\n    print(value)\n\n    return value"
        let text = NSMutableAttributedString(string: source + "\n", attributes: [.font: NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)])
        let quote = NSMutableParagraphStyle(); quote.headIndent = 24; quote.firstLineHeadIndent = 24
        text.append(NSAttributedString(string: "Quoted text", attributes: [.font: NSFont.systemFont(ofSize: 12), .paragraphStyle: quote]))
        let data = try text.data(from: NSRange(location: 0, length: text.length), documentAttributes: [.documentType: NSAttributedString.DocumentType.rtf])
        let file = folder.appendingPathComponent("code.rtf"); try data.write(to: file)
        let blocks = try await DocumentTransfer.load(file).pages[0].blocks
        XCTAssertEqual(blocks.first { $0.kind == .code }?.text, source)
        XCTAssertEqual(blocks.first { $0.kind == .quote }?.text, "Quoted text")
    }

    func testExternalWordCodePreservesIndentTabsAndEmptyLines() throws {
        let source = "    if ready:\n\tprint(value)\n\n\n    return value"
        let document = TransferDocument(name: "code", pages: [TransferPage(title: "code", blocks: [TransferBlock(.code, source), TransferBlock(.quote, "Quoted content")])])
        var package = try ZIPPackage.decode(DOCXTransfer.encode(document))
        package["customXml/velora.xml"] = nil
        let data = try ZIPPackage.encode(package.map { ($0.key, $0.value) })
        let blocks = try DOCXTransfer.decode(data, title: "external").pages[0].blocks
        XCTAssertEqual(blocks.first { $0.kind == .code }?.text, source)
        XCTAssertEqual(blocks.first { $0.kind == .quote }?.text, "Quoted content")
    }

    func testScannedPDFImportsPageImagesInsteadOfFileAttachment() async throws {
        let folder = try directory()
        let pdf = PDFDocument()
        let image = try XCTUnwrap(NSImage(data: png()))
        for index in 0..<2 { pdf.insert(try XCTUnwrap(PDFPage(image: image)), at: index) }
        let file = folder.appendingPathComponent("scanned.pdf")
        try XCTUnwrap(pdf.dataRepresentation()).write(to: file)
        let imported = try await DocumentTransfer.load(file)
        XCTAssertEqual(imported.pages[0].blocks.filter { $0.kind == .image }.count, 2)
        XCTAssertFalse(imported.pages[0].blocks.contains { $0.kind == .pdfDocument })
        XCTAssertThrowsError(try DocumentTransfer.parsedPDF(Data("invalid".utf8), title: "bad"))
    }

    func testScannedPDFRecognizesEditableText() async throws {
        let folder = try directory()
        let image = NSImage(size: NSSize(width: 900, height: 400))
        image.lockFocus()
        NSColor.white.setFill(); NSRect(x: 0, y: 0, width: 900, height: 400).fill()
        let attributes: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 48), .foregroundColor: NSColor.black]
        ("SCANNED DOCUMENT" as NSString).draw(at: NSPoint(x: 40, y: 260), withAttributes: attributes)
        ("Editable text from a PDF scan" as NSString).draw(at: NSPoint(x: 40, y: 140), withAttributes: attributes)
        image.unlockFocus()
        let pdf = PDFDocument(); pdf.insert(try XCTUnwrap(PDFPage(image: image)), at: 0)
        let file = folder.appendingPathComponent("ocr.pdf")
        try XCTUnwrap(pdf.dataRepresentation()).write(to: file)
        let imported = try await DocumentTransfer.load(file)
        let blocks = imported.pages[0].blocks
        XCTAssertTrue(blocks.contains { $0.kind == .image })
        XCTAssertTrue(blocks.contains { $0.kind == .paragraph && $0.text.contains("SCANNED DOCUMENT") })
        XCTAssertTrue(blocks.contains { $0.kind == .paragraph && $0.text.contains("Editable text") })
    }

    func testMarkdownImportSplitsContentIntoNativeBlocks() async throws {
        let folder = try directory()
        let file = folder.appendingPathComponent("blocks.md")
        let source = "# Title\n\n## Section\n\nA **bold** paragraph.\n\n- item\n- [x] done\n\n```swift\nlet x = 1\n```\n\n$$x^2$$\n"
        try source.write(to: file, atomically: true, encoding: .utf8)
        let imported = try await DocumentTransfer.load(file)
        XCTAssertEqual(imported.pages[0].title, "Title")
        XCTAssertEqual(imported.pages[0].blocks.map(\.kind), [.heading2, .paragraph, .bullet, .todo, .code, .equation])
        XCTAssertFalse(imported.pages[0].blocks[1].formatting.isEmpty)
        let plain = DocumentTransfer.plainText("First\r\nSecond\r\n\r\nThird", title: "plain")
        XCTAssertEqual(plain.pages[0].blocks.map(\.text), ["First", "Second", "Third"])
    }

    func testNativePDFAndWordExportsCanBeImportedAndPaginate() async throws {
        let folder = root.appendingPathComponent("QA", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        var document = try fixture()
        for index in 1...42 { document.pages[1].blocks.append(TransferBlock(.paragraph, "\(index). 分页测试内容，保留中文与 English。文本需要自然换行，页面边界不应截断段落。")) }
        let pdf = folder.appendingPathComponent("sample.pdf"); let word = folder.appendingPathComponent("sample.docx")
        try await DocumentExporter.write(document, format: .pdf, to: pdf)
        try await DocumentExporter.write(document, format: .word, to: word)
        let pdfDocument = try XCTUnwrap(PDFDocument(url: pdf))
        XCTAssertGreaterThan(pdfDocument.pageCount, 1)
        XCTAssertTrue(pdfDocument.string?.contains("English") == true)
        let importedPDF = try await DocumentTransfer.load(pdf)
        XCTAssertGreaterThan(importedPDF.pages[0].blocks.count, 2)
        XCTAssertTrue(importedPDF.pages[0].blocks.contains { $0.kind.isHeading })
        XCTAssertFalse(importedPDF.pages[0].blocks.contains { $0.kind == .pdfDocument })
        XCTAssertTrue(importedPDF.pages[0].blocks.contains { $0.text.contains("English") })
        // Explicit PDF-original blocks remain supported by the exporter.
        let original = TransferDocument(name: "original", pages: [TransferPage(title: "original", blocks: [
            TransferBlock(.pdfDocument, EmbeddedPDF.source(try Data(contentsOf: pdf)))
        ])])
        let reexportedPDF = folder.appendingPathComponent("original-roundtrip.pdf")
        try await DocumentExporter.write(original, format: .pdf, to: reexportedPDF)
        XCTAssertEqual(try Data(contentsOf: reexportedPDF), try Data(contentsOf: pdf))
        let importedWord = try await DocumentTransfer.load(word)
        XCTAssertTrue(importedWord.pages[0].blocks.contains { $0.text.contains("English") })
        XCTAssertTrue(importedWord.pages[0].blocks.contains { $0.kind == .image })
        let plain = folder.appendingPathComponent("sample.txt")
        try await DocumentExporter.write(document, format: .text, to: plain)
        let importedText = try await DocumentTransfer.load(plain)
        XCTAssertTrue(importedText.pages[0].blocks.contains { $0.text.contains("English") })
        XCTAssertFalse(try String(contentsOf: plain, encoding: .utf8).contains("data:image/"))
    }
}
