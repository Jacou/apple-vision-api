import Foundation
import Network
import FoundationModels
import AppKit
import ImageIO

// MARK: - Apple Intelligence (Foundation Models) vision

@available(macOS 26.0, *)
func appleRespond(prompt: String, imageData: Data?) async throws -> String {
    let session = LanguageModelSession()
    guard let imageData,
          let src = CGImageSourceCreateWithData(imageData as CFData, nil),
          CGImageSourceGetCount(src) > 0 else {
        return try await session.respond(to: prompt).content
    }
    let tmp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".png")
    try imageData.write(to: tmp)
    defer { try? FileManager.default.removeItem(at: tmp) }

    let attachment = Attachment<ImageAttachmentContent>(imageURL: tmp)
    let p = Prompt {
        prompt
        attachment
    }
    return try await session.respond(to: p).content
}

// MARK: - Per-connection state (holds request buffer; avoids inout-in-escaping-closure)

final class ConnState: @unchecked Sendable {
    let conn: NWConnection
    let id = UUID()
    let server: Server
    var buffer = Data()
    var headerEnd: Int = -1
    var method = ""
    var path = "/"
    var contentLength = 0

    init(conn: NWConnection, server: Server) { self.conn = conn; self.server = server }

    func start() {
        conn.start(queue: .global(qos: .userInitiated))
        receive()
    }

    private func receive() {
        conn.receive(minimumIncompleteLength: 1, maximumLength: 1 << 20) { [weak self] (data: Data?, _ ctx: NWConnection.ContentContext?, _ isComplete: Bool, error: NWError?) in
            guard let self else { return }
            if let data { self.buffer.append(data) }
            if error != nil || isComplete { self.finish() }
            else { self.tryParse() }
        }
    }

    private func tryParse() {
        if headerEnd < 0, let r = buffer.range(of: Data("\r\n\r\n".utf8)) {
            headerEnd = r.upperBound
            let headerStr = String(data: buffer[..<r.lowerBound], encoding: .utf8) ?? ""
            let lines = headerStr.components(separatedBy: "\r\n")
            if let first = lines.first {
                let parts = first.split(separator: " ")
                method = parts.count > 0 ? String(parts[0]) : ""
                path = parts.count > 1 ? String(parts[1]) : "/"
            }
            contentLength = lines.first { $0.lowercased().hasPrefix("content-length:") }
                .map { Int($0.split(separator: ":").last?.trimmingCharacters(in: .whitespaces) ?? "") ?? 0 } ?? 0
        }
        if headerEnd >= 0 && buffer.count >= headerEnd + contentLength {
            let body = buffer.subdata(in: headerEnd..<(headerEnd + contentLength))
            let m = method; let p = path
            Task { await self.server.route(method: m, path: p, body: body, conn: self.conn) }
        } else {
            receive()
        }
    }

    private func finish() {
        server.lock.lock()
        server.states.removeAll { $0.id == id }
        server.lock.unlock()
        conn.cancel()
    }
}

// MARK: - OpenAI-compatible HTTP server (Network.framework)

final class Server: @unchecked Sendable {
    let port: UInt16
    fileprivate let lock = NSLock()
    fileprivate var states = [ConnState]()
    fileprivate var listener: NWListener?

    init(port: UInt16 = 8099) { self.port = port }

    func start() throws {
        let params = NWParameters.tcp
        params.allowLocalEndpointReuse = true
        let listener = try NWListener(using: params, on: NWEndpoint.Port(rawValue: port)!)
        listener.stateUpdateHandler = { (state: NWListener.State) in
            switch state {
            case .ready: print("apple-vision-api listening on 0.0.0.0:\(self.port)", terminator: "\n")
            case .failed(let err): print("listener failed: \(err)", terminator: "\n")
            default: break
            }
        }
        listener.newConnectionHandler = { [weak self] (conn: NWConnection) in
            guard let self else { conn.cancel(); return }
            let st = ConnState(conn: conn, server: self)
            self.lock.lock(); self.states.append(st); self.lock.unlock()
            st.start()
        }
        listener.start(queue: .global(qos: .userInitiated))
        self.listener = listener
    }

