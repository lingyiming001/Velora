import AppKit
import XCTest
@testable import Velora

private final class AIStubProtocol: URLProtocol {
    static var handler: ((URLRequest) throws -> (Int, Data))?
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        do {
            let (status, data) = try Self.handler!(request)
            let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch { client?.urlProtocol(self, didFailWithError: error) }
    }
    override func stopLoading() { }
}

@MainActor
final class MultimodalTests: XCTestCase {
    private func profile(_ capability: AICapability) -> AIModelProfile {
        var value = AIModelProfile(); value.name = capability.label; value.endpoint = "https://example.com/compatible-mode/v1"
        value.model = "test-model"; value.capability = capability
        return value
    }
    private func client(_ handler: @escaping (URLRequest) throws -> (Int, Data)) -> AIClient {
        AIStubProtocol.handler = handler
        let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [AIStubProtocol.self]
        return AIClient(session: URLSession(configuration: config), readKey: { _ in "test-secret" })
    }
    private func requestBody(_ request: URLRequest) -> Data {
        if let body = request.httpBody { return body }
        guard let stream = request.httpBodyStream else { return Data() }
        stream.open(); defer { stream.close() }
        var data = Data(); var buffer = [UInt8](repeating: 0, count: 4096)
        while stream.hasBytesAvailable {
            let count = stream.read(&buffer, maxLength: buffer.count)
            if count <= 0 { break }; data.append(buffer, count: count)
        }
        return data
    }
    private func png() throws -> Data {
        let bitmap = try XCTUnwrap(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 2, pixelsHigh: 2,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        for x in 0..<2 { for y in 0..<2 { bitmap.setColor(.systemBlue, atX: x, y: y) } }
        return try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
    }

    func testCapabilityEndpoints() throws {
        for capability in AICapability.allCases {
            XCTAssertEqual(try AIClient.endpoint(" https://example.com/compatible-mode/v1/ ", capability: capability).path,
                           "/compatible-mode/v1/" + capability.path)
            XCTAssertEqual(try AIClient.endpoint("http://localhost:11434", capability: capability).path, "/v1/" + capability.path)
        }
        XCTAssertEqual(try AIClient.endpoint("https://example.com/custom?version=1", capability: .speech).absoluteString, "https://example.com/custom?version=1")
        XCTAssertThrowsError(try AIClient.endpoint("http://example.com/v1", capability: .speech))
        XCTAssertThrowsError(try AIClient.endpoint("https://user:password@example.com/v1", capability: .chat))
    }

    func testIndependentModelsMigrationAndPersistence() throws {
        let suite = "VeloraMultimodalTests-" + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set("https://example.com/v1", forKey: "aiEndpoint"); defaults.set("legacy-model", forKey: "aiModel")
        let models = AIModelStore(defaults: defaults)
        XCTAssertEqual(models.selected(for: .chat)?.model, "legacy-model")
        XCTAssertEqual(models.selected(for: .chat)?.keyAccount, "ai-key")
        let vision = profile(.vision); let voice = profile(.speech)
        try models.upsert(vision); try models.upsert(voice)
        var another = profile(.speech); another.name = "另一个朗读模型"; another.model = "second-model"
        try models.upsert(another); models.select(another.id, for: .speech)
        let reloaded = AIModelStore(defaults: defaults)
        XCTAssertEqual(reloaded.profiles.count, 4)
        XCTAssertEqual(reloaded.selected(for: .speech)?.id, another.id)
        XCTAssertEqual(reloaded.selected(for: .vision)?.id, vision.id)
        XCTAssertNotEqual(voice.keyAccount, vision.keyAccount)
        XCTAssertEqual(reloaded.selected(for: .chat)?.model, "legacy-model")
        var invalid = vision; invalid.name = " "; XCTAssertThrowsError(try models.upsert(invalid))
        invalid = another; invalid.name = vision.name; XCTAssertThrowsError(try models.upsert(invalid))
        let stored = try XCTUnwrap(defaults.data(forKey: "aiModelConfiguration.v1"))
        XCTAssertFalse(String(decoding: stored, as: UTF8.self).contains("test-secret"))
    }

    func testChatAndVisionRequestAndResponse() async throws {
        let image = try ImageSource.embedded(png())
        let model = profile(.vision)
        let api = client { request in
            XCTAssertEqual(request.url?.path, "/compatible-mode/v1/chat/completions")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer test-secret")
            let body = try JSONSerialization.jsonObject(with: self.requestBody(request)) as! [String: Any]
            XCTAssertEqual(body["model"] as? String, "test-model")
            let messages = body["messages"] as! [[String: Any]]
            let parts = messages[0]["content"] as! [[String: Any]]
            XCTAssertEqual(parts[0]["text"] as? String, "识别图片")
            XCTAssertEqual((parts[1]["image_url"] as? [String: String])?["url"], image)
            return (200, Data(#"{"choices":[{"message":{"content":"蓝色图片"}}]}"#.utf8))
        }
        let result = try await api.chat(profile: model, messages: [AIClient.userMessage("识别图片", image: image)])
        XCTAssertEqual(result, "蓝色图片")
        XCTAssertThrowsError(try AIClient.userMessage("识别", image: "file:///etc/passwd"))
    }

    func testTranscriptionUsesMultipartAndReturnsText() async throws {
        let model = profile(.transcription)
        let api = client { request in
            XCTAssertEqual(request.url?.path, "/compatible-mode/v1/audio/transcriptions")
            XCTAssertTrue(request.value(forHTTPHeaderField: "Content-Type")?.hasPrefix("multipart/form-data; boundary=Velora-") == true)
            let body = String(decoding: self.requestBody(request), as: UTF8.self)
            XCTAssertTrue(body.contains("name=\"model\"\r\n\r\ntest-model"))
            XCTAssertTrue(body.contains("filename=\"audio.wav\"")); XCTAssertTrue(body.contains("test-audio"))
            return (200, Data(#"{"text":"语音识别结果"}"#.utf8))
        }
        let text = try await api.transcribe(profile: model, audio: AIAudioFile(data: Data("test-audio".utf8), filename: "audio.wav", mime: "audio/wav"))
        XCTAssertEqual(text, "语音识别结果")
    }

    func testImageGenerationAndSpeechRequests() async throws {
        let bytes = try png()
        let images = client { request in
            XCTAssertEqual(request.url?.path, "/compatible-mode/v1/images/generations")
            let body = try JSONSerialization.jsonObject(with: self.requestBody(request)) as! [String: Any]
            XCTAssertEqual(body["prompt"] as? String, "蓝色方块")
            return (200, try JSONSerialization.data(withJSONObject: ["data": [["b64_json": bytes.base64EncodedString()]]]))
        }
        let image = try await images.generateImage(profile: profile(.imageGeneration), prompt: "蓝色方块")
        XCTAssertTrue(image.hasPrefix("data:image/png;base64,")); XCTAssertNotNil(ImageSource.thumbnail(image))
        let speech = client { request in
            XCTAssertEqual(request.url?.path, "/compatible-mode/v1/audio/speech")
            let body = try JSONSerialization.jsonObject(with: self.requestBody(request)) as! [String: Any]
            XCTAssertEqual(body["input"] as? String, "你好"); XCTAssertEqual(body["voice"] as? String, "alloy")
            XCTAssertEqual(body["response_format"] as? String, "mp3")
            return (200, Data("fake-mp3".utf8))
        }
        let audio = try await speech.speech(profile: profile(.speech), text: "你好")
        XCTAssertEqual(audio, Data("fake-mp3".utf8))
    }

    func testFailuresDoNotExposeResponseBody() async throws {
        let api = client { _ in (401, Data("private-key-and-content".utf8)) }
        do { _ = try await api.chat(profile: profile(.chat), messages: [AIClient.userMessage("你好")]); XCTFail("HTTP 401 should fail") }
        catch {
            XCTAssertTrue(error.localizedDescription.contains("401"))
            XCTAssertFalse(error.localizedDescription.contains("private-key"))
        }
        let malformed = client { _ in (200, Data(#"{"wrong":"response"}"#.utf8)) }
        do { _ = try await malformed.chat(profile: profile(.chat), messages: []); XCTFail("Invalid response should fail") }
        catch { XCTAssertTrue(error.localizedDescription.contains("格式")) }
    }

    func testLocalImageSurvivesOriginalRemovalAndDatabaseSnapshot() async throws {
        let directory = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent(".agents/test/Multimodal-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let original = directory.appendingPathComponent("original.png"); try png().write(to: original)
        let image = try ImageSource.load(original)
        try FileManager.default.removeItem(at: original)
        XCTAssertNotNil(ImageSource.thumbnail(image))
        let store = try SQLiteStore(databaseURL: directory.appendingPathComponent("source.sqlite"))
        let page = try await store.createPage()
        let model = WorkspaceModel(store: store); await model.refreshPages()
        try await model.insertMedia(.image, text: image, pageID: page.id)
        XCTAssertFalse(model.automationBusy)
        model.workspaceTransitioning = true
        do { try await model.insertMedia(.image, text: image, pageID: page.id); XCTFail("Insertion during transition must fail") }
        catch { }
        model.workspaceTransitioning = false
        let backupURL = directory.appendingPathComponent("backup.sqlite"); try await store.snapshot(to: backupURL)
        let restored = try SQLiteStore(databaseURL: backupURL)
        let blocks = try await restored.blocks(in: page.id)
        XCTAssertEqual(blocks.first?.text, image)
        XCTAssertNotNil(ImageSource.thumbnail(try XCTUnwrap(blocks.first?.text)))
        XCTAssertThrowsError(try ImageSource.embedded(Data("not an image".utf8)))
        XCTAssertThrowsError(try ImageSource.validated("javascript:alert(1)"))
        XCTAssertEqual(try ImageSource.validated(" https://example.com/photo.png "), "https://example.com/photo.png")
    }
}
