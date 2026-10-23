import Foundation

struct AIAudioFile {
    let data: Data
    let filename: String
    let mime: String
    static func load(_ url: URL) throws -> Self {
        let access = url.startAccessingSecurityScopedResource()
        defer { if access { url.stopAccessingSecurityScopedResource() } }
        let allowed = ["mp3": "audio/mpeg", "mp4": "audio/mp4", "m4a": "audio/mp4", "wav": "audio/wav", "webm": "audio/webm", "mpeg": "audio/mpeg", "mpga": "audio/mpeg", "ogg": "audio/ogg", "flac": "audio/flac"]
        let ext = url.pathExtension.lowercased()
        guard let mime = allowed[ext] else { throw AppError.message("请选择 MP3、M4A、WAV、WebM、OGG 或 FLAC 音频") }
        let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        guard size > 0, size <= 25 * 1024 * 1024 else { throw AppError.message("音频文件需小于 25 MB 且不能为空") }
        let data = try Data(contentsOf: url)
        guard data.count <= 25 * 1024 * 1024 else { throw AppError.message("音频文件超过 25 MB") }
        return Self(data: data, filename: "audio." + ext, mime: mime)
    }
}

struct AIClient {
    var session: URLSession?
    var readKey: (String) throws -> String = SecretStore.read

    static func endpoint(_ input: String, capability: AICapability) throws -> URL {
        guard var parts = URLComponents(string: input.trimmingCharacters(in: .whitespacesAndNewlines)),
              let host = parts.host, !host.isEmpty, parts.user == nil, parts.password == nil,
              parts.scheme == "https" || (parts.scheme == "http" && ["localhost", "127.0.0.1", "::1", "[::1]"].contains(host)) else {
            throw AppError.message("填写 HTTPS 接口地址；本机 localhost 服务可使用 HTTP")
        }
        let path = parts.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        if path.isEmpty { parts.path = "/v1/" + capability.path }
        else if path.split(separator: "/").last == "v1" { parts.path = "/" + path + "/" + capability.path }
        parts.fragment = nil
        guard let url = parts.url else { throw AppError.message("接口地址无效") }
        return url
    }

