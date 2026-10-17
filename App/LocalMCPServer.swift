import Foundation
import Network

/// Stateless Streamable HTTP transport: JSON responses, GET/SSE intentionally unsupported (405).
@MainActor
final class LocalMCPServer {
    private let listener: NWListener
    private let token: String
    private let port: UInt16
    private let model: WorkspaceModel
    private var connections: [UUID: NWConnection] = [:]
    var onStatus: ((String) -> Void)?

    init(port: UInt16, token: String, model: WorkspaceModel) throws {
        self.token = token; self.port = port; self.model = model
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: port)!)
        listener = try NWListener(using: parameters)
    }

    func start() {
        listener.stateUpdateHandler = { [weak self] state in
            Task { @MainActor in
                switch state {
                case .ready: self?.onStatus?("运行中 · 127.0.0.1:\(self?.port ?? 0)")
                case .failed(let error): self?.onStatus?("启动失败：\(error.localizedDescription)"); self?.stop()
                default: break
                }
            }
        }
        listener.newConnectionHandler = { [weak self] connection in
            Task { @MainActor in
                guard let self, self.connections.count < 16 else { connection.cancel(); return }
                let id = UUID()
                self.connections[id] = connection
                connection.start(queue: .main)
                self.receive(connection, id: id, buffer: Data())
                DispatchQueue.main.asyncAfter(deadline: .now() + 30) { [weak self] in
                    self?.connections[id]?.cancel(); self?.connections[id] = nil
                }
            }
        }
        listener.start(queue: .main)
    }

    func stop() {
        listener.cancel()
        for connection in connections.values { connection.cancel() }
        connections.removeAll()
    }

    private func receive(_ connection: NWConnection, id: UUID, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, complete, error in
            Task { @MainActor in
                guard let self else { connection.cancel(); return }
                var buffer = buffer
                if let data { buffer.append(data) }
                guard buffer.count <= 1_048_576 else { self.reply(connection, id: id, status: 413); return }
                if let split = buffer.range(of: Data("\r\n\r\n".utf8)),
                   let header = String(data: buffer[..<split.lowerBound], encoding: .utf8) {
                    let lines = header.components(separatedBy: "\r\n")
                    var headers: [String: String] = [:]
                    for line in lines.dropFirst() {
                        let parts = line.split(separator: ":", maxSplits: 1).map(String.init)
                        if parts.count == 2 {
                            let key = parts[0].lowercased()
                            if headers[key] != nil { self.reply(connection, id: id, status: 400); return }
                            headers[key] = parts[1].trimmingCharacters(in: .whitespaces)
                        }
                    }
                    guard headers["transfer-encoding"] == nil else { self.reply(connection, id: id, status: 400); return }
                    let length = Int(headers["content-length"] ?? "0") ?? -1
                    guard (0...1_000_000).contains(length) else { self.reply(connection, id: id, status: 413); return }
                    let available = buffer.count - split.upperBound
                    if available >= length {
                        let body = buffer.subdata(in: split.upperBound..<(split.upperBound + length))
                        await self.handle(connection, id: id, firstLine: lines.first ?? "", headers: headers, body: body)
                        return
                    }
                } else if buffer.count > 16384 { self.reply(connection, id: id, status: 431); return }
                if complete || error != nil { connection.cancel(); self.connections[id] = nil; return }
                self.receive(connection, id: id, buffer: buffer)
            }
        }
    }

    private func handle(_ connection: NWConnection, id connectionID: UUID, firstLine: String, headers: [String: String], body: Data) async {
        guard UserDefaults.standard.bool(forKey: "mcpEnabled") else { reply(connection, id: connectionID, status: 403); return }
        let parts = firstLine.split(separator: " ")
        guard parts.count == 3, parts[1] == "/mcp" else { reply(connection, id: connectionID, status: 404); return }
        guard headers["authorization"] == "Bearer \(token)" else { reply(connection, id: connectionID, status: 401); return }
        if let origin = headers["origin"], !["http://127.0.0.1:\(port)", "http://localhost:\(port)"].contains(origin) {
            reply(connection, id: connectionID, status: 403); return
        }
        guard parts[0] == "POST" else { reply(connection, id: connectionID, status: 405); return }
        let supported = ["2025-03-26", "2025-06-18", "2025-11-25"]
        if let version = headers["mcp-protocol-version"], !supported.contains(version) { reply(connection, id: connectionID, status: 400); return }
        guard headers["content-type"]?.lowercased().hasPrefix("application/json") == true,
              let request = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
              request["jsonrpc"] as? String == "2.0", let method = request["method"] as? String else {
            reply(connection, id: connectionID, status: 400); return
        }
        guard let requestID = request["id"] else { reply(connection, id: connectionID, status: 202); return }
        let params = request["params"] as? [String: Any] ?? [:]
        var response: [String: Any] = ["jsonrpc": "2.0", "id": requestID]
        switch method {
        case "initialize":
            let requested = params["protocolVersion"] as? String ?? "2025-11-25"
            response["result"] = ["protocolVersion": supported.contains(requested) ? requested : "2025-11-25",
                "capabilities": ["tools": ["listChanged": false]],
                "serverInfo": ["name": "velora", "version": "0.1.0"],
                "instructions": "Control the local Velora workspace. Writes require the user to enable MCP write access in Velora settings."] as [String: Any]
        case "ping": response["result"] = [:] as [String: Any]
        case "tools/list":
            let writeEnabled = UserDefaults.standard.bool(forKey: "mcpAllowWrites")
            response["result"] = ["tools": WorkspaceModel.automationTools.filter { writeEnabled || ["list_pages", "read_page"].contains($0["name"] as? String ?? "") }]
        case "tools/call":
            do {
                guard let name = params["name"] as? String,
                      WorkspaceModel.automationTools.contains(where: { $0["name"] as? String == name }) else { throw AppError.message("未知工具") }
                if !["list_pages", "read_page"].contains(name), !UserDefaults.standard.bool(forKey: "mcpAllowWrites") {
                    throw AppError.message("外部写入已关闭，请在 Velora 设置中启用")
                }
                let raw = params["arguments"] as? [String: Any] ?? [:]
                guard raw.values.allSatisfy({ $0 is String }) else { throw AppError.message("工具参数必须为字符串") }
                let output = try await model.executeTool(name, arguments: raw.mapValues { $0 as! String })
                let text = String(decoding: try JSONSerialization.data(withJSONObject: output, options: [.sortedKeys]), as: UTF8.self)
                response["result"] = ["content": [["type": "text", "text": text]], "isError": false] as [String: Any]
            } catch {
                response["result"] = ["content": [["type": "text", "text": error.localizedDescription]], "isError": true] as [String: Any]
            }
        default: response["error"] = ["code": -32601, "message": "Method not found"]
        }
        reply(connection, id: connectionID, status: 200, object: response)
    }

    private func reply(_ connection: NWConnection, id: UUID, status: Int, object: [String: Any]? = nil) {
        let body = object.flatMap { try? JSONSerialization.data(withJSONObject: $0) } ?? Data()
        let reason = [200: "OK", 202: "Accepted", 400: "Bad Request", 401: "Unauthorized", 403: "Forbidden", 404: "Not Found", 405: "Method Not Allowed", 413: "Content Too Large", 431: "Headers Too Large"][status] ?? "Error"
        let header = "HTTP/1.1 \(status) \(reason)\r\nContent-Type: application/json\r\nContent-Length: \(body.count)\r\nConnection: close\r\nCache-Control: no-store\r\n\r\n"
        connection.send(content: Data(header.utf8) + body, completion: .contentProcessed { [weak self] _ in
            connection.cancel()
            Task { @MainActor in self?.connections[id] = nil }
        })
    }
}