    func route(method: String, path: String, body: Data, conn: NWConnection) async {
        do {
            let (status, json) = try await dispatch(method: method, path: path, body: body)
            send(conn, status: status, json: json)
        } catch {
            let msg = "{\"error\":\"\(error.localizedDescription.replacingOccurrences(of: "\"", with: "\\\""))\"}"
            send(conn, status: "500 Internal Server Error", json: msg)
        }
    }

    private func send(_ conn: NWConnection, status: String, json: String) {
        let payload = Data(json.utf8)
        let head = "HTTP/1.1 \(status)\r\nContent-Type: application/json\r\nContent-Length: \(payload.count)\r\nConnection: close\r\n\r\n"
        var out = Data(head.utf8); out.append(payload)
        conn.send(content: out, completion: .contentProcessed { _ in conn.cancel() })
    }

    private func dispatch(method: String, path: String, body: Data) async throws -> (String, String) {
        if path == "/v1/models" || path == "/models" {
            return ("200 OK", #"{"object":"list","data":[{"id":"apple-foundation-vision","object":"model"}]}"#)
        }
        if path == "/health" {
            return ("200 OK", #"{"status":"ok"}"#)
        }
        if method == "POST" && (path == "/v1/chat/completions" || path == "/chat/completions") {
            return ("200 OK", try await chatCompletion(body: body))
        }
        return ("404 Not Found", #"{"error":"not found"}"#)
    }

    private func chatCompletion(body: Data) async throws -> String {
        let obj = try JSONSerialization.jsonObject(with: body) as? [String: Any]
        let messages = (obj?["messages"] as? [[String: Any]]) ?? []
        var text = ""
        var imageData: Data?
        for m in messages where (m["role"] as? String) == "user" {
            let content = m["content"]
            if let s = content as? String {
                text += s + "\n"
            } else if let arr = content as? [[String: Any]] {
                for part in arr {
                    switch part["type"] as? String {
                    case "text": text += (part["text"] as? String ?? "") + "\n"
                    case "image_url":
                        if let url = (part["image_url"] as? [String: Any])?["url"] as? String {
                            if url.hasPrefix("data:") {
                                if let comma = url.firstIndex(of: ","),
                                   let b64 = Data(base64Encoded: String(url[url.index(after: comma)...])
                                        .trimmingCharacters(in: .whitespacesAndNewlines)) {
                                    imageData = b64
                                }
                            } else if let f = FileManager.default.contents(atPath: url) {
                                imageData = f
                            }
                        }
                    default: break
                    }
                }
            }
        }
        let answer = try await appleRespond(prompt: text.trimmingCharacters(in: .whitespacesAndNewlines), imageData: imageData)
        let escaped = answer
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\n", with: "\\n")
        let id = "chatcmpl-\(UUID().uuidString.prefix(8))"
        return """
        {"id":"\(id)","object":"chat.completion","created":\(Int(Date().timeIntervalSince1970)),"model":"apple-foundation-vision","choices":[{"index":0,"message":{"role":"assistant","content":"\(escaped)"},"finish_reason":"stop"}],"usage":{"prompt_tokens":0,"completion_tokens":0,"total_tokens":0}}
        """
    }
}

// MARK: - Main

@main
enum Main {
    static func main() async {
        let portArg = CommandLine.arguments.dropFirst().first
        let port: UInt16 = portArg.flatMap { UInt16($0) } ?? 8099
        let server = Server(port: port)
        do {
            try server.start()
            while true { try await Task.sleep(nanoseconds: 1_000_000_000) }
        } catch {
            print("failed to start: \(error)")
            exit(1)
        }
    }
}