    func send(profile: AIModelProfile, body: Data, contentType: String = "application/json") async throws -> Data {
        guard !profile.model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw AppError.message("请配置模型 ID") }
        var request = URLRequest(url: try Self.endpoint(profile.endpoint, capability: profile.capability))
        request.httpMethod = "POST"; request.timeoutInterval = 180
        request.setValue(contentType, forHTTPHeaderField: "Content-Type")
        let key = try readKey(profile.keyAccount)
        if !key.isEmpty { request.setValue("Bearer " + key, forHTTPHeaderField: "Authorization") }
        request.httpBody = body
        let transport = session ?? URLSession(configuration: .ephemeral, delegate: AINoRedirectDelegate(), delegateQueue: nil)
        defer { if session == nil { transport.finishTasksAndInvalidate() } }
        let (data, response) = try await transport.data(for: request)
        guard let response = response as? HTTPURLResponse else { throw AppError.message("接口未返回 HTTP 响应") }
        guard (200...299).contains(response.statusCode) else {
            // Do not echo provider bodies: they can contain credentials or submitted page content.
            let reason: String
            switch response.statusCode {
            case 401, 403: reason = "请检查该模型配置的密钥和权限"
            case 404: reason = "接口路径或模型不存在，请检查地址和模型 ID"
            case 429: reason = "请求限流或额度不足，请稍后重试"
            default: reason = "请检查服务状态和请求参数"
            }
            throw AppError.message(L10n.tr("请求失败（HTTP \(response.statusCode)）：\(L10n.text(reason))"))
        }
        return data
    }

    static func chatBody(profile: AIModelProfile, messages: [[String: Any]]) throws -> Data {
        try JSONSerialization.data(withJSONObject: ["model": profile.model, "messages": messages, "stream": false])
    }
    static func userMessage(_ text: String, image: String? = nil) throws -> [String: Any] {
        guard let image else { return ["role": "user", "content": text] }
        let normalizedImage = try ImageSource.validated(image)
        return ["role": "user", "content": [["type": "text", "text": text], ["type": "image_url", "image_url": ["url": normalizedImage]]]]
    }
    func chat(profile: AIModelProfile, messages: [[String: Any]]) async throws -> String {
        guard [.chat, .vision].contains(profile.capability) else { throw AppError.message("所选模型不是文字或图片理解模型") }
        let data = try await send(profile: profile, body: Self.chatBody(profile: profile, messages: messages))
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let choices = json["choices"] as? [[String: Any]], let message = choices.first?["message"] as? [String: Any] else {
            throw AppError.message("接口响应不符合 Chat Completions 格式")
        }
        if let text = message["content"] as? String { return text }
        if let parts = message["content"] as? [[String: Any]] { return parts.compactMap { $0["text"] as? String }.joined(separator: "\n") }
        throw AppError.message("模型未返回文字内容")
    }
    static func transcriptionBody(profile: AIModelProfile, audio: AIAudioFile, boundary: String) -> Data {
        var body = Data()
        func append(_ text: String) { body.append(Data(text.utf8)) }
        append("--\(boundary)\r\nContent-Disposition: form-data; name=\"model\"\r\n\r\n\(profile.model)\r\n")
        append("--\(boundary)\r\nContent-Disposition: form-data; name=\"file\"; filename=\"\(audio.filename)\"\r\nContent-Type: \(audio.mime)\r\n\r\n")
        body.append(audio.data); append("\r\n--\(boundary)--\r\n")
        return body
    }
    func transcribe(profile: AIModelProfile, audio: AIAudioFile) async throws -> String {
        guard profile.capability == .transcription else { throw AppError.message("请选择语音转文字模型") }
        let boundary = "Velora-" + UUID().uuidString
        let body = Self.transcriptionBody(profile: profile, audio: audio, boundary: boundary)
        let data = try await send(profile: profile, body: body, contentType: "multipart/form-data; boundary=" + boundary)
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any], let text = json["text"] as? String else {
            throw AppError.message("语音接口未返回 text 字段")
        }
        return text
    }
    func generateImage(profile: AIModelProfile, prompt: String) async throws -> String {
        guard profile.capability == .imageGeneration else { throw AppError.message("请选择图片生成模型") }
        let body = try JSONSerialization.data(withJSONObject: ["model": profile.model, "prompt": prompt, "n": 1])
        let data = try await send(profile: profile, body: body)
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let images = json["data"] as? [[String: Any]], let first = images.first else { throw AppError.message("图片接口未返回 data 数组") }
        if let encoded = first["b64_json"] as? String, let bytes = Data(base64Encoded: encoded) { return try ImageSource.embedded(bytes) }
        if let url = first["url"] as? String { return try ImageSource.validated(url) }
        throw AppError.message("图片接口未返回有效图片或 URL")
    }
    static func downloadImage(_ source: String) async throws -> String {
        let value = try ImageSource.validated(source)
        guard let url = URL(string: value), url.scheme != "data" else { return value }
        let session = URLSession(configuration: .ephemeral)
        defer { session.finishTasksAndInvalidate() }
        var request = URLRequest(url: url); request.timeoutInterval = 60
        let (stream, response) = try await session.bytes(for: request)
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode),
              response.expectedContentLength <= ImageSource.maximumBytes else { throw AppError.message("生成图片下载失败或超过 12 MB") }
        var data = Data()
        for try await byte in stream {
            guard data.count < ImageSource.maximumBytes else { throw AppError.message("图片超过 12 MB") }
            data.append(byte)
        }
        return try ImageSource.embedded(data)
    }

    func speech(profile: AIModelProfile, text: String) async throws -> Data {
        guard profile.capability == .speech else { throw AppError.message("请选择语音朗读模型") }
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, text.count <= 4096 else { throw AppError.message("朗读文字需为 1–4096 个字符") }
        let body = try JSONSerialization.data(withJSONObject: ["model": profile.model, "input": text, "voice": profile.voice, "response_format": "mp3"])
        return try await send(profile: profile, body: body)
    }
}

private final class AINoRedirectDelegate: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) { completionHandler(nil) }
}
